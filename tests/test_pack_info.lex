# tests/test_pack_info.lex — the DomainPack agent-domain manifest (PackInfo)
# serializes to the JSON shape consoles read from /platform/packs's
# agent_packs field.

import "lex-schema/json_value" as jv

import "../src/pack" as pack

fn sample() -> pack.PackInfo {
  { name: "logistics", title: "Logistics", tagline: "Moving goods.", personas: [{ kind: "truck", title: "Truck", tagline: "Runs the routes.", suggested_prompts: ["What is your status?"] }] }
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

fn test_info_json_shape() -> Result[Unit, Str] {
  let s := jv.stringify(pack.info_json(sample()))
  if str.contains(s, "\"personas\"") {
    assert_true(str.contains(s, "\"suggested_prompts\""), "suggested_prompts missing from serialized PackInfo")
  } else {
    Err("personas missing from serialized PackInfo")
  }
}

fn test_infos_json_is_list() -> Result[Unit, Str] {
  match pack.infos_json([sample()]) {
    JList(items) => assert_true(list.len(items) == 1, "one info serializes to one list entry"),
    _ => Err("infos_json must serialize to a JSON list"),
  }
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_info_json_shape(), test_infos_json_is_list()]
}

