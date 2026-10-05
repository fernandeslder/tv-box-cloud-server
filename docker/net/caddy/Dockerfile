# Caddy + Cloudflare DNS plugin (needed for trusted wildcard certs via DNS-01).
# Built locally on first `docker compose up` (~2 min). Pinned for reproducibility.
FROM caddy:2.11-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2.11-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
