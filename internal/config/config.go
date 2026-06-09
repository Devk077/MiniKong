package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Server    ServerConfig     `yaml:"server"`
	Admin     AdminConfig      `yaml:"admin"`
	Upstreams []UpstreamConfig `yaml:"upstreams"`
	Routes    []RouteConfig    `yaml:"routes"`
}

type ServerConfig struct {
	Port int `yaml:"port"`
}

type AdminConfig struct {
	Port int    `yaml:"port"`
	Host string `yaml:"host"` // defaults to "127.0.0.1"; set to "0.0.0.0" for Docker
}

type UpstreamConfig struct {
	Name    string   `yaml:"name"`
	Targets []string `yaml:"targets"`
}

type RouteConfig struct {
	Path     string        `yaml:"path"     json:"path"`
	Upstream string        `yaml:"upstream" json:"upstream"`
	Plugins  PluginsConfig `yaml:"plugins"  json:"plugins"`
}

type PluginsConfig struct {
	RateLimit RateLimitConfig `yaml:"rate_limit" json:"rate_limit"`
	Cache     CacheConfig     `yaml:"cache"      json:"cache"`
	Auth      AuthConfig      `yaml:"auth"       json:"auth"`
}

type RateLimitConfig struct {
	Enabled           bool    `yaml:"enabled"             json:"enabled"`
	RequestsPerSecond float64 `yaml:"requests_per_second" json:"requests_per_second"`
	Burst             int     `yaml:"burst"               json:"burst"`
}

type CacheConfig struct {
	Enabled    bool `yaml:"enabled"     json:"enabled"`
	TTLSeconds int  `yaml:"ttl_seconds" json:"ttl_seconds"`
	MaxEntries int  `yaml:"max_entries" json:"max_entries"`
}

type AuthConfig struct {
	Enabled bool         `yaml:"enabled" json:"enabled"`
	Users   []UserConfig `yaml:"users"   json:"users"`
}

type UserConfig struct {
	Username string `yaml:"username" json:"username"`
	Password string `yaml:"password" json:"password"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config YAML: %w", err)
	}

	if err := validate(&cfg); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

func validate(cfg *Config) error {
	upstreamNames := make(map[string]bool, len(cfg.Upstreams))
	for _, u := range cfg.Upstreams {
		if len(u.Targets) == 0 {
			return fmt.Errorf("upstream %q has no targets", u.Name)
		}
		upstreamNames[u.Name] = true
	}

	for _, r := range cfg.Routes {
		if !upstreamNames[r.Upstream] {
			return fmt.Errorf("route %q references unknown upstream %q", r.Path, r.Upstream)
		}
		if r.Plugins.RateLimit.Enabled && r.Plugins.RateLimit.RequestsPerSecond <= 0 {
			return fmt.Errorf("route %q: rate_limit.requests_per_second must be > 0 when enabled", r.Path)
		}
		if r.Plugins.Cache.Enabled && r.Plugins.Cache.MaxEntries <= 0 {
			return fmt.Errorf("route %q: cache.max_entries must be > 0 when enabled", r.Path)
		}
	}

	return nil
}
