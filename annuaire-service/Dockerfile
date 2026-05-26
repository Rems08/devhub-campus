# syntax=docker/dockerfile:1.7
# Multi-stage build pour annuaire-service.
# Contraintes (polycopié) : multi-stage, ≤ 200 Mo, USER non-root, pas de secret,
# LABEL org.opencontainers.image.source, /healthz, LOG_LEVEL.

# ---- Stage 1 : install des dépendances de prod uniquement ----
FROM node:20.18-alpine AS build

WORKDIR /app

# package*.json d'abord pour bénéficier du cache Docker
COPY package.json ./
COPY package-lock.json* ./

# `npm ci` aurait été préférable mais nécessite un lockfile.
# Pour le TP : install reproductible via `npm install --omit=dev` + flag --no-audit pour la vitesse.
RUN npm install --omit=dev --no-audit --no-fund \
    && npm cache clean --force

COPY src ./src

# ---- Stage 2 : image runtime minimale ----
FROM node:20.18-alpine AS runtime

# OCI labels — traçabilité dans GHCR + outils SBOM
LABEL org.opencontainers.image.source="https://github.com/Rems08/devhub-campus" \
      org.opencontainers.image.title="annuaire-service" \
      org.opencontainers.image.description="Annuaire DevHub Campus" \
      org.opencontainers.image.licenses="UNLICENSED"

# Création d'un user non-root dédié
RUN addgroup -g 1001 -S app && adduser -u 1001 -S app -G app

WORKDIR /app
COPY --from=build --chown=app:app /app/node_modules ./node_modules
COPY --from=build --chown=app:app /app/src ./src
COPY --chown=app:app package.json ./

USER 1001

ENV NODE_ENV=production \
    PORT=8080 \
    LOG_LEVEL=info

EXPOSE 8080

# K8s pilote la health via readiness/liveness probes — HEALTHCHECK Docker non utilisé
CMD ["node", "src/index.js"]
