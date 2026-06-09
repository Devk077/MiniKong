package proxy

import (
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"

	"stathat.com/c/consistent"

	"github.com/Devk077/minigateway/internal/metrics"
)

// Proxy forwards requests to upstream targets using consistent hashing on client IP.
type Proxy struct {
	upstream string
	route    string
	ring     *consistent.Consistent
	proxies  map[string]*httputil.ReverseProxy
}

func New(route, upstream string, targets []string) *Proxy {
	ring := consistent.New()
	proxies := make(map[string]*httputil.ReverseProxy, len(targets))

	for _, target := range targets {
		ring.Add(target)

		targetURL, err := url.Parse(target)
		if err != nil {
			panic("minigateway: invalid upstream target URL " + target + ": " + err.Error())
		}

		scheme := targetURL.Scheme
		host := targetURL.Host

		rp := &httputil.ReverseProxy{
			Director: func(req *http.Request) {
				req.URL.Scheme = scheme
				req.URL.Host = host
				// Suppress default Go user-agent if caller didn't set one.
				if _, ok := req.Header["User-Agent"]; !ok {
					req.Header.Set("User-Agent", "")
				}
			},
		}
		proxies[target] = rp
	}

	return &Proxy{
		upstream: upstream,
		route:    route,
		ring:     ring,
		proxies:  proxies,
	}
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	clientIP, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		clientIP = r.RemoteAddr
	}

	target, err := p.ring.Get(clientIP)
	if err != nil {
		http.Error(w, "no upstream available", http.StatusBadGateway)
		return
	}

	rp, ok := p.proxies[target]
	if !ok {
		http.Error(w, "upstream not found", http.StatusBadGateway)
		return
	}

	metrics.UpstreamRequests.WithLabelValues(p.route, p.upstream).Inc()
	rp.ServeHTTP(w, r)
}
