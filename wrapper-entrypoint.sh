#!/bin/sh
set -e

# =============================================================================
# telegram-files-proxy wrapper entrypoint
#
# TELEGRAM_LOCAL controls nginx proxy, NOT the --local flag:
#   true/1  (default) = nginx OFF, bot-api serves directly (original behavior)
#   false/0           = nginx ON,  bot-api behind reverse proxy with file serving
#
# --local is ALWAYS enabled regardless of TELEGRAM_LOCAL value.
# =============================================================================

# --- Validation helpers ---
validate_port() {
    echo "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_cidr() {
    # Accept IPv4, IPv4/CIDR, IPv6, IPv6/CIDR — reject everything else
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^[0-9a-fA-F:]+(/[0-9]{1,3})?$'
}

# --- 1. Determine proxy mode from user's TELEGRAM_LOCAL ---
USER_LOCAL="${TELEGRAM_LOCAL:-true}"

case "$USER_LOCAL" in
    false|0|no|off)
        PROXY_MODE=true
        ;;
    *)
        PROXY_MODE=false
        ;;
esac

# Force --local ON for the aiogram entrypoint (always)
export TELEGRAM_LOCAL=1

# --- 2. If no proxy mode, just run the original entrypoint ---
if [ "$PROXY_MODE" = "false" ]; then
    echo "telegram-files-proxy: proxy OFF (TELEGRAM_LOCAL=true), direct mode"
    exec /docker-entrypoint.sh
fi

# =============================================================================
# PROXY MODE: nginx reverse proxy + sendfile for file downloads
# =============================================================================

echo "telegram-files-proxy: proxy ON (TELEGRAM_LOCAL=false)"

# --- 3. Validate ALLOWED_IPS ---
if [ -z "$ALLOWED_IPS" ]; then
    echo "WARNING: ALLOWED_IPS is empty. File downloads will be denied for all IPs."
    echo "Set ALLOWED_IPS to a comma-separated list of IPs/CIDRs (e.g. '192.168.1.100,10.0.0.0/24')"
fi

# --- 4. Generate IP whitelist block for /file/ location ---
ALLOW_BLOCK=""
if [ -n "$ALLOWED_IPS" ]; then
    OLD_IFS="$IFS"
    IFS=','
    for ip in $ALLOWED_IPS; do
        ip=$(echo "$ip" | tr -d ' ')
        if [ -n "$ip" ]; then
            if ! validate_cidr "$ip"; then
                echo "ERROR: Invalid IP/CIDR in ALLOWED_IPS: '$ip'" >&2
                exit 1
            fi
            ALLOW_BLOCK="${ALLOW_BLOCK}
        allow ${ip};"
        fi
    done
    IFS="$OLD_IFS"
fi

# --- 5. Validate and override TELEGRAM_HTTP_PORT to internal port ---
# nginx will listen on the original port (8081), bot-api on internal 8083
ORIGINAL_PORT="${TELEGRAM_HTTP_PORT:-8081}"
if ! validate_port "$ORIGINAL_PORT"; then
    echo "ERROR: Invalid TELEGRAM_HTTP_PORT value: '$ORIGINAL_PORT'" >&2
    exit 1
fi
export TELEGRAM_HTTP_PORT=8083

# --- 6. Generate nginx config ---
mkdir -p /etc/nginx/http.d
cat > /etc/nginx/http.d/default.conf << NGINX_EOF
server {
    listen ${ORIGINAL_PORT};
    server_name _;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # --- Defense-in-depth: block path traversal at server level ---
    location ~ \.\. {
        return 403;
    }

    # --- API calls: proxy with path rewriting ---
    location ~ ^/bot {
        proxy_pass http://127.0.0.1:8083;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;

        # Disable upstream compression so sub_filter works
        proxy_set_header Accept-Encoding "";

        # Rewrite getFile response: strip absolute path prefix
        # "/var/lib/telegram-bot-api/TOKEN/path" -> "TOKEN/path"
        # Bot library then constructs: /file/bot{TOKEN}/{file_path}
        sub_filter_types application/json;
        sub_filter '"/var/lib/telegram-bot-api/' '"';
        sub_filter_once off;
    }

    # --- File downloads: IP-restricted proxy to bot-api ---
    # bot-api in --local mode serves files at /file/bot{TOKEN}/{path}
    location /file/ {${ALLOW_BLOCK}
        deny all;

        proxy_pass http://127.0.0.1:8083;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # --- Fallback: proxy everything else to bot-api ---
    location / {
        proxy_pass http://127.0.0.1:8083;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Block database/internal files
    location ~* \.(binlog|db|sqlite|log)\$ {
        return 404;
    }

    # Block hidden files
    location ~ /\. {
        return 404;
    }
}
NGINX_EOF

# --- 7. Validate and start nginx ---
echo "telegram-files-proxy: nginx on :${ORIGINAL_PORT} -> bot-api on :8083"
echo "telegram-files-proxy: file downloads allowed for: ${ALLOWED_IPS:-NONE}"
nginx -t 2>&1 || { echo "ERROR: nginx config validation failed" >&2; exit 1; }
nginx 2>&1 || { echo "ERROR: nginx failed to start" >&2; exit 1; }

# --- 8. Run original entrypoint (foreground, PID 1) ---
exec /docker-entrypoint.sh
