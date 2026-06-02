# lex-soft Dockerfile
#
# Build context must be the workspace root (one level above lex-soft):
#   docker build -f lex-soft/Dockerfile -t lex-soft .
#
# Handled automatically by docker-compose.yml (context: ../).

FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY lex-lang/target/release/lex /usr/local/bin/lex
RUN chmod +x /usr/local/bin/lex

# Platform dependencies
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
