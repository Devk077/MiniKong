package cache

import (
	"bytes"
	"net/http"
	"time"

	lru "github.com/hashicorp/golang-lru/v2"

	"github.com/Devk077/minigateway/internal/config"
	"github.com/Devk077/minigateway/internal/metrics"
)

type cacheEntry struct {
	statusCode int
	headers    http.Header
	body       []byte
	expiry     time.Time
}

type Cache struct {
	cfg   config.CacheConfig
	route string
	store *lru.Cache[string, *cacheEntry]
}

func New(cfg config.CacheConfig, route string) (*Cache, error) {
	if !cfg.Enabled {
		return &Cache{cfg: cfg, route: route}, nil
	}
	store, err := lru.New[string, *cacheEntry](cfg.MaxEntries)
	if err != nil {
		return nil, err
	}
	return &Cache{cfg: cfg, route: route, store: store}, nil
}

func (c *Cache) Name() string { return "cache" }

func (c *Cache) Handle(w http.ResponseWriter, r *http.Request, next http.Handler) {
	// Only cache GET requests when the plugin is enabled.
	if !c.cfg.Enabled || r.Method != http.MethodGet {
		next.ServeHTTP(w, r)
		return
	}

	key := r.URL.String()

	// HIT: valid entry exists and has not expired.
	if entry, ok := c.store.Get(key); ok && time.Now().Before(entry.expiry) {
		metrics.CacheHits.WithLabelValues(c.route).Inc()
		for k, vals := range entry.headers {
			for _, v := range vals {
				w.Header().Add(k, v)
			}
		}
		w.Header().Set("X-Cache", "HIT")
		w.WriteHeader(entry.statusCode)
		w.Write(entry.body) //nolint:errcheck
		return
	}

	// MISS: buffer the proxied response so we can store it before sending.
	metrics.CacheMisses.WithLabelValues(c.route).Inc()

	buf := &bufferedRecorder{header: make(http.Header)}
	next.ServeHTTP(buf, r)

	// Only cache successful responses.
	if buf.statusCode == http.StatusOK {
		c.store.Add(key, &cacheEntry{
			statusCode: buf.statusCode,
			headers:    buf.header.Clone(),
			body:       buf.body.Bytes(),
			expiry:     time.Now().Add(time.Duration(c.cfg.TTLSeconds) * time.Second),
		})
	}

	// Flush buffered response to the real ResponseWriter.
	for k, vals := range buf.header {
		for _, v := range vals {
			w.Header().Add(k, v)
		}
	}
	w.Header().Set("X-Cache", "MISS")
	w.WriteHeader(buf.statusCode)
	w.Write(buf.body.Bytes()) //nolint:errcheck
}

// bufferedRecorder captures an HTTP response entirely in memory before writing
// it to the client. This lets us inspect and store the response before sending.
type bufferedRecorder struct {
	header      http.Header
	statusCode  int
	body        bytes.Buffer
	wroteHeader bool
}

func (b *bufferedRecorder) Header() http.Header { return b.header }

func (b *bufferedRecorder) WriteHeader(code int) {
	if !b.wroteHeader {
		b.statusCode = code
		b.wroteHeader = true
	}
}

func (b *bufferedRecorder) Write(data []byte) (int, error) {
	if !b.wroteHeader {
		b.WriteHeader(http.StatusOK)
	}
	return b.body.Write(data)
}
