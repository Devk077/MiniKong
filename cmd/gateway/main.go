package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/Devk077/minigateway/internal/admin"
	"github.com/Devk077/minigateway/internal/config"
	"github.com/Devk077/minigateway/internal/plugins"
	"github.com/Devk077/minigateway/internal/plugins/auth"
	"github.com/Devk077/minigateway/internal/plugins/cache"
	"github.com/Devk077/minigateway/internal/plugins/ratelimit"
	"github.com/Devk077/minigateway/internal/proxy"
	"github.com/Devk077/minigateway/internal/router"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: gateway <config-file>")
	}

	cfg, err := config.Load(os.Args[1])
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	// Index upstreams by name for O(1) lookup.
	upstreams := make(map[string][]string, len(cfg.Upstreams))
	for _, u := range cfg.Upstreams {
		upstreams[u.Name] = u.Targets
	}

	// Build the route table.
	rt := router.New()
	for _, route := range cfg.Routes {
		h, err := buildHandler(route, upstreams[route.Upstream])
		if err != nil {
			log.Fatalf("build handler for route %s: %v", route.Path, err)
		}
		rt.AddRoute(route, h)
	}

	// Metrics server — always on :2112.
	metricsMux := http.NewServeMux()
	metricsMux.Handle("/metrics", promhttp.Handler())
	metricsServer := &http.Server{
		Addr:    ":2112",
		Handler: metricsMux,
	}

	// Admin server — defaults to 127.0.0.1 (loopback only).
	// Set admin.host: "0.0.0.0" in config to expose inside Docker.
	adminHost := cfg.Admin.Host
	if adminHost == "" {
		adminHost = "127.0.0.1"
	}
	adminMux := http.NewServeMux()
	admin.New(rt, upstreams, buildHandler).Register(adminMux)
	adminServer := &http.Server{
		Addr:    fmt.Sprintf("%s:%d", adminHost, cfg.Admin.Port),
		Handler: adminMux,
	}

	// Gateway server.
	gatewayServer := &http.Server{
		Addr:    fmt.Sprintf(":%d", cfg.Server.Port),
		Handler: rt,
	}

	go func() {
		log.Printf("metrics server listening on :2112")
		if err := metricsServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("metrics server: %v", err)
		}
	}()

	go func() {
		log.Printf("admin server listening on :%d", cfg.Admin.Port)
		if err := adminServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("admin server: %v", err)
		}
	}()

	go func() {
		log.Printf("gateway listening on :%d", cfg.Server.Port)
		if err := gatewayServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("gateway server: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	<-quit

	log.Println("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_ = metricsServer.Shutdown(ctx)
	_ = adminServer.Shutdown(ctx)
	_ = gatewayServer.Shutdown(ctx)
	log.Println("shutdown complete")
}

// buildHandler compiles the full plugin chain + proxy for a route.
// Order: Auth -> RateLimit -> Cache -> Proxy.
func buildHandler(cfg config.RouteConfig, targets []string) (http.Handler, error) {
	authPlugin := auth.New(cfg.Plugins.Auth)
	rlPlugin := ratelimit.New(cfg.Plugins.RateLimit, cfg.Path)
	cachePlugin, err := cache.New(cfg.Plugins.Cache, cfg.Path)
	if err != nil {
		return nil, fmt.Errorf("init cache plugin: %w", err)
	}

	p := proxy.New(cfg.Path, cfg.Upstream, targets)
	return plugins.Chain([]plugins.Plugin{authPlugin, rlPlugin, cachePlugin}, p), nil
}
