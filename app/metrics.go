package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics are registered on a private registry so tests can create as many
// servers as they like. Labels only ever carry route templates (for example
// "/orders/{id}"), never raw paths or IDs, to keep cardinality bounded.
type Metrics struct {
	Registry         *prometheus.Registry
	Requests         *prometheus.CounterVec
	Duration         *prometheus.HistogramVec
	InFlight         prometheus.Gauge
	PaymentsDuration prometheus.Histogram
	PaymentsErrors   prometheus.Counter
	OrdersCreated    prometheus.Counter
	OrdersRejected   *prometheus.CounterVec
}

// sloBuckets include exactly 0.3s, the latency SLO threshold, so the SLO can
// be computed from the histogram without interpolation.
var sloBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5, 10}

// Rejection reasons are a fixed set so orders_rejected_total stays bounded.
const (
	reasonInvalidJSON     = "invalid_json"
	reasonBodyTooLarge    = "body_too_large"
	reasonInvalidCustomer = "invalid_customer"
	reasonNoItems         = "no_items"
	reasonTooManyItems    = "too_many_items"
	reasonInvalidSKU      = "invalid_sku"
	reasonInvalidQuantity = "invalid_quantity"
)

var allReasons = []string{
	reasonInvalidJSON, reasonBodyTooLarge, reasonInvalidCustomer, reasonNoItems,
	reasonTooManyItems, reasonInvalidSKU, reasonInvalidQuantity,
}

func NewMetrics(version, commit string) *Metrics {
	reg := prometheus.NewRegistry()
	m := &Metrics{
		Registry: reg,
		Requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests handled, by route template, method and status code.",
		}, []string{"route", "method", "code"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds, by route template and method. Has a bucket at 0.3s, the SLO threshold.",
			Buckets: sloBuckets,
		}, []string{"route", "method"}),
		InFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "HTTP requests currently being served.",
		}),
		PaymentsDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "payments_call_duration_seconds",
			Help:    "Duration of the simulated downstream payments call.",
			Buckets: sloBuckets,
		}),
		PaymentsErrors: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "payments_call_errors_total",
			Help: "Simulated payments calls that failed.",
		}),
		OrdersCreated: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "orders_created_total",
			Help: "Orders created successfully.",
		}),
		OrdersRejected: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "orders_rejected_total",
			Help: "Orders rejected by validation, by reason.",
		}, []string{"reason"}),
	}
	buildInfo := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "app_build_info",
		Help: "Always 1. Labels carry the running version and git commit.",
	}, []string{"version", "commit"})
	buildInfo.WithLabelValues(version, commit).Set(1)

	reg.MustRegister(
		m.Requests, m.Duration, m.InFlight, m.PaymentsDuration, m.PaymentsErrors,
		m.OrdersCreated, m.OrdersRejected, buildInfo,
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	// Start every reason at zero so rate() works before the first rejection.
	for _, r := range allReasons {
		m.OrdersRejected.WithLabelValues(r)
	}
	return m
}
