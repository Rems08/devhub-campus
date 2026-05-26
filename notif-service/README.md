# notif-service

Service Go — émission d'événements (Slack / email / push, mocké en TP).

## Endpoints

| Méthode | Path | Description |
|---|---|---|
| GET | `/healthz` | sonde de santé K8s |
| GET | `/events` | liste les événements émis |

## Variables d'environnement

| Variable | Défaut | Description |
|---|---|---|
| `PORT` | `8080` | port HTTP |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

## Lancer en local

```sh
LOG_LEVEL=debug go run ./cmd
curl http://localhost:8080/healthz
```

## Image

Distroless static, ≤ 20 Mo. Tag = SHA court du commit.
