#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${GITHUB_OUTPUT:?}"
directory="$RUNNER_TEMP/ios-docker-images"
archive="$directory/images.tar.gz"
mkdir -p "$directory"
started=$SECONDS

# Keep the reaper version explicit so the archive matches the image Testcontainers uses.
ryuk='testcontainers/ryuk:0.14.0'
echo "RYUK_CONTAINER_IMAGE=$ryuk" >> "$GITHUB_ENV"
images=('postgres:14' "${E2E_CORE_IMAGE:-supertokens/supertokens-postgresql:12.0.10}" "$ryuk")
if [[ -f "$archive" ]]; then
  if gzip -dc "$archive" | docker load; then
    for image in "${images[@]}"; do
      docker image inspect "$image" > /dev/null 2>&1 || docker pull "$image"
    done
    echo "Docker image cache loaded in $((SECONDS - started))s ($(du -h "$archive" | cut -f1))"
    exit 0
  fi
  rm -f "$archive"
fi

for image in "${images[@]}"; do docker pull "$image"; done
pulled=$SECONDS
# Docker save/load does not preserve registry digest references. Digest-selected
# Core images are pulled separately; still cache Postgres and the reaper.
if [[ "${images[1]}" == *@* ]]; then
  cache_images=("${images[0]}" "$ryuk")
else
  cache_images=("${images[@]}")
fi
docker save "${cache_images[@]}" | gzip -1 > "$archive.tmp"
size_kb=$(du -k "$archive.tmp" | cut -f1)
echo "Docker images: pull $((pulled - started))s; archive $((SECONDS - pulled))s; $size_kb KiB"
# A miss pays compression once; hits only load. Never archive VM disks or containers.
if (( size_kb <= 768000 )); then
  mv "$archive.tmp" "$archive"
  echo 'save=true' >> "$GITHUB_OUTPUT"
else
  rm -f "$archive.tmp"
  echo 'Skipping image cache upload: exceeds 750 MiB budget'
fi
