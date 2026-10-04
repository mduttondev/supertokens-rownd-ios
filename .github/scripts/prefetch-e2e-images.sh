#!/usr/bin/env bash
set -euo pipefail

# Keep Core/Postgres aligned with test-server/server.ts and Ryuk with locked Testcontainers 11.14.0.
images=(
  "postgres:14"
  "${E2E_CORE_IMAGE:-supertokens/supertokens-postgresql:12.0.10}"
  "${RYUK_CONTAINER_IMAGE:-testcontainers/ryuk:0.14.0}"
)

# CI bounds this step to 15 minutes, before simulator boot and the backend startup timer.
# Sequential pulls avoid competing for the Intel runner's network and Docker VM resources.
for image in "${images[@]}"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    printf 'E2E image already available: %s\n' "$image"
  else
    docker pull "$image"
  fi
done
