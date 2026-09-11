package internal

// Added to the pinned Thruster source by instrument.rb. Keep the original
// cache/compression/sendfile and proxy behavior; instrument their boundaries.
import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptrace"
	"os"
	"strconv"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

var iamTracingOnce sync.Once
var iamTracingProvider *sdktrace.TracerProvider

func iamTracingEnabled() bool { return os.Getenv("IAM_TRACE_INGRESS_PHASES") != "false" }

func iamInitTracing() {
	iamTracingOnce.Do(func() {
		if !iamTracingEnabled() {
			return
		}
		options := []otlptracehttp.Option{}
		if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") == "" {
			options = append(options, otlptracehttp.WithEndpointURL("http://otel-collector:4318"))
		}
		exporter, err := otlptracehttp.New(context.Background(), options...)
		if err != nil {
			slog.Error("Initialize ingress tracing", "error", err)
			return
		}
		name := os.Getenv("OTEL_SERVICE_NAME")
		if name == "" {
			name = os.Getenv("IAM_RAILS_SERVICE_NAME")
		}
		host, _ := os.Hostname()
		iamTracingProvider = sdktrace.NewTracerProvider(
			sdktrace.WithBatcher(exporter),
			sdktrace.WithResource(resource.NewSchemaless(
				attribute.String("service.name", name+"-ingress"),
				attribute.String("service.instance.id", host+":"+strconv.Itoa(os.Getpid())),
				attribute.String("deployment.role", "ingress"),
				attribute.Int("process.pid", os.Getpid()),
			)),
		)
		otel.SetTracerProvider(iamTracingProvider)
		otel.SetTextMapPropagator(propagation.TraceContext{})
	})
}

func iamShutdownTracing() {
	if iamTracingProvider != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := iamTracingProvider.Shutdown(ctx); err != nil {
			slog.Warn("Flush ingress tracing", "error", err)
		}
	}
}

func iamTraceHandler(next http.Handler) http.Handler {
	iamInitTracing()
	if !iamTracingEnabled() {
		return next
	}
	return otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		span := trace.SpanFromContext(r.Context())
		span.AddEvent("thruster.handler.entry")
		defer span.AddEvent("thruster.handler.finish")
		next.ServeHTTP(w, r)
	}), "thruster.ingress")
}

func iamTraceTransport(next http.RoundTripper) http.RoundTripper {
	iamInitTracing()
	if !iamTracingEnabled() {
		return next
	}
	return otelhttp.NewTransport(next, otelhttp.WithSpanNameFormatter(func(_ string, _ *http.Request) string {
		return "thruster.upstream"
	}), otelhttp.WithClientTrace(func(ctx context.Context) *httptrace.ClientTrace {
		span := trace.SpanFromContext(ctx)
		event := func(name string) { span.AddEvent(name) }
		return &httptrace.ClientTrace{
			GetConn: func(_ string) { event("thruster.upstream.connection.acquire.begin") },
			GotConn: func(info httptrace.GotConnInfo) {
				span.AddEvent("thruster.upstream.connection.acquired", trace.WithAttributes(attribute.Bool("connection.reused", info.Reused)))
			},
			DNSStart:     func(httptrace.DNSStartInfo) { event("thruster.upstream.dns.begin") },
			DNSDone:      func(httptrace.DNSDoneInfo) { event("thruster.upstream.dns.finish") },
			ConnectStart: func(_, _ string) { event("thruster.upstream.connect.begin") },
			ConnectDone: func(_, _ string, err error) {
				span.AddEvent("thruster.upstream.connect.finish", trace.WithAttributes(attribute.Bool("error", err != nil)))
			},
			WroteHeaders: func() { event("thruster.upstream.request.headers.written") },
			WroteRequest: func(info httptrace.WroteRequestInfo) {
				span.AddEvent("thruster.upstream.request.written", trace.WithAttributes(attribute.Bool("error", info.Err != nil)))
			},
			GotFirstResponseByte: func() { event("thruster.upstream.response.first_byte") },
		}
	}))
}
