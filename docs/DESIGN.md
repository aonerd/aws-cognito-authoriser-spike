# Cognito + API Gateway Spike: Design Document

Date: 2025-11-16

## 1. Objectives

- Prove end-to-end authentication using Amazon Cognito User Pools with API Gateway HTTP API (v2) and Lambda.
- Compare behavior with API Gateway JWT Authorizer vs a custom Lambda Authorizer.
- Specifically validate logout behavior (token revocation) and ensure logged-out tokens are denied.
- Provide repeatable automation and concise manual test steps.

## 2. High-level Architecture

```
Client ──► API Gateway (HTTP API v2)
              ├─ Route: GET /public (no auth) ─► Lambda Backend
              └─ Route: GET /secure (auth)
                   ├─ Option A: JWT Authorizer (stateless)
                   └─ Option B: Lambda Authorizer (revocation-aware)

Cognito User Pool ◄─(authenticate / sign-out)── Client, AWS CLI
CloudWatch Logs ◄─(logs from authorizer + backend)─ API Gateway/Lambda
```

- Option A (default): API Gateway JWT Authorizer verifies signature/issuer/audience/exp only; does not consult Cognito for revocation → logged-out tokens remain valid until expiry.
- Option B (spike): Custom Lambda Authorizer performs minimal claim checks and then calls Cognito `GetUser` with the Access token to verify it is still valid (revocation-aware).

## 3. Provisioning (CloudFormation)

Two templates are provided:
- `cognito-api-spike.yaml`: Baseline stack using JWT Authorizer.
- `cognito-api-spike-lambda-authorizer.yaml`: Variant using a custom Lambda Authorizer.

Common resources:
- Cognito User Pool + App Client
- API Gateway HTTP API v2
- Lambda Backend for business logic
- Routes: `GET /public` (unauthenticated) and `GET /secure` (authenticated)

Additional for Lambda Authorizer variant:
- `AuthorizerFunction` (Python 3.11, inline) + IAM role with `cognito-idp:GetUser`
- API Gateway Authorizer (REQUEST type) targeting the Lambda
- Backend updated to read claims from `requestContext.authorizer.lambda`

## 4. Lambda Authorizer Design (Revocation-aware)

### 4.1 Why a Lambda Authorizer?
API Gateway’s JWT Authorizer is stateless: it validates the JWT cryptographically (signature and standard claims), but it cannot know if the user logged out after token issuance. Therefore, a JWT remains valid until `exp`, even post-logout. The Lambda Authorizer mitigates this by consulting Cognito in real-time.

### 4.2 Contract
- Input: HTTP request with `Authorization: Bearer <token>` header.
- Token type required for authorization: Cognito Access token.
- Output: IAM Allow or Deny policy, with minimal claims in context when allowed.
- Error mode: Fail closed (deny) on any validation or runtime error.

### 4.3 Processing Steps
1. Extract `Authorization` header and remove `Bearer ` prefix.
2. Decode JWT payload (base64url) to obtain claims (no external library, avoid layers).
3. Validate minimal claims:
   - `exp` in the future (reject expired tokens)
   - `iss` equals `https://cognito-idp.<region>.amazonaws.com/<userPoolId>`
   - `token_use` is `access` (ID tokens are denied because revocation check requires Access token)
4. Revocation check (critical): call `cognito-idp:GetUser` with the token in `AccessToken`.
   - If Cognito returns user → token is valid (not revoked)
   - If Cognito returns `NotAuthorizedException` → token is revoked/invalid → deny
5. Build an IAM policy (Allow/Deny). On Allow, propagate a minimal subset of claims to the backend via authorizer context.

> Note: We intentionally avoid heavy JWT libraries and signature verification here and rely on Cognito’s `GetUser` to validate authenticity of the Access token. We still perform basic `exp/iss/token_use` checks to fail fast and reduce unnecessary Cognito calls.

### 4.4 Pseudocode (simplified)

```python
# Inputs: event.headers['authorization']
# Env: USER_POOL_ID, REGION

token = extract_bearer(event.headers.get('authorization'))
claims = decode_base64url_payload(token)

if not validate_exp_iss_use(claims, USER_POOL_ID, REGION):
    return deny()

try:
    cognito.get_user(AccessToken=token)
except cognito.exceptions.NotAuthorizedException:
    return deny()  # revoked/invalid

return allow_with_context(minimal_claims(claims))
```

### 4.5 Why Access token (not ID token)?
- Cognito’s `GetUser` API only accepts Access tokens. There is no equivalent revocation check for ID tokens.
- Result: the Lambda Authorizer enforces Access tokens for `/secure`. ID tokens will be denied.

### 4.6 Failure Modes & Responses
- Missing/empty `Authorization` → 401/403 (Deny)
- Invalid base64/JWT structure → 401/403 (Deny)
- `exp` in past → 401/403 (Deny)
- Issuer mismatch → 401/403 (Deny)
- `token_use` != `access` → 401/403 (Deny)
- `GetUser` returns NotAuthorizedException (revoked/invalid) → 401/403 (Deny)
- Any exception (timeouts, IAM issues) → 401/403 (Deny, fail closed)

### 4.7 Performance Considerations
- Each authorized call performs a `GetUser` call to Cognito (regional): adds ~tens of milliseconds.
- If needed, consider short-lived positive caching (e.g., 30–60s keyed by `jti`/`sub`) with careful trade-offs.
- Timeouts: Authorizer Lambda timeout is 10s (default in template). Keep under API Gateway authorizer limits.

### 4.8 Operational Concerns
- Logs: `/aws/lambda/<authorizer-fn-name>` contains allow/deny & error logging.
- Metrics: Add CloudWatch metrics filters for Deny counts, NotAuthorizedException rates.
- Limits: Authorizer context size is limited; we pass only essential fields.

## 5. Backend Lambda Behavior
- `/public`: no authorizer; backend sets `authenticated: false` when no context.
- `/secure`: expects authorizer context; backend echoes a minimal set of claims.

Example backend response (authorized):
```json
{
  "message": "Success",
  "authenticated": true,
  "claims": {
    "sub": "...",
    "username": "...",
    "token_use": "access"
  },
  "authorizerType": "Lambda",
  "path": "/secure",
  "method": "GET",
  "timestamp": "..."
}
```

## 6. Auth & Logout Flows

### 6.1 Secure request with Lambda Authorizer
```
Client ── GET /secure (Authorization: Bearer <access>) ──► API GW
  ► Lambda Authorizer
     1) decode+validate claims
     2) cognito-idp:GetUser(AccessToken)
     3) Allow policy + context
  ► Backend Lambda (business logic)
  ◄── 200 { authenticated: true, claims, ... }
```

### 6.2 Logout revocation
```
Client/CLI ── global-sign-out(accessToken) ─► Cognito

Later:
Client ── GET /secure (Authorization: old access) ──► API GW
  ► Lambda Authorizer
     cognito-idp:GetUser(AccessToken=old) → NotAuthorizedException
     Deny policy
  ◄── 401/403 { message: Unauthorized/Forbidden }
```

> Propagation: A short 2–3s delay after logout is recommended before testing the revoked token.

## 7. Security Discussion

- JWT Authorizer limitation (stateless) ⇒ cannot detect logout; tokens valid until `exp`.
- Lambda Authorizer enforces revocation by consulting Cognito in real time.
- We fail closed on errors and keep the claims surface small.
- Only Access tokens are accepted for `/secure` in the Lambda Authorizer variant.
- Alternatives & Enhancements:
  - Shorten token TTLs (e.g., 15 min) to reduce exposure window.
  - Add signature verification with JWKS (PyJWT/python-jose) if you need ID-token acceptance; revocation still requires another mechanism.
  - Implement a token blacklist (DynamoDB/Redis) for immediate invalidation without external calls.

See `SECURITY_ANALYSIS.md` for deeper trade-offs and options.

## 8. Deployment & Environments

- JWT Authorizer stack: `cognito-api-spike.yaml` (stack name: `cognito-api-spike`)
- Lambda Authorizer stack: `cognito-api-spike-lambda-authorizer.yaml` (stack name: `cognito-api-spike-lambda`)

Helper scripts
- `deploy_and_test.sh`: JWT authorizer stack end-to-end
- `test_access_token.sh`: Retrieve Access token and test `/secure`
- `test_logout_security.sh`: Validate JWT authorizer behavior post-logout
- `deploy_lambda_authorizer.sh`: Deploy/test Lambda Authorizer stack (includes revocation test)

## 9. Manual Testing (Lambda Authorizer)

Use the Access token (required by `GetUser`).

```bash
# Load stack outputs
export STACK=cognito-api-spike-lambda
export REGION=us-east-1
export API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
export USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
export CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)

# Authenticate
export USERNAME="testuser@example.com"
export PASSWORD="MySecurePass123!"
AUTH_JSON=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT_ID" --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" --region "$REGION")
export ACCESS_TOKEN=$(echo "$AUTH_JSON" | jq -r '.AuthenticationResult.AccessToken')

# Before logout: expect 200
curl -s -o /dev/null -w "Secure (with token) -> HTTP %{http_code}\n" \
  -H "Authorization: Bearer $ACCESS_TOKEN" "$API_URL/secure"

# Logout (revoke) and wait
aws cognito-idp global-sign-out --access-token "$ACCESS_TOKEN" --region "$REGION"
sleep 3

# After logout (same token): expect 401/403
curl -s -o /dev/null -w "Secure (revoked token) -> HTTP %{http_code}\n" \
  -H "Authorization: Bearer $ACCESS_TOKEN" "$API_URL/secure"

# Fresh token should work again
AUTH_JSON2=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT_ID" --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" --region "$REGION")
NEW_ACCESS_TOKEN=$(echo "$AUTH_JSON2" | jq -r '.AuthenticationResult.AccessToken')

curl -s -o /dev/null -w "Secure (fresh token) -> HTTP %{http_code}\n" \
  -H "Authorization: Bearer $NEW_ACCESS_TOKEN" "$API_URL/secure"
```

## 10. Observability (Debugging)

- Authorizer logs: `aws logs tail /aws/lambda/<authorizer-fn> --since 5m --region <region>`
  - Common errors: missing `jose` (if using a library), invalid JWT structure, NotAuthorizedException
- Backend logs: `aws logs tail /aws/lambda/<backend-fn> --since 5m`
- API Gateway metrics: 4XX/5XX spikes on `/secure` can indicate token/authorizer issues

## 11. Known Limitations

- Lambda Authorizer requires Access tokens; ID tokens will be denied (no revocation check for ID tokens).
- Authorizer adds extra latency + cost (Cognito call per request). Consider caching if appropriate.
- The inline code does minimal claim checks; signature verification is delegated to Cognito via `GetUser`.

## 12. Future Enhancements

- Add optional JWKS signature verification (PyJWT/python-jose) via a Lambda layer
- Introduce positive cache for `GetUser` results (very short TTL) with eviction on logout hooks
- Provide a parameterized template toggle between JWT and Lambda authorizers
- Add structured metrics (success/deny) and alarms

---

References:
- README.md — Quickstart, scripts, curl recipes
- SECURITY_ANALYSIS.md — Revocation limitation, options, and recommendations
- cognito-api-spike-lambda-authorizer.yaml — Lambda Authorizer template
- deploy_lambda_authorizer.sh — Deploy + validate revocation test

