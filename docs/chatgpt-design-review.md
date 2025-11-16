# Design Review: Cognito + API Gateway Authorizer Spike

Overall, this is a solid, well-reasoned approach that correctly accepts the hard truth about Cognito + JWT authorizers and then designs around it.

Let me break it down into:
- 👍 What’s strong about it
- ⚠️ Where the sharp edges are
- 🛠 Suggestions / refinements

---

## 👍 Strengths

1. You’ve nailed the core limitation
   You’re explicit that:
   - JWT Authorizer is stateless → can’t see logout / revocation
   - Lambda Authorizer + Cognito → can use GetUser as a real-time “is this access token still valid?” check
   That’s the right mental model, and you’re not trying to force the JWT authorizer to do something it can’t.

2. Clear separation of Option A vs Option B
   - Option A = “vanilla JWT authorizer, good for stateless, no revocation”
   - Option B = “stateful, revocation-aware, access-token-only”
   That’s a nice teaching / spike structure and makes it easy for others to understand the trade-off.

3. Revocation semantics are actually correct
   Using cognito-idp:GlobalSignOut + GetUser(AccessToken) is one of the only ways to get close to “immediate logout” with Cognito access tokens:
   - If GetUser succeeds → token is genuine and not revoked
   - If NotAuthorizedException → token is expired / revoked / invalid
   Combined with your exp/iss/token_use checks, that’s a clean, defensible pattern.

4. Fail-closed and defensive design
   I like that you:
   - Deny on any parsing/validation error
   - Deny on any AWS errors / timeouts
   - Pass minimal context downstream
   That’s the right bias for an authorizer.

5. You correctly restrict revocation-aware flow to Access Tokens
   You explicitly call out: GetUser only works with Access tokens → ID tokens are denied.
   That’s accurate and avoids the common “just use ID tokens everywhere” mistake.

---

## ⚠️ Risks / Limitations (to consciously accept)

None of these are “this is wrong”, more “be very aware”:

1. Every secure call hits Cognito
   - One GetUser per /secure call → extra latency + cost + potential for rate limiting
   - For low/medium TPS spikes, fine; for high-volume APIs, this becomes a real scaling concern
   You do mention performance + possible short-lived caching, which is good. Treat this as a known, explicit trade-off for the revocation requirement.

2. You’re not validating the JWT signature
   You rely on Cognito as an oracle:
   - If the token is fake → GetUser fails → deny
   - From a security standpoint, this is actually OK.
   But it means you’re treating the JWT more as a “Cognito access ticket” than as a cryptographically self-contained artifact. That’s fine as long as it’s intentional (which it is).

3. Real requirement: “ID+Access tokens accepted” is now effectively gone for the revocation-aware path
   You previously had a core requirement to support both idToken + accessToken. This doc correctly concludes:
   - JWT Authorizer: can accept both (ID or Access) but no revocation
   - Lambda Authorizer: must accept Access only (for GetUser)
   That’s the right conclusion, but make it crystal clear to stakeholders that: you can’t have “accept both ID and Access tokens and hard revocation” with this design. The moment you want revocation via Cognito, you must require Access tokens.

4. Global sign-out semantics
   Global sign-out invalidates all sessions for the user. It’s powerful but:
   - Logging out on one device logs out everything using that token
   - If you ever need per-device / per-session logout semantics, you’ll need more nuance (e.g., mapping tokens to device IDs, session IDs, etc.)

5. Cognito GetUser rate limits & blast radius
   - If something goes wrong (misconfigured retries, traffic spike, DoS attempt), your authorizer and Cognito are tightly coupled.
   - Worth adding retry/backoff carefully and strict timeouts to ensure the authorizer doesn’t hang.

---

## 🛠 Suggestions / Refinements

If I were iterating this with you, I’d suggest:

1. Make the trade-off super explicit in the doc

   Add a short “Conclusion” paragraph in bold near the top:

   - JWT Authorizer: stateless, supports ID+Access tokens, no immediate logout.
   - Lambda Authorizer: stateful via GetUser, Access tokens only, supports immediate logout.
   - Therefore, the system must choose between “ID+Access, stateless” vs “Access-only, revocation-aware” on a per-route or per-service basis.

   That will save future-you many conversations.

2. Consider a hybrid model per endpoint sensitivity

   For example:
   - Low/medium-sensitivity routes: use plain JWT Authorizer (fast, cheap, no Cognito call).
   - High-sensitivity routes (money movements, PII writes, admin operations): use Lambda Authorizer with revocation.

   This reduces load on Cognito while still meeting the strict requirement where it really matters.

3. Tighten claim checks slightly

   You already check:
   - exp
   - iss
   - token_use

   Consider also:
   - aud matches app client ID (helps ensure the token is for this app)
   - optional scope / cognito:groups / custom claims to implement authorization tiers (e.g. role, permissions)

   Even simple scope checks (e.g. contains 'api.read') make the authorizer much more valuable.

4. Be clear on “expiry vs revocation”

   You’re already good here, but emphasise:
   - Expired tokens are blocked by your own exp check before Cognito
   - Logout / revocation is enforced by GetUser

   Just so nobody later assumes Cognito is doing more than it is.

5. Plan for scaling

   If this ever graduates beyond spike:
   - Measure p95/p99 latency impact of GetUser
   - Check Cognito rate limits vs expected TPS
   - Possibly introduce:
     - Very short TTL positive cache (e.g. 15–30s) keyed by sub or jti
     - Separate “session invalidation” mechanism if business needs richer semantics than “global sign-out”

---

## My overall take

- Conceptually sound ✅
- Honest about Cognito/JWT limitations ✅
- Security posture is conservative (fail closed, minimal context) ✅
- Main cost is latency + Cognito coupling ⚠️ but acceptable for a spike / selective use.

If your non-negotiable requirement is:

> “When a user logs out, that token must stop working immediately”

…then this Lambda Authorizer + GetUser pattern is one of the few pragmatic ways to get there without introducing your own token store/blacklist system.

I’d be comfortable moving forward with this as:
- the reference spike, and
- the template for high-value endpoints in a real system.

If you want, next step I can help you:
- Turn this design doc into the actual `cognito-api-spike-lambda-authorizer.yaml` template, or
- Draft a short Decision Record (ADR) summarising: we choose Lambda Authorizer + GetUser for revocation-aware endpoints; JWT Authorizer for everything else.
