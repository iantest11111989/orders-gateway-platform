package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	mrand "math/rand/v2"
	"net/http"
	"regexp"
	"time"
)

const (
	maxBodyBytes = 64 << 10
	maxItems     = 50
	maxQuantity  = 100
)

var (
	customerIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	skuPattern        = regexp.MustCompile(`^[A-Z0-9][A-Z0-9-]{0,31}$`)
	orderIDPattern    = regexp.MustCompile(`^ord_[0-9a-f]{16}$`)
)

type Item struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

type OrderRequest struct {
	CustomerID string `json:"customer_id"`
	Items      []Item `json:"items"`
}

type Order struct {
	OrderID    string    `json:"order_id"`
	CustomerID string    `json:"customer_id"`
	Items      []Item    `json:"items"`
	TotalItems int       `json:"total_items"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"created_at"`
	// EstimatedDelivery is set only when Config.DeliveryEstimates is on (v2).
	EstimatedDelivery *time.Time `json:"estimated_delivery,omitempty"`
}

// deliveryDays is how long after creation an order is estimated to arrive:
// 2 to 5 days, derived from the order ID so GET stays deterministic.
func deliveryDays(id string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(id))
	return 2 + int(h.Sum32()%4)
}

// withDeliveryEstimate fills EstimatedDelivery.
func withDeliveryEstimate(o Order) Order {
	t := o.CreatedAt.Add(time.Duration(deliveryDays(o.OrderID)) * 24 * time.Hour)
	o.EstimatedDelivery = &t
	return o
}

type validationError struct {
	reason string
	msg    string
}

func (e *validationError) Error() string { return e.msg }

// decodeOrder parses and validates a POST /orders body. Unknown fields are
// rejected, so clients cannot smuggle extra data (such as card numbers) into
// the service.
func decodeOrder(w http.ResponseWriter, r *http.Request) (OrderRequest, *validationError) {
	var req OrderRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return req, &validationError{reasonBodyTooLarge, "request body is too large"}
		}
		return req, &validationError{reasonInvalidJSON, "request body must be a JSON object with customer_id and items"}
	}
	if dec.Decode(&struct{}{}) != io.EOF {
		return req, &validationError{reasonInvalidJSON, "request body must contain a single JSON object"}
	}
	return req, validateOrder(req)
}

func validateOrder(req OrderRequest) *validationError {
	if !customerIDPattern.MatchString(req.CustomerID) {
		return &validationError{reasonInvalidCustomer, "customer_id must be 1-64 letters, digits, '-' or '_'"}
	}
	if len(req.Items) == 0 {
		return &validationError{reasonNoItems, "items must contain at least one item"}
	}
	if len(req.Items) > maxItems {
		return &validationError{reasonTooManyItems, fmt.Sprintf("items may contain at most %d items", maxItems)}
	}
	for i, it := range req.Items {
		if !skuPattern.MatchString(it.SKU) {
			return &validationError{reasonInvalidSKU, fmt.Sprintf("items[%d].sku must be 1-32 uppercase letters, digits or '-'", i)}
		}
		if it.Quantity < 1 || it.Quantity > maxQuantity {
			return &validationError{reasonInvalidQuantity, fmt.Sprintf("items[%d].quantity must be 1-%d", i, maxQuantity)}
		}
	}
	return nil
}

func newOrderID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b) // crypto/rand.Read never returns an error
	return "ord_" + hex.EncodeToString(b)
}

var errPaymentsFailed = errors.New("payments dependency failed")

// callPayments simulates a downstream payments call: it takes about
// PaymentsLatency (plus or minus 20%) and fails with PaymentsErrorRate.
func (s *Server) callPayments(ctx context.Context) error {
	start := time.Now()
	defer func() { s.metrics.PaymentsDuration.Observe(time.Since(start).Seconds()) }()

	if d := jitter(s.cfg.PaymentsLatency); d > 0 {
		t := time.NewTimer(d)
		defer t.Stop()
		select {
		case <-t.C:
		case <-ctx.Done():
			// The client went away; that is not a payments failure.
			return ctx.Err()
		}
	}
	if s.cfg.PaymentsErrorRate > 0 && s.rand() < s.cfg.PaymentsErrorRate {
		s.metrics.PaymentsErrors.Inc()
		return errPaymentsFailed
	}
	return nil
}

func jitter(d time.Duration) time.Duration {
	if d <= 0 {
		return 0
	}
	return time.Duration(float64(d) * (0.8 + 0.4*mrand.Float64())) //nolint:gosec // simulated latency jitter, not security
}

var (
	fakeSKUs     = []string{"SKU-BOOK-1", "SKU-MUG-2", "SKU-SHIRT-3", "SKU-LAMP-4", "SKU-PEN-5", "SKU-BAG-6"}
	fakeStatuses = []string{"created", "paid", "packed", "shipped", "delivered"}
	fakeEpoch    = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
)

// fakeOrder deterministically generates an order from its ID, so the same ID
// always returns the same order without any storage.
func fakeOrder(id string) Order {
	h := fnv.New64a()
	_, _ = h.Write([]byte(id))
	rng := mrand.New(mrand.NewPCG(h.Sum64(), 0x6f72646572)) //nolint:gosec // deterministic fake data, not security

	n := 1 + rng.IntN(3)
	items := make([]Item, n)
	total := 0
	for i := range items {
		items[i] = Item{SKU: fakeSKUs[rng.IntN(len(fakeSKUs))], Quantity: 1 + rng.IntN(5)}
		total += items[i].Quantity
	}
	return Order{
		OrderID:    id,
		CustomerID: fmt.Sprintf("cust-%04d", rng.IntN(10000)),
		Items:      items,
		TotalItems: total,
		Status:     fakeStatuses[rng.IntN(len(fakeStatuses))],
		CreatedAt:  fakeEpoch.Add(time.Duration(rng.IntN(300*24)) * time.Hour),
	}
}

func (s *Server) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	req, verr := decodeOrder(w, r)
	if verr != nil {
		s.metrics.OrdersRejected.WithLabelValues(verr.reason).Inc()
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": verr.msg, "reason": verr.reason})
		return
	}
	if err := s.callPayments(r.Context()); err != nil {
		if r.Context().Err() != nil {
			return // client gone: nothing to write, observe records 499
		}
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "payments service unavailable, try again"})
		return
	}
	total := 0
	for _, it := range req.Items {
		total += it.Quantity
	}
	order := Order{
		OrderID:    newOrderID(),
		CustomerID: req.CustomerID,
		Items:      req.Items,
		TotalItems: total,
		Status:     "created",
		CreatedAt:  time.Now().UTC(),
	}
	if s.cfg.DeliveryEstimates {
		order = withDeliveryEstimate(order)
	}
	setOrderID(r.Context(), order.OrderID)
	s.metrics.OrdersCreated.Inc()
	w.Header().Set("Location", "/orders/"+order.OrderID)
	writeJSON(w, http.StatusCreated, order)
}

func (s *Server) handleGetOrder(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !orderIDPattern.MatchString(id) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "order not found"})
		return
	}
	setOrderID(r.Context(), id)
	order := fakeOrder(id)
	if s.cfg.DeliveryEstimates {
		order = withDeliveryEstimate(order)
	}
	writeJSON(w, http.StatusOK, order)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
