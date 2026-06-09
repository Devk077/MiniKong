package plugins

import "net/http"

// Chain compiles a slice of plugins and a final handler into a single http.Handler.
// Execution order: plugins[0] -> plugins[1] -> ... -> final.
// The chain is built once at route-load time; zero allocation per request.
func Chain(ps []Plugin, final http.Handler) http.Handler {
	h := final
	for i := len(ps) - 1; i >= 0; i-- {
		p := ps[i]   // new var per iteration — safe closure capture
		next := h
		h = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p.Handle(w, r, next)
		})
	}
	return h
}
