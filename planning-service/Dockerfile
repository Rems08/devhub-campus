# syntax=docker/dockerfile:1.7
# Multi-stage build pour planning-service (Python FastAPI).

# ---- Stage 1 : install des dépendances dans un virtualenv ----
FROM python:3.12-slim AS build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build

# venv isolé qu'on copiera dans le stage runtime — pas de pip dans l'image finale
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# ---- Stage 2 : image runtime minimale ----
FROM python:3.12-slim AS runtime

LABEL org.opencontainers.image.source="https://github.com/Rems08/devhub-campus" \
      org.opencontainers.image.title="planning-service" \
      org.opencontainers.image.description="Planning DevHub Campus" \
      org.opencontainers.image.licenses="UNLICENSED"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8080 \
    LOG_LEVEL=info

RUN groupadd --system --gid 1001 app && useradd --system --uid 1001 --gid 1001 app

COPY --from=build --chown=app:app /opt/venv /opt/venv

WORKDIR /app
COPY --chown=app:app app ./app

USER 1001

EXPOSE 8080

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
