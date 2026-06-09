# MiniGateway — Architecture & Implementation Reference

> **Project:** MiniGateway — Kong-Inspired API Gateway in Go
> **Author:** Dev Kapadia
> **Goal:** Resume project demonstrating systems/infrastructure depth in Go
> **Target roles:** Backend SWE, Platform Engineer, Infrastructure Engineer

---

## Table of Contents

1. [What This Project Is](#1-what-this-project-is)
2. [Why This Tech Stack](#2-why-this-tech-stack)
3. [High-Level Architecture](#3-high-level-architecture)
4. [Request Lifecycle End-to-End](#4-request-lifecycle-end-to-end)
5. [Package-by-Package Reference](#5-package-by-package-reference)
6. [Config Schema Complete](#6-config-schema-complete)
7. [Plugin System Design](#7-plugin-system-design)
8. [Consistent Hashing Design](#8-consistent-hashing-design)
9. [Admin API Reference](#9-admin-api-reference)
10. [Prometheus Metrics Reference](#10-prometheus-metrics-reference)
11. [Concurrency Model](#11-concurrency-model)
12. [Security Model](#12-security-model)
13. [Performance Design](#13-performance-design)
14. [Docker and Deployment Model](#14-docker-and-deployment-model)
15. [Key Design Decisions and Trade-offs](#15-key-design-decisions-and-trade-offs)
16. [What This Demonstrates on Your Resume](#16-what-this-demonstrates-on-your-resume)

---

## 1. What This Project Is

MiniGateway is a simplified API gateway written from scratch in Go. An API gateway is a reverse proxy that sits in front of multiple backend services and acts as the single entry point for all client traffic. The most well-known production API gateway is Kong (written in Lua/C on top of Nginx). MiniGateway implements the core concepts of Kong in pure Go.

**Core responsibilities:**
- **Routing:** Match an incoming HTTP request to the correct backend service based on path prefix.
- **Plugin Chain:** Run a configurable sequence of middlewares (auth, rate limiting, caching) before forwarding the request.
- **Reverse Proxy:** Forward the request to a backend upstream service and stream the response back.
- **Load Distribution:** Use a consistent hashing ring to distribute traffic across multiple instances of the same upstream service.
- **Observability:** Expose per-route latency, cache, and rate-limit metrics via Prometheus.
- **Live Configuration:** Allow routes to be added, updated, or deleted at runtime via a REST Admin API without restarting the process.

**What it is NOT:**
- Not a production-grade gateway (no TLS termination, no service discovery, no circuit breaking).
- Does not implement Kong's plugin ecosystem — it implements three specific plugins as a demonstration.
- Not a general-purpose load balancer.

---

## 2. Why This Tech Stack

### Go (net/http, httputil.ReverseProxy)

Go's standard library includes a production-quality HTTP server and a httputil.ReverseProxy that handles the mechanics of forwarding requests (hop-by-hop header stripping, X-Forwarded-For, response streaming). Writing this in Go means you get goroutine-based concurrency for free — each incoming request is handled in its own goroutine, which is the same model used in production Go services like those at CRED.

### stathat/consistent (consistent hashing)

A consistent hash ring solves the "which upstream do I send this request to?" problem in a way that minimizes remapping when nodes are added or removed. A simple round-robin would re-map all requests on every node change; consistent hashing only remaps K/N keys (K = total keys, N = total nodes). This is the same algorithm used in Cassandra and Dynamo for partition assignment. We use a library because the algorithm itself is not the point of this project — the gateway architecture is.

### hashicorp/golang-lru/v2 (LRU cache)

This is the standard LRU cache library in the Go ecosystem, used in production by HashiCorp Vault, Consul, and Nomad. It provides a thread-safe, size-bounded cache with O(1) get/put. We add TTL on top by storing an expiry timestamp alongside each cached response.

### golang.org/x/time/rate (token bucket)

This is the official Go extended library for rate limiting. It implements the token bucket algorithm: a bucket holds up to burst tokens, refills at rate tokens/second. Each request consumes one token. If the bucket is empty, the request is denied with 429. This is the same algorithm used in most cloud API rate limiters.

### prometheus/client_golang (metrics)

Prometheus is the de facto standard for metrics in Go services. You already used it at CRED. The promauto package auto-registers metrics, and promhttp.Handler() exposes them at /metrics.

### gopkg.in/yaml.v3 (config)

The standard Go YAML library. Declarative YAML config (routes, upstreams, plugins) means the gateway behavior is described as data, not code — the same approach used by Kong, Nginx, and Kubernetes.

---

## 3. High-Level Architecture

```
                     +----------------------------------------------------+
                     |              MiniGateway Process                   |
                     |                                                    |
  Client             |  :8080  Gateway Server                             |
  --------> HTTP --->|  http.ServeMux --> Router.ServeHTTP()              |
                     |         |                                          |
                     |         +-- /api/v1/* --> Plugin Chain A --> Proxy A
                     |         +-- /api/v2/* --> Plugin Chain B --> Proxy B
                     |         +-- (no match) --> 404                     |
                     |                                                    |
                     |  :9090  Admin Server                               |
                     |  GET/POST/DELETE /admin/routes --> Router update   |
                     |                                                    |
                     |  :2112  Metrics Server                             |
                     |  GET /metrics --> Prometheus text format           |
                     +----------------------------------------------------+
                                  |                |
                         upstream-a:5000    upstream-b:6000
                         (mock echo)        (mock echo)
```

Three separate HTTP servers run concurrently in the same process (three goroutines). Each server is independently shut down during graceful shutdown.

The Route Table is the central data structure. It is a slice of routeEntry structs, each holding:
- The route config (path, upstream name, plugin settings)
- The compiled http.Handler (the full plugin chain + proxy for that route)

The route table is protected by a sync.RWMutex. Reads (request handling) take an RLock. Writes (Admin API changes) take a Lock.

---

## 4. Request Lifecycle End-to-End

This is the exact sequence of operations for a single HTTP request:

```
1. Client sends: GET /api/v1/users HTTP/1.1

2. net/http server accepts connection, spawns goroutine

3. Router.ServeHTTP() is called
   a. RLock acquired on route table
   b. Iterate routes (longest path first):
      - /api/v1/ matches /api/v1/users YES
   c. RLock released
   d. statusRecorder wraps ResponseWriter (captures status code for metrics)
   e. Route handler (plugin chain) is called

4. Plugin: Auth
   - cfg.Enabled = false --> call next immediately (no-op)

5. Plugin: RateLimit
   - cfg.Enabled = true
   - limiter.Allow() --> true (token available)
   - call next

6. Plugin: Cache
   - cfg.Enabled = true, method = GET
   - key = "/api/v1/users" (full URL string)
   - cache.Get(key) --> MISS (first request)
   - metrics.CacheMisses.WithLabelValues("/api/v1/").Inc()
   - create bufferedRecorder (captures full response body in memory)
   - call next (proxy) with bufferedRecorder

7. Proxy.ServeHTTP()
   - clientIP = "127.0.0.1" (stripped from RemoteAddr)
   - ring.Get("127.0.0.1") --> "http://upstream-a:5000"
   - metrics.UpstreamRequests.WithLabelValues("/api/v1/", "service-a").Inc()
   - httputil.ReverseProxy.ServeHTTP() forwards request to upstream-a:5000
   - upstream responds: 200 OK
   - ReverseProxy streams response into bufferedRecorder

8. Back in Cache plugin:
   - bufferedRecorder.statusCode = 200
   - Store in LRU: key="/api/v1/users", body, headers, expiry=now+30s
   - Flush bufferedRecorder --> writes headers + body to statusRecorder

9. Back in Router:
   - duration = time.Since(start)
   - metrics.RequestDuration.Observe(duration) [labeled route/upstream/status]

10. Response delivered: 200 OK, X-Cache: MISS

---- Second identical request ----

Step 6 (Cache):
   - cache.Get("/api/v1/users") --> HIT, not expired
   - metrics.CacheHits.WithLabelValues("/api/v1/").Inc()
   - Write cached headers + body directly to responseWriter
   - Add X-Cache: HIT header
   - return (proxy is NEVER called)

Steps 7-8: SKIPPED entirely. No network call to upstream.
```

---

## 5. Package-by-Package Reference

### internal/config

**Purpose:** Defines all data structures mapping to the YAML config file. Single Load(path) function.

**Key types:**
```
Config
+-- ServerConfig  { port: 8080 }
+-- AdminConfig   { port: 9090 }
+-- []UpstreamConfig { name, []targets }
+-- []RouteConfig
    +-- PluginsConfig
        +-- RateLimitConfig { enabled, rps, burst }
        +-- CacheConfig     { enabled, ttl_seconds, max_entries }
        +-- AuthConfig      { enabled, []UserConfig }
```

**Why separate from main:** Config structs are used by every other package. A shared config package avoids circular imports.

---

### internal/metrics

**Purpose:** Declares all five Prometheus metric variables using promauto (auto-registers on package init).

```go
RequestDuration      *prometheus.HistogramVec  // labels: route, upstream, status_code
CacheHits            *prometheus.CounterVec    // labels: route
CacheMisses          *prometheus.CounterVec    // labels: route
RateLimitRejections  *prometheus.CounterVec    // labels: route
UpstreamRequests     *prometheus.CounterVec    // labels: route, upstream
```

**Why a dedicated package:** Prometheus metrics must be registered exactly once (double-registration panics). Package-level vars ensure single initialization regardless of how many packages import metrics.

---

### internal/plugins

**Purpose:** Defines the Plugin interface and the Chain builder function.

```go
type Plugin interface {
    Name() string
    Handle(w http.ResponseWriter, r *http.Request, next http.Handler)
}
```

Every plugin receives ResponseWriter, Request, and a next handler. Calling next.ServeHTTP(w, r) passes control forward. NOT calling next short-circuits the chain (returns 401, 429, or cache hit directly).

The Chain function compiles a []Plugin + final handler into a single http.Handler via nested closures. This handler is stored in the route table and reused for every request — zero allocation overhead at request time.

---

### internal/plugins/auth

Implements HTTP Basic Authentication.

- Enabled = false: call next (no-op)
- Enabled = true: parse Authorization: Basic <base64> header, decode, compare against users list
- Match: call next
- No match: 401 Unauthorized

**Security note for README:** Basic Auth over plain HTTP sends credentials in base64 (not encrypted). In production, TLS termination must precede the gateway. TLS is out of scope for this demo.

---

### internal/plugins/ratelimit

Implements token bucket rate limiting per route.

- Enabled = false: call next
- Enabled = true: call limiter.Allow()
  - true: consume token, call next
  - false: bucket empty, return 429 Too Many Requests with Retry-After: 1 header

Token bucket semantics:
```
Capacity = burst (e.g. 20 tokens)
Refill rate = requests_per_second (e.g. 100 tok/sec = 1 token per 10ms)
Initial state = full bucket

Steady state: up to 100 req/sec pass
Burst: up to 120 req in first second (100 steady + 20 burst)
```

rate.Limiter from golang.org/x/time/rate is documented as safe for concurrent use. No additional mutex needed.

---

### internal/plugins/cache

Implements per-route LRU response cache with TTL for GET requests only.

Cache key = r.URL.String() (full URL including query string)

HIT path:
1. LRU lookup -> found and not expired
2. Write cached headers + body to ResponseWriter
3. Add X-Cache: HIT header
4. return (proxy not called)

MISS path:
1. Increment CacheMisses counter
2. Create bufferedRecorder (implements http.ResponseWriter in memory)
3. Call next with bufferedRecorder (proxy runs, writes to buffer)
4. If status = 200: store body + headers + expiry in LRU
5. Flush bufferedRecorder to real ResponseWriter

The bufferedRecorder captures Header(), WriteHeader(), and Write() entirely in memory. The actual HTTP response is only written after next returns. This ensures we either cache the complete response or nothing.

Why only GET/200: Non-GET requests are not idempotent (POST, PUT, DELETE mutate state). Non-200 responses may be transient errors. Caching either would cause incorrect behavior.

---

### internal/proxy

Wraps httputil.ReverseProxy with consistent hash target selection.

```go
type Proxy struct {
    upstream string                              // for metrics label
    route    string                              // for metrics label
    ring     *consistent.Consistent             // hash ring with all target URLs
    proxies  map[string]*httputil.ReverseProxy  // pre-built proxy per target URL
}
```

On every request:
1. Strip port from r.RemoteAddr to get client IP
2. ring.Get(clientIP) -> target URL (consistent, same client always hits same upstream)
3. Look up pre-built ReverseProxy for that target
4. Increment UpstreamRequests metric
5. proxy.ServeHTTP(w, r)

The Director function on each ReverseProxy rewrites req.URL.Scheme and req.URL.Host before forwarding. The URL path is NOT modified — upstream receives the full original path.

---

### internal/router

Maintains the route table and serves as the main http.Handler for the gateway server.

```go
type routeEntry struct {
    config  config.RouteConfig
    handler http.Handler  // compiled plugin chain for this route
}

type Router struct {
    mu     sync.RWMutex
    routes []*routeEntry  // sorted longest-path-first
}
```

Path matching: prefix match, longest path wins. Routes are kept sorted by len(path) descending so the first match is always most specific.

ServeHTTP wraps ResponseWriter in a statusRecorder (captures HTTP status code), runs the plugin chain, then records request duration to the histogram metric.

AddRoute (called by Admin API): acquires write lock, replaces existing entry if path matches, appends if new, re-sorts. The old plugin chain for that path is simply replaced — any in-flight request using the old chain completes normally.

---

### internal/admin

Provides the REST Admin API for live route management.

```go
type HandlerBuilderFunc func(cfg config.RouteConfig, targets []string) (http.Handler, error)
```

This function is defined in main.go and injected into the admin handler. It builds the full plugin chain for a given route config. Admin calls it on every add/update operation.

Endpoints (Go 1.22 pattern syntax):
```
GET    /admin/routes           -> list all routes as JSON
POST   /admin/routes           -> upsert a route (add or replace)
DELETE /admin/routes/{path...} -> remove route by path
```

Hot reload flow:
1. Receive POST with new route config JSON
2. Parse and validate
3. Look up upstream targets from known upstreams map
4. Call HandlerBuilderFunc -> new compiled http.Handler
5. Call router.AddRoute(cfg, handler) -> atomic swap under write lock
6. Return 201/200

From the moment AddRoute returns, all new requests use the new handler. Zero downtime.

---

### cmd/gateway

Entry point. Wires all packages together and manages three server lifetimes.

Startup sequence:
1. Load YAML config
2. Build upstream map: map[name][]string{targets}
3. For each route: buildHandler(cfg, targets) -> compiled handler
4. Register with router
5. Start metrics server (:2112)
6. Start admin server (:9090)
7. Start gateway server (:8080)
8. Block on SIGINT/SIGTERM
9. Shutdown all three servers with 10s context deadline

Graceful shutdown: http.Server.Shutdown() stops accepting new connections and waits for active handlers to finish. No request is hard-killed.

---

### cmd/mockserver

Tiny HTTP echo server used as upstream target in development and Docker Compose.

Responds to any request with:
```json
{
  "server": "upstream-a",
  "method": "GET",
  "path": "/api/v1/users",
  "query": "",
  "headers": { "User-Agent": "..." }
}
```

Configured by environment variables:
```
SERVER_NAME=upstream-a   (shown in response body, identifies which instance responded)
PORT=5000                (listen port)
```

---

## 6. Config Schema Complete

```yaml
server:
  port: 8080              # Gateway proxy port

admin:
  port: 9090              # Admin REST API port (metrics always on :2112)

upstreams:
  - name: service-a       # Unique identifier; referenced by routes
    targets:              # One or more backend URLs
      - http://upstream-a:5000
      - http://upstream-a:5001  # Multiple -> consistent hash distributes traffic

  - name: service-b
    targets:
      - http://upstream-b:6000

routes:
  - path: /api/v1/             # URL prefix; longer paths matched first
    upstream: service-a        # Must match a name in upstreams
    plugins:
      rate_limit:
        enabled: true
        requests_per_second: 100.0   # Token bucket fill rate (float64)
        burst: 20                    # Max burst capacity (int)
      cache:
        enabled: true
        ttl_seconds: 30              # Response cache TTL in seconds
        max_entries: 1000            # LRU capacity; oldest evicted when full
      auth:
        enabled: false
        users: []                    # Only read when enabled: true

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

Validation rules enforced at startup:
- Every route upstream must match a name in upstreams list
- targets must not be empty
- requests_per_second must be > 0 when rate_limit.enabled = true
- max_entries must be > 0 when cache.enabled = true

---

## 7. Plugin System Design

### The Interface

```go
type Plugin interface {
    Name() string
    Handle(w http.ResponseWriter, r *http.Request, next http.Handler)
}
```

To add a new plugin (e.g. JWT validator, request logger, circuit breaker):
1. Create a new package under internal/plugins/
2. Define a struct with a New(cfg) constructor
3. Implement Name() string and Handle(w, r, next)
4. Add it to buildHandler() in main.go
5. Add its config struct to PluginsConfig in internal/config/config.go

No other file changes required.

### Plugin Execution Order and Why

Order: Auth -> RateLimit -> Cache -> Proxy

1. Auth first: No point spending rate-limit tokens on unauthenticated requests. Reject immediately with 401.
2. RateLimit second: Authenticated but rate-limited clients get 429. Prevents DoS by valid users.
3. Cache third: Only check/populate cache for requests that pass both gates. Prevents caching responses for requests we'd reject on replay.
4. Proxy last: Only reach the upstream if all gates pass and the cache missed.

---

## 8. Consistent Hashing Design

### The Problem

With N upstream instances, simple round-robin remaps all sessions when N changes. Consistent hashing only remaps K/N keys.

### How It Works

A consistent hash ring places both nodes and keys on a circular number line (0 to 2^32-1). Each node occupies multiple positions (virtual nodes, 20 by default in stathat/consistent). To find the node for a key:
1. Hash the key to a position
2. Walk clockwise until you hit a node position
3. That node handles the key

Adding a node only affects keys between the new node and its clockwise predecessor.

### Implementation

```go
ring := consistent.New()
for _, target := range targets {
    ring.Add(target)  // "http://upstream-a:5000"
}

// Per request:
clientIP, _, _ := net.SplitHostPort(r.RemoteAddr)
target, _ := ring.Get(clientIP)  // deterministic: same IP -> same target
proxy := proxies[target]
proxy.ServeHTTP(w, r)
```

Key choice is client IP: same client always routes to same upstream instance (session affinity). This is the same approach as Nginx ip_hash.

---

## 9. Admin API Reference

Base URL: http://localhost:9090

### GET /admin/routes
Returns all active routes as a JSON array.

### POST /admin/routes
Upsert a route (add new or replace existing, matched by path).

Request body:
```json
{
  "path": "/api/v3/",
  "upstream": "service-a",
  "plugins": {
    "rate_limit": { "enabled": true, "requests_per_second": 200, "burst": 50 },
    "cache": { "enabled": true, "ttl_seconds": 60, "max_entries": 500 },
    "auth": { "enabled": false }
  }
}
```

Errors: 400 if upstream unknown, 400 if malformed JSON, 400 if missing required fields.

### DELETE /admin/routes/{path}
Remove a route. The path in the URL is the route path minus its leading slash.

Example to delete /api/v3/:
```
DELETE http://localhost:9090/admin/routes/api/v3/
```

Response 204 on success, 404 if not found.

---

## 10. Prometheus Metrics Reference

Metrics endpoint: http://localhost:2112/metrics

### minigateway_request_duration_seconds (Histogram)
Total gateway latency per request, labeled by route, upstream, status_code.
Includes plugin chain time + proxy time (or cache lookup time for hits).

p99 latency query:
```promql
histogram_quantile(0.99,
  sum(rate(minigateway_request_duration_seconds_bucket[5m])) by (route, le)
)
```

### minigateway_cache_hits_total (Counter)
Increments on valid (non-expired) cache hit. Labeled by route.

### minigateway_cache_misses_total (Counter)
Increments when cache lookup fails or entry is expired. Labeled by route.

Cache hit ratio:
```promql
rate(minigateway_cache_hits_total[5m])
/
(rate(minigateway_cache_hits_total[5m]) + rate(minigateway_cache_misses_total[5m]))
```

### minigateway_ratelimit_rejections_total (Counter)
Increments on 429 responses from rate limit plugin. Labeled by route.

### minigateway_upstream_requests_total (Counter)
Increments only when the proxy actually forwards to an upstream (NOT on cache hits). Labeled by route, upstream.

Upstream load reduction:
```promql
1 - (
  rate(minigateway_upstream_requests_total[5m])
  /
  rate(minigateway_request_duration_seconds_count[5m])
)
```

---

## 11. Concurrency Model

Go's net/http spawns one goroutine per request. All shared state must be protected.

| Shared resource | Protection | Notes |
|---|---|---|
| Router route table | sync.RWMutex | Many concurrent readers; Admin API is exclusive writer |
| LRU cache entries | hashicorp/golang-lru internal lock | Thread-safe by library design |
| Rate limiter | golang.org/x/time/rate internal atomics | Thread-safe by library design |
| Prometheus metrics | prometheus/client_golang internal atomics | Thread-safe by library design |
| Proxy map (target->ReverseProxy) | None | Written once at startup; read-only thereafter |

### The RWMutex Pattern

```go
// Read path (every request) - concurrent readers allowed
r.mu.RLock()
routes := r.routes  // copy slice header (pointer + len + cap)
r.mu.RUnlock()
// iterate routes without holding lock - safe because entries never mutated

// Write path (Admin API) - exclusive
r.mu.Lock()
// replace or append to r.routes
r.mu.Unlock()
```

In-flight requests that already copied the old routes slice will complete with the old handlers. This is correct behavior. No request is dropped during a route update.

---

## 12. Security Model

### What This Project Secures

| Threat | Mitigation |
|---|---|
| Unauthenticated access | Basic Auth plugin per route |
| Traffic flood / DoS | Token bucket rate limiter per route |
| Admin API network exposure | Bind admin server to 127.0.0.1:9090 only |
| Admin request body attacks | http.MaxBytesReader 1MB limit on admin endpoints |
| Hop-by-hop header injection | httputil.ReverseProxy strips these automatically |

### Known Limitations (noted in README)

| Limitation | Note |
|---|---|
| Basic Auth over plain HTTP | TLS termination out of scope for demo; credentials are base64 not encrypted |
| Passwords in YAML plaintext | Demo project; production uses secrets manager |
| Global rate limiting (not per-IP) | Simpler for demo; per-IP would need a map of limiters |
| No health checking | Down upstream returns 502; no automatic failover |

---

## 13. Performance Design

### How Less Than 2ms Proxy Overhead Is Achievable

Proxy overhead = gateway-added latency beyond the upstream's own response time.

For the cache-miss path:
- Route matching: O(N) scan, N <= 10 routes, ~microseconds
- Plugin traversal: 3 function calls, ~nanoseconds
- limiter.Allow(): atomic CAS, ~nanoseconds
- LRU Get: hash map lookup, ~nanoseconds
- httputil.ReverseProxy setup: header copies, Director call, ~10 microseconds
- Response buffering: bytes.Buffer write, ~0.1ms for 1KB response

Total overhead for 1KB response: approximately 0.5-1ms. Well under 2ms.

What dominates total latency: network RTT to upstream (not gateway code). If upstream takes 50ms, gateway adds ~1ms on top.

### How 85% Cache Hit Rate Is Achievable

For a hot-key workload (20 unique URLs, 10,000 total requests, each URL hit ~500 times):
- First 20 requests: misses (cold cache)
- Next 9,980: hits (warm cache)
- Hit rate = 9,980 / 10,000 = 99.8%

For realistic 80/20 distribution (20% of URLs = 80% of traffic, cache fits top URLs):
- Hit rate ~= 80-85%

### How 60% Upstream Load Reduction Is Achieved

Upstream load reduction = fraction of requests NOT reaching the upstream = cache hit rate.

If 85% of requests are cache hits, only 15% reach the upstream = 85% reduction.
The 60% claim is conservative. Actual reduction equals the measured cache hit rate.

minigateway_upstream_requests_total vs minigateway_request_duration_seconds_count shows this directly in Prometheus.

---

## 14. Docker and Deployment Model

### Multi-Stage Dockerfile

```
Stage 1 (golang:1.22-alpine as builder):
  COPY go.mod go.sum -> RUN go mod download (cached layer)
  COPY . .
  RUN go build -o /gateway ./cmd/gateway
  RUN go build -o /mockserver ./cmd/mockserver

Stage 2 (alpine:latest):
  COPY /gateway and /mockserver from builder
  COPY config/ /config/
  Expose 8080 9090 2112
```

CGO_ENABLED=0 produces a fully static binary. No libc dependency. Runs on any Linux. The final image is ~15MB total.

### Docker Compose Services

```
gateway:
  build: .
  command: ["/gateway", "/config/gateway.yaml"]
  ports: 8080, 9090, 2112
  depends_on: upstream-a, upstream-b

upstream-a:
  build: .
  command: ["/mockserver"]
  env: SERVER_NAME=upstream-a, PORT=5000

upstream-b:
  build: .
  command: ["/mockserver"]
  env: SERVER_NAME=upstream-b, PORT=6000
```

One image, two binaries, command decides which to run. Docker Compose network allows services to reference each other by name (upstream-a, upstream-b) via Docker DNS.

---

## 15. Key Design Decisions and Trade-offs

### Compile plugin chain at route-load time (not per-request)
Alternative: build the chain on every request.
Reason: Building allocates http.HandlerFunc closures. At 1000 req/sec that is 1000 heap allocations/sec just for chain construction. Compiling once at startup and reusing the handler means zero allocation overhead at request time.

### Buffer response body for caching
Alternative: stream response to client and simultaneously write to cache.
Reason: Streaming while caching requires io.TeeReader and careful goroutine management. Buffering is simpler and correct. Downside: a 1MB response uses 1MB of RAM for the duration of caching. Acceptable at demo scale.

### Use client IP for consistent hash key
Alternative: URL path hash.
Reason: Session affinity. Same client always routes to same upstream instance. URL-based hashing is better for stateless sharded backends. Client IP is better for stateful backends with session data. Either could be added as a config option.

### No TTL built into LRU
Alternative: use github.com/patrickmn/go-cache which has native TTL.
Reason: hashicorp/golang-lru is more widely production-used. TTL is trivially added on top by comparing time.Now() against a stored expiry. Expired entries occupy LRU slots until evicted by capacity — acceptable at demo scale.

### Admin API on separate port
Alternative: /admin/ prefix on port 8080.
Reason: In production, admin port is firewalled (only control plane can reach it). Gateway port is public. Separate ports make this access control trivial at the network layer.

---

## 16. What This Demonstrates on Your Resume

### For Backend SWE roles
- You understand HTTP mechanics: headers, status codes, ReverseProxy, response streaming
- You can build a middleware pipeline that composes behaviors cleanly
- You know how to write concurrent Go safely (RWMutex, goroutines, graceful shutdown)

### For Platform and Infrastructure roles
- You understand API gateway architecture (same concepts Kong, Envoy, and Nginx implement)
- You can write declarative config-driven systems (YAML routes -> runtime behavior)
- You know how to expose Prometheus metrics and explain what each metric tells an on-call engineer
- You understand consistent hashing and why it matters for distributed load balancing

### For SRE roles
- You implemented observability from day one (metrics, not just logs)
- You designed for zero-downtime operations (Admin API hot reload without restart)
- You containerized the service with Docker Compose for environment-parity testing

### How It Differentiates from RateGuard
RateGuard shows you can implement one algorithm (sliding window) in Spring Boot.
MiniGateway shows you can architect a system where rate limiting is just one plugin in a larger composable infrastructure layer. The level of abstraction is categorically different.

RateGuard = "I can implement a specific algorithm"
MiniGateway = "I can design extensible systems"
