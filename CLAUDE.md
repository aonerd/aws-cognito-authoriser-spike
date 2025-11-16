# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a spike/proof-of-concept project demonstrating AWS Cognito authentication with API Gateway HTTP API (v2) using JWT authorizers. The project is infrastructure-as-code using CloudFormation.

## Architecture

The spike creates an end-to-end authentication flow:

1. **Cognito User Pool**: Manages user authentication with email-based usernames
2. **API Gateway HTTP API (v2)**: Modern HTTP API with two routes:
   - `GET /public` - No authentication required
   - `GET /secure` - Requires valid JWT from Cognito
3. **JWT Authorizer**: Validates JWTs using Cognito as the issuer, with the User Pool Client ID as the audience
4. **Lambda Backend**: Simple Node.js 20.x function that returns JWT claims and request metadata

Key architectural decisions:
- Uses HTTP API (v2) not REST API - simpler, cheaper, better for JWT auth
- JWT authorizer validates tokens against Cognito issuer URL
- ID tokens (not access tokens) are used as they contain user claims
- Identity source is the `Authorization` header
- Lambda receives decoded JWT claims in `event.requestContext.authorizer.jwt.claims`

## Deployment Commands

Deploy the stack:
```bash
aws cloudformation deploy \
  --template-file cognito-api-spike.yaml \
  --stack-name cognito-api-spike \
  --capabilities CAPABILITY_IAM \
  --region us-east-1
```

Get stack outputs:
```bash
aws cloudformation describe-stacks \
  --stack-name cognito-api-spike \
  --region us-east-1 \
  --query 'Stacks[0].Outputs'
```

Delete the stack:
```bash
aws cloudformation delete-stack \
  --stack-name cognito-api-spike \
  --region us-east-1
```

## Testing Workflow

Extract output values:
```bash
USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name cognito-api-spike --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name cognito-api-spike --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`UserPoolClientId`].OutputValue' --output text)
API_URL=$(aws cloudformation describe-stacks --stack-name cognito-api-spike --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text)
```

Create test user:
```bash
aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID \
  --username testuser@example.com \
  --user-attributes Name=email,Value=testuser@example.com Name=email_verified,Value=true \
  --temporary-password TempPass123! \
  --message-action SUPPRESS \
  --region us-east-1

aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username testuser@example.com \
  --password MySecurePass123! \
  --permanent \
  --region us-east-1
```

Authenticate and get tokens:
```bash
AUTH_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD=MySecurePass123! \
  --region us-east-1)

ID_TOKEN=$(echo $AUTH_RESPONSE | jq -r '.AuthenticationResult.IdToken')
ACCESS_TOKEN=$(echo $AUTH_RESPONSE | jq -r '.AuthenticationResult.AccessToken')
```

Test endpoints:
```bash
# Public endpoint (no auth)
curl -X GET "${API_URL}/public"

# Secure endpoint (without token - should return 401)
curl -X GET "${API_URL}/secure"

# Secure endpoint (with ID token - should succeed)
curl -X GET "${API_URL}/secure" -H "Authorization: Bearer ${ID_TOKEN}"
```

## Important Notes

- The User Pool App Client uses `USER_PASSWORD_AUTH` flow (no client secret)
- No Hosted UI or Cognito domain is configured - this is a minimal spike
- JWT authorizer expects `Authorization: Bearer <token>` header format
- Use the **ID token** for API calls (contains user claims), not the access token
- Lambda function logs full event to CloudWatch for debugging
- All resources are self-contained in the CloudFormation template with no parameters
