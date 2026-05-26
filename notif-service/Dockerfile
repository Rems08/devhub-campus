# syntax=docker/dockerfile:1.7
# Multi-stage build pour notif-service (Go). Cible image ≤ 50 Mo.

# ---- Stage 1 : build statique ----
FROM golang:1.22-alpine AS build

WORKDIR /src

# Téléchargement modules en couche séparée pour bénéficier du cache
COPY go.mod ./
RUN go mod download

COPY cmd ./cmd

# Build statique, sans symboles debug, sans cgo — pour une image distroless
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -trimpath -ldflags="-s -w" -o /out/notif ./cmd

# ---- Stage 2 : image runtime ultra-minimaliste ----
FROM gcr.io/distroless/static-debian12:nonroot

LABEL org.opencontainers.image.source="https://github.com/Rems08/devhub-campus" \
      org.opencontainers.image.title="notif-service" \
      org.opencontainers.image.description="Notif DevHub Campus" \
      org.opencontainers.image.licenses="UNLICENSED"

COPY --from=build /out/notif /notif

ENV PORT=8080 \
    LOG_LEVEL=info

EXPOSE 8080

# distroless/static-debian12:nonroot lance par défaut en UID 65532
USER 65532:65532

ENTRYPOINT ["/notif"]
