FROM oven/bun:1.4.0-debian AS bun
FROM node:26-bookworm-slim
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl ca-certificates git dbus dbus-x11 gnome-keyring libsecret-1-0 libsecret-tools procps \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
COPY scripts/linux/session.sh /usr/local/bin/pi-remote-test-session
RUN chmod 755 /usr/local/bin/pi-remote-test-session
ENTRYPOINT ["dbus-run-session", "--", "/usr/local/bin/pi-remote-test-session"]
