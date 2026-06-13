#!/bin/bash
# run-benchmarks.sh — WSL/Linux benchmark runner for MiniGateway
# Run from the project root: bash scripts/run-benchmarks.sh

GATEWAY="http://localhost:8080"
ADMIN="http://localhost:9090"
METRICS="http://localhost:2112"
GW_PID="" UA_PID="" UB_PID=""

cleanup() {
    echo ""
    echo "Stopping services..."
    [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true
    [ -n "$UA_PID" ] && kill "$UA_PID" 2>/dev/null || true
    [ -n "$UB_PID" ] && kill "$UB_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- build ----
echo ""
echo "=== MiniGateway Benchmarks (WSL / compiled binary) ==="
echo ""
echo "Building binaries..."
mkdir -p bin
go build -o bin/gateway    ./cmd/gateway    || { echo "ERROR: build failed"; exit 1; }
go build -o bin/mockserver ./cmd/mockserver || { echo "ERROR: build failed"; exit 1; }
echo "Build OK."

# ---- start services ----
echo "Starting upstream-a, upstream-b, gateway..."
SERVER_NAME=upstream-a PORT=5000 ./bin/mockserver >/tmp/ua.log 2>&1 & UA_PID=$!
SERVER_NAME=upstream-b PORT=6000 ./bin/mockserver >/tmp/ub.log 2>&1 & UB_PID=$!
./bin/gateway config/gateway.yaml >/tmp/gw.log 2>&1 & GW_PID=$!

echo "Waiting for gateway on :8080..."
for i in $(seq 1 40); do
    curl -sf "$GATEWAY/api/v1/ping" >/dev/null 2>&1 && break
    sleep 0.5
done
if ! curl -sf "$GATEWAY/api/v1/ping" >/dev/null 2>&1; then
    echo "ERROR: gateway did not start. Check /tmp/gw.log"
    exit 1
fi
echo "Gateway is up."

# ---- ensure GOPATH/bin is in PATH ----
export PATH=$PATH:$(go env GOPATH)/bin

# ---- install hey if missing ----
if ! command -v hey &>/dev/null; then
    echo "Installing hey..."
    go install github.com/rakyll/hey@latest
fi
echo "hey: $(command -v hey)"
echo ""

# ---- helpers ----
update_v1() {
    curl -sf -X POST "$ADMIN/admin/routes" \
        -H "Content-Type: application/json" -d "$1" >/dev/null
}
restore_v1() {
    update_v1 '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":true,"requests_per_second":100.0,"burst":20},"cache":{"enabled":true,"ttl_seconds":30,"max_entries":1000},"auth":{"enabled":false}}}'
}

get_p_ms() {
    # $1 = hey output, $2 = percentile number (e.g. 50, 99)
    # hey line: "  50%% in 0.0007 secs"  (some terminals/versions double the %)
    # Strip all % from field 1 and compare numerically to handle both formats.
    local secs
    secs=$(printf '%s\n' "$1" | tr -d '\r' | awk -v p="$2" '
        {
            n = $1; gsub(/%/, "", n)
            if (n == p && $2 == "in" && NF >= 3) { print $3; exit }
        }
    ')
    awk -v v="${secs:-0}" 'BEGIN { printf "%.2f", v * 1000 }'
}
get_rps() {
    echo "$1" | grep 'Requests/sec:' | awk '{printf "%.0f", $2}'
}
get_status_count() {
    echo "$1" | grep -F "[$2]" | awk '{print $2}'
}

# ============================================================
# Benchmark A — proxy overhead (no plugins)
# ============================================================
echo "--- Benchmark A: Proxy Overhead (no plugins, 5000 req, c=50) ---"

update_v1 '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'
sleep 0.2

OUT_A=$(hey -n 5000 -c 50 "$GATEWAY/api/v1/bench-a" 2>&1)
printf '%s\n' "$OUT_A" > /tmp/hey-bench-a.txt
echo "$OUT_A" | grep -E 'Requests/sec:|% in|\[200\]'

P50_A=$(get_p_ms "$OUT_A" 50)
P99_A=$(get_p_ms "$OUT_A" 99)
RPS_A=$(get_rps "$OUT_A")

echo "  => p50=${P50_A}ms  p99=${P99_A}ms  rps=${RPS_A}"
restore_v1

# ============================================================
# Benchmark B — cache hit rate
# ============================================================
echo ""
echo "--- Benchmark B: Cache Hit Rate (same URL, 10000 req, c=50) ---"

update_v1 '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":true,"ttl_seconds":30,"max_entries":1000},"auth":{"enabled":false}}}'
sleep 0.2

echo "  Warming cache (1000 req)..."
hey -n 1000 -c 10 "$GATEWAY/api/v1/bench-b-key" >/dev/null 2>&1

OUT_B=$(hey -n 10000 -c 50 "$GATEWAY/api/v1/bench-b-key" 2>&1)
echo "$OUT_B" | grep -E 'Requests/sec:|50% in|99% in|\[200\]'

P50_B=$(get_p_ms "$OUT_B" 50)
P99_B=$(get_p_ms "$OUT_B" 99)
RPS_B=$(get_rps "$OUT_B")

sleep 0.3
MRAW=$(curl -s "$METRICS/metrics")
HITS=$(echo "$MRAW" | grep 'minigateway_cache_hits_total{route="/api/v1/"}' | tail -1 | awk '{print $NF}')
MISS=$(echo "$MRAW" | grep 'minigateway_cache_misses_total{route="/api/v1/"}' | tail -1 | awk '{print $NF}')
UPR=$(echo  "$MRAW" | grep 'minigateway_upstream_requests_total{route="/api/v1/"'        | tail -1 | awk '{print $NF}')
ALL=$(echo  "$MRAW" | grep 'minigateway_request_duration_seconds_count{route="/api/v1/"' | tail -1 | awk '{print $NF}')

HIT_PCT=$(awk  -v h="${HITS:-0}" -v m="${MISS:-0}" 'BEGIN {t=h+m; printf "%.1f", (t>0 ? h/t*100 : 0)}')
LOAD_RED=$(awk -v u="${UPR:-0}"  -v a="${ALL:-1}"  'BEGIN {printf "%.1f", (1 - u/a) * 100}')

echo "  => hit rate=${HIT_PCT}%  load reduction=${LOAD_RED}%  p50=${P50_B}ms  p99=${P99_B}ms  rps=${RPS_B}"
restore_v1

# ============================================================
# Benchmark C — rate limit enforcement
# ============================================================
echo ""
echo "--- Benchmark C: Rate Limit (50 rps, burst 5, 1000 req, c=100) ---"

update_v1 '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":true,"requests_per_second":50.0,"burst":5},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'
sleep 0.2

OUT_C=$(hey -n 1000 -c 100 "$GATEWAY/api/v1/bench-c" 2>&1)
echo "$OUT_C" | grep -E 'Requests/sec:|Status code distribution|\[200\]|\[429\]'

OK200=$(get_status_count "$OUT_C" 200)
REJ429=$(get_status_count "$OUT_C" 429)

echo "  => 200 OK=${OK200:-0}  429 Rejected=${REJ429:-0}"
restore_v1

# ============================================================
# Summary
# ============================================================
echo ""
echo "================================================="
echo "  BENCHMARK SUMMARY  (WSL, compiled binary)"
echo "================================================="
echo ""
echo "  A. Proxy overhead (no plugins, 5000 req, c=50):"
echo "     p50 = ${P50_A} ms  |  p99 = ${P99_A} ms  |  rps = ${RPS_A}"
echo ""
echo "  B. Cache hit rate (same URL, 10000 req, c=50):"
echo "     Hit rate = ${HIT_PCT}%   Upstream load reduction = ${LOAD_RED}%"
echo "     p50 = ${P50_B} ms  |  p99 = ${P99_B} ms  |  rps = ${RPS_B}"
echo ""
echo "  C. Rate limit (50 rps, burst 5, 1000 req, c=100):"
echo "     200 OK = ${OK200:-0}   429 Rejected = ${REJ429:-0}"
echo ""
echo "Paste this output back to Claude to update README.md"
echo ""
