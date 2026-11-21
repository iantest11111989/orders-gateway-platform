package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testConfig() Config {
	c := DefaultConfig()
	c.PaymentsLatency = 0
	c.Version = "test"
	c.WarmUp = 0
	c.DrainDelay = 0
	c.ShutdownLimit = 2 * time.Second
	return c
}

func newTestServer(t *testing.T, cfg Config) (*Server, *bytes.Buffer) {
	t.Helper()
	var logs bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	s := NewServer(cfg, log, "abc123")
	s.SetReady(true)
	return s, &logs
}

func do(s *Server, method, path, body string, hdr ...string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

const goodOrder = `{"customer_id":"cust-42","items":[{"sku":"SKU-MUG-2","quantity":2},{"sku":"SKU-PEN-5","quantity":1}]}`

func TestCreateOrder(t *testing.T) {
	s, logs := newTestServer(t, testConfig())
	rec := do(s, "POST", "/orders", goodOrder)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body)
	}
	var o Order
	if err := json.Unmarshal(rec.Body.Bytes(), &o); err != nil {
		t.Fatal(err)
	}
	if !orderIDPattern.MatchString(o.OrderID) || o.CustomerID != "cust-42" || o.TotalItems != 3 || o.Status != "created" {
		t.Errorf("unexpected order %+v", o)
	}
	if got := rec.Header().Get("Location"); got != "/orders/"+o.OrderID {
		t.Errorf("Location = %q", got)
	}
	line := lastLog(t, logs)
	if line["level"] != "INFO" || line["route"] != "/orders" || line["order_id"] != o.OrderID || line["version"] != "test" {
		t.Errorf("log line %v", line)
	}
}

func TestCreateOrderValidation(t *testing.T) {
	many := `{"customer_id":"c","items":[` + strings.Repeat(`{"sku":"A","quantity":1},`, maxItems) + `{"sku":"A","quantity":1}]}`
	cases := []struct {
		name, body, reason string
	}{
		{"not json", `nope`, reasonInvalidJSON},
		{"two objects", goodOrder + goodOrder, reasonInvalidJSON},
		{"unknown field", `{"customer_id":"c","items":[{"sku":"A","quantity":1}],"card_number":"4111"}`, reasonInvalidJSON},
		{"missing customer", `{"items":[{"sku":"A","quantity":1}]}`, reasonInvalidCustomer},
		{"bad customer", `{"customer_id":"a b","items":[{"sku":"A","quantity":1}]}`, reasonInvalidCustomer},
		{"no items", `{"customer_id":"c","items":[]}`, reasonNoItems},
		{"too many items", many, reasonTooManyItems},
		{"lowercase sku", `{"customer_id":"c","items":[{"sku":"abc","quantity":1}]}`, reasonInvalidSKU},
		{"zero quantity", `{"customer_id":"c","items":[{"sku":"A","quantity":0}]}`, reasonInvalidQuantity},
		{"huge quantity", `{"customer_id":"c","items":[{"sku":"A","quantity":101}]}`, reasonInvalidQuantity},
		{"too large", `{"customer_id":"` + strings.Repeat("x", maxBodyBytes) + `"}`, reasonBodyTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, logs := newTestServer(t, testConfig())
			rec := do(s, "POST", "/orders", tc.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, body %s", rec.Code, rec.Body)
			}
			var resp map[string]string
			_ = json.Unmarshal(rec.Body.Bytes(), &resp)
			if resp["reason"] != tc.reason {
				t.Errorf("reason = %q, want %q", resp["reason"], tc.reason)
			}
			if lvl := lastLog(t, logs)["level"]; lvl != "WARN" {
				t.Errorf("log level = %v, want WARN", lvl)
			}
			if !strings.Contains(scrape(t, s), `orders_rejected_total{reason="`+tc.reason+`"} 1`) {
				t.Errorf("rejection not counted")
			}
		})
	}
}

func TestPaymentsFailure(t *testing.T) {
	cfg := testConfig()
	cfg.PaymentsErrorRate = 1
	s, logs := newTestServer(t, cfg)
	rec := do(s, "POST", "/orders", goodOrder)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d", rec.Code)
	}
	if lvl := lastLog(t, logs)["level"]; lvl != "ERROR" {
		t.Errorf("log level = %v, want ERROR", lvl)
	}
	m := scrape(t, s)
	for _, want := range []string{"payments_call_errors_total 1", "orders_created_total 0"} {
		if !strings.Contains(m, want) {
			t.Errorf("metrics missing %q", want)
		}
	}
}

func TestFaultInjection(t *testing.T) {
	cfg := testConfig()
	cfg.FaultErrorRate = 1
	s, _ := newTestServer(t, cfg)
	if rec := do(s, "POST", "/orders", goodOrder); rec.Code != http.StatusInternalServerError {
		t.Errorf("POST /orders status = %d, want 500", rec.Code)
	}
	if rec := do(s, "GET", "/orders/ord_0123456789abcdef", ""); rec.Code != http.StatusInternalServerError {
		t.Errorf("GET /orders/{id} status = %d, want 500", rec.Code)
	}
	// Probes and metrics must not be affected by fault injection.
	for _, p := range []string{"/healthz", "/readyz", "/metrics"} {
		if rec := do(s, "GET", p, ""); rec.Code != http.StatusOK {
			t.Errorf("%s status = %d, want 200", p, rec.Code)
		}
	}
}

func TestFaultLatency(t *testing.T) {
	cfg := testConfig()
	cfg.FaultLatency = 50 * time.Millisecond
	s, _ := newTestServer(t, cfg)
	start := time.Now()
	do(s, "GET", "/orders/ord_0123456789abcdef", "")
	if d := time.Since(start); d < 50*time.Millisecond {
		t.Errorf("request took %v, want at least 50ms", d)
	}
}

func TestGetOrder(t *testing.T) {
	s, _ := newTestServer(t, testConfig())
	id := "ord_0123456789abcdef"
	a := do(s, "GET", "/orders/"+id, "")
	b := do(s, "GET", "/orders/"+id, "")
	if a.Code != http.StatusOK {
		t.Fatalf("status = %d", a.Code)
	}
	if a.Body.String() != b.Body.String() {
		t.Errorf("same ID gave different orders:\n%s\n%s", a.Body, b.Body)
	}
	var o Order
	_ = json.Unmarshal(a.Body.Bytes(), &o)
	if o.OrderID != id || len(o.Items) == 0 || o.TotalItems == 0 {
		t.Errorf("unexpected order %+v", o)
	}
	other := do(s, "GET", "/orders/ord_fedcba9876543210", "")
	if other.Body.String() == a.Body.String() {
		t.Errorf("different IDs gave the same order")
	}
}

func TestGetOrderMalformed(t *testing.T) {
	s, _ := newTestServer(t, testConfig())
	for _, id := range []string{"123", "ord_XYZ", "ord_0123456789abcdef0", "ORD_0123456789abcdef"} {
		if rec := do(s, "GET", "/orders/"+id, ""); rec.Code != http.StatusNotFound {
			t.Errorf("%s: status = %d, want 404", id, rec.Code)
		}
	}
}

func TestRequestID(t *testing.T) {
	s, logs := newTestServer(t, testConfig())
	rec := do(s, "GET", "/healthz", "", "X-Request-ID", "abc-123")
	if got := rec.Header().Get("X-Request-ID"); got != "abc-123" {
		t.Errorf("echoed request ID = %q", got)
	}
	if got := lastLog(t, logs)["request_id"]; got != "abc-123" {
		t.Errorf("logged request ID = %v", got)
	}
	// A missing or unsafe ID is replaced with a generated one.
	for _, in := range []string{"", "has space", strings.Repeat("a", 200), "x\ny"} {
		rec := do(s, "GET", "/healthz", "", "X-Request-ID", in)
		got := rec.Header().Get("X-Request-ID")
		if got == "" || got == in || !requestIDPattern.MatchString(got) {
			t.Errorf("input %q: got request ID %q", in, got)
		}
	}
}

func TestReadiness(t *testing.T) {
	s, _ := newTestServer(t, testConfig())
	s.SetReady(false)
	if rec := do(s, "GET", "/readyz", ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("not ready: status = %d", rec.Code)
	}
	if rec := do(s, "GET", "/healthz", ""); rec.Code != http.StatusOK {
		t.Errorf("liveness should pass while not ready: %d", rec.Code)
	}
	s.SetReady(true)
	if rec := do(s, "GET", "/readyz", ""); rec.Code != http.StatusOK {
		t.Errorf("ready: status = %d", rec.Code)
	}
}

func TestMetricsUseRouteTemplates(t *testing.T) {
	s, _ := newTestServer(t, testConfig())
	do(s, "GET", "/orders/ord_0123456789abcdef", "")
	do(s, "GET", "/orders/ord_aaaaaaaaaaaaaaaa", "")
	do(s, "GET", "/no/such/path", "")
	do(s, "BREW", "/orders", "")
	m := scrape(t, s)
	for _, want := range []string{
		`http_requests_total{code="200",method="GET",route="/orders/{id}"} 2`,
		`http_requests_total{code="404",method="other",route="unmatched"} 1`,
		`http_request_duration_seconds_bucket{method="GET",route="/orders/{id}",le="0.3"} 2`,
		`app_build_info{commit="abc123",version="test"} 1`,
		`http_requests_in_flight 1`, // the scrape itself
		`go_goroutines`,
		`payments_call_duration_seconds_bucket`,
	} {
		if !strings.Contains(m, want) {
			t.Errorf("metrics missing %q", want)
		}
	}
	for _, bad := range []string{"ord_0123456789abcdef", "/no/such/path", "BREW"} {
		if strings.Contains(m, bad) {
			t.Errorf("metrics leak raw value %q", bad)
		}
	}
}

func TestPanicRecovery(t *testing.T) {
	s, logs := newTestServer(t, testConfig())
	h := s.observe(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("boom") }))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Errorf("status = %d", rec.Code)
	}
	if !strings.Contains(logs.String(), `"panic":"boom"`) {
		t.Errorf("panic not logged")
	}
}

func TestLoadConfig(t *testing.T) {
	env := map[string]string{
		"PORT": "9090", "LOG_LEVEL": "DEBUG", "PAYMENTS_LATENCY_MS": "120",
		"PAYMENTS_ERROR_RATE": "0.05", "FAULT_ERROR_RATE": "0.5", "FAULT_LATENCY_MS": "300",
		"APP_VERSION": "v2",
	}
	c, err := LoadConfig(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	if c.Port != 9090 || c.LogLevel != slog.LevelDebug || c.PaymentsLatency != 120*time.Millisecond ||
		c.PaymentsErrorRate != 0.05 || c.FaultErrorRate != 0.5 || c.FaultLatency != 300*time.Millisecond || c.Version != "v2" {
		t.Errorf("unexpected config %+v", c)
	}

	bad := map[string]string{"PORT": "0", "LOG_LEVEL": "loud", "PAYMENTS_ERROR_RATE": "2", "FAULT_LATENCY_MS": "-1"}
	_, err = LoadConfig(func(k string) string { return bad[k] })
	if err == nil {
		t.Fatal("expected an error")
	}
	for k := range bad {
		if !strings.Contains(err.Error(), k) {
			t.Errorf("error does not mention %s: %v", k, err)
		}
	}
}

// TestGracefulShutdown checks the SIGTERM sequence: readiness fails at once,
// the server keeps answering during the drain delay, and an in-flight request
// completes before serve returns.
func TestGracefulShutdown(t *testing.T) {
	cfg := testConfig()
	cfg.DrainDelay = 300 * time.Millisecond
	cfg.FaultLatency = 500 * time.Millisecond // a slow in-flight request
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	base := "http://" + ln.Addr().String()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serve(ctx, cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), ln) }()

	waitFor(t, func() bool { return status(base+"/readyz") == 200 })

	slow := make(chan int, 1)
	go func() { slow <- status(base + "/orders/ord_0123456789abcdef") }()
	time.Sleep(50 * time.Millisecond)
	cancel() // like SIGTERM

	waitFor(t, func() bool { return status(base+"/readyz") == 503 })
	if c := status(base + "/healthz"); c != 200 {
		t.Errorf("healthz during drain = %d, want 200", c)
	}
	if c := <-slow; c != 200 {
		t.Errorf("in-flight request = %d, want 200", c)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("serve returned %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("serve did not return")
	}
}

func TestWarmUp(t *testing.T) {
	cfg := testConfig()
	cfg.WarmUp = 300 * time.Millisecond
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	base := "http://" + ln.Addr().String()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = serve(ctx, cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), ln) }()

	waitFor(t, func() bool { return status(base+"/healthz") == 200 })
	if c := status(base + "/readyz"); c != 503 {
		t.Errorf("readyz during warm-up = %d, want 503", c)
	}
	waitFor(t, func() bool { return status(base+"/readyz") == 200 })
}

// ---- helpers ----

func status(url string) int {
	resp, err := http.Get(url) //nolint:gosec // test helper against a local server
	if err != nil {
		return 0
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met in time")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func scrape(t *testing.T, s *Server) string {
	t.Helper()
	return do(s, "GET", "/metrics", "").Body.String()
}

func lastLog(t *testing.T, logs *bytes.Buffer) map[string]any {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	var m map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &m); err != nil {
		t.Fatalf("last log line is not JSON: %q", lines[len(lines)-1])
	}
	return m
}

// A client that disconnects or times out is recorded as 499: not a success,
// not a server error, and not a payments failure.
func TestClientDisconnect(t *testing.T) {
	cases := map[string]func(*Config){
		"during payments call": func(c *Config) { c.PaymentsLatency = time.Second },
		"during fault latency": func(c *Config) { c.FaultLatency = time.Second },
	}
	for name, tweak := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := testConfig()
			tweak(&cfg)
			s, logs := newTestServer(t, cfg)
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
			defer cancel()
			req := httptest.NewRequest("POST", "/orders", strings.NewReader(goodOrder)).WithContext(ctx)
			s.Handler().ServeHTTP(httptest.NewRecorder(), req)

			line := lastLog(t, logs)
			if line["level"] != "WARN" || line["status"] != float64(499) {
				t.Errorf("log line %v, want WARN status 499", line)
			}

			m := scrape(t, s)
			for _, want := range []string{
				`http_requests_total{code="499",method="POST",route="/orders"} 1`,
				"payments_call_errors_total 0",
				"orders_created_total 0",
			} {
				if !strings.Contains(m, want) {
					t.Errorf("metrics missing %q", want)
				}
			}
			for _, bad := range []string{`code="502"`, `code="200",method="POST"`} {
				if strings.Contains(m, bad) {
					t.Errorf("metrics contain %s", bad)
				}
			}
		})
	}
}
