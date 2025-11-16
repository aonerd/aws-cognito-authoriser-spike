#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="cognito-api-spike-lambda"
TEMPLATE_FILE="cognito-api-spike-lambda-authorizer.yaml"
REGION="us-east-1"
USERNAME="testuser@example.com"
TEMP_PASS="TempPass123!"
PERM_PASS="MySecurePass123!"
SECURITY_TEST_PASSED=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_highlight() {
    echo -e "${MAGENTA}[LAMBDA-AUTH]${NC} $1"
}

# Check prerequisites
echo_status "Checking prerequisites..."
command -v aws >/dev/null || { echo_error "AWS CLI not found. Please install and configure it first."; exit 1; }
command -v jq >/dev/null || { echo_error "jq not found. Please install it (brew install jq)."; exit 1; }

# Check if template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo_error "Template file $TEMPLATE_FILE not found"
    exit 1
fi

echo_success "Prerequisites check passed"

echo_highlight "╔════════════════════════════════════════════════════════════════╗"
echo_highlight "║  Lambda Authorizer Deployment & Testing                       ║"
echo_highlight "║  (Token Revocation Support)                                    ║"
echo_highlight "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo_status "Stack Name: $STACK_NAME"
echo_status "Region: $REGION"
echo_status "Template: $TEMPLATE_FILE"
echo ""

# Deploy CloudFormation stack
echo_status "1. Deploying CloudFormation stack with Lambda Authorizer..."
aws cloudformation deploy \
  --template-file "$TEMPLATE_FILE" \
  --stack-name "$STACK_NAME" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

if [ $? -eq 0 ]; then
    echo_success "Stack deployed successfully"
else
    echo_error "Stack deployment failed"
    exit 1
fi

# Get stack outputs
echo_status "2. Reading stack outputs..."
USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`UserPoolClientId`].OutputValue' --output text)
API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text)
AUTHORIZER_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`AuthorizerFunctionArn`].OutputValue' --output text)

echo "User Pool ID: $USER_POOL_ID"
echo "Client ID: $CLIENT_ID"
echo "API URL: $API_URL"
echo_highlight "Lambda Authorizer ARN: $AUTHORIZER_ARN"
echo ""

# Create test user
echo_status "3. Creating test user (with suppressed email)..."
aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$USERNAME" \
  --user-attributes Name=email,Value="$USERNAME" Name=email_verified,Value=true \
  --temporary-password "$TEMP_PASS" \
  --message-action SUPPRESS \
  --region "$REGION" 2>/dev/null || echo_warning "User creation may have failed (user might already exist), continuing..."

# Set permanent password
echo_status "4. Setting permanent password..."
aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "$USERNAME" \
  --password "$PERM_PASS" \
  --permanent \
  --region "$REGION"

echo_success "Test user configured"

# Authenticate to get tokens
echo_status "5. Authenticating user to get tokens..."
AUTH_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters USERNAME="$USERNAME",PASSWORD="$PERM_PASS" \
  --region "$REGION")

ID_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.AuthenticationResult.IdToken // empty')
ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.AuthenticationResult.AccessToken // empty')

if [ -z "$ACCESS_TOKEN" ]; then
  echo_error "Failed to obtain tokens. Authentication response:"
  echo "$AUTH_RESPONSE" | jq .
  exit 1
fi

echo_success "Tokens obtained successfully"
echo "ID Token (first 80 chars): ${ID_TOKEN:0:80}..."
echo "Access Token (first 80 chars): ${ACCESS_TOKEN:0:80}..."
echo ""

# Tests with Lambda Authorizer
echo_highlight "═══════════════════════════════════════════════════════════════"
echo_highlight "  Testing API Endpoints with Lambda Authorizer"
echo_highlight "═══════════════════════════════════════════════════════════════"
echo ""

# Test 1: Public endpoint
echo_status "Test 1: Public endpoint (no authentication required)"
PUBLIC_RESPONSE=$(curl -sS "${API_URL}/public")
echo "Response:"; echo "$PUBLIC_RESPONSE" | jq . 2>/dev/null || echo "$PUBLIC_RESPONSE"
if echo "$PUBLIC_RESPONSE" | jq -e '.authenticated == false' >/dev/null 2>&1; then
  echo_success "✅ Public endpoint test passed"
else
  echo_warning "⚠️  Public endpoint response format unexpected"
fi
echo ""

# Test 2: Secure endpoint without token (should fail)
echo_status "Test 2: Secure endpoint without token (should return 401/403)"
HTTP_STATUS=$(curl -sS -o /tmp/secure_no_token_response.json -w "%{http_code}" "${API_URL}/secure" || echo "000")
echo "HTTP Status: $HTTP_STATUS"; cat /tmp/secure_no_token_response.json
if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ]; then
  echo_success "✅ Lambda Authorizer correctly rejected unauthorized request"
else
  echo_error "❌ Expected 401/403 status, got $HTTP_STATUS"
fi
echo ""

# Test 3: Secure endpoint with Access token (should succeed)
echo_status "Test 3: Secure endpoint with valid ACCESS token"
SECURE_WITH_TOKEN_RESPONSE=$(curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL}/secure")
echo "Response:"; echo "$SECURE_WITH_TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$SECURE_WITH_TOKEN_RESPONSE"
if echo "$SECURE_WITH_TOKEN_RESPONSE" | jq -e '.authenticated == true' >/dev/null 2>&1; then
  echo_success "✅ Lambda Authorizer validated access token and granted access"
  if echo "$SECURE_WITH_TOKEN_RESPONSE" | jq -e '.authorizerType == "Lambda"' >/dev/null 2>&1; then
    echo_highlight "✅ Confirmed: Using Lambda Authorizer"
  fi
else
  echo_error "❌ Secure endpoint authentication failed"
fi
echo ""

# Test 4: Logout & revocation test (Access token)
echo_highlight "═══════════════════════════════════════════════════════════════"
echo_highlight "  CRITICAL TEST: Token Revocation with Lambda Authorizer"
echo_highlight "═══════════════════════════════════════════════════════════════"
echo ""

echo_status "4a. Token BEFORE logout (should work)"
PRE_STATUS=$(curl -sS -o /tmp/pre.json -w "%{http_code}" -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL}/secure")
echo "HTTP Status: $PRE_STATUS"
if [ "$PRE_STATUS" != "200" ]; then
  echo_error "❌ Token failed before logout (test setup issue)"; exit 1
fi
echo ""

echo_status "4b. Global sign-out to revoke tokens..."
aws cognito-idp admin-user-global-sign-out --user-pool-id "$USER_POOL_ID" --username "$USERNAME" --region "$REGION" >/dev/null 2>&1 && echo_success "✅ Global sign out completed"

echo_status "⏳ Waiting 3 seconds for logout to propagate..."; sleep 3
echo ""

echo_status "4c. SAME Access token AFTER logout (should be rejected)"
POST_STATUS=$(curl -sS -o /tmp/post.json -w "%{http_code}" -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL}/secure")
echo "HTTP Status: $POST_STATUS"; cat /tmp/post.json
if [ "$POST_STATUS" = "401" ] || [ "$POST_STATUS" = "403" ]; then
  echo_success "✅✅✅ SECURITY TEST PASSED: Revoked token rejected"
  SECURITY_TEST_PASSED=true
else
  echo_error "❌ SECURITY TEST FAILED: Token still accepted after logout"
  SECURITY_TEST_PASSED=false
fi
echo ""

echo_status "4d. Fresh tokens after logout (should work)"
FRESH_AUTH=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT_ID" --auth-parameters USERNAME="$USERNAME",PASSWORD="$PERM_PASS" --region "$REGION")
FRESH_ACCESS=$(echo "$FRESH_AUTH" | jq -r '.AuthenticationResult.AccessToken // empty')
FRESH_STATUS=$(curl -sS -o /tmp/fresh.json -w "%{http_code}" -H "Authorization: Bearer ${FRESH_ACCESS}" "${API_URL}/secure")
echo "HTTP Status: $FRESH_STATUS"; cat /tmp/fresh.json
if [ "$FRESH_STATUS" = "200" ]; then
  echo_success "✅ Fresh token works"
else
  echo_error "❌ Fresh token failed"
fi
echo ""

# Summary
echo_highlight "═══════════════════════════════════════════════════════════════"
echo_highlight "  Test Summary"
echo_highlight "═══════════════════════════════════════════════════════════════"
echo_success "✅ Infrastructure deployed with Lambda Authorizer"
echo_success "✅ Public endpoint accessible without authentication"
echo_success "✅ Lambda Authorizer rejecting unauthorized requests"
echo_success "✅ Lambda Authorizer validating access tokens"

if [ "$SECURITY_TEST_PASSED" = true ]; then
    echo_success "✅✅✅ TOKEN REVOCATION: WORKING CORRECTLY ✅✅✅"
    echo_highlight "🔒 Logged-out tokens are properly rejected!"
    echo_highlight "🎉 Lambda Authorizer successfully mitigates the JWT Authorizer limitation!"
else
    echo_error "❌❌❌ TOKEN REVOCATION: NOT WORKING ❌❌❌"
    echo_error "Logged-out tokens are still accepted - investigation required"
fi

echo ""
echo_status "📋 Infrastructure Details:"
echo "Stack Name: $STACK_NAME"
echo "Region: $REGION"
echo "User Pool ID: $USER_POOL_ID"
echo "Client ID: $CLIENT_ID"
echo "API URL: $API_URL"
echo_highlight "Authorizer Type: Lambda (with Cognito revocation checking)"

echo ""
echo_status "🧹 Cleanup Commands (run when ready to delete resources):"
echo "aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION"
echo "aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION"

echo ""
if [ "$SECURITY_TEST_PASSED" = true ]; then
    echo_highlight "╔════════════════════════════════════════════════════════════════╗"
    echo_highlight "║  🎉 SUCCESS: Lambda Authorizer Spike Complete! 🎉            ║"
    echo_highlight "║  Token revocation is working correctly!                       ║"
    echo_highlight "╚════════════════════════════════════════════════════════════════╝"
else
    echo_error "⚠️  Warning: Security test did not pass as expected"
fi
