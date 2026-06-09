package ratelimit

import (
	"net/http"

	"golang.org/x/time/rate"

	"github.com/Devk077/minigateway/internal/config"
	"github.com/Devk077/minigateway/internal/metrics"
)

type RateLimit struct {
	cfg     config.RateLimitConfig
	route   string
	limiter *rate.Limiter
}

func New(cfg config.RateLimitConfig, route string) *RateLimit {
	var limiter *rate.Limiter
	if cfg.Enabled {
		limiter = rate.NewLimiter(rate.Limit(cfg.RequestsPerSecond), cfg.Burst)
	}
	return &RateLimit{cfg: cfg, route: route, limiter: limiter}
}

func (rl *RateLimit) Name() string { return "ratelimit" }

func (rl *RateLimit) Handle(w http.ResponseWriter, r *http.Request, next http.Handler) {
	if !rl.cfg.Enabled {
		next.ServeHTTP(w, r)
		return
	}

	if !rl.limiter.Allow() {
		metrics.RateLimitRejections.WithLabelValues(rl.route).Inc()
		w.Header().Set("Retry-After", "1")
		http.Error(w, "Too Many Requests", http.StatusTooManyRequests)
		return
	}

	next.ServeHTTP(w, r)
}
