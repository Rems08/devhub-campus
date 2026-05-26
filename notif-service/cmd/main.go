// notif-service — émet des événements vers Slack / email / push (mocké en TP).
package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type event struct {
	Channel string `json:"channel"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
}

var events = []event{
	{Channel: "#students", Subject: "Bienvenue M2 IW", Body: "Le portail DevHub est ouvert."},
	{Channel: "#staff", Subject: "Rappel cours", Body: "Clusterisation 13h30, salle A4."},
}

func main() {
	port := envOrDefault("PORT", "8080")
	logLevel := strings.ToLower(envOrDefault("LOG_LEVEL", "info"))

	var lvl slog.Level
	switch logLevel {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
	slog.SetDefault(logger)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "notif"})
	})
	mux.HandleFunc("/events", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, events)
	})

	if _, err := strconv.Atoi(port); err != nil {
		slog.Error("invalid PORT", "value", port)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		slog.Info("notif up", "port", port)
		slog.Debug("config", "LOG_LEVEL", logLevel)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	slog.Info("shutting down")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
}

func envOrDefault(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
