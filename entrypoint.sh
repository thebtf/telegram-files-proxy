#!/bin/sh
set -e

# Fail-safe: if no IPs specified, deny everything
if [ -z "$ALLOWED_IPS" ]; then
    echo "ERROR: ALLOWED_IPS is empty. All requests will be denied."
    echo "Set ALLOWED_IPS to a comma-separated list of IPs/CIDRs (e.g. '192.168.1.100,10.0.0.0/24')"
fi

# Generate allow directives from comma-separated ALLOWED_IPS
ALLOW_BLOCK=""
if [ -n "$ALLOWED_IPS" ]; then
    OLD_IFS="$IFS"
    IFS=','
    for ip in $ALLOWED_IPS; do
        ip=$(echo "$ip" | tr -d ' ')
        if [ -n "$ip" ]; then
            ALLOW_BLOCK="$ALLOW_BLOCK
    allow $ip;"
        fi
    done
    IFS="$OLD_IFS"
fi

PORT="${LISTEN_PORT:-8080}"

cat > /etc/nginx/conf.d/default.conf << NGINX_EOF
server {
    listen ${PORT};
    server_name _;

    # --- IP whitelist (generated from ALLOWED_IPS) ---
${ALLOW_BLOCK}
    deny all;

    root /data;
    autoindex off;

    # Security headers
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header X-Robots-Tag noindex always;
    add_header Cache-Control "no-store" always;

    # Serve static files only
    location / {
        try_files \$uri =404;
    }

    # Block internal database files
    location ~* \.(binlog|db|sqlite)$ {
        deny all;
        return 404;
    }

    # Block hidden files
    location ~ /\. {
        deny all;
        return 404;
    }
}
NGINX_EOF

echo "telegram-files-proxy: listening on :${PORT}, allowed IPs: ${ALLOWED_IPS:-NONE}"
exec "$@"
