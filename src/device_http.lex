# device_http.lex — device registration surface (lex-ev-fleet#187).
#
# Issues platform-signed device certificates. Admin-gated + fail-closed (bearer ==
# DEVICE_ADMIN_KEY; unset ⇒ disabled, never open). A device registers ONCE (submits
# its public key), gets a certificate it stores, then signs every reading it sends;
# any service verifies with device_identity.verify_reading — no lookup. This closes
# the "a spoofed edge feed is invisible" gap: provenance runs from the device up.
#
#   POST /devices/register  { device_id, public_key, kind }  -> platform-signed cert
#   GET  /devices                                             -> registered devices (audit)

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "./settlement" as settlement

import "lex-device-identity/src/device_identity" as di

type DeviceRow = { device_id :: Str, tenant :: Str, kind :: Str, public_key :: Str, issued_at_ms :: Int, expires_at_ms :: Int }

# Certificate lifetime: 180 days. Re-register to rotate; an explicit revocation
# list is a follow-up (short TTL keeps blast radius bounded meanwhile).
fn cert_ttl_ms() -> Int {
  15552000000
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn authed(admin_key :: Str, c :: ctx.Ctx) -> Bool {
  if str.is_empty(admin_key) {
    false
  } else {
    match ctx.bearer_token(c) {
      None => false,
      Some(t) => t == admin_key,
    }
  }
}

fn deny(admin_key :: Str) -> resp.Response {
  if str.is_empty(admin_key) {
    resp.forbidden("{\"error\":\"device registration disabled (DEVICE_ADMIN_KEY unset)\"}")
  } else {
    resp.unauthorized("{\"error\":\"missing or invalid bearer token\"}")
  }
}

fn handle_register(c :: ctx.Ctx, db :: Db, sign_seed :: Bytes, admin_key :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  if not authed(admin_key, c) {
    deny(admin_key)
  } else {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let device_id := jstr(j, "device_id")
        let public_key := jstr(j, "public_key")
        if str.is_empty(device_id) or str.is_empty(public_key) {
          resp.bad_request("{\"error\":\"device_id and public_key are required\"}")
        } else {
          let tenant := ctx.header_or(c, "X-Tenant-Id", "default")
          let kind := jstr(j, "kind")
          let issued := time.now_ms()
          let expires := issued + cert_ttl_ms()
          match di.issue_cert(device_id, tenant, kind, public_key, issued, expires, sign_seed) {
            Err(e) => resp.json_status(500, jv.stringify(JObj([("error", JStr(e))]))),
            Ok(cert) => {
              let __u := sql.exec(db, "INSERT INTO device_certs (device_id, tenant, kind, public_key, issued_at_ms, expires_at_ms, revoked) VALUES (?, ?, ?, ?, ?, ?, 0) ON CONFLICT (device_id) DO UPDATE SET tenant = ?, kind = ?, public_key = ?, issued_at_ms = ?, expires_at_ms = ?, revoked = 0", [PStr(device_id), PStr(tenant), PStr(kind), PStr(public_key), PInt(issued), PInt(expires), PStr(tenant), PStr(kind), PStr(public_key), PInt(issued), PInt(expires)])
              let log := settlement.trail_on(db)
              let __e := tlog.append(log, "device.registered", None, jv.stringify(JObj([("device_id", JStr(device_id)), ("tenant", JStr(tenant)), ("kind", JStr(kind)), ("expires_at_ms", JInt(expires)), ("at_ms", JInt(issued))])))
              resp.json_status(201, cert)
            },
          }
        }
      },
    }
  }
}

fn device_to_json(r :: DeviceRow) -> jv.Json {
  JObj([("device_id", JStr(r.device_id)), ("tenant", JStr(r.tenant)), ("kind", JStr(r.kind)), ("public_key", JStr(r.public_key)), ("issued_at_ms", JInt(r.issued_at_ms)), ("expires_at_ms", JInt(r.expires_at_ms))])
}

fn handle_list(c :: ctx.Ctx, db :: Db, admin_key :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  if not authed(admin_key, c) {
    deny(admin_key)
  } else {
    let tenant := ctx.header_or(c, "X-Tenant-Id", "default")
    let rows :: Result[List[DeviceRow], SqlError] := sql.query(db, "SELECT device_id, tenant, kind, public_key, issued_at_ms, expires_at_ms FROM device_certs WHERE tenant = ? AND revoked = 0 ORDER BY issued_at_ms DESC LIMIT 500", [PStr(tenant)])
    match rows {
      Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
      Ok(rs) => resp.json(jv.stringify(JList(list.map(rs, device_to_json)))),
    }
  }
}

# Host opt-in, mirroring dsr.mount. `admin_key` gates registration (empty ⇒
# disabled); `sign_seed` is the deployment ed25519 identity that signs certs.
fn mount(r :: router.Router, db :: Db, sign_seed :: Bytes, admin_key :: Str) -> router.Router {
  let r_reg := router.route_effectful(r, "POST", "/devices/register", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_register(c, db, sign_seed, admin_key)
  })
  router.route_effectful(r_reg, "GET", "/devices", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_list(c, db, admin_key)
  })
}

