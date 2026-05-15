# peers.lex — static peer map.
#
# In a multi-process deployment, each peer URL would point at that
# agent's `lex serve`. For the in-process demo, every agent is hosted
# at localhost:8080 — A2A becomes a self-loopback POST, which still
# exercises the HTTP path end-to-end.

import "lex-soft/a2a" as a2a

fn local() -> List[a2a.Peer] {
  [
    { name: "vehicle", url: "http://localhost:8080" },
    { name: "depot",   url: "http://localhost:8080" },
    { name: "depot2",  url: "http://localhost:8080" },
    { name: "pv",      url: "http://localhost:8080" },
    { name: "tms",     url: "http://localhost:8080" },
  ]
}
