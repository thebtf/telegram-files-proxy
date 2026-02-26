#!/bin/sh
# =============================================================================
# telegram-files-proxy integration tests
# Builds Docker image and validates nginx config, routing, and file serving
# =============================================================================

IMAGE="tfp-test"
CONTAINER="tfp-test-$$"
TESTS=0; PASSED=0; FAILED=0

# --- Helpers ---
cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

test_case() {
    TESTS=$((TESTS + 1))
    printf "  [%02d] %-60s " "$TESTS" "$1"
}

pass() { PASSED=$((PASSED + 1)); echo "OK"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL${1:+: $1}"; }

# HTTP via curl (installed in test container)
http_get() {
    HTTP_CODE=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8081$1" 2>/dev/null)
    HTTP_BODY=$(docker exec "$CONTAINER" curl -s "http://127.0.0.1:8081$1" 2>/dev/null)
}

wait_for_port() {
    local port=$1 max=$2 i=0
    while [ $i -lt $max ]; do
        if docker exec "$CONTAINER" curl -sf -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null ||
           docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null | grep -qE '^[1-5]'; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

start_proxy_container() {
    # Use $# to distinguish "no arg" (default IPs) from "empty arg" (deny all)
    local allowed_ips
    if [ $# -gt 0 ]; then
        allowed_ips="$1"
    else
        allowed_ips="127.0.0.0/8,192.168.1.0/24,10.0.0.1"
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" \
        -e TELEGRAM_LOCAL=false \
        -e ALLOWED_IPS="$allowed_ips" \
        -e TELEGRAM_API_ID=12345 \
        -e TELEGRAM_API_HASH=abcdef1234567890abcdef1234567890 \
        --entrypoint sh "$IMAGE" -c '
            cat > /docker-entrypoint.sh << "INNER"
#!/bin/sh
echo "ENTRYPOINT_REACHED"
exec sleep 3600
INNER
            chmod +x /docker-entrypoint.sh
            exec /wrapper-entrypoint.sh
        ' >/dev/null 2>&1
    sleep 3
    # Install curl for HTTP testing (BusyBox wget lacks -S flag)
    docker exec "$CONTAINER" apk add --no-cache curl >/dev/null 2>&1
}

# =============================================================================
echo "=== Building image ==="
docker build -t "$IMAGE" -q . || { echo "BUILD FAILED"; exit 1; }
echo ""

# =============================================================================
echo "=== Shell validation ==="

test_case "wrapper-entrypoint.sh is valid POSIX shell"
docker run --rm --entrypoint sh "$IMAGE" -c "sh -n /wrapper-entrypoint.sh" 2>/dev/null && pass || fail

# =============================================================================
echo ""
echo "=== Proxy mode: nginx config ==="

start_proxy_container "127.0.0.0/8,192.168.1.0/24,10.0.0.1"

test_case "container is running"
docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true" && pass || fail

test_case "entrypoint reached (no crash before exec)"
docker logs "$CONTAINER" 2>&1 | grep -q "ENTRYPOINT_REACHED" && pass || \
    fail "$(docker logs "$CONTAINER" 2>&1 | grep -i error | head -1)"

test_case "nginx -t passes inside container"
docker exec "$CONTAINER" nginx -t 2>&1 | grep -q "test is successful" && pass || \
    fail "$(docker exec "$CONTAINER" nginx -t 2>&1)"

test_case "nginx process is running"
docker exec "$CONTAINER" pgrep nginx >/dev/null 2>&1 && pass || fail

test_case "nginx listens on port 8081"
wait_for_port 8081 5 && pass || fail "port 8081 not responding"

test_case "nginx config has listen 8081"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "listen.*8081" && pass || fail

test_case "nginx config has client_max_body_size"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "client_max_body_size" && pass || fail

test_case "nginx config has client_body_buffer_size 16m"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "client_body_buffer_size 16m" && pass || fail

test_case "nginx temp directory on data volume (not overlay fs)"
docker exec "$CONTAINER" sh -c 'test -d /var/lib/telegram-bot-api/.nginx_temp && touch /var/lib/telegram-bot-api/.nginx_temp/test_write && rm /var/lib/telegram-bot-api/.nginx_temp/test_write' && pass || fail

test_case "nginx config has client_body_temp_path"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "client_body_temp_path" && pass || fail

test_case "nginx config has sendfile enabled"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "sendfile on" && pass || fail

test_case "nginx config has file download location"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "/file/bot" && pass || fail

test_case "nginx config has allow 192.168.1.0/24"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "allow 192.168.1.0/24" && pass || fail

test_case "nginx config has allow 10.0.0.1"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "allow 10.0.0.1" && pass || fail

test_case "nginx config has deny all"
docker exec "$CONTAINER" nginx -T 2>&1 | grep -q "deny all" && pass || fail

# --- File serving ---
test_case "file serving: create test file on disk"
docker exec "$CONTAINER" sh -c '
    mkdir -p /var/lib/telegram-bot-api/TESTTOKEN123/photos
    echo "hello-sendfile" > /var/lib/telegram-bot-api/TESTTOKEN123/photos/test.jpg
    chown -R telegram-bot-api:telegram-bot-api /var/lib/telegram-bot-api/TESTTOKEN123
' 2>/dev/null && pass || fail

test_case "file serving: GET /file/bot.../test.jpg returns 200"
http_get "/file/botXYZ/TESTTOKEN123/photos/test.jpg"
[ "$HTTP_CODE" = "200" ] && pass || fail "got HTTP $HTTP_CODE"

test_case "file serving: response body matches file content"
echo "$HTTP_BODY" | grep -q "hello-sendfile" && pass || fail "got '$HTTP_BODY'"

# --- Security ---
test_case "security: hidden files (/.) returns 404"
http_get "/.hidden"
[ "$HTTP_CODE" = "404" ] && pass || fail "got HTTP $HTTP_CODE"

test_case "security: .binlog file returns 404"
docker exec "$CONTAINER" sh -c '
    echo "secret" > /var/lib/telegram-bot-api/TESTTOKEN123/data.binlog
' 2>/dev/null
http_get "/file/botXYZ/TESTTOKEN123/data.binlog"
[ "$HTTP_CODE" = "404" ] && pass || fail "got HTTP $HTTP_CODE"

# --- Bot API proxy ---
test_case "proxy: /bot* -> upstream (expect 502, bot-api not running)"
http_get "/bot123456:AABBCC/getMe"
[ "$HTTP_CODE" = "502" ] && pass || fail "got HTTP $HTTP_CODE"

test_case "proxy: fallback / -> upstream (expect 502)"
http_get "/"
[ "$HTTP_CODE" = "502" ] && pass || fail "got HTTP $HTTP_CODE"

cleanup

# =============================================================================
echo ""
echo "=== Proxy mode: deny all (empty ALLOWED_IPS) ==="

start_proxy_container ""

test_case "deny-all: nginx starts with empty ALLOWED_IPS"
docker exec "$CONTAINER" pgrep nginx >/dev/null 2>&1 && pass || fail

test_case "deny-all: file request returns 403"
docker exec "$CONTAINER" sh -c '
    mkdir -p /var/lib/telegram-bot-api/TOK/photos
    echo "test" > /var/lib/telegram-bot-api/TOK/photos/f.jpg
    chown -R telegram-bot-api:telegram-bot-api /var/lib/telegram-bot-api/TOK
' 2>/dev/null
http_get "/file/botTOK/TOK/photos/f.jpg"
[ "$HTTP_CODE" = "403" ] && pass || fail "got HTTP $HTTP_CODE"

cleanup

# =============================================================================
echo ""
echo "=== Direct mode ==="

test_case "direct mode: logs show 'proxy OFF'"
LOGS=$(docker run --rm \
    -e TELEGRAM_LOCAL=true \
    -e TELEGRAM_API_ID=12345 \
    -e TELEGRAM_API_HASH=abcdef1234567890abcdef1234567890 \
    --entrypoint sh "$IMAGE" -c '
        cat > /docker-entrypoint.sh << "INNER"
#!/bin/sh
echo "DIRECT_MODE_OK"
INNER
        chmod +x /docker-entrypoint.sh
        exec /wrapper-entrypoint.sh
    ' 2>&1)
echo "$LOGS" | grep -q "proxy OFF" && pass || fail

# =============================================================================
echo ""
echo "=== PUID/PGID ==="

test_case "PUID/PGID: user remapped to 1234:5678"
RESULT=$(docker run --rm \
    -e PUID=1234 \
    -e PGID=5678 \
    -e TELEGRAM_LOCAL=true \
    -e TELEGRAM_API_ID=12345 \
    -e TELEGRAM_API_HASH=abcdef1234567890abcdef1234567890 \
    --entrypoint sh "$IMAGE" -c '
        cat > /docker-entrypoint.sh << "INNER"
#!/bin/sh
id telegram-bot-api
INNER
        chmod +x /docker-entrypoint.sh
        /wrapper-entrypoint.sh 2>&1
    ' 2>&1)
echo "$RESULT" | grep -q "uid=1234" && pass || fail "$(echo "$RESULT" | grep 'uid=')"

# =============================================================================
echo ""
echo "==========================================="
printf "  TOTAL: %d  PASSED: %d  FAILED: %d\n" "$TESTS" "$PASSED" "$FAILED"
echo "==========================================="

[ "$FAILED" -eq 0 ] && echo "ALL TESTS PASSED" && exit 0
echo "SOME TESTS FAILED" && exit 1
