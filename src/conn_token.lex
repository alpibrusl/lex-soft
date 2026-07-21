# conn_token.lex — the raw HS256 connection-token primitives.
#
# Split out of federation.lex so identity.lex (which mints these tokens as part
# of issuing an audit-resolvable credential) doesn't have to import federation
# — federation.lex, in turn, needs to import identity.lex for #62's onboarding
# hardening. Both now depend on this instead of on each other.

import "lex-crypto/src/jwt" as jwt

import "std.str" as str

import "std.crypto" as crypto

# A stable, public key id for an HS256 secret: the first 8 hex of its SHA-256.
# One-way, so it reveals nothing about the secret, yet lets a verifier holding a
# rotation ring pick the signing key directly instead of trying each in turn.
fn secret_kid(secret :: Bytes) -> Str {
  str.slice(crypto.hex_encode(crypto.sha256(secret)), 0, 8)
}

# Symmetric: we both issue and verify our own connection tokens, so HS256 is
# correct. iss=us, sub=partner, aud=scope, exp=now+TTL. The token is stamped with
# the signing key's kid — verifies identically (the kid header is signature-
# covered), and lets rotation resolve the key without trying the whole ring.
fn issue(secret :: Bytes, our_org :: Str, partner_org :: Str, scope :: Str, ttl :: Int, jti :: Str, now :: Int) -> Str {
  jwt.sign_hs256_kid(secret, secret_kid(secret), { sub: partner_org, iss: our_org, aud: scope, jti: jti, exp: now + ttl, nbf: 0, iat: now })
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

