package router

import (
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Devk077/minigateway/internal/config"
	"github.com/Devk077/minigateway/internal/metrics"
)

type routeEntry struct {
	config  config.RouteConfig
	handler http.Handler
}

// Router is the main http.Handler for the gateway. It matches requests by
// longest-prefix-first and dispatches to the compiled plugin chain for each route.
type Router struct {
	mu     sync.RWMutex
	routes []*routeEntry
}

func New() *Router {
	return &Router{}
}

// AddRoute upserts a route (matched by path) and keeps the table sorted
// longest-path-first so the first match is always the most specific.
func (rt *Router) AddRoute(cfg config.RouteConfig, handler http.Handler) {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	for i, e := range rt.routes {
		if e.config.Path == cfg.Path {
			rt.routes[i] = &routeEntry{config: cfg, handler: handler}
			return
		}
	}

	rt.routes = append(rt.routes, &routeEntry{config: cfg, handler: handler})
	sort.Slice(rt.routes, func(i, j int) bool {
		return len(rt.routes[i].config.Path) > len(rt.routes[j].config.Path)
	})
}

// RemoveRoute deletes the route with the given path. Returns false if not found.
func (rt *Router) RemoveRoute(path string) bool {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	for i, e := range rt.routes {
		if e.config.Path == path {
			rt.routes = append(rt.routes[:i], rt.routes[i+1:]...)
			return true
		}
	}
	return false
}

// Routes returns a snapshot of the current route configs (used by Admin API).
func (rt *Router) Routes() []config.RouteConfig {
	rt.mu.RLock()
	defer rt.mu.RUnlock()

	cfgs := make([]config.RouteConfig, len(rt.routes))
	for i, e := range rt.routes {
		cfgs[i] = e.config
	}
	return cfgs
}

func (rt *Router) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rt.mu.RLock()
	routes := rt.routes
	rt.mu.RUnlock()

	var entry *routeEntry
	for _, e := range routes {
		if strings.HasPrefix(r.URL.Path, e.config.Path) {
			entry = e
			break
		}
	}

	if entry == nil {
		http.NotFound(w, r)
		return
	}

	rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	start := time.Now()
	entry.handler.ServeHTTP(rec, r)
	duration := time.Since(start)

	metrics.RequestDuration.WithLabelValues(
		entry.config.Path,
		entry.config.Upstream,
		strconv.Itoa(rec.status),
	).Observe(duration.Seconds())
}

// statusRecorder wraps ResponseWriter to capture the HTTP status code for metrics.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (sr *statusRecorder) WriteHeader(code int) {
	if !sr.wroteHeader {
		sr.status = code
		sr.wroteHeader = true
		sr.ResponseWriter.WriteHeader(code)
	}
}

func (sr *statusRecorder) Write(b []byte) (int, error) {
	if !sr.wroteHeader {
		sr.WriteHeader(http.StatusOK)
	}
	return sr.ResponseWriter.Write(b)
}
