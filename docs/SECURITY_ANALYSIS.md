# Security Analysis: JWT Token Revocation Limitation and Mitigation

## 🚨 Critical Finding: API Gateway JWT Authorizer Limitation

### Issue Description
During logout testing, we discovered that API Gateway's built-in JWT authorizer **does not validate token revocation**. When a user performs a global sign-out through Cognito, the tokens become invalid in Cognito's systems, but API Gateway continues to accept them as long as they are cryptographically valid and not expired.

### Test Results (JWT Authorizer)
```bash
# Before logout: ✅ Tokens work (Expected)
curl -H "Authorization: Bearer $TOKEN" /secure -> 200 OK

# After Cognito global sign-out: ❌ Tokens still work (Security Issue)
curl -H "Authorization: Bearer $TOKEN" /secure -> 200 OK (Should be 401/403)

# Refresh token: ✅ Properly invalidated (Expected)
aws cognito-idp initiate-auth --auth-flow REFRESH_TOKEN_AUTH -> FAILED (Correctly rejected)
```

### Root Cause Analysis

**API Gateway JWT Authorizer Behavior:**
1. ✅ Validates JWT signature using Cognito's public keys
2. ✅ Validates expiration time (`exp` claim)
3. ✅ Validates audience (`aud` claim)
4. ✅ Validates issuer (`iss` claim)
5. ❌ **Does NOT check token revocation status with Cognito**

**Why This Happens:**
- API Gateway JWT authorizer performs **stateless validation**
- No real-time communication with Cognito to check revocation
- Designed for performance - avoids additional API calls
- Common limitation in JWT-based systems

### Security Impact

**High Risk Scenarios:**
1. **Stolen Device:** If a user's device is stolen and they perform logout, the tokens on the device remain valid
2. **Compromised Session:** Attackers with valid tokens can continue access even after user logout
3. **Employee Termination:** Terminated employees' tokens remain valid until natural expiration
4. **Security Breach Response:** Emergency logouts don't immediately invalidate existing tokens

**Default Token Lifespan (baseline template):**
- **Access Tokens:** 60 minutes
- **ID Tokens:** 60 minutes  
- **Refresh Tokens:** 30 days (but are invalidated on global sign-out)

---

## ✅ Implemented Mitigation in This Spike: Revocation-aware Lambda Authorizer

We added an alternative stack that replaces the JWT Authorizer with a **Lambda Authorizer** and validates revocation at request time by calling Cognito.

- Template: `cognito-api-spike-lambda-authorizer.yaml`
- Deploy/test script: `deploy_lambda_authorizer.sh`
- Stack name: `cognito-api-spike-lambda`

### How It Works (Summary)
- Accepts only Cognito **Access tokens** for `/secure` (ID tokens are denied)
- Steps per request:
  1) Extract bearer token and decode JWT payload (base64url) to read claims (no third-party libs)  
  2) Validate basic claims: `exp` (not expired), `iss` matches pool, and `token_use` in {access,id}  
  3) Critical revocation check: `cognito-idp:GetUser(AccessToken=<token>)`
     - If returns a user → token is active (not revoked)
     - If `NotAuthorizedException` → token revoked/invalid → DENY
  4) Return Allow policy (with minimal claims in context) or Deny policy

> Note: The authorizer purposefully requires an Access token because `GetUser` only accepts Access tokens. This is how revocation is enforced reliably.

### Why We Don't Pull In JWT Libraries Here
- To keep the spike self-contained (no layer/package management), we decode the payload to read claims and rely on Cognito `GetUser` for token validity/activeness.  
- We still validate minimal claims (exp/iss/token_use) to fail fast and avoid unnecessary Cognito calls.

### Validated Results (Lambda Authorizer)
From `deploy_lambda_authorizer.sh` runtime output:

- `/secure` with valid Access token → `200 Success` (authorizerType: Lambda)
- After `admin-user-global-sign-out` → same token → `401/403` (rejected as revoked)
- Re-authenticate → fresh token → `200 Success`

This confirms that the Lambda Authorizer detects and denies logged-out tokens.

### Manual Verification (copy-paste)
```bash
# Load outputs (Lambda authorizer stack)
export STACK=cognito-api-spike-lambda; export REGION=us-east-1
export API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
export USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
export CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)

# Authenticate and get Access token
export USERNAME="testuser@example.com"; export PASSWORD="MySecurePass123!"
AUTH_JSON=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT_ID" --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" --region "$REGION")
export ACCESS_TOKEN=$(echo "$AUTH_JSON" | jq -r '.AuthenticationResult.AccessToken')

# Before logout: expect 200
curl -s -o /dev/null -w "Secure (with token) -> HTTP %{http_code}\n" -H "Authorization: Bearer $ACCESS_TOKEN" "$API_URL/secure"

# Logout (revoke) and wait
aws cognito-idp global-sign-out --access-token "$ACCESS_TOKEN" --region "$REGION"; sleep 3

# After logout (same token): expect 401/403
curl -s -o /dev/null -w "Secure (revoked token) -> HTTP %{http_code}\n" -H "Authorization: Bearer $ACCESS_TOKEN" "$API_URL/secure"

# Fresh token should work again
AUTH_JSON2=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT_ID" --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" --region "$REGION")
NEW_ACCESS_TOKEN=$(echo "$AUTH_JSON2" | jq -r '.AuthenticationResult.AccessToken')
curl -s -o /dev/null -w "Secure (fresh token) -> HTTP %{http_code}\n" -H "Authorization: Bearer $NEW_ACCESS_TOKEN" "$API_URL/secure"
```

### Performance & Cost Considerations
- Each authorized request performs `GetUser` to Cognito (adds ~tens of ms per call; regional API).  
- If needed, consider a very short-lived positive cache (e.g., 30–60s) keyed by `sub`/`jti`, with careful trade-offs (risk: stale allow).
- Authorizer timeout is 10s; keep within API Gateway authorizer limits; monitor for NotAuthorizedException spikes.

### Operational Guidance
- Logs: `/aws/lambda/<authorizer-fn>` shows allow/deny decisions and errors.
- Alarms: Add CloudWatch alarms for high Deny rates or authorizer errors/timeouts.
- Rollout: Use the Lambda Authorizer stack (`cognito-api-spike-lambda`) alongside the JWT stack; cut traffic gradually or implement per-route authorizer selection.

---

## 🔧 Mitigation Strategies (Choosing the Right Option)

### Option A: Custom Lambda Authorizer (Implemented Here)
Pros:  
- ✅ Real-time revocation via Cognito `GetUser`  
- ✅ Immediate denial of logged-out tokens  
- ✅ Minimal changes to backend logic (claims via context)

Cons:  
- ❌ Extra latency + Lambda + Cognito call cost per authorized request  
- ❌ Access-token requirement for `/secure`  
- ❌ More moving parts (Lambda authorizer code + IAM)

### Option B: Shorter Token Expiration
Pros:  
- ✅ Simple and cheap  
- ✅ Reduces exposure window

Cons:  
- ❌ Tokens still valid until expiry (no immediate logout)  
- ❌ Requires client-side refresh more frequently

### Option C: Application-Level Blacklist
Pros:  
- ✅ Full control over revocation semantics  
- ✅ Can support ID-token-like scenarios with your own checks

Cons:  
- ❌ State management & scale complexity  
- ❌ Distributed cache invalidation challenges

### Option D: Hybrid (Recommended for Many Apps)
- Short-lived Access/ID tokens (e.g., 15 min)
- Automatic refresh using refresh tokens
- Optional Lambda Authorizer for high-risk routes

---

## 📋 Recommendations for Production

Tiered approach:
- High-sensitivity endpoints (admin, money-movement): use **Lambda Authorizer** (revocation-aware) + shorter TTLs
- General endpoints: at least **shorter TTLs**; add Lambda Authorizer if risk warrants
- Always monitor: Deny rates, NotAuthorizedException spikes, authorizer errors/timeouts

Template hints:
- Lambda Authorizer template sets 15-minute Access/ID token validity (adjust per risk appetite)
- JWT Authorizer baseline retains 60-minute defaults (demonstrates limitation)

---

## 🎯 Updated Test Results Summary

- JWT Authorizer:  
  - ✅ Refresh tokens invalidated on logout  
  - ❌ Access/ID tokens remain valid until expiry  
- Lambda Authorizer:  
  - ✅ Access tokens rejected immediately after logout (revocation detected)  
  - ✅ Fresh tokens work post-logout  

This spike demonstrates a practical, deployable mitigation for logout security with Cognito and API Gateway.

## 📚 References

- [AWS API Gateway JWT Authorizer Documentation](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html)
- [JWT Best Practices RFC](https://tools.ietf.org/html/rfc8725)
- [OWASP Token Revocation Guidelines](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html#token-sidejacking)
- Project files:  
  - `../cognito-api-spike-lambda-authorizer.yaml` (Lambda Authorizer stack)  
  - `../deploy_lambda_authorizer.sh` (deployment + automated revocation test)  
  - `DESIGN.md` (deep dive)  
  - `../README.md` (manual curl tests)
