#!/usr/bin/env bash
# Rebuilds and restarts the API container from the current checkout, then waits
# for it to report healthy. Run from the repo root on the VPS. Invoked by the
# GitHub Actions deploy workflow (via the deploy key's forced command) after it
# has fast-forwarded ~/nafil-backend to origin/prod.
set -euo pipefail

cd "$(dirname "$0")"

echo "Deploying $(git rev-parse --short HEAD): $(git log -1 --format=%s)"
docker compose -f docker-compose.backend.yml up -d --build

for i in $(seq 1 30); do
  status=$(docker inspect --format '{{.State.Health.Status}}' nafil-api 2>/dev/null || echo missing)
  if [ "$status" = "healthy" ]; then
    echo "nafil-api is healthy"
    exit 0
  fi
  sleep 3
done

echo "nafil-api did not become healthy (status: $status)" >&2
docker logs --tail 40 nafil-api >&2 || true
exit 1
