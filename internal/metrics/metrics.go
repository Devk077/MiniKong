package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	RequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "minigateway_request_duration_seconds",
		Help:    "Total gateway request latency, labeled by route, upstream, and status code.",
		Buckets: prometheus.DefBuckets,
	}, []string{"route", "upstream", "status_code"})

	CacheHits = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "minigateway_cache_hits_total",
		Help: "Number of cache hits, labeled by route.",
	}, []string{"route"})

	CacheMisses = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "minigateway_cache_misses_total",
		Help: "Number of cache misses, labeled by route.",
	}, []string{"route"})

	RateLimitRejections = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "minigateway_ratelimit_rejections_total",
		Help: "Number of requests rejected by rate limiter, labeled by route.",
	}, []string{"route"})

	UpstreamRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "minigateway_upstream_requests_total",
		Help: "Number of requests forwarded to upstream (excludes cache hits), labeled by route and upstream.",
	}, []string{"route", "upstream"})
)
