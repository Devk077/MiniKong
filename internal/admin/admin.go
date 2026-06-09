package admin

import (
	"encoding/json"
	"net/http"

	"github.com/Devk077/minigateway/internal/config"
)

// HandlerBuilderFunc builds the full plugin chain for a given route config.
// Defined in main.go and injected here to avoid circular imports.
type HandlerBuilderFunc func(cfg config.RouteConfig, targets []string) (http.Handler, error)

// Router is the subset of router.Router the admin handler needs.
type Router interface {
	AddRoute(cfg config.RouteConfig, handler http.Handler)
	RemoveRoute(path string) bool
	Routes() []config.RouteConfig
}

type Handler struct {
	router    Router
	upstreams map[string][]string
	build     HandlerBuilderFunc
}

func New(router Router, upstreams map[string][]string, build HandlerBuilderFunc) *Handler {
	return &Handler{router: router, upstreams: upstreams, build: build}
}

// Register wires all admin endpoints onto mux using Go 1.22 method+path patterns.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /admin/routes", h.listRoutes)
	mux.HandleFunc("POST /admin/routes", h.upsertRoute)
	mux.HandleFunc("DELETE /admin/routes/{path...}", h.deleteRoute)
}

func (h *Handler) listRoutes(w http.ResponseWriter, r *http.Request) {
	routes := h.router.Routes()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(routes) //nolint:errcheck
}

func (h *Handler) upsertRoute(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)

	var cfg config.RouteConfig
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return
	}
	if cfg.Path == "" {
		http.Error(w, "bad request: path is required", http.StatusBadRequest)
		return
	}

	targets, ok := h.upstreams[cfg.Upstream]
	if !ok {
		http.Error(w, "bad request: unknown upstream "+cfg.Upstream, http.StatusBadRequest)
		return
	}

	handler, err := h.build(cfg, targets)
	if err != nil {
		http.Error(w, "internal error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Check before AddRoute to decide 201 (new) vs 200 (updated).
	isUpdate := false
	for _, e := range h.router.Routes() {
		if e.Path == cfg.Path {
			isUpdate = true
			break
		}
	}

	h.router.AddRoute(cfg, handler)

	if isUpdate {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusCreated)
	}
}

func (h *Handler) deleteRoute(w http.ResponseWriter, r *http.Request) {
	// PathValue returns "api/v3/" (no leading slash); restore it.
	path := "/" + r.PathValue("path")

	if !h.router.RemoveRoute(path) {
		http.Error(w, "route not found: "+path, http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
