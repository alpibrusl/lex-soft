# conn_token.lex — the raw HS256 connection-token primitives.
#
# Split out of federation.lex so identity.lex (which mints these tokens as part
# of issuing an audit-resolvable credential) doesn't have to import federation
# — federation.lex, in turn, needs to import identity.lex for #62's onboarding
# hardening. Both now depend on this instead of on each other.

import "lex-crypto/src/jwt" as jwt

import "std.str" as str

# Symmetric: we both issue and verify our own connection tokens, so HS256 is
# correct. iss=us, sub=partner, aud=scope, exp=now+TTL.
fn issue(secret :: Bytes, our_org :: Str, partner_org :: Str, scope :: Str, ttl :: Int, jti :: Str, now :: Int) -> Str {
  jwt.sign_hs256(secret, { sub: partner_org, iss: our_org, aud: scope, jti: jti, exp: now + ttl, nbf: 0, iat: now })
}

# Inbound identity: a presented bearer token must be a JWT we signed and that has
# not expired. Stateless — no DB lookup.
fn verify(secret :: Bytes, presented :: Str) -> [time] Bool {
  if str.is_empty(presented) {
    false
  } else {
    match jwt.verify_hs256(secret, presented) {
      Ok(_) => true,
      Err(_) => false,
    }
  }
}

