#!/usr/bin/env bash
# Generate curl command to test access token with Cognito API

set -euo pipefail

STACK_NAME="cognito-api-spike"
REGION="us-east-1"
USERNAME="testuser@example.com"
PASSWORD="MySecurePass123!"

echo "🔄 Getting fresh access token from Cognito..."

# Get stack outputs
USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`UserPoolClientId`].OutputValue' --output text)
API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text)

# Authenticate and get access token
AUTH_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
  --region "$REGION")

ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.AuthenticationResult.AccessToken')

if [ -z "$ACCESS_TOKEN" ]; then
  echo "❌ Failed to get access token"
  exit 1
fi

echo "✅ Access token obtained successfully!"
echo ""
echo "📋 Copy and run this curl command:"
echo ""
echo "curl -X GET \"${API_URL}/secure\" \\"
echo "  -H \"Authorization: Bearer ${ACCESS_TOKEN}\" \\"
echo "  -H \"Content-Type: application/json\" | jq ."
echo ""
echo "🔗 Or test it now:"

# Test the access token immediately
echo ""
echo "🧪 Testing access token..."
RESPONSE=$(curl -s -X GET "${API_URL}/secure" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json")

echo "$RESPONSE" | jq .

# Check if successful
if echo "$RESPONSE" | jq -e '.authenticated == true' >/dev/null 2>&1; then
  echo ""
  echo "✅ Success! Access token is working."
  echo "📊 Key claims in access token:"
  echo "$RESPONSE" | jq -r '.claims | "- Token Use: \(.token_use)\n- Scope: \(.scope)\n- Username: \(.username)\n- Client ID: \(.client_id)"'
else
  echo ""
  echo "❌ Access token test failed"
fi
