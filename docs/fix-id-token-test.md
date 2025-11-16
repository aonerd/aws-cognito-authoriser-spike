# Fix: test_logout_security.sh - ID Token Support

## Issue
When testing the Lambda Authorizer stack with `test_logout_security.sh`, Step 6 (fresh tokens test) was showing an error:
```
[ERROR] ❌ Fresh ID token failed 
Response: {"message":"Forbidden"}
```

## Root Cause
The Lambda Authorizer only accepts Access tokens because:
- Cognito's `GetUser` API (used for revocation checks) only accepts Access tokens
- ID tokens cannot be used for revocation validation
- This is expected behavior, not an error

## Fix Applied
Updated Step 6 of `test_logout_security.sh` to:

1. **Test Access tokens first** (primary requirement)
2. **Skip ID token tests** when Lambda Authorizer is detected
3. **Add clear messaging** that ID tokens are not supported by Lambda Authorizer

### Changes Made

**Before:**
- Always tested both ID and Access tokens
- Showed error when ID token failed with Lambda Authorizer

**After:**
- Tests Access token first (primary)
- Only tests ID token if `USE_ACCESS_TOKEN_PRIMARY=false` (JWT authorizer)
- Shows warning message for Lambda Authorizer: "Skipping ID token test (Lambda Authorizer requires Access tokens only)"
- Clarifies: "ID tokens are not supported by Lambda Authorizer - this is expected"

## Test Flow Now

### For Lambda Authorizer Stack
```bash
STACK_NAME=cognito-api-spike-lambda ./test_logout_security.sh
```

Step 6 output:
```
[INFO] Step 6: Getting FRESH tokens after logout (should work normally)...
[SUCCESS] ✅ Fresh tokens obtained successfully after logout
[INFO] Testing fresh Access token...
HTTP Status: 200
[SUCCESS] ✅ Fresh Access token works correctly
[WARNING] ⚠️  Skipping ID token test (Lambda Authorizer requires Access tokens only)
[WARNING]    ID tokens are not supported by Lambda Authorizer - this is expected
```

### For JWT Authorizer Stack
```bash
./test_logout_security.sh
```

Step 6 output:
```
[INFO] Step 6: Getting FRESH tokens after logout (should work normally)...
[SUCCESS] ✅ Fresh tokens obtained successfully after logout
[INFO] Testing fresh Access token...
HTTP Status: 200
[SUCCESS] ✅ Fresh Access token works correctly
[INFO] Testing fresh ID token...
HTTP Status: 200
[SUCCESS] ✅ Fresh ID token works correctly
```

## Validation
- ✅ Bash syntax check passed
- ✅ No errors reported
- ✅ Test logic correctly differentiates between authorizer types
- ✅ Clear messaging for expected behavior

## Related Documentation
- `docs/DESIGN.md` - Explains why Lambda Authorizer requires Access tokens
- `docs/SECURITY_ANALYSIS.md` - Details on GetUser revocation check
- `cognito-api-spike-lambda-authorizer.yaml` - Lambda Authorizer template

## Summary
The "error" was actually expected behavior. The fix clarifies this by skipping ID token tests for Lambda Authorizer and explaining why. This aligns the test script with the Lambda Authorizer's Access-token-only requirement.

