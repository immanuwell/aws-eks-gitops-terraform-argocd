package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type response struct {
	Status   string            `json:"status"`
	Hostname string            `json:"hostname"`
	Version  string            `json:"version"`
	Color    string            `json:"color"` // "blue" or "green" for blue-green demo
	Env      map[string]string `json:"env,omitempty"`
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	hostname, _ := os.Hostname()
	version := getEnv("APP_VERSION", "dev")
	color := getEnv("APP_COLOR", "blue")
	port := getEnv("PORT", "8080")

	mux := http.NewServeMux()

	// Root handler — returns app metadata as JSON
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		slog.Info("request received",
			"method", r.Method,
			"path", r.URL.Path,
			"remote_addr", r.RemoteAddr,
		)

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-App-Version", version)
		w.Header().Set("X-App-Color", color)

		json.NewEncoder(w).Encode(response{
			Status:   "ok",
			Hostname: hostname,
			Version:  version,
			Color:    color,
		})
	})

	// /health — liveness probe
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	})

	// /ready — readiness probe (could check downstream dependencies)
	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
	})

	// /metrics — placeholder (Prometheus client would go here in production)
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("# HELP demo_app_requests_total Total HTTP requests\n"))
		w.Write([]byte("# TYPE demo_app_requests_total counter\n"))
		w.Write([]byte("demo_app_requests_total 0\n"))
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Graceful shutdown
	done := make(chan os.Signal, 1)
	signal.Notify(done, os.Interrupt, syscall.SIGTERM)

	go func() {
		slog.Info("server starting", "port", port, "version", version, "color", color)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	<-done
	slog.Info("server shutting down...")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		slog.Error("shutdown error", "error", err)
		os.Exit(1)
	}

	slog.Info("server stopped")
}

func getEnv(key, defaultValue string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return defaultValue
}
