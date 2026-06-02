# ev_fleet Dockerfile
# Build context: workspace root
# docker build -f lex-soft/examples/ev_fleet/Dockerfile -t ev-fleet .

FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY lex-lang/target/release/lex /usr/local/bin/lex
RUN chmod +x /usr/local/bin/lex

COPY lex-schema/              /app/lex-schema/
COPY lex-web/                 /app/lex-web/
COPY lex-llm/                 /app/lex-llm/
COPY lex-agent/               /app/lex-agent/
COPY lex-jobs/                /app/lex-jobs/
COPY lex-log/                 /app/lex-log/
COPY lex-spec/                /app/lex-spec/
COPY lex-cli/                 /app/lex-cli/
COPY lex-mcp/                 /app/lex-mcp/
COPY lex-soft/                /app/lex-soft/

WORKDIR /app/lex-soft/examples/ev_fleet

ENV PORT=8100 \
    DB_PATH=/data/ev_fleet.db

EXPOSE 8100

CMD ["lex", "run", \
     "--allow-effects", "net,io,env,time,random,sql,fs_read,fs_write,concurrent,llm,proc,crypto", \
     "main.lex", "main"]
