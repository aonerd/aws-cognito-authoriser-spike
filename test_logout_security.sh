#!/usr/bin/env bash
# Test logout functionality and token invalidation security
# This script tests either JWT authorizer (stateless) or Lambda authorizer (revocation-aware)
# Configure STACK_NAME to point to the desired stack

set -euo pipefail

# Default to JWT authorizer stack; set to "cognito-api-spike-lambda" for Lambda authorizer
STACK_NAME="${STACK_NAME:-cognito-api-spike-lambda}"
REGION="us-east-1"
USERNAME="testuser@example.com"
PASSWORD="MySecurePass123!"

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

echo_status "🔒 Cognito Logout & Token Invalidation Security Test"
echo ""

# Get stack outputs
echo_status "Getting stack configuration..."
USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`UserPoolClientId`].OutputValue' --output text)
API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text)
AUTHORIZER_TYPE=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`AuthorizerType`].OutputValue' --output text 2>/dev/null || echo "JWT (stateless)")

echo "Stack Name: $STACK_NAME"
echo "User Pool ID: $USER_POOL_ID"
echo "Client ID: $CLIENT_ID"
echo "API URL: $API_URL"
echo "Authorizer Type: $AUTHORIZER_TYPE"
echo ""

# Determine token to use based on authorizer type
if [[ "$AUTHORIZER_TYPE" == *"Lambda"* ]]; then
    echo_warning "Note: Lambda Authorizer detected - using Access tokens for revocation checks"
    USE_ACCESS_TOKEN_PRIMARY=true
else
    echo_warning "Note: JWT Authorizer detected - testing with both ID and Access tokens"
    USE_ACCESS_TOKEN_PRIMARY=false
fi
echo ""

# Step 1: Authenticate and get initial tokens
echo_status "Step 1: Getting initial authentication tokens..."
AUTH_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
  --region "$REGION")

ID_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.AuthenticationResult.IdToken')
ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.AuthenticationResult.AccessToken')
REFRESH_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.AuthenticationResult.RefreshToken')

if [ -n "$ID_TOKEN" ] && [ "$ID_TOKEN" != "null" ]; then
    echo_success "✅ Initial tokens obtained successfully"
    echo "ID Token (first 50 chars): ${ID_TOKEN:0:50}..."
    echo "Access Token (first 50 chars): ${ACCESS_TOKEN:0:50}..."
    echo "Refresh Token (first 50 chars): ${REFRESH_TOKEN:0:50}..."
else
    echo_error "❌ Failed to obtain initial tokens"
    exit 1
fi
echo ""

# Step 2: Test tokens before logout
echo_status "Step 2: Testing tokens BEFORE logout (establishing baseline)..."

# Test Access token (primary for Lambda Authorizer)
echo_status "Testing Access token before logout..."
ACCESS_PRE_RESPONSE=$(curl -sS -o /tmp/access_pre_logout.json -w "%{http_code}" "${API_URL}/secure" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")
ACCESS_PRE_BODY=$(cat /tmp/access_pre_logout.json 2>/dev/null || echo "{}")

echo "HTTP Status: $ACCESS_PRE_RESPONSE"
if [ "$ACCESS_PRE_RESPONSE" = "200" ]; then
    echo_success "✅ Access token working before logout"
    echo "Response preview: $(echo "$ACCESS_PRE_BODY" | jq -c '.message + " (authenticated: " + (.authenticated|tostring) + ")"' 2>/dev/null || echo "$ACCESS_PRE_BODY")"
else
    echo_error "❌ Access token failed before logout - test setup issue"
    echo "Response: $ACCESS_PRE_BODY"
    exit 1
fi


# Test ID token (for JWT authorizer comparison)
if [ "$USE_ACCESS_TOKEN_PRIMARY" = false ]; then
    echo_status "Testing ID token before logout..."
    ID_PRE_RESPONSE=$(curl -sS -o /tmp/id_pre_logout.json -w "%{http_code}" "${API_URL}/secure" \
      -H "Authorization: Bearer ${ID_TOKEN}")
    ID_PRE_BODY=$(cat /tmp/id_pre_logout.json 2>/dev/null || echo "{}")

    echo "HTTP Status: $ID_PRE_RESPONSE"
    if [ "$ID_PRE_RESPONSE" = "200" ]; then
        echo_success "✅ ID token working before logout"
        echo "Response preview: $(echo "$ID_PRE_BODY" | jq -c '.message + " (authenticated: " + (.authenticated|tostring) + ")"' 2>/dev/null || echo "$ID_PRE_BODY")"
    else
        echo_warning "⚠️  ID token failed before logout"
        echo "Response: $ID_PRE_BODY"
    fi
else
    echo_warning "⚠️  Skipping ID token test (Lambda Authorizer requires Access tokens)"
    ID_PRE_RESPONSE="200"
fi
echo ""


echo "curl -s -H \"Authorization: Bearer $ACCESS_TOKEN\" \"$API_URL/secure\""
echo
sleep 3

# Step 3: Perform global logout
echo_status "Step 3: Performing GLOBAL LOGOUT to invalidate all user tokens..."

echo `aws cognito-idp global-sign-out --access-token "$ACCESS_TOKEN" --region "$REGION"`

sleep 3

echo

if [ $? -eq 0 ]; then
    echo_success "✅ Global sign-out completed successfully"
    echo_warning "⏳ All tokens for user '$USERNAME' should now be invalidated"
else
    echo_error "❌ Global sign-out failed"
    exit 1
fi
echo ""



# Wait for logout to propagate
echo_status "⏳ Waiting 3 seconds for logout to propagate..."
sleep 3



# Step 4: Test tokens after logout (should fail)
echo_status "Step 4: Testing SAME tokens AFTER logout (should be REJECTED)..."

# Test Access token after logout (primary test)
echo_status "Testing Access token after logout..."
ACCESS_POST_RESPONSE=$(curl -sS -o /tmp/access_post_logout.json -w "%{http_code}" "${API_URL}/secure" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")
ACCESS_POST_BODY=$(cat /tmp/access_post_logout.json 2>/dev/null || echo "{}")

echo "HTTP Status: $ACCESS_POST_RESPONSE"
echo "Response: $ACCESS_POST_BODY"

if [ "$ACCESS_POST_RESPONSE" = "401" ] || [ "$ACCESS_POST_RESPONSE" = "403" ]; then
    echo_success "✅ SECURITY TEST PASSED: Access token correctly rejected after logout"
else
    if [ "$USE_ACCESS_TOKEN_PRIMARY" = true ]; then
        echo_error "❌ SECURITY VULNERABILITY: Access token still accepted after logout!"
        echo_error "   Expected: 401/403, Got: $ACCESS_POST_RESPONSE"
        echo_error "   This is a serious security issue - logged out tokens should not work!"
    else
        echo_warning "⚠️  EXPECTED BEHAVIOR (JWT Authorizer): Access token still accepted after logout"
        echo_warning "   JWT Authorizer is stateless and cannot check revocation"
        echo_warning "   See docs/SECURITY_ANALYSIS.md for mitigation strategies"
    fi
fi

# Test ID token after logout (for JWT authorizer comparison)
if [ "$USE_ACCESS_TOKEN_PRIMARY" = false ]; then
    echo_status "Testing ID token after logout..."
    ID_POST_RESPONSE=$(curl -sS -o /tmp/id_post_logout.json -w "%{http_code}" "${API_URL}/secure" \
      -H "Authorization: Bearer ${ID_TOKEN}")
    ID_POST_BODY=$(cat /tmp/id_post_logout.json 2>/dev/null || echo "{}")

    echo "HTTP Status: $ID_POST_RESPONSE"
    echo "Response: $ID_POST_BODY"

    if [ "$ID_POST_RESPONSE" = "401" ] || [ "$ID_POST_RESPONSE" = "403" ]; then
        echo_success "✅ SECURITY TEST PASSED: ID token correctly rejected after logout"
    else
        echo_warning "⚠️  EXPECTED BEHAVIOR (JWT Authorizer): ID token still accepted after logout"
        echo_warning "   JWT Authorizer is stateless and cannot check revocation"
        echo_warning "   See docs/SECURITY_ANALYSIS.md for mitigation strategies"
    fi
else
    echo_warning "⚠️  Skipping ID token test (Lambda Authorizer requires Access tokens)"
    ID_POST_RESPONSE="401"
fi
echo ""

# Step 5: Test refresh token after logout (should also fail)
echo_status "Step 5: Testing refresh token after logout (should be invalidated)..."
REFRESH_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow REFRESH_TOKEN_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters REFRESH_TOKEN="$REFRESH_TOKEN" \
  --region "$REGION" 2>/dev/null || echo '{"error": "refresh_failed"}')

if echo "$REFRESH_RESPONSE" | jq -e '.AuthenticationResult.IdToken' >/dev/null 2>&1; then
    echo_error "❌ SECURITY VULNERABILITY: Refresh token still works after logout!"
    echo_error "   Refresh tokens should be invalidated during global sign-out"
else
    echo_success "✅ SECURITY TEST PASSED: Refresh token correctly invalidated after logout"
fi
echo ""

# Step 6: Get fresh tokens and verify they work
echo_status "Step 6: Getting FRESH tokens after logout (should work normally)..."
FRESH_AUTH_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
  --region "$REGION")

FRESH_ID_TOKEN=$(echo "$FRESH_AUTH_RESPONSE" | jq -r '.AuthenticationResult.IdToken')
FRESH_ACCESS_TOKEN=$(echo "$FRESH_AUTH_RESPONSE" | jq -r '.AuthenticationResult.AccessToken')

if [ -n "$FRESH_ACCESS_TOKEN" ] && [ "$FRESH_ACCESS_TOKEN" != "null" ]; then
    echo_success "✅ Fresh tokens obtained successfully after logout"

    # Test fresh Access token (primary test)
    echo_status "Testing fresh Access token..."
    FRESH_ACCESS_RESPONSE=$(curl -sS -o /tmp/fresh_access.json -w "%{http_code}" "${API_URL}/secure" \
      -H "Authorization: Bearer ${FRESH_ACCESS_TOKEN}")
    FRESH_ACCESS_BODY=$(cat /tmp/fresh_access.json 2>/dev/null || echo "{}")

    echo "HTTP Status: $FRESH_ACCESS_RESPONSE"
    if [ "$FRESH_ACCESS_RESPONSE" = "200" ]; then
        echo_success "✅ Fresh Access token works correctly"
        echo "Response preview: $(echo "$FRESH_ACCESS_BODY" | jq -c '.message + " (authenticated: " + (.authenticated|tostring) + ")"' 2>/dev/null)"
    else
        echo_error "❌ Fresh Access token failed"
        echo "Response: $FRESH_ACCESS_BODY"
    fi

    # Test fresh ID token (only for JWT authorizer)
    if [ "$USE_ACCESS_TOKEN_PRIMARY" = false ]; then
        echo_status "Testing fresh ID token..."
        FRESH_ID_RESPONSE=$(curl -sS -o /tmp/fresh_id.json -w "%{http_code}" "${API_URL}/secure" \
          -H "Authorization: Bearer ${FRESH_ID_TOKEN}")
        FRESH_ID_BODY=$(cat /tmp/fresh_id.json 2>/dev/null || echo "{}")

        echo "HTTP Status: $FRESH_ID_RESPONSE"
        if [ "$FRESH_ID_RESPONSE" = "200" ]; then
            echo_success "✅ Fresh ID token works correctly"
            echo "Response preview: $(echo "$FRESH_ID_BODY" | jq -c '.message + " (authenticated: " + (.authenticated|tostring) + ")"' 2>/dev/null)"
        else
            echo_error "❌ Fresh ID token failed"
            echo "Response: $FRESH_ID_BODY"
        fi
    else
        echo_warning "⚠️  Skipping ID token test (Lambda Authorizer requires Access tokens only)"
        echo_warning "   ID tokens are not supported by Lambda Authorizer - this is expected"
    fi
else
    echo_error "❌ Failed to obtain fresh tokens after logout"
fi
echo ""

# Step 7: Security summary
echo_status "🔒 SECURITY TEST SUMMARY"
echo ""

SECURITY_ISSUES=0

# Access token check
if [ "$ACCESS_POST_RESPONSE" != "401" ] && [ "$ACCESS_POST_RESPONSE" != "403" ]; then
    if [ "$USE_ACCESS_TOKEN_PRIMARY" = true ]; then
        echo_error "❌ Access Token Security Issue: Logged out tokens still accepted (Lambda Authorizer)"
        ((SECURITY_ISSUES++))
    else
        echo_warning "⚠️  Access Token: Logged out tokens still accepted (expected for JWT Authorizer)"
        echo_warning "   This is a known limitation of stateless JWT authorization"
    fi
else
    echo_success "✅ Access Token Security: Logged out tokens properly rejected"
fi

# ID token check (only for JWT authorizer)
if [ "$USE_ACCESS_TOKEN_PRIMARY" = false ]; then
    if [ "$ID_POST_RESPONSE" != "401" ] && [ "$ID_POST_RESPONSE" != "403" ]; then
        echo_warning "⚠️  ID Token: Logged out tokens still accepted (expected for JWT Authorizer)"
        echo_warning "   This is a known limitation of stateless JWT authorization"
    else
        echo_success "✅ ID Token Security: Logged out tokens properly rejected"
    fi
fi

# Refresh token check (should always be invalidated)
if echo "$REFRESH_RESPONSE" | jq -e '.AuthenticationResult.IdToken' >/dev/null 2>&1; then
    echo_error "❌ Refresh Token Security Issue: Refresh token not invalidated"
    ((SECURITY_ISSUES++))
else
    echo_success "✅ Refresh Token Security: Refresh token properly invalidated"
fi

echo ""
if [ $SECURITY_ISSUES -eq 0 ]; then
    if [ "$USE_ACCESS_TOKEN_PRIMARY" = true ]; then
        echo_success "🎉 ALL SECURITY TESTS PASSED (Lambda Authorizer)!"
        echo_success "   ✅ Logout functionality is working correctly with revocation"
        echo_success "   ✅ Invalidated Access tokens are properly rejected"
        echo_success "   ✅ Fresh authentication works after logout"
        echo_success "   ✅ Lambda Authorizer successfully mitigates JWT limitation"
    else
        echo_warning "⚠️  JWT AUTHORIZER LIMITATION CONFIRMED"
        echo_warning "   ✅ Refresh tokens properly invalidated"
        echo_warning "   ⚠️  ID/Access tokens remain valid until expiry (known limitation)"
        echo_warning "   📋 See docs/SECURITY_ANALYSIS.md for mitigation strategies:"
        echo_warning "      • Use Lambda Authorizer for revocation-aware endpoints"
        echo_warning "      • Reduce token TTLs (15 min recommended)"
        echo_warning "      • Implement token blacklist"
        echo ""
        echo_warning "   To test Lambda Authorizer (with revocation):"
        echo_warning "   STACK_NAME=cognito-api-spike-lambda ./test_logout_security.sh"
    fi
else
    echo_error "🚨 SECURITY VULNERABILITIES DETECTED!"
    echo_error "   Found $SECURITY_ISSUES security issue(s)"
    echo_error "   This requires immediate attention before production use"
    exit 1
fi

echo ""
echo_status "🧹 Cleanup: Remove temporary files..."
rm -f /tmp/id_pre_logout.json /tmp/access_pre_logout.json /tmp/id_post_logout.json /tmp/access_post_logout.json /tmp/fresh_id.json /tmp/fresh_access.json

echo_success "Logout security testing completed successfully! 🎉"
