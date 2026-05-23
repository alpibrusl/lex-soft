# agents/charge/tools.lex — HTTP tools wrapping the lex-charge REST API.
#
# Errors are returned as Ok({"error": "..."}) so the LLM can read them
# and decide how to proceed rather than seeing a hard failure.

import "std.http" as http
import "std.bytes" as bytes
import "std.str" as str
import "std.int" as int
import "std.float" as float
import "std.list" as list
import "lex-schema/json_value" as jv
import "lex-schema/schema" as s
import "lex-schema/error" as e
import "lex-llm/src/tool" as t

fn http_err(err :: HttpError) -> Str {
  match err {
    TimeoutError    => "timeout",
    TlsError(m)     => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m)  => str.concat("decode: ", m),
  }
}

fn call_get(url :: Str) -> [net, io, proc] Result[jv.Json, e.Errors] {
  match http.get(url) {
    Err(err) => Ok(JObj([("error", JStr(http_err(err)))])),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_)   => Ok(JObj([("error", JStr("response body decode failed"))])),
      Ok(body) => match jv.parse(body) {
        Err(_) => Ok(JStr(body)),
        Ok(j)  => Ok(j),
      },
    },
  }
}

fn call_post(url :: Str, body :: Str) -> [net, io, proc] Result[jv.Json, e.Errors] {
  match http.post(url, bytes.from_str(body), "application/json") {
    Err(err) => Ok(JObj([("error", JStr(http_err(err)))])),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_)   => Ok(JObj([("error", JStr("response body decode failed"))])),
      Ok(body) => match jv.parse(body) {
        Err(_) => Ok(JStr(body)),
        Ok(j)  => Ok(j),
      },
    },
  }
}

fn arg_str(args :: jv.Json, key :: Str) -> Str {
  match jv.get_field(args, key) { Some(JStr(s)) => s, _ => "" }
}

fn arg_float(args :: jv.Json, key :: Str) -> Float {
  match jv.get_field(args, key) {
    Some(JFloat(f)) => f,
    Some(JInt(n))   => int.to_float(n),
    _               => 0.0,
  }
}

fn make_tools(charge_url :: Str) -> List[t.Tool] {
  [
    t.define(
      "get_available_chargers",
      "List chargers currently available for a new session. Returns charger IDs, max power (kW), and connector types.",
      { title: "GetAvailableChargers", description: "No parameters required.", fields: [] },
      fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        call_get(str.concat(charge_url, "/api/v1/chargers?status=available"))
      }
    ),
    t.define(
      "get_charger_status",
      "Get the current status and active session details for a specific charger.",
      { title: "GetChargerStatus", description: "Identify the charger to inspect.", fields: [s.required_str("charger_id", [])] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        call_get(str.concat(charge_url, str.concat("/api/v1/chargers/", arg_str(args, "charger_id"))))
      }
    ),
    t.define(
      "schedule_charge",
      "Schedule a charging session. Check availability first. Returns the schedule ID and estimated completion time.",
      { title: "ScheduleCharge", description: "Charging session parameters.", fields: [
        s.required_str("vin", []),
        s.required_str("charger_id", []),
        s.required_float("target_soc_pct", []),
        s.required_float("available_minutes", []),
      ] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let body := jv.stringify(JObj([
          ("vin",               JStr(arg_str(args, "vin"))),
          ("charger_id",        JStr(arg_str(args, "charger_id"))),
          ("target_soc_pct",    JFloat(arg_float(args, "target_soc_pct"))),
          ("available_minutes", JFloat(arg_float(args, "available_minutes"))),
        ]))
        call_post(str.concat(charge_url, "/api/v1/charge-schedule"), body)
      }
    ),
  ]
}
