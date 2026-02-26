# telegram-files-proxy

Nginx-based HTTP file proxy for [Telegram Bot API](https://github.com/tdlib/telegram-bot-api) local mode.

## Why

In local mode (`--local`), the Bot API server returns absolute file paths instead of serving files via HTTP.
This is by design — local mode assumes filesystem co-location.

If your bot runs on a **different machine**, it can't access those paths. This container bridges that gap:
mount the Bot API data directory and serve files over HTTP with IP-based access control.

## Usage

```bash
docker run -d \
  --name telegram-files-proxy \
  -p 8088:8080 \
  -v /path/to/telegram-bot-api/data:/data:ro \
  -e ALLOWED_IPS="192.168.1.100,10.0.0.0/24" \
  thebtf/telegram-files-proxy:latest
```

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ALLOWED_IPS` | **Yes** | *(empty — deny all)* | Comma-separated IPs or CIDRs allowed to access files |
| `LISTEN_PORT` | No | `8080` | Port nginx listens on inside the container |

### Bot Integration

1. Bot calls `getFile` → gets absolute path: `/var/lib/telegram-bot-api/{token}/photos/file_2.jpg`
2. Strip the prefix `/var/lib/telegram-bot-api/` (the container's internal data path)
3. Construct URL: `http://<proxy-host>:<port>/{token}/photos/file_2.jpg`

### Security

- **Deny-all by default** — if `ALLOWED_IPS` is empty, all requests are rejected
- `.binlog`, `.db`, `.sqlite` files are blocked
- Hidden files (dotfiles) are blocked
- No directory listing
- Read-only volume mount recommended

## License

MIT
