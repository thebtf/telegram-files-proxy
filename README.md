# telegram-files-proxy

Drop-in replacement for [aiogram/telegram-bot-api](https://hub.docker.com/r/aiogram/telegram-bot-api) that adds HTTP file serving in local mode.

## Problem

In local mode (`--local`), the Bot API server returns absolute file paths instead of serving files via HTTP.
This removes the 20MB download limit but breaks remote file access — bots on other machines can't read local paths.

## Solution

This image embeds nginx as a reverse proxy inside the telegram-bot-api container:

```
Bot (remote) → nginx:8081 → /bot{token}/*       → telegram-bot-api:8083 (internal)
                           → /file/bot{token}/*  → filesystem (direct serve)
```

- **API calls** are proxied transparently to the internal bot-api
- **`getFile` responses** are rewritten: absolute paths become relative (via `sub_filter`)
- **File downloads** are served directly by nginx from the data directory
- **IP whitelist** restricts who can download files (deny-all by default)
- **No file size limit** — bot-api runs in local mode

## Usage

```bash
docker run -d \
  --name telegram-bot-api \
  -p 8081:8081 \
  -v /path/to/data:/var/lib/telegram-bot-api \
  -e TELEGRAM_API_ID=12345 \
  -e TELEGRAM_API_HASH=abcdef \
  -e TELEGRAM_LOCAL=1 \
  -e ALLOWED_IPS="192.168.1.100,10.0.0.0/24" \
  thebtf/telegram-files-proxy:latest
```

### Environment Variables

All standard [aiogram/telegram-bot-api](https://github.com/aiogram/telegram-bot-api-docker) variables are supported, plus:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ALLOWED_IPS` | **Yes** | *(empty — deny all)* | Comma-separated IPs/CIDRs for file download access |

### How It Works

1. Bot calls `getFile` → nginx proxies to bot-api → response rewritten to strip prefix
2. Bot library constructs download URL using standard pattern: `http://host:8081/file/bot{TOKEN}/{file_path}`
3. nginx serves the file directly from the filesystem — no 20MB limit

### Security

- **Deny-all by default** for file downloads — `ALLOWED_IPS` is mandatory
- API calls (`/bot*`) are unrestricted (bot token is the auth)
- `.binlog`, `.db`, `.sqlite` files are blocked
- Hidden files (dotfiles) are blocked

## License

MIT
