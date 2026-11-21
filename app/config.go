package main

import (
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds every runtime setting. Operators set the exported ones through
// environment variables only; the timing fields are fixed defaults that tests
// shorten.
type Config struct {
	Port              int           // PORT
	LogLevel          slog.Level    // LOG_LEVEL: debug, info, warn, error
	PaymentsLatency   time.Duration // PAYMENTS_LATENCY_MS: simulated payments call time
	PaymentsErrorRate float64       // PAYMENTS_ERROR_RATE: 0..1, chance the payments call fails (502)
	FaultErrorRate    float64       // FAULT_ERROR_RATE: 0..1, chance an /orders request returns 500
	FaultLatency      time.Duration // FAULT_LATENCY_MS: extra delay added to /orders requests
	Version           string        // APP_VERSION

	WarmUp        time.Duration // readiness fails for this long after start
	DrainDelay    time.Duration // after SIGTERM, keep serving while endpoints are removed
	ShutdownLimit time.Duration // max time to finish in-flight requests
}

// DefaultConfig returns production defaults. DrainDelay + ShutdownLimit
// (25s) stays under the chart's 30s terminationGracePeriodSeconds.
func DefaultConfig() Config {
	return Config{
		Port:            8080,
		LogLevel:        slog.LevelInfo,
		PaymentsLatency: 40 * time.Millisecond,
		Version:         buildVersion,
		WarmUp:          2 * time.Second,
		DrainDelay:      5 * time.Second,
		ShutdownLimit:   20 * time.Second,
	}
}

// LoadConfig reads the environment on top of DefaultConfig.
func LoadConfig(getenv func(string) string) (Config, error) {
	c := DefaultConfig()
	var errs []string
	bad := func(k, v, why string) { errs = append(errs, fmt.Sprintf("%s=%q: %s", k, v, why)) }

	if v := getenv("PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil || p < 1 || p > 65535 {
			bad("PORT", v, "must be 1-65535")
		} else {
			c.Port = p
		}
	}
	if v := getenv("LOG_LEVEL"); v != "" {
		if err := c.LogLevel.UnmarshalText([]byte(strings.ToLower(v))); err != nil {
			bad("LOG_LEVEL", v, "must be debug, info, warn or error")
		}
	}
	ms := func(k string, dst *time.Duration) {
		if v := getenv(k); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 0 || n > 60000 {
				bad(k, v, "must be 0-60000 milliseconds")
				return
			}
			*dst = time.Duration(n) * time.Millisecond
		}
	}
	rate := func(k string, dst *float64) {
		if v := getenv(k); v != "" {
			f, err := strconv.ParseFloat(v, 64)
			if err != nil || f < 0 || f > 1 {
				bad(k, v, "must be between 0 and 1")
				return
			}
			*dst = f
		}
	}
	ms("PAYMENTS_LATENCY_MS", &c.PaymentsLatency)
	rate("PAYMENTS_ERROR_RATE", &c.PaymentsErrorRate)
	rate("FAULT_ERROR_RATE", &c.FaultErrorRate)
	ms("FAULT_LATENCY_MS", &c.FaultLatency)
	if v := getenv("APP_VERSION"); v != "" {
		c.Version = v
	}

	if len(errs) > 0 {
		return c, fmt.Errorf("invalid configuration: %s", strings.Join(errs, "; "))
	}
	return c, nil
}

// envGetter adapts os.Getenv for LoadConfig.
var envGetter = os.Getenv
