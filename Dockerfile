# lex-soft Dockerfile
# Build context: workspace root
#   docker build -f lex-soft/Dockerfile -t lex-soft .

ARG RUST_VERSION=1.94

# ── Stage 1: dependency cache (cargo-chef) ─────────────────────────
FROM rust:${RUST_VERSION}-bookworm AS chef
WORKDIR /build
RUN cargo install cargo-chef --locked --version 0.1.71

FROM chef AS planner
COPY lex-lang/ .
RUN cargo chef prepare --recipe-path recipe.json

# ── Stage 2: compile lex (exported as lex-builder for reuse) ───────
FROM chef AS lex-builder
COPY --from=planner /build/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json --bin lex
COPY lex-lang/ .
RUN cargo build --release --bin lex && strip /build/target/release/lex

# ── Stage 3: runtime ───────────────────────────────────────────────
FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=lex-builder /build/target/release/lex /usr/local/bin/lex

COPY lex-schema/  /app/lex-schema/
COPY lex-web/     /app/lex-web/
COPY lex-llm/     /app/lex-llm/
COPY lex-agent/   /app/lex-agent/
COPY lex-jobs/    /app/lex-jobs/
COPY lex-log/     /app/lex-log/
COPY lex-spec/    /app/lex-spec/
COPY lex-cli/     /app/lex-cli/
COPY lex-mcp/     /app/lex-mcp/
COPY lex-soft/    /app/lex-soft/

WORKDIR /app/lex-soft

ENV PORT=9000 \
    DB_URL=platform.db

EXPOSE 9000

CMD ["lex", "run", \
     "--allow-effects", "net,io,env,time,random,sql,fs_read,fs_write,concurrent,llm,proc,crypto", \
     "src/soft.lex", "start_platform"]
