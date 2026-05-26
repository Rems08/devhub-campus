# planning-service

Service Python FastAPI — emplois du temps, salles, créneaux.

## Endpoints

| Méthode | Path | Description |
|---|---|---|
| GET | `/healthz` | sonde de santé K8s |
| GET | `/slots` | liste tous les créneaux |
| GET | `/slots/:id` | détail d'un créneau |

## Variables d'environnement

| Variable | Défaut | Description |
|---|---|---|
| `PORT` | `8080` | port HTTP |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

## Lancer en local

```sh
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
LOG_LEVEL=debug uvicorn app.main:app --port 8080
```
