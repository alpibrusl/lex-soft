# tests/test_device_identity.lex — device-cert + signed-reading verification (device_identity.lex, #187).
#
# End-to-end: a platform-signed cert over a device key, a device-signed reading,
# and the four ways verification must fail — tampered body, wrong platform key,
# and an expired certificate.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "lex-crypto/src/ed25519" as ed

import "../src/device_identity" as di

fn ok(cond :: Bool, name :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn unwrap(r :: Result[Str, Str]) -> Str {
  match r {
    Ok(s) => s,
    Err(_) => "",
  }
}

# Fixed 32-byte ed25519 seeds for deterministic keys.
fn platform_seed() -> Bytes {
  bytes.from_str("platform_seed_aaaaaaaaaaaaaaaaaa")
}

fn device_seed() -> Bytes {
  bytes.from_str("device_seed_bbbbbbbbbbbbbbbbbbbb")
}

fn wrong_seed() -> Bytes {
  bytes.from_str("wrong_platform_seed_cccccccccccc")
}

fn a_cert(expires :: Int) -> [crypto] Str {
  let dev_pub := unwrap(ed.public_key_b64(device_seed()))
  unwrap(di.issue_cert("reefer-01", "acme", "reefer", dev_pub, 1000, expires, platform_seed()))
}

fn a_reading_sig(body :: Str) -> [crypto] Str {
  unwrap(ed.sign_text(device_seed(), di.digest(body)))
}

fn verifies_a_valid_reading() -> [crypto] Result[Unit, Str] {
  let ppub := unwrap(ed.public_key_b64(platform_seed()))
  let body := "{\"temp_c\":4.2}"
  match di.verify_reading(a_cert(9000), body, a_reading_sig(body), ppub, 5000) {
    Ok(d) => ok(d.device_id == "reefer-01" and d.tenant == "acme", "valid reading verifies to the device identity"),
    Err(e) => Err(str.concat("valid reading rejected: ", e)),
  }
}

fn rejects_tampered_body() -> [crypto] Result[Unit, Str] {
  let ppub := unwrap(ed.public_key_b64(platform_seed()))
  let sig := a_reading_sig("{\"temp_c\":4.2}")
  match di.verify_reading(a_cert(9000), "{\"temp_c\":40.0}", sig, ppub, 5000) {
    Ok(_) => Err("a tampered body was accepted"),
    Err(_) => Ok(()),
  }
}

fn rejects_wrong_platform_key() -> [crypto] Result[Unit, Str] {
  let wrong_pub := unwrap(ed.public_key_b64(wrong_seed()))
  let body := "{\"temp_c\":4.2}"
  match di.verify_reading(a_cert(9000), body, a_reading_sig(body), wrong_pub, 5000) {
    Ok(_) => Err("cert accepted under the wrong platform key"),
    Err(_) => Ok(()),
  }
}

fn rejects_expired_cert() -> [crypto] Result[Unit, Str] {
  let ppub := unwrap(ed.public_key_b64(platform_seed()))
  let body := "{\"temp_c\":4.2}"
  match di.verify_reading(a_cert(9000), body, a_reading_sig(body), ppub, 10000) {
    Ok(_) => Err("an expired cert was accepted"),
    Err(_) => Ok(()),
  }
}

fn run_all() -> [io, crypto] Unit {
  let results := [verifies_a_valid_reading(), rejects_tampered_body(), rejects_wrong_platform_key(), rejects_expired_cert()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __show := list.fold(failures, (), fn (_a :: Unit, m :: Str) -> [io] Unit {
      io.print(str.concat("FAIL: ", str.concat(m, "\n")))
    })
    let __boom := 1 / 0
    ()
  }
}

