```markdown
# Test Run 1 — Verbatim Terminal Transcript with Commentary

This report preserves the exact terminal input/output verbatim, divided into logical stages with brief commentary for context. Each fenced block is the original transcript text for that stage.

---

## Stage 1: Initial environment setup and first auth attempt (multi-line quoting issue)

```text
Last login: Sun Nov 16 21:11:51 on ttys031
➜  ~ # Set your stack name and region
export STACK=cognito-api-spike-lambda
export REGION=us-east-1

# Pull API URL and Cognito details from the stack
export API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
export USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
export CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)

# Use the test user created by the spike scripts
export USERNAME="testuser@example.com"
export PASSWORD="MySecurePass123!"

# Authenticate to get an Access token
AUTH_JSON=$(aws cognito-idp initiate-auth \
--auth-flow USER_PASSWORD_AUTH \
--client-id "$CLIENT_ID" \
--auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
--region "$REGION")

export ACCESS_TOKEN=$(echo "$AUTH_JSON" | jq -r '.AuthenticationResult.AccessToken')
echo "Access token (first 60): ${ACCESS_TOKEN:0:60}..."

dquote>
➜  ~
```

---

## Stage 2: Re-run setup; second quoting error and interrupt

```text
➜  ~ # Set your stack name and region
export STACK=cognito-api-spike-lambda
export REGION=us-east-1

# Pull API URL and Cognito details from the stack
export API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
export USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
export CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)

# Use the test user created by the spike scripts
export USERNAME="testuser@example.com"
export PASSWORD="MySecurePass123!"
dquote> "
^C%
```

---

## Stage 3: Reset variables; correct quoting for password

```text
➜  ~ export STACK=cognito-api-spike-lambda
export REGION=us-east-1

# Pull API URL and Cognito details from the stack
export API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
export USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
export CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)

➜  ~ # Use the test user created by the spike scripts
export USERNAME="testuser@example.com"
export PASSWORD="MySecurePass123!"
dquote>
➜  ~ export USERNAME="testuser@example.com"

➜  ~ export PASSWORD="MySecurePass123!"

dquote>
➜  ~ export PASSWORD='MySecurePass123!'
```

---

## Stage 4: Auth failure due to wrong USERNAME; diagnose and re-auth with explicit username

```text
➜  ~ # Authenticate to get an Access token
AUTH_JSON=$(aws cognito-idp initiate-auth \
--auth-flow USER_PASSWORD_AUTH \
--client-id "$CLIENT_ID" \
--auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
--region "$REGION")

An error occurred (NotAuthorizedException) when calling the InitiateAuth operation: Incorrect username or password.
➜  ~ echo $USER
aiden
➜  ~ echo $USERNAME
aiden
➜  ~
➜  ~ echo $USERNAME
aiden
➜  ~ AUTH_JSON=$(aws cognito-idp initiate-auth \
--auth-flow USER_PASSWORD_AUTH \
--client-id "$CLIENT_ID" \
--auth-parameters USERNAME="testuser@example.com",PASSWORD="$PASSWORD" \
--region "$REGION")
➜  ~ echo $AUTH_JSON
{
"ChallengeParameters": {},
"AuthenticationResult": {
"AccessToken": "eyJraWQiOiJzQnBYWjNDdXJQamdIdXE5SmVtdFVZMXdrd0VGTFJQRHQraDVJXC80UU95TT0iLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJkNDk4MDQ1OC1iMDIxLTcwMDgtZDQ4ZS0wZDFlMjRiZmZhNGYiLCJpc3MiOiJodHRwczpcL1wvY29nbml0by1pZHAudXMtZWFzdC0xLmFtYXpvbmF3cy5jb21cL3VzLWVhc3QtMV9XVXpabW5YMkciLCJjbGllbnRfaWQiOiI1bGU5Mm9kN2NuajJhMDY2YnNoaTI1N3EwcyIsIm9yaWdpbl9qdGkiOiIyYWM3NTVkOC0zYzcwLTQ1NjgtYWMyMC1iMWU4NzAxZjAxODgiLCJldmVudF9pZCI6Ijc3ZDZlMWU3LTVlNTUtNDQzMy04ZjlkLTI4ZDM4M2NkYTc4NSIsInRva2VuX3VzZSI6ImFjY2VzcyIsInNjb3BlIjoiYXdzLmNvZ25pdG8uc2lnbmluLnVzZXIuYWRtaW4iLCJhdXRoX3RpbWUiOjE3NjMzMjgxODksImV4cCI6MTc2MzMyOTA4OSwiaWF0IjoxNzYzMzI4MTg5LCJqdGkiOiJmZjk3YmYxNy1iMTA4LTRhMjctYjUzZi04MmUyNTFjNTcxMWEiLCJ1c2VybmFtZSI6ImQ0OTgwNDU4LWIwMjEtNzAwOC1kNDhlLTBkMWUyNGJmZmE0ZiJ9.o3PT-a57gpG01lPqzt_087oufeMU2yhufZZEY4OUdlFzQ2qoJmX9jRfq2buVeNXGFZkP6Ms2hYHFd3TqkstvsK9A_o3D0ilkF8VjmO7sIuMkWbF84ab833JfkblgvybezEkK7kv1aCr4NZCBv52iO-HKYAuOY8zJLI1keEpA2UsmMDoaYWFMmTjnfONTmLQnfznSib2Vk3F9WdkhEhPl82WpiEz6er-8mOwZGkk3phI8FkivM0_6M48o4vO3q-vHq7m5T4u-cwG61QRsGoib8FVGTmbosSD0TSJBaqim8Zl9b65Zx8kk_KI7dAV9wy1UHzjfJYXm6E60xpqOF4JceA",
"ExpiresIn": 900,
"TokenType": "Bearer",
"RefreshToken": "eyJjdHkiOiJKV1QiLCJlbmMiOiJBMjU2R0NNIiwiYWxnIjoiUlNBLU9BRVAifQ.abpndEfr8IWitAycNk9mYHUZQUwaniRjrheLgFrvpd9cvbs29-3w81gDvtk-pedNRrlsVwlwtqBy7xgsaop6-Ik9J16hwZJt8NAUDxZjDhbbnFMp02hrtf3I-kVGoysljuC7b33wF3XqkCLsMaWX_zzN3AtBSZjeDBZTE6kCRJSHh9mdIroHoiNK3MtJZABFhtboRIN-55aQbZ2nuV3B_52i3w1LkbTfMGg18kNq4hrwnQNOMuqO63WaDeHxCOqhG8BmmZilEQxKvwcGcKwk0s4NszOjxCKq5g644bZTwvHzhLpuhDBbKtk70MReYfX5eR8R0fjYVh189AD3k9WrqA.Ynnr_fZZPMsz4cjr.6AmCsEbfOxnhrx9NdrvUW7ROWcoVJGjA-pKwpeT-l-RmiHL4EbiZvUyY4e55f-IjPpCgzGAfqLEl8E_HCz6pT6s1mARxDTRPLSZ2dn6S5bJvolw7rIUM4RQqz3qzl8OOSq6hcT6v8aIsjwUtA0ipH574Mgzi8Kf1pYEN2I9I_kVjg9gxuvu_3VNIKkhKjVP44wbJk3A2NLc0XGhqhgE0lZQ6Nv7SHEv70tHe-Nr3YBW7HL3jlMQjY_I-Q8oEVuZztBAxqFCdHTR4iafplrTOcC_KIUhOEVmVbJQA28OxcWgjf8ge_K5xFYWFJ7SbR5VjK6tqwPPWq5-fMmKAeRe4-9vF0NvjwIULm6J-DHUu-5sY6KYZiubf30TgniisHSoyLESXJ_F86RGugGuJ0ZuRD4p_hSG4WOUXqa5Uo0FQJrAsA82F0edLxuv1LF2KEyKcKQlTMj4He_JYdTnem_UffupX1JnPnTIbdVssrEolqqUAEKD60ci2ImmAtexPyt772o5GdKHE5YNw7udVPelyv3KA4h0x7Sba8TL2fAOCKKwK0QY3RSfVxtAOo2gpD7J36vLUQkKkN5kXHjEtgHM1VZnvRbWk7JQwTmZTpKkvCjx0Gcs9fS6aCmCHi66LPiuMvA75OA0UOUyPctOfKb8El68eGAlrDd4eLEIZ1aVIAY_G-7Yr_mkhgy23yFOMOlCfPRUbEkvYzjUYhqdYj0k1ZDeLzXjnKKcH__ti7tjfvQ4UjjQfotW6VjBuPQOpfsW2omN1jvttBYCP0-Vu8Yr06SsJXQ9nm_pwMzJYHLs5HpVshKreVzfFDZ265UjZnXRwi3L7WYz2UDBfJBeK9KXIevJJILRNespcysasp4Q4MXll4moruvzsdNQGsZpRGZD0OkLtQ2LXA_H9HJHSCYZze2wQMHxmVWgAEWXt8ywsyNYKjsIU0aNSz-OWp9SsRO9rmQzC3TvbWsfqcuusG3xZk6YXaR0n1VTBhbuBXOf_IF8R1a4i4TfnPe9baU853_Nyj_Ks1omWvG3CZrohsmYsUmwG4KgApe3OUG9y1bDbhf9S3U7ODP-gObozxh4EhkUA0xh211bK9Tu56bfIOLqp0wvBh2JfLbpFLqExhTQzh9SvL2HboC1UKtVZOqZrY3bNYLP20XybEiwlCjvYMH4Wj2oit1uSre60fre1-7kJpN_XBVJygdsakIfLl_kPddW0tblv_YN_ZJHhpXkBT6yMNT5bOr5-mCMDwm2w9DEpRLvXm3wHyYkfO2qj2VTpckJsw2ytTnkyalDuzsbXz6cOba8YTwAhtBPeEyIQOzoyx6C9bPRG64447oVwRpA.WjLdEAxGemB5IDgZeYXLBg",
"IdToken": "eyJraWQiOiJMZml1dG1tbmFWNEtlZ1BWZGJ5Y1g5Tmo1eUZNZlhGWjFoYkc1VFMzR2ZnPSIsImFsZyI6IlJTMjU2In0.eyJzdWIiOiJkNDk4MDQ1OC1iMDIxLTcwMDgtZDQ4ZS0wZDFlMjRiZmZhNGYiLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiaXNzIjoiaHR0cHM6XC9cL2NvZ25pdG8taWRwLnVzLWVhc3QtMS5hbWF6b25hd3MuY29tXC91cy1lYXN0LTFfV1V6Wm1uWDJHIiwiY29nbml0bzp1c2VybmFtZSI6ImQ0OTgwNDU4LWIwMjEtNzAwOC1kNDhlLTBkMWUyNGJmZmE0ZiIsIm9yaWdpbl9qdGkiOiIyYWM3NTVkOC0zYzcwLTQ1NjgtYWMyMC1iMWU4NzAxZjAxODgiLCJhdWQiOiI1bGU5Mm9kN2NuajJhMDY2YnNoaTI1N3EwcyIsImV2ZW50X2lkIjoiNzdkNmUxZTctNWU1NS00NDMzLThmOWQtMjhkMzgzY2RhNzg1IiwidG9rZW5fdXNlIjoiaWQiLCJhdXRoX3RpbWUiOjE3NjMzMjgxODksImV4cCI6MTc2MzMyOTA4OSwiaWF0IjoxNzYzMzI4MTg5LCJqdGkiOiI0OTU3Nzc0Yy04ZTFjLTRjNWYtYTUzMy0xYmI5MjlhYjNhYWUiLCJlbWFpbCI6InRlc3R1c2VyQGV4YW1wbGUuY29tIn0.paJI3n-OgTnEP32Gk6vBcuPUavBAAEqF8l_nFVnVGyBz_ldB4u6k8LgSrYCIbjHvBZJDDER1a6AVwUK3szYiyJzgTHAozCWJI80PDYjSiJOtKzpyxdHLAhXQIufG7yNjoHbJ5jMn0trxG12TPbg3K7O7Gf1-AdBwS2MJLB5AZF515uqWSj8zUzTuLZMD6AlxZX--tUZ03OWMxyhOZvubp96EV82B-dXpTG5kxR2C6Dtcq4aXF43HdlWMnFmSB9ThaXtweU8mOYn2pFa16UIyPJ77qW0GW32F22dTSvpsU6MRLG6vG5AzPkojpfJ8RbkJwee6weuZr-L5DXeEftOm4A"
}
}
```

---

## Stage 5: Export Access token and test endpoints

```text
➜  ~ export ACCESS_TOKEN=$(echo "$AUTH_JSON" | jq -r '.AuthenticationResult.AccessToken')

➜  ~ echo "Access token (first 60): ${ACCESS_TOKEN:0:60}..."
Access token (first 60): eyJraWQiOiJzQnBYWjNDdXJQamdIdXE5SmVtdFVZMXdrd0VGTFJQRHQraDVJ...
➜  ~ curl -s -o /dev/null -w "Public -> HTTP %{http_code}\n" "$API_URL/public"

Public -> HTTP 200
➜  ~ curl -s -o /dev/null -w "Secure (no token) -> HTTP %{http_code}\n" "$API_URL/secure"

Secure (no token) -> HTTP 401
➜  ~ curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
-o /dev/null -w "Secure (with token) -> HTTP %{http_code}\n" \
"$API_URL/secure"
Secure (with token) -> HTTP 200
```

---

## Stage 6: Global sign-out and revocation verification

```text
➜  ~ aws cognito-idp global-sign-out --access-token "$ACCESS_TOKEN" --region "$REGION"

➜  ~ curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
-o /dev/null -w "Secure (revoked token) -> HTTP %{http_code}\n" \
"$API_URL/secure"
Secure (revoked token) -> HTTP 403
```

---

## Stage 7: Re-authenticate to obtain a fresh token

```text
➜  ~ AUTH_JSON2=$(aws cognito-idp initiate-auth \
--auth-flow USER_PASSWORD_AUTH \
--client-id "$CLIENT_ID" \
--auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
--region "$REGION")
NEW_ACCESS_TOKEN=$(echo "$AUTH_JSON2" | jq -r '.AuthenticationResult.AccessToken')
➜  ~ AUTH_JSON=$(aws cognito-idp initiate-auth \
--auth-flow USER_PASSWORD_AUTH \
--client-id "$CLIENT_ID" \
--auth-parameters USERNAME="testuser@example.com",PASSWORD="$PASSWORD" \
--region "$REGION")
➜  ~ export ACCESS_TOKEN=$(echo "$AUTH_JSON" | jq -r '.AuthenticationResult.AccessToken')

➜  ~
```

---

End of verbatim transcript.
```
