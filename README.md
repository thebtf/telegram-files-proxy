# telegram-files-proxy

Drop-in replacement for [aiogram/telegram-bot-api](https://hub.docker.com/r/aiogram/telegram-bot-api) that adds HTTP file serving in local mode.

## Problem

In local mode (`--local`), the Bot API server returns absolute file paths instead of serving files via HTTP.
This removes the 20MB download limit but breaks remote file access — bots on other machines can't read local paths.

## Solution

This image embeds nginx as a reverse proxy inside the telegram-bot-api container.
`--local` mode is **always enabled** (2GB uploads, local webhooks). The `TELEGRAM_LOCAL` variable
controls whether nginx is active — not the `--local` flag itself.

### TELEGRAM_LOCAL behavior

| Value | nginx | bot-api | File access |
|-------|-------|---------|-------------|
| `true` / `1` (default) | OFF | :8081 direct | Absolute paths (original behavior) |
| `false` / `0` | ON (:8081) | :8083 internal | HTTP via nginx (remote-like) |

### Proxy mode architecture (`TELEGRAM_LOCAL=false`)

```
Bot (remote) → nginx:8081 → /bot{token}/*       → bot-api:8083 (API + path rewriting)
                           → /file/bot{token}/*  → disk via sendfile (zero-copy + IP whitelist)
                           → /*                  → bot-api:8083 (fallback)
```

- **API calls** (`/bot*`) are proxied with `sub_filter` to rewrite absolute paths to relative
- **File downloads** (`/file/*`) are served directly from disk via nginx `sendfile` (zero-copy, no userspace buffering) with IP whitelist
- **IP whitelist** restricts who can download files (deny-all by default)
- **No file size limit** — bot-api runs in `--local` mode regardless

## Usage

### Default mode (original behavior)

```bash
docker run -d \
  --name telegram-bot-api \
  -p 8081:8081 \
  -v /path/to/data:/var/lib/telegram-bot-api \
  -e TELEGRAM_API_ID=12345 \
  -e TELEGRAM_API_HASH=abcdef \
  thebtf/telegram-files-proxy:latest
```

### Proxy mode (HTTP file serving)

```bash
docker run -d \
  --name telegram-bot-api \
  -p 8081:8081 \
  -v /path/to/data:/var/lib/telegram-bot-api \
  -e TELEGRAM_API_ID=12345 \
  -e TELEGRAM_API_HASH=abcdef \
  -e TELEGRAM_LOCAL=false \
  -e ALLOWED_IPS="192.168.1.100,10.0.0.0/24" \
  thebtf/telegram-files-proxy:latest
```

### Environment Variables

All standard [aiogram/telegram-bot-api](https://github.com/aiogram/telegram-bot-api-docker) variables are supported, plus:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TELEGRAM_LOCAL` | No | `true` | `true` = direct mode (no nginx), `false` = proxy mode (nginx reverse proxy) |
| `ALLOWED_IPS` | When proxy mode | *(empty — deny all)* | Comma-separated IPs/CIDRs for file download access |
| `PUID` | No | `1026` | User ID for file ownership (host volume mapping) |
| `PGID` | No | `100` | Group ID for file ownership (host volume mapping) |
| `CLIENT_MAX_BODY_SIZE` | No | `20m` | Max upload size through nginx (proxy mode only, e.g. `2000m`) |

### How Proxy Mode Works

1. Bot calls `getFile` → nginx proxies to bot-api → response rewritten to strip path prefix
2. Bot library constructs download URL: `http://host:8081/file/bot{TOKEN}/{file_path}`
3. nginx serves the file directly from disk via `sendfile` (zero-copy: disk → kernel → network), enforcing IP whitelist

### Security

- **Deny-all by default** for file downloads — `ALLOWED_IPS` is mandatory in proxy mode
- API calls (`/bot*`) are unrestricted (bot token is the auth)
- `.binlog`, `.db`, `.sqlite` files are blocked
- Hidden files (dotfiles) are blocked
- Path traversal (`..`) is blocked
- IP/CIDR values in `ALLOWED_IPS` are validated at startup (rejects malformed input)
- `TELEGRAM_HTTP_PORT` is validated as integer 1-65535

## License

MIT
