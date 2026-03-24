# ── Docker Autostart Runner ───────────────────────────────────────────────────
# Runs autostart.sh inside a container while controlling the HOST Docker daemon
# via socket mount:
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock autostart
#
# The container needs no special privileges — just the socket bind mount.

FROM alpine:3.19

# docker CLI + netcat (for wait_for_port probing) + coreutils for date
RUN apk add --no-cache \
      docker-cli \
      netcat-openbsd \
      coreutils

WORKDIR /app

COPY autostart.sh .
RUN chmod +x autostart.sh

ENTRYPOINT ["sh", "/app/autostart.sh"]
