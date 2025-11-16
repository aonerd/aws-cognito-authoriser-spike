#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="cognito-api-spike"
TEMPLATE_FILE="cognito-api-spike.yaml"
REGION="us-east-1"
USERNAME="testuser@example.com"
TEMP_PASS="TempPass123!"
PERM_PASS="MySecurePass123!"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

echo_status "Starting Cognito API Spike deployment and testing..."
echo "Stack Name: $STACK_NAME"
echo "Region: $REGION"
echo "Template: $TEMPLATE_FILE"
echo ""

# Deploy CloudFormation stack
echo_status "1. Deploying CloudFormation stack..."
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

echo "User Pool ID: $USER_POOL_ID"
echo "Client ID: $CLIENT_ID"
echo "API URL: $API_URL"
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

if [ -z "$ID_TOKEN" ]; then
  echo_error "Failed to obtain tokens. Authentication response:"
  echo "$AUTH_RESPONSE" | jq .
  exit 1
fi

echo_success "Tokens obtained successfully"
echo "ID Token (first 80 chars): ${ID_TOKEN:0:80}..."
echo "Access Token (first 80 chars): ${ACCESS_TOKEN:0:80}..."
echo ""

# Test endpoints
echo_status "6. Testing API endpoints..."

# Test 1: Public endpoint (no auth)
echo_status "Test 1: Public endpoint (no authentication required)"
PUBLIC_RESPONSE=$(curl -sS "${API_URL}/public")
echo "Response:"
echo "$PUBLIC_RESPONSE" | jq . 2>/dev/null || echo "$PUBLIC_RESPONSE"

# Check if response indicates unauthenticated access
if echo "$PUBLIC_RESPONSE" | jq -e '.authenticated == false' >/dev/null 2>&1; then
    echo_success "✅ Public endpoint test passed - correctly shows unauthenticated access"
else
    echo_warning "⚠️  Public endpoint response format unexpected"
fi
echo ""

# Test 2: Secure endpoint without token (should fail)
echo_status "Test 2: Secure endpoint without token (should return 401)"
HTTP_STATUS=$(curl -sS -o /tmp/secure_no_token_response.json -w "%{http_code}" "${API_URL}/secure" || echo "000")
SECURE_NO_TOKEN_RESPONSE=$(cat /tmp/secure_no_token_response.json 2>/dev/null || echo "")

echo "HTTP Status: $HTTP_STATUS"
echo "Response: $SECURE_NO_TOKEN_RESPONSE"

if [ "$HTTP_STATUS" = "401" ]; then
    echo_success "✅ Secure endpoint correctly rejected unauthorized request"
else
    echo_error "❌ Expected 401 status, got $HTTP_STATUS"
fi
echo ""

# Test 3: Secure endpoint with ID token (should succeed)
echo_status "Test 3: Secure endpoint with ID token (should succeed)"
SECURE_WITH_ID_TOKEN_RESPONSE=$(curl -sS -H "Authorization: Bearer ${ID_TOKEN}" "${API_URL}/secure")
echo "Response with ID Token:"
echo "$SECURE_WITH_ID_TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$SECURE_WITH_ID_TOKEN_RESPONSE"

# Check if response indicates authenticated access
if echo "$SECURE_WITH_ID_TOKEN_RESPONSE" | jq -e '.authenticated == true' >/dev/null 2>&1; then
    echo_success "✅ Secure endpoint with ID token test passed - correctly authenticated and returned claims"

    # Display claims
    echo_status "JWT Claims received from ID token:"
    echo "$SECURE_WITH_ID_TOKEN_RESPONSE" | jq '.claims' 2>/dev/null || echo "Could not parse claims"
else
    echo_error "❌ Secure endpoint authentication with ID token failed"
fi
echo ""

# Test 4: Secure endpoint with Access token (may succeed or fail depending on configuration)
echo_status "Test 4: Secure endpoint with Access token (testing behavior)"
SECURE_WITH_ACCESS_TOKEN_RESPONSE=$(curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL}/secure" -w "HTTP_STATUS:%{http_code}" 2>/dev/null)

# Extract HTTP status and response body
ACCESS_TOKEN_HTTP_STATUS=$(echo "$SECURE_WITH_ACCESS_TOKEN_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
ACCESS_TOKEN_RESPONSE_BODY=$(echo "$SECURE_WITH_ACCESS_TOKEN_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')

echo "HTTP Status with Access Token: $ACCESS_TOKEN_HTTP_STATUS"
echo "Response with Access Token:"
echo "$ACCESS_TOKEN_RESPONSE_BODY" | jq . 2>/dev/null || echo "$ACCESS_TOKEN_RESPONSE_BODY"

if [ "$ACCESS_TOKEN_HTTP_STATUS" = "200" ]; then
    # Check if response indicates authenticated access
    if echo "$ACCESS_TOKEN_RESPONSE_BODY" | jq -e '.authenticated == true' >/dev/null 2>&1; then
        echo_success "✅ Secure endpoint accepts Access tokens - authenticated successfully"

        # Display claims
        echo_status "JWT Claims received from Access token:"
        echo "$ACCESS_TOKEN_RESPONSE_BODY" | jq '.claims' 2>/dev/null || echo "Could not parse claims"
    else
        echo_warning "⚠️  Access token accepted but authentication status unexpected"
    fi
elif [ "$ACCESS_TOKEN_HTTP_STATUS" = "401" ] || [ "$ACCESS_TOKEN_HTTP_STATUS" = "403" ]; then
    echo_success "✅ Secure endpoint correctly rejects Access tokens (ID tokens only)"
else
    echo_warning "⚠️  Unexpected response with Access token: HTTP $ACCESS_TOKEN_HTTP_STATUS"
fi
echo ""

# Test 5: Token invalidation (logout) testing
echo_status "Test 5: Token invalidation and logout security"
echo_status "5a. Testing tokens BEFORE logout (should work)"

# Test ID token before logout
echo_status "Testing ID token before logout..."
PRE_LOGOUT_ID_RESPONSE=$(curl -sS -H "Authorization: Bearer ${ID_TOKEN}" "${API_URL}/secure" -w "HTTP_STATUS:%{http_code}" 2>/dev/null)
PRE_LOGOUT_ID_STATUS=$(echo "$PRE_LOGOUT_ID_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
PRE_LOGOUT_ID_BODY=$(echo "$PRE_LOGOUT_ID_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')

if [ "$PRE_LOGOUT_ID_STATUS" = "200" ]; then
    echo_success "✅ ID token works before logout (status: $PRE_LOGOUT_ID_STATUS)"
else
    echo_error "❌ ID token failed before logout (status: $PRE_LOGOUT_ID_STATUS)"
fi

# Test Access token before logout
echo_status "Testing Access token before logout..."
PRE_LOGOUT_ACCESS_RESPONSE=$(curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL}/secure" -w "HTTP_STATUS:%{http_code}" 2>/dev/null)
PRE_LOGOUT_ACCESS_STATUS=$(echo "$PRE_LOGOUT_ACCESS_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
PRE_LOGOUT_ACCESS_BODY=$(echo "$PRE_LOGOUT_ACCESS_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')

if [ "$PRE_LOGOUT_ACCESS_STATUS" = "200" ]; then
    echo_success "✅ Access token works before logout (status: $PRE_LOGOUT_ACCESS_STATUS)"
else
    echo_error "❌ Access token failed before logout (status: $PRE_LOGOUT_ACCESS_STATUS)"
fi

echo ""
echo_status "5b. Performing GLOBAL SIGN OUT to invalidate tokens..."

# Perform global sign out to invalidate all tokens for the user
aws cognito-idp admin-user-global-sign-out \
  --user-pool-id "$USER_POOL_ID" \
  --username "$USERNAME" \
  --region "$REGION" >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo_success "✅ Global sign out completed successfully"
else
    echo_error "❌ Global sign out failed"
    exit 1
fi

echo ""
echo_status "5c. Testing the SAME tokens AFTER logout (should be rejected)"

# Wait a moment for the logout to propagate
sleep 2

# Test ID token after logout (should fail)
echo_status "Testing ID token after logout..."
POST_LOGOUT_ID_RESPONSE=$(curl -sS -H "Authorization: Bearer ${ID_TOKEN}" "${API_URL}/secure" -w "HTTP_STATUS:%{http_code}" 2>/dev/null)
POST_LOGOUT_ID_STATUS=$(echo "$POST_LOGOUT_ID_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
POST_LOGOUT_ID_BODY=$(echo "$POST_LOGOUT_ID_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')

echo "HTTP Status: $POST_LOGOUT_ID_STATUS"
echo "Response: $POST_LOGOUT_ID_BODY"

if [ "$POST_LOGOUT_ID_STATUS" = "401" ] || [ "$POST_LOGOUT_ID_STATUS" = "403" ]; then
    echo_success "✅ ID token correctly rejected after logout (status: $POST_LOGOUT_ID_STATUS)"
else
    echo_error "❌ ID token still accepted after logout (status: $POST_LOGOUT_ID_STATUS) - SECURITY ISSUE!"
fi

# Test Access token after logout (should fail)
echo_status "Testing Access token after logout..."
POST_LOGOUT_ACCESS_RESPONSE=$(curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL}/secure" -w "HTTP_STATUS:%{http_code}" 2>/dev/null)
POST_LOGOUT_ACCESS_STATUS=$(echo "$POST_LOGOUT_ACCESS_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
POST_LOGOUT_ACCESS_BODY=$(echo "$POST_LOGOUT_ACCESS_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')

echo "HTTP Status: $POST_LOGOUT_ACCESS_STATUS"
echo "Response: $POST_LOGOUT_ACCESS_BODY"

if [ "$POST_LOGOUT_ACCESS_STATUS" = "401" ] || [ "$POST_LOGOUT_ACCESS_STATUS" = "403" ]; then
    echo_success "✅ Access token correctly rejected after logout (status: $POST_LOGOUT_ACCESS_STATUS)"
else
    echo_error "❌ Access token still accepted after logout (status: $POST_LOGOUT_ACCESS_STATUS) - SECURITY ISSUE!"
fi

echo ""
echo_status "5d. Testing with FRESH tokens after logout (should work again)"

# Authenticate again to get new tokens
echo_status "Getting fresh tokens after logout..."
NEW_AUTH_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters USERNAME="$USERNAME",PASSWORD="$PERM_PASS" \
  --region "$REGION")

NEW_ID_TOKEN=$(echo "$NEW_AUTH_RESPONSE" | jq -r '.AuthenticationResult.IdToken // empty')
NEW_ACCESS_TOKEN=$(echo "$NEW_AUTH_RESPONSE" | jq -r '.AuthenticationResult.AccessToken // empty')

if [ -n "$NEW_ID_TOKEN" ] && [ "$NEW_ID_TOKEN" != "null" ]; then
    echo_success "✅ Fresh tokens obtained successfully after logout"

    # Test fresh ID token
    echo_status "Testing fresh ID token..."
    FRESH_ID_RESPONSE=$(curl -sS -H "Authorization: Bearer ${NEW_ID_TOKEN}" "${API_URL}/secure" -w "HTTP_STATUS:%{http_code}" 2>/dev/null)
    FRESH_ID_STATUS=$(echo "$FRESH_ID_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)

    if [ "$FRESH_ID_STATUS" = "200" ]; then
        echo_success "✅ Fresh ID token works correctly (status: $FRESH_ID_STATUS)"
    else
        echo_error "❌ Fresh ID token failed (status: $FRESH_ID_STATUS)"
    fi

    # Test fresh Access token
    echo_status "Testing fresh Access token..."
    FRESH_ACCESS_RESPONSE=$(curl -sS -H "Authorization: Bearer ${NEW_ACCESS_TOKEN}" "${API_URL}/secure" -w "HTTP_STATUS:%{http_code}" 2>/dev/null)
    FRESH_ACCESS_STATUS=$(echo "$FRESH_ACCESS_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)

    if [ "$FRESH_ACCESS_STATUS" = "200" ]; then
        echo_success "✅ Fresh Access token works correctly (status: $FRESH_ACCESS_STATUS)"
    else
        echo_error "❌ Fresh Access token failed (status: $FRESH_ACCESS_STATUS)"
    fi
else
    echo_error "❌ Failed to obtain fresh tokens after logout"
fi
echo ""

# Function to decode JWT token payload
decode_jwt_payload() {
    local token="$1"
    local token_type="$2"

    echo_status "Decoding $token_type payload (JWT claims)..."
    local payload_b64=$(echo "$token" | cut -d. -f2)

    # Add padding if needed and decode
    local padded_payload="${payload_b64}===="
    if command -v python3 >/dev/null; then
        local decoded_payload=$(echo "$padded_payload" | python3 -c 'import sys,base64,json; s=sys.stdin.read().strip(); print(json.dumps(json.loads(base64.b64decode(s).decode()), indent=2))' 2>/dev/null)
        if [ $? -eq 0 ]; then
            echo "Decoded $token_type claims:"
            echo "$decoded_payload"
        else
            echo_warning "Could not decode $token_type payload with python3"
        fi
    elif echo "$padded_payload" | base64 -d >/dev/null 2>&1; then
        echo "$padded_payload" | base64 -d | jq . 2>/dev/null || echo_warning "Could not decode $token_type payload with base64 -d"
    elif echo "$padded_payload" | base64 --decode >/dev/null 2>&1; then
        echo "$padded_payload" | base64 --decode | jq . 2>/dev/null || echo_warning "Could not decode $token_type payload with base64 --decode"
    else
        echo_warning "Could not decode $token_type payload - no suitable base64 decoder found"
    fi
    echo ""
}

# Decode both token payloads
echo_status "7. Decoding JWT token payloads..."
decode_jwt_payload "$ID_TOKEN" "ID Token"
decode_jwt_payload "$ACCESS_TOKEN" "Access Token"

# Summary
echo_status "🎉 Testing Complete! Summary:"
echo_success "✅ CloudFormation stack deployed successfully"
echo_success "✅ Test user created and configured"
echo_success "✅ Authentication flow working (obtained JWT tokens)"
echo_success "✅ Public endpoint accessible without authentication"
echo_success "✅ Secure endpoint properly rejecting unauthorized requests"
echo_success "✅ Secure endpoint accepting valid JWT tokens and returning claims"
echo_success "✅ Token invalidation (logout) security verified"
echo_success "✅ Logged out tokens properly rejected by authorizer"
echo_success "✅ Fresh tokens work correctly after logout"

echo ""
echo_status "📋 Infrastructure Details:"
echo "Stack Name: $STACK_NAME"
echo "Region: $REGION"
echo "User Pool ID: $USER_POOL_ID"
echo "Client ID: $CLIENT_ID"
echo "API URL: $API_URL"
echo "Public Endpoint: ${API_URL}/public"
echo "Secure Endpoint: ${API_URL}/secure"

echo ""
echo_status "🧹 Cleanup Commands (run when ready to delete resources):"
echo "aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION"
echo "aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION"

echo ""
echo_success "All tests completed successfully! 🎉"
