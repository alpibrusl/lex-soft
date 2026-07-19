# agents/tms/tools.lex — HTTP tools for lex-tms, lex-logistics, lex-routing,
# lex-telemetry, and charge-agent (via platform send_message).
#
# request_charging no longer builds a raw A2A envelope — the platform's
# send_message tool handles that, so this tool just delegates to it via
# a plain description. The LLM will call send_message("charge-agent", ...).

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

fn make_tools(tms_url :: Str, logistics_url :: Str, routing_url :: Str, telemetry_url :: Str) -> List[t.Tool] {
  [
    t.define(
      "list_vehicles",
      "List registered EV trucks. Optionally filter by status: available, in_service, maintenance, retired.",
      { title: "ListVehicles", description: "Vehicle list filter.", fields: [s.optional(s.required_str("status", []))] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let status := arg_str(args, "status")
        let url := if str.is_empty(status) {
          str.concat(tms_url, "/api/v1/vehicles")
        } else {
          str.concat(tms_url, str.concat("/api/v1/vehicles?status=", status))
        }
        call_get(url)
      }
    ),
    t.define(
      "get_vehicle",
      "Get a vehicle by VIN including specs and current status.",
      { title: "GetVehicle", description: "Vehicle lookup.", fields: [s.required_str("vin", [])] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        call_get(str.concat(tms_url, str.concat("/api/v1/vehicles/", arg_str(args, "vin"))))
      }
    ),
    t.define(
      "list_drivers",
      "List registered drivers. Optionally filter by status: available, on_duty, off_duty, retired.",
      { title: "ListDrivers", description: "Driver list filter.", fields: [s.optional(s.required_str("status", []))] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let status := arg_str(args, "status")
        let url := if str.is_empty(status) {
          str.concat(tms_url, "/api/v1/drivers")
        } else {
          str.concat(tms_url, str.concat("/api/v1/drivers?status=", status))
        }
        call_get(url)
      }
    ),
    t.define(
      "get_driver_hos_summary",
      "Get HOS compliance summary for a driver: driving minutes today, this week, last 14 days, with statutory limits.",
      { title: "GetDriverHosSummary", description: "HOS lookup.", fields: [s.required_str("driver_id", [])] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        call_get(str.concat(tms_url, str.concat("/api/v1/hos/", str.concat(arg_str(args, "driver_id"), "/summary"))))
      }
    ),
    t.define(
      "list_orders",
      "List freight orders. Optionally filter by status: pending, assigned, in_transit, delivered, cancelled.",
      { title: "ListOrders", description: "Order list filter.", fields: [s.optional(s.required_str("status", []))] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let status := arg_str(args, "status")
        let url := if str.is_empty(status) {
          str.concat(tms_url, "/api/v1/orders")
        } else {
          str.concat(tms_url, str.concat("/api/v1/orders?status=", status))
        }
        call_get(url)
      }
    ),
    t.define(
      "dispatch_order",
      "Assign a freight order to a route, driver, and vehicle. Updates order status to 'assigned'.",
      { title: "DispatchOrder", description: "Dispatch parameters.", fields: [
        s.required_str("order_id", []),
        s.required_str("route_id", []),
        s.required_str("vin", []),
        s.required_str("driver_id", []),
        s.optional(s.required_str("notes", [])),
      ] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let body := jv.stringify(JObj([
          ("order_id",  JStr(arg_str(args, "order_id"))),
          ("route_id",  JStr(arg_str(args, "route_id"))),
          ("vin",       JStr(arg_str(args, "vin"))),
          ("driver_id", JStr(arg_str(args, "driver_id"))),
          ("notes",     JStr(arg_str(args, "notes"))),
        ]))
        call_post(str.concat(tms_url, "/api/v1/assignments"), body)
      }
    ),
    t.define(
      "route_plan",
      "Compute a truck route between ordered waypoints. Returns distance_km, duration_min, and per-leg breakdown.",
      { title: "RoutePlan", description: "Routing request.", fields: [
        s.required_str("waypoints_json", []),
        s.optional(s.required_float("weight_kg", [])),
        s.optional(s.required_float("height_m", [])),
        s.optional(s.required_float("width_m", [])),
        s.optional(s.required_float("length_m", [])),
      ] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let wps := match jv.parse(arg_str(args, "waypoints_json")) { Ok(j) => j, Err(_) => JList([]) }
        let truck := JObj([
          ("weight_kg", JFloat(arg_float(args, "weight_kg"))),
          ("height_m",  JFloat(arg_float(args, "height_m"))),
          ("width_m",   JFloat(arg_float(args, "width_m"))),
          ("length_m",  JFloat(arg_float(args, "length_m"))),
        ])
        call_post(str.concat(routing_url, "/route"), jv.stringify(JObj([("waypoints", wps), ("truck", truck)])))
      }
    ),
    t.define(
      "range_check",
      "Check if a vehicle can reach a destination given its current SoC.",
      { title: "RangeCheck", description: "Range feasibility check.", fields: [
        s.required_str("origin_json", []),
        s.required_str("destination_json", []),
        s.required_float("current_soc_pct", []),
        s.required_float("battery_capacity_kwh", []),
        s.optional(s.required_float("consumption_kwh_per_100km", [])),
      ] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let origin := match jv.parse(arg_str(args, "origin_json"))      { Ok(j) => j, Err(_) => JObj([]) }
        let dest   := match jv.parse(arg_str(args, "destination_json")) { Ok(j) => j, Err(_) => JObj([]) }
        let body   := jv.stringify(JObj([("waypoints", JList([origin, dest]))]))
        match call_post(str.concat(routing_url, "/route"), body) {
          Err(e) => Err(e),
          Ok(route_j) => {
            let dist := match jv.get_field(route_j, "distance_km") {
              Some(JFloat(f)) => f,
              Some(JInt(n))   => int.to_float(n),
              _               => 0.0,
            }
            let kwh_per_100  := if arg_float(args, "consumption_kwh_per_100km") > 0.0 { arg_float(args, "consumption_kwh_per_100km") } else { 120.0 }
            let needed_kwh   := dist * kwh_per_100 / 100.0
            let available    := arg_float(args, "battery_capacity_kwh") * arg_float(args, "current_soc_pct") / 100.0
            Ok(JObj([
              ("distance_km",   JFloat(dist)),
              ("needed_kwh",    JFloat(needed_kwh)),
              ("available_kwh", JFloat(available)),
              ("feasible",      JBool(available >= needed_kwh)),
            ]))
          },
        }
      }
    ),
    t.define(
      "get_route",
      "Get a delivery route by ID including its stops and current status.",
      { title: "GetRoute", description: "Route lookup.", fields: [s.required_str("route_id", [])] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        call_get(str.concat(logistics_url, str.concat("/api/v1/routes/", arg_str(args, "route_id"))))
      }
    ),
    t.define(
      "create_route",
      "Create a new delivery route for a vehicle on a given date. Returns the new route ID.",
      { title: "CreateRoute", description: "New route parameters.", fields: [
        s.required_str("vin", []),
        s.required_str("route_date", []),
        s.optional(s.required_str("route_name", [])),
      ] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let body := jv.stringify(JObj([
          ("vin",        JStr(arg_str(args, "vin"))),
          ("route_date", JStr(arg_str(args, "route_date"))),
          ("route_name", JStr(arg_str(args, "route_name"))),
        ]))
        call_post(str.concat(logistics_url, "/api/v1/routes"), body)
      }
    ),
    t.define(
      "compute_caw",
      "Compute charge-as-worked energy for a planned route and persist the result for audit. Returns target SoC, energy needed, estimated charge time, and a record ID.",
      { title: "ComputeCAW", description: "CAW computation inputs.", fields: [
        s.required_str("vin", []),
        s.required_float("current_soc_pct", []),
        s.required_float("battery_capacity_kwh", []),
        s.required_str("segments_json", []),
        s.required_float("available_charge_min", []),
        s.optional(s.required_float("max_charge_power_kw", [])),
        s.optional(s.required_float("safety_buffer_pct", [])),
      ] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        let segs  := match jv.parse(arg_str(args, "segments_json")) { Ok(j) => j, Err(_) => JList([]) }
        let power  := arg_float(args, "max_charge_power_kw")
        let safety := arg_float(args, "safety_buffer_pct")
        let body  := jv.stringify(JObj([
          ("vin",                  JStr(arg_str(args, "vin"))),
          ("current_soc_pct",      JFloat(arg_float(args, "current_soc_pct"))),
          ("battery_capacity_kwh", JFloat(arg_float(args, "battery_capacity_kwh"))),
          ("segments",             segs),
          ("available_charge_min", JFloat(arg_float(args, "available_charge_min"))),
          ("max_charge_power_kw",  JFloat(if power  > 0.0 { power  } else { 150.0 })),
          ("safety_buffer_pct",    JFloat(if safety > 0.0 { safety } else { 15.0  })),
        ]))
        call_post(str.concat(logistics_url, "/api/v1/caw/persist"), body)
      }
    ),
    t.define(
      "get_vehicle_telemetry",
      "Get live telemetry for a vehicle: soc_percent, estimated_range_km, charging_status, latitude, longitude, speed_kmh, odometer_km.",
      { title: "GetVehicleTelemetry", description: "Telemetry lookup.", fields: [s.required_str("vin", [])] },
      fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
        call_get(str.concat(telemetry_url, str.concat("/vehicles/", str.concat(arg_str(args, "vin"), "/telemetry/latest"))))
      }
    ),
  ]
}
