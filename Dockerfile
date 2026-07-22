# lex-soft Dockerfile
# Build context: workspace root
#
# The lex runtime is fetched from the prebuilt lex-lang release.

FROM debian:12-slim

ARG LEX_VERSION=0.10.7
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
      amd64) A=x86_64-unknown-linux-gnu ;; \
      arm64) A=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
    curl -fsSL "https://github.com/alpibrusl/lex-lang/releases/download/v${LEX_VERSION}/lex-v${LEX_VERSION}-${A}.tar.gz" \
      | tar -xz -C /usr/local/bin --strip-components=1 --wildcards '*/lex' \
 && lex --version

COPY lex-schema/  /app/lex-schema/
COPY lex-trail/   /app/lex-trail/
COPY lex-crypto/  /app/lex-crypto/
COPY lex-orm/     /app/lex-orm/
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
