package plugins

import "net/http"

// Plugin is the interface every middleware must implement.
// To short-circuit: write to w and return WITHOUT calling next.ServeHTTP.
// To pass through: call next.ServeHTTP(w, r) and return.
type Plugin interface {
	Name() string
	Handle(w http.ResponseWriter, r *http.Request, next http.Handler)
}
