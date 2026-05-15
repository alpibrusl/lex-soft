# message.lex — A2A message envelope.
#
# Matches the shape soft's Rust runner posted to `/a2a/messages`:
# `{ from, topic, payload_json }`. The payload stays opaque (Str) so
# agents that don't need to parse it can ignore the format.

import "lex-schema/schema"      as s
import "lex-schema/constraints" as c

type Message = { from :: Str, topic :: Str, payload_json :: Str }

fn new(from :: Str, topic :: Str, payload_json :: Str) -> Message {
  { from: from, topic: topic, payload_json: payload_json }
}

# lex-schema validator for the inbox request body.
fn envelope_schema() -> s.ModelSchema {
  { title: "a2a_message", description: "A2A envelope",
    fields: [
      s.required_str("from",         [c.StrNonEmpty]),
      s.required_str("topic",        [c.StrNonEmpty]),
      s.required_str("payload_json", []),
    ] }
}
