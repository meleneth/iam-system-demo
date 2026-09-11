package internal

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

func TestIAMIngressParentageAndPayload(t *testing.T) {
	t.Setenv("IAM_TRACE_INGRESS_PHASES", "true")
	iamTracingOnce = sync.Once{}
	iamTracingOnce.Do(func() {}) // use the in-memory provider, no collector needed
	exporter := tracetest.NewInMemoryExporter()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSyncer(exporter))
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	var downstream trace.SpanContext
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		downstream = trace.SpanContextFromContext(otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header)))
		body, _ := io.ReadAll(r.Body)
		if r.Header.Get("pad-user-id") != "real-actor" || string(body) != "original body" {
			t.Error("actor or body changed")
		}
		w.WriteHeader(201)
		_, _ = w.Write([]byte("response body"))
	}))
	defer upstream.Close()
	target, _ := url.Parse(upstream.URL)
	handler := iamTraceHandler(NewProxyHandler(target, "", false))
	request := httptest.NewRequest("POST", "http://example.test/", strings.NewReader("original body"))
	request.Header.Set("pad-user-id", "real-actor")
	request.Header.Set("traceparent", "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != 201 || response.Body.String() != "response body" {
		t.Fatal("response changed")
	}
	spans := exporter.GetSpans()
	if len(spans) != 2 {
		t.Fatalf("expected ingress and upstream spans, got %d", len(spans))
	}
	var ingress, client tracetest.SpanStub
	for _, span := range spans {
		if span.Name == "thruster.ingress" {
			ingress = span
		}
		if span.Name == "thruster.upstream" {
			client = span
		}
	}
	if ingress.Parent.SpanID().String() != "bbbbbbbbbbbbbbbb" || client.Parent.SpanID() != ingress.SpanContext.SpanID() || downstream.SpanID() != client.SpanContext.SpanID() {
		t.Fatal("trace parentage broken")
	}
	for _, name := range []string{"thruster.upstream.connection.acquired", "thruster.upstream.request.written", "thruster.upstream.response.first_byte"} {
		found := false
		for _, event := range client.Events {
			if event.Name == name {
				found = true
			}
		}
		if !found {
			t.Errorf("missing %s", name)
		}
	}
	if client.EndTime.After(ingress.EndTime) {
		t.Error("upstream body outlived ingress")
	}

	// Parent sampling is honored and an unsampled request still propagates.
	exporter.Reset()
	request = httptest.NewRequest("POST", "http://example.test/", strings.NewReader("original body"))
	request.Header.Set("pad-user-id", "real-actor")
	request.Header.Set("traceparent", "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00")
	handler.ServeHTTP(httptest.NewRecorder(), request)
	if len(exporter.GetSpans()) != 0 || downstream.IsSampled() {
		t.Fatal("unsampled parent ignored")
	}
}

func TestIAMDisabledIngress(t *testing.T) {
	t.Setenv("IAM_TRACE_INGRESS_PHASES", "false")
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("traceparent") != "unchanged" {
			t.Error("disabled tracing changed headers")
		}
		w.WriteHeader(204)
	})
	request := httptest.NewRequest("GET", "/", nil)
	request.Header.Set("traceparent", "unchanged")
	response := httptest.NewRecorder()
	iamTraceHandler(handler).ServeHTTP(response, request)
	if response.Code != 204 {
		t.Fatal("disabled tracing changed response")
	}
}
