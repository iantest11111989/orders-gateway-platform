package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	mrand "math/rand/v2"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Server wires the handlers, middleware, metrics and readiness state.
type Server struct {
	cfg     Config
	log     *slog.Logger
	metrics *Metrics
	ready   atomic.Bool
	rand    func() float64 // injectable for tests
	handler http.Handler
}

func NewServer(cfg Config, log *slog.Logger, commit string) *Server {
	s := &Server{
		cfg:     cfg,
		log:     log,
		metrics: NewMetrics(cfg.Version, commit),
		rand:    mrand.Float64,
	}

	mux := http.NewServeMux()
	// Business routes go through fault injection; probes and metrics never do,
	// so FAULT_* demos break the API without making Kubernetes kill the pods.
	mux.Handle("POST /orders", s.faults(http.HandlerFunc(s.handleCreateOrder)))
	mux.Handle("GET /orders/{id}", s.faults(http.HandlerFunc(s.handleGetOrder)))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !s.ready.Load() {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.metrics.Registry, promhttp.HandlerOpts{
		Registry: s.metrics.Registry,
	}))

	s.handler = s.observe(mux)
	return s
}

func (s *Server) Handler() http.Handler { return s.handler }
func (s *Server) SetReady(v bool)       { s.ready.Store(v) }

// statusClientClosed is the de facto code (nginx, Envoy) for a request the
// client abandoned before a response was written.
const statusClientClosed = 499

// faults injects FAULT_LATENCY_MS and FAULT_ERROR_RATE for demos.
func (s *Server) faults(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if d := s.cfg.FaultLatency; d > 0 {
			t := time.NewTimer(d)
			select {
			case <-t.C:
			case <-r.Context().Done():
				t.Stop()
				return // observe records 499
			}
		}
		if s.cfg.FaultErrorRate > 0 && s.rand() < s.cfg.FaultErrorRate {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "injected fault"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- request context ----

type ctxKey struct{}

type reqInfo struct {
	requestID string
	orderID   string
}

func setOrderID(ctx context.Context, id string) {
	if ri, ok := ctx.Value(ctxKey{}).(*reqInfo); ok {
		ri.orderID = id
	}
}

// Incoming X-Request-ID values are only trusted if they look like an ID, so
// clients cannot inject arbitrary text into logs.
var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)

func newRequestID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(b)
}

func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// routeOf returns the matched route template without the method, for example
// "/orders/{id}". Unmatched requests share one label value.
func routeOf(r *http.Request) string {
	p := r.Pattern
	if p == "" {
		return "unmatched"
	}
	if i := strings.IndexByte(p, ' '); i >= 0 {
		p = p[i+1:]
	}
	return p
}

// observe handles request IDs, metrics, panic recovery and the one log line
// per request.
func (s *Server) observe(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rid := r.Header.Get("X-Request-ID")
		if !requestIDPattern.MatchString(rid) {
			rid = newRequestID()
		}
		w.Header().Set("X-Request-ID", rid)
		info := &reqInfo{requestID: rid}
		r = r.WithContext(context.WithValue(r.Context(), ctxKey{}, info))
		rec := &statusRecorder{ResponseWriter: w}

		s.metrics.InFlight.Inc()
		defer func() {
			s.metrics.InFlight.Dec()
			if p := recover(); p != nil {
				s.log.Error("panic", "panic", p, "request_id", rid)
				if rec.status == 0 {
					writeJSON(rec, http.StatusInternalServerError, map[string]string{"error": "internal error"})
				}
			}
			if rec.status == 0 {
				rec.status = http.StatusOK
				if r.Context().Err() != nil {
					// The handler gave up because the client disconnected
					// or timed out. Record nginx/Envoy's 499 so this counts
					// neither as a success nor as a server error.
					rec.status = statusClientClosed
				}
			}
			s.record(r, rec.status, time.Since(start), info)
		}()
		next.ServeHTTP(rec, r)
	})
}

func (s *Server) record(r *http.Request, status int, d time.Duration, info *reqInfo) {
	route := routeOf(r)
	method := r.Method
	if route == "unmatched" {
		method = "other" // keep arbitrary client methods out of label values
	}
	s.metrics.Requests.WithLabelValues(route, method, strconv.Itoa(status)).Inc()
	s.metrics.Duration.WithLabelValues(route, method).Observe(d.Seconds())

	level := slog.LevelInfo
	switch {
	case route == "/healthz" || route == "/readyz" || route == "/metrics":
		level = slog.LevelDebug // probes and scrapes would drown the useful lines
	case status >= 500:
		level = slog.LevelError
	case status >= 400:
		level = slog.LevelWarn
	}
	attrs := []slog.Attr{
		slog.String("method", r.Method),
		slog.String("route", route),
		slog.Int("status", status),
		slog.Float64("duration_ms", float64(d.Microseconds())/1000),
		slog.String("request_id", info.requestID),
		slog.String("version", s.cfg.Version),
	}
	if info.orderID != "" {
		attrs = append(attrs, slog.String("order_id", info.orderID))
	}
	s.log.LogAttrs(r.Context(), level, "request", attrs...)
}
