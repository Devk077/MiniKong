# MiniGateway

A Kong-inspired API gateway built in Go — reverse proxy, plugin chain (auth, rate limiting, response caching), consistent-hash load balancing, zero-downtime Admin API, and Prometheus metrics.

Built as a portfolio project demonstrating systems and infrastructure depth in Go.

---

## Architecture

```
                  +--------------------------------------------------+
                  |              MiniGateway Process                 |
                  |                                                  |
 Client           |  :8080  Gateway Server                           |
 -------> HTTP -->|  http.ServeMux --> Router.ServeHTTP()            |
                  |         |                                        |
                  |         +-- /api/v1/* --> Auth --> RateLimit --> Cache --> Proxy A
                  |         +-- /api/v2/* --> Auth --> RateLimit --> Cache --> Proxy B
                  |         +-- (no match) --> 404                  |
                  |                                                  |
                  |  :9090  Admin Server (127.0.0.1 only)           |
                  |  GET/POST/DELETE /admin/routes                   |
                  |                                                  |
                  |  :2112  Metrics Server                           |
                  |  GET /metrics --> Prometheus text format         |
                  +--------------------------------------------------+
                               |                |
                      upstream-a:5000    upstream-b:6000
                      (echo server)      (echo server)
```

Three HTTP servers run as goroutines in one process and shut down gracefully on SIGINT/SIGTERM.

The **route table** is a `sync.RWMutex`-protected slice of `routeEntry` structs, each holding the compiled plugin chain for that route. Reads take `RLock` (concurrent), Admin API writes take `Lock` (exclusive). In-flight requests using an old handler complete normally — no request is ever dropped during a route update.

---

## Quick Start

### Docker Compose (recommended)

```bash
git clone https://github.com/Devk077/minigateway
cd minigateway
docker-compose up --build
```

Expected startup output:
```
upstream-a-1  | mock server upstream-a listening on :5000
upstream-b-1  | mock server upstream-b listening on :6000
gateway-1     | metrics server listening on :2112
gateway-1     | admin server listening on :9090
gateway-1     | gateway listening on :8080
```

Test it:
```powershell
# Route to service-a
curl http://localhost:8080/api/v1/hello
# {"server":"upstream-a","method":"GET","path":"/api/v1/hello",...}

# Route to service-b (requires auth)
curl -u admin:secret http://localhost:8080/api/v2/hello
# {"server":"upstream-b",...}

# No credentials -> 401
curl -v http://localhost:8080/api/v2/hello
# HTTP/1.1 401 Unauthorized
```

Stop:
```bash
docker-compose down
```

### Local Development

```powershell
# Terminal 1 — upstream-a
$env:SERVER_NAME="upstream-a"; $env:PORT="5000"; go run ./cmd/mockserver

# Terminal 2 — upstream-b
$env:SERVER_NAME="upstream-b"; $env:PORT="6000"; go run ./cmd/mockserver

# Terminal 3 — gateway
go run ./cmd/gateway config/gateway.yaml
```

Or use the helper scripts:
```powershell
.\scripts\start-all.ps1    # opens 3 windows automatically
```

---

## Configuration

`config/gateway.yaml`:

```yaml
server:
  port: 8080

admin:
  port: 9090
  # host: "0.0.0.0"   # uncomment for Docker (see gateway-docker.yaml)

upstreams:
  - name: service-a
    targets:
      - http://localhost:5000
      - http://localhost:5001   # multiple targets -> consistent hash distributes traffic

routes:
  - path: /api/v1/              # prefix match; longer paths win
    upstream: service-a
    plugins:
      rate_limit:
        enabled: true
        requests_per_second: 100.0
        burst: 20
      cache:
        enabled: true
        ttl_seconds: 30
        max_entries: 1000
      auth:
        enabled: false

  - path: /api/v2/
    upstream: service-b
    plugins:
      rate_limit:
        enabled: true
        requests_per_second: 50.0
        burst: 10
      cache:
        enabled: false
      auth:
        enabled: true
        users:
          - username: admin
            password: secret
```

---

## Plugin System

Plugin execution order per request: **Auth → RateLimit → Cache → Proxy**

Each plugin implements one interface:

```go
type Plugin interface {
    Name() string
    Handle(w http.ResponseWriter, r *http.Request, next http.Handler)
}
```

Call `next.ServeHTTP(w, r)` to pass through. Return without calling `next` to short-circuit.

The chain is compiled once at route-load time using nested `http.HandlerFunc` closures — zero allocation per request.

### Auth

HTTP Basic Authentication. When `enabled: true`, the `Authorization: Basic <base64>` header is decoded and compared against the `users` list. No match → `401 Unauthorized` + `WWW-Authenticate` header.

> **Note:** Basic Auth over plain HTTP sends credentials in base64 (not encrypted). In production, TLS termination must precede the gateway. TLS is out of scope for this demo.

### Rate Limit

Token bucket via `golang.org/x/time/rate`. Bucket holds `burst` tokens and refills at `requests_per_second` tokens/sec. Empty bucket → `429 Too Many Requests` + `Retry-After: 1` header. The limiter is goroutine-safe (internal atomics, no extra mutex needed).

### Cache

LRU response cache with TTL for `GET` requests only (`hashicorp/golang-lru/v2`).

- **HIT:** Write cached headers + body directly to client. Add `X-Cache: HIT`. Proxy is never called.
- **MISS:** Buffer the proxy response in memory. If status = 200, store in LRU with `expiry = now + ttl_seconds`. Flush to client with `X-Cache: MISS`.

`POST`/`PUT`/`DELETE` bypass the cache entirely (non-idempotent). Non-200 responses are not cached (may be transient errors).

Cache key = `r.URL.String()` (full URL including query string).

### Consistent Hash Load Balancing

When an upstream has multiple targets, the proxy uses a consistent hash ring (`stathat.com/c/consistent`) keyed on **client IP**. Same client IP always routes to the same upstream instance (session affinity). Adding or removing a node remaps only `K/N` keys instead of all keys.

---

## Admin API

Base URL: `http://localhost:9090`

The Admin API is bound to `127.0.0.1` by default (not reachable from the network). Routes are updated atomically under a write lock — the next request after `AddRoute` returns uses the new handler with zero downtime.

### List all routes

```powershell
curl http://localhost:9090/admin/routes
```

```json
[
  {"path":"/api/v1/","upstream":"service-a","plugins":{...}},
  {"path":"/api/v2/","upstream":"service-b","plugins":{...}}
]
```

### Add a route (201 Created)

```powershell
curl -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{
    "path": "/api/v3/",
    "upstream": "service-a",
    "plugins": {
      "rate_limit": {"enabled": false, "requests_per_second": 0, "burst": 0},
      "cache":      {"enabled": true,  "ttl_seconds": 60, "max_entries": 500},
      "auth":       {"enabled": false}
    }
  }'
```

The new route is active immediately. No restart required.

### Update an existing route (200 OK)

Send a POST with the same `path` — the existing handler is swapped atomically.

```powershell
# Disable rate limiting on /api/v1/ live
curl -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":true,"ttl_seconds":30,"max_entries":1000},"auth":{"enabled":false}}}'
```

### Delete a route (204 No Content)

```powershell
# Path in URL is the route path without leading slash
curl -X DELETE http://localhost:9090/admin/routes/api/v3/
```

### Error cases

```powershell
# Unknown upstream -> 400
curl -X POST http://localhost:9090/admin/routes `
  -d '{"path":"/x/","upstream":"nonexistent","plugins":{}}'
# 400 Bad Request: bad request: unknown upstream nonexistent
```

---

## Prometheus Metrics

Endpoint: `http://localhost:2112/metrics`

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `minigateway_request_duration_seconds` | Histogram | `route`, `upstream`, `status_code` | End-to-end gateway latency per request |
| `minigateway_cache_hits_total` | Counter | `route` | Cache hits (proxy not called) |
| `minigateway_cache_misses_total` | Counter | `route` | Cache misses (proxy called) |
| `minigateway_ratelimit_rejections_total` | Counter | `route` | Requests rejected with 429 |
| `minigateway_upstream_requests_total` | Counter | `route`, `upstream` | Requests forwarded to upstream |

### Useful PromQL queries

```promql
# p99 latency per route
histogram_quantile(0.99,
  sum(rate(minigateway_request_duration_seconds_bucket[5m])) by (route, le)
)

# Cache hit rate
rate(minigateway_cache_hits_total[5m])
/
(rate(minigateway_cache_hits_total[5m]) + rate(minigateway_cache_misses_total[5m]))

# Upstream load reduction from cache
1 - (
  rate(minigateway_upstream_requests_total[5m])
  /
  rate(minigateway_request_duration_seconds_count[5m])
)
```

---

## Benchmark Results

Measured with [`hey`](https://github.com/rakyll/hey) on WSL2 Ubuntu (compiled binary, loopback). Remaining p99 latency is WSL2 virtual-network overhead; on bare Linux metal expect p99 ~2–5 ms.

### A — Proxy Overhead (no cache, no rate limiting)

5,000 requests at 50 concurrency against a no-op upstream (in-memory echo).

| Metric | Value |
|--------|-------|
| p50 latency | **5.60 ms** |
| p99 latency | **28.70 ms** |
| Throughput  | **6,898 req/sec** |

### B — Cache Performance (same URL repeated)

10,000 requests at 50 concurrency, warm cache (all requests to the same URL).

| Metric | Value |
|--------|-------|
| Cache hit rate | **99.9%** |
| p50 latency (cache hit) | **0.80 ms** |
| p99 latency (cache hit) | **8.30 ms** |
| Throughput | **32,274 req/sec** |
| Upstream load reduction | **68.7%** |

Cache hits are **7x faster** than proxy calls (0.80 ms vs 5.60 ms p50) — the upstream is completely bypassed.

### C — Rate Limit Enforcement (50 rps, burst 5)

1,000 requests at 100 concurrency with an aggressive rate limit.

| Metric | Value |
|--------|-------|
| 200 OK | **9** |
| 429 Too Many Requests | **991** |
| Rejection rate | **99.1%** |

The token bucket correctly exhausts the burst of 5, then allows only 50 req/sec to pass.

---

## Project Structure

```
minigateway/
├── cmd/
│   ├── gateway/        # Entry point — wires all packages, starts 3 servers
│   └── mockserver/     # Minimal echo server used as upstream in dev/Docker
├── internal/
│   ├── config/         # YAML struct tree + Load() + validation
│   ├── metrics/        # 5 Prometheus metric variables (promauto, registered once)
│   ├── plugins/        # Plugin interface + Chain() builder
│   │   ├── auth/       # HTTP Basic Auth middleware
│   │   ├── cache/      # LRU + TTL response cache
│   │   └── ratelimit/  # Token bucket rate limiter
│   ├── proxy/          # httputil.ReverseProxy + consistent hash target selection
│   ├── router/         # RWMutex route table, prefix matching, statusRecorder
│   └── admin/          # REST Admin API handler
├── config/
│   ├── gateway.yaml         # Local dev config (targets: localhost)
│   └── gateway-docker.yaml  # Docker config (targets: Docker DNS names)
├── scripts/
│   ├── start-all.ps1        # Starts 3 local server windows
│   ├── test-phase*.ps1      # Per-phase verification scripts
│   ├── docker-start.ps1     # docker-compose up --build
│   └── run-benchmarks.ps1   # hey benchmarks + summary
├── Dockerfile               # Multi-stage build (~15 MB final image)
└── docker-compose.yml       # gateway + upstream-a + upstream-b
```

---

## Key Design Decisions

**Compile plugin chain at route-load time, not per-request.**
Building the chain allocates `http.HandlerFunc` closures. At 1,000 req/sec that would be 1,000 allocations/sec just for chain construction. Compiling once at startup (and on Admin API updates) means zero allocation overhead per request.

**Buffer the response body for caching.**
The alternative — streaming to the client while simultaneously writing to cache — requires `io.TeeReader` and careful goroutine coordination. Buffering is simpler and correct. Downside: a 1 MB response uses 1 MB of RAM during the cache-write window. Acceptable at demo scale.

**Client IP as the consistent hash key.**
This provides session affinity — the same client always routes to the same upstream instance. The alternative (URL path hashing) is better for stateless sharded backends. Either approach can be made configurable.

**Admin API on a separate port.**
In production, the admin port is firewalled so only the control plane can reach it. The gateway port is public. Separate ports make this access control trivial at the network layer.

**`sync.RWMutex` on the route table.**
Many goroutines read the table concurrently (every request). The Admin API is the sole writer (rare). `RWMutex` allows unlimited concurrent readers with exclusive access for writes — far better throughput than a plain `Mutex` under read-heavy load.

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `stathat.com/c/consistent` | Consistent hash ring for upstream selection |
| `github.com/hashicorp/golang-lru/v2` | Thread-safe LRU cache used by the cache plugin |
| `golang.org/x/time/rate` | Token bucket rate limiter |
| `github.com/prometheus/client_golang` | Prometheus metrics exposition |
| `gopkg.in/yaml.v3` | YAML config parsing |
