# MiniGateway — Phase-by-Phase Development Guide

> Work through phases in order. Do not start Phase N+1 until Phase N verification passes completely.
> All commands run from: X:\projects\Go\minigateway\

---

## Before You Start — One-Time Setup

### 1. Confirm Go version
```powershell
go version
```
Expected: `go1.22` or higher.

### 2. Confirm Docker
```powershell
docker version
docker-compose version
```
Both must return version info without errors.

### 3. Install hey (load testing, needed for Phase 7)
```powershell
go install github.com/rakyll/hey@latest
hey --version
```

---

## PHASE 1 — Scaffold, Config Loader, Mock Server

### What gets built
- `go.mod` with all five dependencies declared
- `internal/config/config.go` — all YAML structs + Load() function
- `cmd/mockserver/main.go` — HTTP echo server (the fake upstream)
- `config/gateway.yaml` — sample config file

### Why this phase exists
Before any gateway logic, you need:
1. A compilable Go module (go.mod + go.sum)
2. A way to load and validate YAML config
3. A mock upstream to proxy to (so Phase 2 can be tested end-to-end)

The mock server IS the upstream — a separate process that responds with JSON identifying itself.

### Files to write
```
go.mod
internal/config/config.go
cmd/mockserver/main.go
config/gateway.yaml
```

### Commands BEFORE phase
```powershell
ls X:\projects\Go\minigateway
```

### Commands AFTER writing files
```powershell
# Download all dependencies, generate go.sum
go mod tidy

# Confirm compile
go build ./...

# Check for issues
go vet ./...
```

### Manual Verification

Open TWO terminals:

**Terminal 1 — start mock upstream-a:**
```powershell
cd X:\projects\Go\minigateway
$env:SERVER_NAME="upstream-a"; $env:PORT="5000"; go run ./cmd/mockserver
```
Expected output: `mock server upstream-a listening on :5000`

**Terminal 2 — test it:**
```powershell
curl.exe http://localhost:5000/anything
```
Expected response:
```json
{"server":"upstream-a","method":"GET","path":"/anything","query":"","headers":{...}}
```

### Phase 1 Checklist
- [ ] `go mod tidy` exits 0, go.sum created
- [ ] `go build ./...` exits 0
- [ ] `go vet ./...` exits 0
- [ ] Mock server starts and responds correctly
- [ ] Response body contains `"server": "upstream-a"` matching env var

---

## PHASE 2 — Core Proxy + Router (No Plugins Yet)

### What gets built
- `internal/proxy/proxy.go` — httputil.ReverseProxy + consistent hash target selection
- `internal/router/router.go` — thread-safe route table, prefix matching, ServeHTTP
- `internal/metrics/metrics.go` — all five Prometheus metric declarations
- `cmd/gateway/main.go` — entry point, wires router + proxy, starts three servers

At the end of this phase: gateway forwards requests to upstreams with NO plugins.
Plugins come in Phase 3. This isolation lets you debug proxy issues separately.

### Key structs to understand

**Router:**
```
type routeEntry struct {
    config  config.RouteConfig   // route settings from YAML
    handler http.Handler         // compiled plugin chain (just proxy for now)
}
type Router struct {
    mu     sync.RWMutex         // protects routes slice
    routes []*routeEntry        // sorted longest-path-first
}
```

**Proxy:**
```
type Proxy struct {
    upstream string                              // name, for metrics label
    route    string                              // path, for metrics label
    ring     *consistent.Consistent             // hash ring
    proxies  map[string]*httputil.ReverseProxy  // pre-built proxy per target URL
}
```

### Files to write
```
internal/proxy/proxy.go
internal/router/router.go
internal/metrics/metrics.go
cmd/gateway/main.go
```

### Commands BEFORE phase
```powershell
go build ./...
go vet ./...
```

### Commands AFTER writing files
```powershell
go build ./...
go vet ./...

# Terminal A: upstream-a
$env:SERVER_NAME="upstream-a"; $env:PORT="5000"; go run ./cmd/mockserver

# Terminal B: upstream-b
$env:SERVER_NAME="upstream-b"; $env:PORT="6000"; go run ./cmd/mockserver

# Terminal C: gateway
go run ./cmd/gateway config/gateway.yaml
```
Expected gateway output:
```
metrics server listening on :2112
admin server listening on :9090
gateway listening on :8080
```

### Manual Verification

Run from a fourth terminal while all three services are running:

```powershell
# Route to service-a
curl.exe http://localhost:8080/api/v1/hello
# Expected: 200, body contains "server": "upstream-a"

# Route to service-b
curl.exe http://localhost:8080/api/v2/hello
# Expected: 200, body contains "server": "upstream-b"

# Unknown path
curl.exe -v http://localhost:8080/unknown/path
# Expected: 404

# Metrics endpoint exists
curl.exe http://localhost:2112/metrics
# Expected: Prometheus text format with go_* and process_* lines

# Consistent hash affinity - same IP always hits same upstream
for ($i=1; $i -le 10; $i++) {
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/test" -UseBasicParsing
    ($r.Content | ConvertFrom-Json).server
}
# Expected: "upstream-a" printed 10 times (same server every time)
```

### Phase 2 Checklist
- [ ] `go build ./...` exits 0
- [ ] `go vet ./...` exits 0
- [ ] Gateway starts, logs all three servers
- [ ] /api/v1/* routes to upstream-a
- [ ] /api/v2/* routes to upstream-b
- [ ] /unknown returns 404
- [ ] /metrics responds with Prometheus text format
- [ ] 10 requests from same IP always hit same upstream (consistent hash)

---

## PHASE 3 — Plugin Chain (Auth, RateLimit, Cache)

### What gets built
- `internal/plugins/plugin.go` — Plugin interface
- `internal/plugins/chain.go` — Chain builder function
- `internal/plugins/auth/auth.go` — Basic auth middleware
- `internal/plugins/ratelimit/ratelimit.go` — Token bucket rate limiter
- `internal/plugins/cache/cache.go` — LRU response cache with TTL
- Update `cmd/gateway/main.go` — wire plugins into buildHandler()

### The Plugin Interface
```go
type Plugin interface {
    Name() string
    Handle(w http.ResponseWriter, r *http.Request, next http.Handler)
}
```
To SHORT-CIRCUIT: write error to `w`, return WITHOUT calling `next.ServeHTTP(w, r)`.
To PASS THROUGH: call `next.ServeHTTP(w, r)` and return.

### Plugin Execution Order and Why
```
Auth -> RateLimit -> Cache -> Proxy

1. Auth first:      Reject unauthenticated requests before spending rate-limit tokens.
2. RateLimit second: Reject over-limit requests before hitting the cache.
3. Cache third:     Serve from cache; if miss, call proxy and store result.
4. Proxy last:      Only reached if all gates pass AND cache missed.
```

### The bufferedRecorder (used internally by cache plugin)
On cache MISS the cache plugin needs to capture the response body to store it.
It uses a bufferedRecorder that implements http.ResponseWriter but stores everything in memory:
```
Header()      -> returns its own headers map (not the real ResponseWriter's)
WriteHeader() -> stores status code, does NOT send to client
Write()       -> appends to bytes.Buffer, does NOT send to client
flush(w)      -> copies stored headers + status + body to the real ResponseWriter
```
On cache HIT: cached headers + body written directly to real ResponseWriter. Proxy never called.

### Files to write
```
internal/plugins/plugin.go
internal/plugins/chain.go
internal/plugins/auth/auth.go
internal/plugins/ratelimit/ratelimit.go
internal/plugins/cache/cache.go
cmd/gateway/main.go (updated)
```

### Commands BEFORE phase
```powershell
go build ./...
go vet ./...
# All Phase 2 checks must still pass
```

### Commands AFTER writing files
```powershell
go build ./...
go vet ./...
# Start same stack as Phase 2 (3 terminals: upstream-a, upstream-b, gateway)
```

### Manual Verification

Run all these from a fourth terminal with all services running:

**Auth Tests** (route /api/v2/ has auth.enabled = true, username=admin, password=secret)
```powershell
# No credentials -> 401
curl.exe -v http://localhost:8080/api/v2/test
# Expected: HTTP 401 Unauthorized

# Wrong credentials -> 401
curl.exe -v -u "admin:wrongpassword" http://localhost:8080/api/v2/test
# Expected: HTTP 401

# Correct credentials -> 200
curl.exe -v -u "admin:secret" http://localhost:8080/api/v2/test
# Expected: HTTP 200, body contains "server": "upstream-b"

# Route /api/v1/ has auth.enabled = false -> no credentials needed
curl.exe http://localhost:8080/api/v1/test
# Expected: HTTP 200
```

**Rate Limit Tests** (route /api/v1/ has 100 rps, burst 20)
```powershell
# Send 150 rapid requests, expect some 429s
$results = @()
for ($i=1; $i -le 150; $i++) {
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/test" `
         -UseBasicParsing -ErrorAction SilentlyContinue
    $results += $r.StatusCode
}
$results | Group-Object | Format-Table Name, Count
# Expected: mix of 200 and 429. First ~120 pass (20 burst + 100/s). Then 429s appear.

# Verify Retry-After header on 429
$r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/test" `
     -UseBasicParsing -ErrorAction SilentlyContinue
$r.Headers["Retry-After"]
# Expected: "1"
```

**Cache Tests** (route /api/v1/ has cache.enabled = true, ttl = 30s)
```powershell
# First request -> MISS
$r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/cache-key-1" -UseBasicParsing
$r.Headers["X-Cache"]
# Expected: "MISS"

# Second identical request -> HIT
$r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/cache-key-1" -UseBasicParsing
$r.Headers["X-Cache"]
# Expected: "HIT"

# Different URL -> MISS
$r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/cache-key-2" -UseBasicParsing
$r.Headers["X-Cache"]
# Expected: "MISS"

# POST is never cached
$r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/cache-key-1" `
     -Method POST -UseBasicParsing -ErrorAction SilentlyContinue
$r.Headers["X-Cache"]
# Expected: no X-Cache header at all

# Route /api/v2/ has cache.enabled = false -> never cached (Basic auth base64 = admin:secret)
$r = Invoke-WebRequest -Uri "http://localhost:8080/api/v2/test" `
     -Headers @{Authorization="Basic YWRtaW46c2VjcmV0"} -UseBasicParsing
$r.Headers["X-Cache"]
# Expected: no X-Cache header, even on repeat requests
```

### Phase 3 Checklist
- [ ] `go build ./...` exits 0
- [ ] `go vet ./...` exits 0
- [ ] /api/v2/ with no credentials -> 401
- [ ] /api/v2/ with wrong credentials -> 401
- [ ] /api/v2/ with correct credentials -> 200
- [ ] 150 rapid requests to /api/v1/ -> mix of 200 and 429
- [ ] 429 response has Retry-After header
- [ ] First GET to a URL -> X-Cache: MISS
- [ ] Second GET to same URL -> X-Cache: HIT
- [ ] POST request -> no X-Cache header
- [ ] /api/v2/ (cache disabled) -> no X-Cache ever

---

## PHASE 4 — Admin API (Zero-Downtime Route Changes)

### What gets built
- `internal/admin/admin.go` — REST handler for GET/POST/DELETE /admin/routes
- Update `cmd/gateway/main.go` — inject HandlerBuilderFunc into admin handler

### The Core Concept: Zero Downtime
When you POST a new route, the NEXT request to that path uses the new config.
No restart. No dropped requests. In-flight requests complete with the old config.

This works because:
1. Admin builds a new http.Handler (full plugin chain) for the new route config
2. router.AddRoute() acquires a write lock, swaps the old entry, releases lock
3. All new requests read the updated table under RLock

### HandlerBuilderFunc
```go
type HandlerBuilderFunc func(cfg config.RouteConfig, targets []string) (http.Handler, error)
```
Defined in main.go and injected into admin.New(). Admin delegates chain-building
back to main.go to avoid circular imports.

### Files to write
```
internal/admin/admin.go
cmd/gateway/main.go (updated with admin wiring)
```

### Commands BEFORE phase
```powershell
go build ./...
go vet ./...
# All Phase 3 checks must still pass
```

### Commands AFTER writing files
```powershell
go build ./...
go vet ./...
# Start full stack (same three terminals as before)
```

### Manual Verification

```powershell
# Test 1: List current routes (should see 2)
curl.exe http://localhost:9090/admin/routes
# Expected: JSON array with /api/v1/ and /api/v2/

# Test 2: Add a new route that does not exist yet
curl.exe -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{"path":"/api/v3/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":true,"ttl_seconds":60,"max_entries":100},"auth":{"enabled":false}}}'
# Expected: HTTP 201 Created

# Test 3: Hit the new route immediately (NO restart)
curl.exe http://localhost:8080/api/v3/hello
# Expected: 200, "server": "upstream-a"
# If 404 here: Admin API is not wiring routes correctly

# Test 4: List routes (now 3)
curl.exe http://localhost:9090/admin/routes
# Expected: 3 routes in JSON array

# Test 5: Delete the route
curl.exe -X DELETE "http://localhost:9090/admin/routes/api/v3/"
# Expected: HTTP 204 No Content

# Test 6: Hit deleted route -> gone
curl.exe -v http://localhost:8080/api/v3/hello
# Expected: 404

# Test 7: List routes (back to 2)
curl.exe http://localhost:9090/admin/routes

# Test 8: Error case - unknown upstream
curl.exe -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{"path":"/api/v4/","upstream":"nonexistent","plugins":{}}'
# Expected: HTTP 400 with error message

# Test 9: Update existing route (POST = upsert)
curl.exe -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'
# Expected: HTTP 200 (updated)
# Now /api/v1/ has no rate limiting and no caching
# Verify: send 150 requests -> all 200 (no 429s anymore)
```

### Phase 4 Checklist
- [ ] `go build ./...` exits 0
- [ ] `go vet ./...` exits 0
- [ ] GET /admin/routes -> 2 routes as JSON
- [ ] POST /admin/routes with /api/v3/ -> 201
- [ ] Immediate GET /api/v3/ -> 200 (zero downtime confirmed)
- [ ] GET /admin/routes -> 3 routes
- [ ] DELETE /admin/routes/api/v3/ -> 204
- [ ] GET /api/v3/ after delete -> 404
- [ ] POST with unknown upstream -> 400 with error message
- [ ] POST to update existing route -> 200, behavior changes immediately

---

## PHASE 5 — Prometheus Metrics Verification

### What gets confirmed
The metrics package was declared in Phase 2. This phase verifies all five metrics
populate with real labeled values after traffic is sent.

Check that these calls exist in your code:
- `metrics.RequestDuration.Observe()` — in router.ServeHTTP() after handler returns
- `metrics.CacheHits.Inc()` / `metrics.CacheMisses.Inc()` — in cache plugin
- `metrics.RateLimitRejections.Inc()` — in ratelimit plugin
- `metrics.UpstreamRequests.Inc()` — in proxy.ServeHTTP()

### Commands AFTER confirming all metric calls exist
```powershell
go build ./...
go vet ./...
# Start full stack
```

### Manual Verification

```powershell
# Step 1: Generate cache metrics (1 miss then 1 hit)
curl.exe http://localhost:8080/api/v1/metrics-test-abc
curl.exe http://localhost:8080/api/v1/metrics-test-abc

# Step 2: Generate rate limit metrics (rapid burst)
for ($i=1; $i -le 30; $i++) {
    Invoke-WebRequest -Uri "http://localhost:8080/api/v1/rl-test" `
        -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
}

# Step 3: Check all five metric names appear
curl.exe http://localhost:2112/metrics | Select-String "minigateway"

# Must see ALL of:
# minigateway_request_duration_seconds_bucket
# minigateway_request_duration_seconds_sum
# minigateway_request_duration_seconds_count
# minigateway_cache_hits_total
# minigateway_cache_misses_total
# minigateway_ratelimit_rejections_total
# minigateway_upstream_requests_total

# Detailed checks:
curl.exe http://localhost:2112/metrics | Select-String "cache_hits"
# Expected: minigateway_cache_hits_total{route="/api/v1/"} 1

curl.exe http://localhost:2112/metrics | Select-String "cache_misses"
# Expected: minigateway_cache_misses_total{route="/api/v1/"} 1

curl.exe http://localhost:2112/metrics | Select-String "ratelimit_rejections"
# Expected: minigateway_ratelimit_rejections_total{route="/api/v1/"} N (some number > 0)

curl.exe http://localhost:2112/metrics | Select-String "upstream_requests"
# Expected: minigateway_upstream_requests_total{route="/api/v1/",upstream="service-a"} N
# This number should be LESS than total requests (cache is reducing upstream calls)

curl.exe http://localhost:2112/metrics | Select-String "duration_seconds_bucket"
# Expected: multiple lines like:
# minigateway_request_duration_seconds_bucket{...le="0.005"} 5
```

### Phase 5 Checklist
- [ ] `go build ./...` exits 0
- [ ] `go vet ./...` exits 0
- [ ] cache_hits_total > 0 for /api/v1/ after a cache hit
- [ ] cache_misses_total > 0 for /api/v1/ after a cache miss
- [ ] ratelimit_rejections_total > 0 after burst
- [ ] upstream_requests_total < total_requests_count (cache reducing upstream load)
- [ ] request_duration_seconds_bucket has entries with route/upstream/status_code labels
- [ ] All 5 metric names present in /metrics output

---

## PHASE 6 — Docker Compose

### What gets built
- `Dockerfile` — multi-stage build producing both gateway and mockserver binaries
- `docker-compose.yml` — three services: gateway, upstream-a, upstream-b

### Multi-Stage Dockerfile explained
```
Stage 1 (golang:1.22-alpine as builder):
  COPY go.mod go.sum -> RUN go mod download  <- cached layer
  COPY . .
  RUN go build -o /gateway ./cmd/gateway
  RUN go build -o /mockserver ./cmd/mockserver

Stage 2 (alpine:latest):
  COPY /gateway /mockserver from builder
  COPY config/ /config/
  EXPOSE 8080 9090 2112
```
CGO_ENABLED=0 produces a fully static binary. Final image ~15MB.
One image, two binaries — docker-compose `command:` decides which runs.

### Commands BEFORE phase
```powershell
docker info     # confirm daemon is running
# Stop all locally running gateway/mockserver processes (free ports 8080,9090,2112,5000,6000)
```

### Commands AFTER writing files
```powershell
# Build image
docker build -t minigateway:local .
# Expected: no errors. If go.sum mismatch: run go mod tidy locally first.

# Start full stack
docker-compose up --build
# Expected:
# upstream-a-1 | mock server upstream-a listening on :5000
# upstream-b-1 | mock server upstream-b listening on :6000
# gateway-1    | metrics server listening on :2112
# gateway-1    | admin server listening on :9090
# gateway-1    | gateway listening on :8080
```

### Manual Verification

Open a second terminal while docker-compose is running:

```powershell
# Routes correctly inside Docker
curl.exe http://localhost:8080/api/v1/ping
# Expected: 200, "server": "upstream-a"

curl.exe http://localhost:8080/api/v2/ping
# Expected: 401 (auth required, no credentials provided)

curl.exe -u admin:secret http://localhost:8080/api/v2/ping
# Expected: 200, "server": "upstream-b"

# Admin API works
curl.exe http://localhost:9090/admin/routes
# Expected: 2 routes as JSON

# Metrics work
curl.exe http://localhost:2112/metrics | Select-String "minigateway"

# Generate traffic then verify metrics
for ($i=1; $i -le 20; $i++) {
    Invoke-WebRequest -Uri "http://localhost:8080/api/v1/docker-test" -UseBasicParsing | Out-Null
}
curl.exe http://localhost:2112/metrics | Select-String "cache_hits"
# Expected: value > 0

# Check logs
docker-compose logs gateway

# Clean shutdown
docker-compose down
# Expected: all containers stop, no errors
```

### Phase 6 Checklist
- [ ] `docker build -t minigateway:local .` succeeds
- [ ] `docker-compose up --build` starts all three containers cleanly
- [ ] Gateway routes correctly to upstream-a and upstream-b via Docker DNS
- [ ] Auth works inside Docker (401 on /api/v2/ without credentials)
- [ ] Admin API accessible on :9090
- [ ] Metrics accessible on :2112 and populate after traffic
- [ ] `docker-compose down` clean shutdown

---

## PHASE 7 — Benchmarks + README

### What gets built
- Run `hey` load tests, measure actual numbers
- Write actual measured numbers into README.md
- README covers: architecture diagram, setup, benchmark results, curl examples

### Why benchmarks matter for the resume
The resume bullets claim specific numbers. These must be real — measured, not guessed.
An interviewer WILL ask "how did you measure this?"

### Benchmark Design

**Test A — Proxy overhead (cache DISABLED, measures raw proxy latency):**
```powershell
# Disable cache via Admin API first:
curl.exe -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'

# Run benchmark
hey -n 5000 -c 50 http://localhost:8080/api/v1/bench-no-cache
# Read p99 from output -> this is proxy overhead
# Expected: < 5ms for local loopback (1-3ms typical)
```

**Test B — Cache hit rate (repeated URL = high hit rate):**
```powershell
# Re-enable cache first:
curl.exe -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":true,"ttl_seconds":30,"max_entries":1000},"auth":{"enabled":false}}}'

# Warm up:
hey -n 1000 -c 10 http://localhost:8080/api/v1/warmup

# Main benchmark - same URL, cache fills after first request:
hey -n 10000 -c 50 http://localhost:8080/api/v1/bench-key

# Check Prometheus hit rate after:
curl.exe http://localhost:2112/metrics | Select-String "cache_hits"
curl.exe http://localhost:2112/metrics | Select-String "cache_misses"
# hit_rate = hits / (hits + misses) * 100
# Expected for same-URL benchmark: > 99% (only first request is a miss)
# Expected for realistic varied-URL benchmark: ~85%
```

**Test C — Rate limit rejections visible:**
```powershell
curl.exe -X POST http://localhost:9090/admin/routes `
  -H "Content-Type: application/json" `
  -d '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":true,"requests_per_second":50,"burst":5},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'

hey -n 1000 -c 100 http://localhost:8080/api/v1/bench-rl
# hey output will show: [429] N responses
```

### Reading hey Output
```
Latency distribution:
  10% in 0.0005 secs
  ...
  99% in 0.0034 secs   <-- YOUR p99 (multiply by 1000 for ms)

Status code distribution:
  [200] 4500 responses
  [429]  500 responses  <-- rate limit rejections
```

### Phase 7 Checklist
- [ ] hey installed and working
- [ ] Benchmark A (no-cache p99) run and number recorded
- [ ] Benchmark B (cache hit rate) run and percentage recorded from Prometheus
- [ ] Benchmark C (rate limit) shows 429s in hey output
- [ ] All three resume bullet numbers confirmed or updated to match measurements
- [ ] README.md written with:
  - [ ] ASCII architecture diagram
  - [ ] docker-compose up getting-started section
  - [ ] All curl examples for Admin API
  - [ ] Prometheus metrics explanation
  - [ ] Actual measured benchmark results

---

## Post-Phase-7 — GitHub + Resume Update

### Push to GitHub
```powershell
cd X:\projects\Go\minigateway
git init
git add .
git commit -m "feat: MiniGateway - Kong-inspired API gateway in Go"
gh repo create minigateway --public --source=. --remote=origin --push
```

### Update projects.md
In `X:\projects\resumes\data\projects.md` for Project 13 (MiniGateway):
- Set Timeline to today's date
- Replace `(add link after repo is created)` with the actual GitHub URL
- Update benchmark numbers in Resume Bullets to match actual measured values

---

## Appendix — Troubleshooting

### `go mod tidy` fails with "no required module"
```powershell
go get github.com/stathat/consistent@latest
go get github.com/hashicorp/golang-lru/v2@latest
go get github.com/prometheus/client_golang@latest
go get golang.org/x/time@latest
go get gopkg.in/yaml.v3@latest
go mod tidy
```

### Gateway starts but all requests return 502 Bad Gateway
The upstream mock servers are not running. Start them in separate terminals first.

### curl.exe not found
Use the full Invoke-WebRequest form:
```powershell
Invoke-WebRequest -Uri "http://localhost:8080/api/v1/test" -UseBasicParsing
```

### X-Cache header not appearing
Either cache plugin is not wired into the chain in buildHandler(), or the route has cache.enabled: false in gateway.yaml. Check both.

### docker-compose: port already in use
```powershell
netstat -ano | Select-String ":8080"
Stop-Process -Id <PID>
```

### go.sum out of date when building Docker
Run `go mod tidy` locally, commit the updated go.sum, then rebuild.

---

## Appendix — Key Go Concepts Used

### sync.RWMutex
Multiple goroutines can hold RLock simultaneously. Only one can hold Lock.
Use RLock for reading the route table (every request).
Use Lock only for modifying it (Admin API, rare).
Better throughput than a plain Mutex under read-heavy workloads.

### http.Handler and http.HandlerFunc
`http.Handler` is an interface: `ServeHTTP(ResponseWriter, *Request)`.
`http.HandlerFunc` is a function type implementing that interface.
The plugin chain is built from nested HandlerFuncs. No framework needed.

### httputil.ReverseProxy
Standard library type for forwarding requests. Director modifies the request before sending.
Automatically strips hop-by-hop headers (Connection, Keep-Alive, Transfer-Encoding).

### Graceful shutdown pattern
```go
ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
server.Shutdown(ctx)
```
Stops accepting connections immediately. Waits for active handlers to finish.
If they do not finish in 10 seconds, the context expires and Shutdown returns.
