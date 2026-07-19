# device_identity.lex — device certificates + signed-reading verification (lex-ev-fleet#187).
#
# The substrate that lets the tamper-evident trail start AT the device instead of
# server-side. A device generates its own ed25519 keypair, submits only its public
# key, and the platform issues a CERTIFICATE — {device_id, tenant, kind, public_key,
# expiry} signed by the deployment key. Each reading the device sends is signed by
# its private key. Any service can then verify OFFLINE, with no registry lookup:
# (1) the cert was issued by the platform, (2) the reading was signed by the cert's
# key, (3) the cert matches the tenant and hasn't expired.
#
# Signing reuses the same ed25519-over-sha256-hex envelope the DSR/audit exports
# use. Crypto ops carry the `crypto` effect (deterministic; still unit-testable).

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-crypto/src/ed25519" as ed

fn digest(body :: Str) -> [crypto] Str {
  crypto.hex_encode(crypto.sha256(bytes.from_str(body)))
}

# The certificate body (what the platform signs). Fixed field order so the signed
# bytes are reproducible on both sides.
fn cert_body(device_id :: Str, tenant :: Str, kind :: Str, public_key :: Str, issued_at_ms :: Int, expires_at_ms :: Int) -> Str {
  jv.stringify(JObj([("device_id", JStr(device_id)), ("tenant", JStr(tenant)), ("kind", JStr(kind)), ("public_key", JStr(public_key)), ("issued_at_ms", JInt(issued_at_ms)), ("expires_at_ms", JInt(expires_at_ms))]))
}

# Issue a platform-signed certificate: sign the cert body with the deployment key
# and return the self-contained envelope the device stores and presents.
fn issue_cert(device_id :: Str, tenant :: Str, kind :: Str, public_key :: Str, issued_at_ms :: Int, expires_at_ms :: Int, sign_seed :: Bytes) -> [crypto] Result[Str, Str] {
  let body := cert_body(device_id, tenant, kind, public_key, issued_at_ms, expires_at_ms)
  let d := digest(body)
  match ed.sign_text(sign_seed, d) {
    Err(e) => Err(e),
    Ok(sig) => Ok(jv.stringify(JObj([("cert", JStr(body)), ("sha256", JStr(d)), ("alg", JStr("ed25519")), ("signature", JStr(sig))]))),
  }
}

type VerifiedDevice = { device_id :: Str, tenant :: Str, kind :: Str }

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

# Verify a device-signed reading end to end. `platform_pub_b64` is the deployment
# identity pubkey; `now_ms` is passed in so this stays free of the time effect.
# Returns the device's identity on success, or a reason string on any failure.
fn verify_reading(cert_env_json :: Str, body :: Str, reading_sig_b64 :: Str, platform_pub_b64 :: Str, now_ms :: Int) -> [crypto] Result[VerifiedDevice, Str] {
  match jv.parse(cert_env_json) {
    Err(_) => Err("invalid certificate envelope"),
    Ok(env) => {
      let cert_str := jstr(env, "cert")
      if not ed.verify_text(platform_pub_b64, digest(cert_str), jstr(env, "signature")) {
        Err("certificate not signed by the platform")
      } else {
        match jv.parse(cert_str) {
          Err(_) => Err("invalid certificate body"),
          Ok(cert) => {
            let expires := jint(cert, "expires_at_ms")
            if expires > 0 and now_ms > expires {
              Err("certificate expired")
            } else {
              if not ed.verify_text(jstr(cert, "public_key"), digest(body), reading_sig_b64) {
                Err("reading signature invalid")
              } else {
                Ok({ device_id: jstr(cert, "device_id"), tenant: jstr(cert, "tenant"), kind: jstr(cert, "kind") })
              }
            }
          },
        }
      }
    },
  }
}

