// Command orders-gateway is a small stateless HTTP service used to
// demonstrate running, shipping, observing and operating a workload on
// Kubernetes. It has no database: orders are validated, a downstream
// payments call is simulated, and lookups return deterministic fake data.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// Set at build time with -ldflags "-X main.buildVersion=... -X main.commit=...
// -X main.buildFeatures=...".
var (
	buildVersion = "dev"
	commit       = "unknown"
	// buildFeatures switches on build-time features. "delivery-estimates"
	// adds estimated_delivery to orders: the visible change in the v2 demo
	// image (Dockerfile build-arg FEATURES).
	buildFeatures = ""
)

func main() {
	if err := run(context.Background(), envGetter, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, getenv func(string) string, out *os.File) error {
	cfg, err := LoadConfig(getenv)
	if err != nil {
		return err
	}
	log := slog.New(slog.NewJSONHandler(out, &slog.HandlerOptions{Level: cfg.LogLevel}))

	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", fmt.Sprintf(":%d", cfg.Port))
	if err != nil {
		return err
	}
	return serve(ctx, cfg, log, ln)
}

// serve runs the server until ctx is cancelled, then shuts down gracefully:
// readiness fails at once, the server keeps serving for DrainDelay so the
// load balancer stops sending new traffic, then in-flight requests get up to
// ShutdownLimit to finish.
func serve(ctx context.Context, cfg Config, log *slog.Logger, ln net.Listener) error {
	s := NewServer(cfg, log, commit)
	srv := &http.Server{
		Handler:           s.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      125 * time.Second, // above FAULT_LATENCY_MS + PAYMENTS_LATENCY_MS at their 60s maximums
		IdleTimeout:       60 * time.Second,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}

	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	log.Info("starting",
		"addr", ln.Addr().String(), "version", cfg.Version, "commit", commit,
		"payments_latency_ms", cfg.PaymentsLatency.Milliseconds(),
		"payments_error_rate", cfg.PaymentsErrorRate,
		"fault_error_rate", cfg.FaultErrorRate,
		"fault_latency_ms", cfg.FaultLatency.Milliseconds())

	warm := time.NewTimer(cfg.WarmUp)
	defer warm.Stop()
	for {
		select {
		case err := <-errc:
			return err
		case <-warm.C:
			s.SetReady(true)
			log.Info("ready")
			continue
		case <-ctx.Done():
		}
		break
	}

	s.SetReady(false)
	log.Info("shutting down: readiness now failing, draining", "drain_delay_s", cfg.DrainDelay.Seconds())
	select {
	case <-time.After(cfg.DrainDelay):
	case err := <-errc:
		return err
	}

	sctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownLimit)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		log.Error("shutdown did not finish in time", "error", err)
		return err
	}
	if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	log.Info("stopped")
	return nil
}
