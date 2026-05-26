# annuaire-service

Service Node.js — annuaire des étudiants. Expose un CRUD minimal.

## Endpoints

| Méthode | Path | Description |
|---|---|---|
| GET | `/healthz` | sonde de santé K8s |
| GET | `/students` | liste tous les étudiants |
| GET | `/students/:id` | détail d'un étudiant |

## Variables d'environnement

| Variable | Défaut | Description |
|---|---|---|
| `PORT` | `8080` | port HTTP |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

## Lancer en local (hors Docker)

```sh
npm install
LOG_LEVEL=debug node src/index.js
curl http://localhost:8080/healthz
```

## Build de l'image

```sh
docker build -t ghcr.io/rems08/annuaire:$(git rev-parse --short HEAD) .
docker run --rm -p 8080:8080 -e LOG_LEVEL=debug ghcr.io/rems08/annuaire:$(git rev-parse --short HEAD)
```

## Chart Helm

Voir `chart/`. Trois fichiers de values :

- `values.yaml` — defaults
- `values-dev.yaml` — environnement `devhub-dev`
- `values-preview.yaml` — environnements éphémères

```sh
helm lint chart/
helm template chart/ -f chart/values-dev.yaml
```
