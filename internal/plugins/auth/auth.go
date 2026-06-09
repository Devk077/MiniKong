package auth

import (
	"encoding/base64"
	"net/http"
	"strings"

	"github.com/Devk077/minigateway/internal/config"
)

type Auth struct {
	cfg config.AuthConfig
}

func New(cfg config.AuthConfig) *Auth {
	return &Auth{cfg: cfg}
}

func (a *Auth) Name() string { return "auth" }

func (a *Auth) Handle(w http.ResponseWriter, r *http.Request, next http.Handler) {
	if !a.cfg.Enabled {
		next.ServeHTTP(w, r)
		return
	}

	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Basic ") {
		w.Header().Set("WWW-Authenticate", `Basic realm="minigateway"`)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	decoded, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(header, "Basic "))
	if err != nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	parts := strings.SplitN(string(decoded), ":", 2)
	if len(parts) != 2 {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	username, password := parts[0], parts[1]
	for _, u := range a.cfg.Users {
		if u.Username == username && u.Password == password {
			next.ServeHTTP(w, r)
			return
		}
	}

	w.Header().Set("WWW-Authenticate", `Basic realm="minigateway"`)
	http.Error(w, "Unauthorized", http.StatusUnauthorized)
}
