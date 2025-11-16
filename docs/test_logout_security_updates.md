# test_logout_security.sh Updates Summary

## Changes Made

Updated `test_logout_security.sh` to align with Lambda Authorizer requirements and provide clear testing for both JWT and Lambda authorizer stacks.

### Key Changes

1. **Configurable Stack Selection**
   - Default: `cognito-api-spike` (JWT authorizer)
   - Override via environment variable: `STACK_NAME=cognito-api-spike-lambda ./test_logout_security.sh`
   - Auto-detects authorizer type from stack outputs

2. **Access Token Primary Testing**
   - Lambda Authorizer requires Access tokens (Cognito GetUser only accepts Access tokens)
   - Access token tests run first
   - ID token tests conditional based on authorizer type

3. **Authorizer-Aware Expectations**
   - Lambda Authorizer: Expects 401/403 for revoked tokens (security requirement)
   - JWT Authorizer: Documents expected behavior (tokens valid until expiry) as a known limitation

4. **Enhanced Output**
   - Shows stack name and authorizer type
   - Clear warnings about JWT authorizer limitations
   - Links to `docs/SECURITY_ANALYSIS.md` for mitigation strategies
   - Different success messages for Lambda vs JWT authorizer

5. **Test Order Alignment**
   - Access token tested before ID token (matches Lambda Authorizer priority)
   - Skip ID token tests when Lambda Authorizer is detected
   - Maintains backwards compatibility with JWT authorizer stack

## Usage Examples

### Test JWT Authorizer (default)
```bash
./test_logout_security.sh
```

Expected: Tokens remain valid after logout (known limitation documented)

### Test Lambda Authorizer (revocation-aware)
```bash
STACK_NAME=cognito-api-spike-lambda ./test_logout_security.sh
```

Expected: Tokens rejected after logout (security test passes)

### Compare Both
```bash
# JWT authorizer
./test_logout_security.sh > jwt_test.log

# Lambda authorizer
STACK_NAME=cognito-api-spike-lambda ./test_logout_security.sh > lambda_test.log

# Compare
diff jwt_test.log lambda_test.log
```

## Test Flow

1. **Setup**: Load stack outputs, detect authorizer type
2. **Authenticate**: Get ID, Access, and Refresh tokens
3. **Pre-Logout**: Test Access token (and ID token for JWT authorizer)
4. **Logout**: Perform global sign-out
5. **Post-Logout**: Test same tokens (expect rejection for Lambda, document limitation for JWT)
6. **Refresh Test**: Verify refresh token invalidated (both stacks)
7. **Fresh Auth**: Verify new tokens work
8. **Summary**: Display results with authorizer-specific context

## Exit Codes

- `0`: Tests passed (Lambda authorizer) or limitations documented (JWT authorizer)
- `1`: Unexpected failures (e.g., Lambda authorizer not rejecting revoked tokens)

## Related Files

- `cognito-api-spike.yaml` - JWT authorizer stack
- `cognito-api-spike-lambda-authorizer.yaml` - Lambda authorizer stack
- `docs/SECURITY_ANALYSIS.md` - Security findings and mitigations
- `docs/DESIGN.md` - Architecture details
- `docs/test-run-1.md` - Verbatim test transcript

