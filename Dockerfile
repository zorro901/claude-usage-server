FROM alpine:3.24.1

RUN apk add --no-cache bash curl jq coreutils findutils

WORKDIR /app

COPY scripts/claude-usage-report.sh /app/scripts/claude-usage-report.sh
COPY docker/entrypoint.sh /app/docker/entrypoint.sh

RUN chmod 755 /app/scripts/claude-usage-report.sh /app/docker/entrypoint.sh

ENV CLAUDE_HOME=/claude-home

ENTRYPOINT ["/app/docker/entrypoint.sh"]
