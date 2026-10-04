#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != x86_64 ]]; then
  echo 'This setup requires an Intel macOS runner with nested virtualization.' >&2
  exit 1
fi

: "${RUNNER_TEMP:?}"
: "${GITHUB_PATH:?}"
: "${GITHUB_ENV:?}"
tools="$RUNNER_TEMP/ios-docker-tools"
mkdir -p "$tools/bin" "$tools/downloads"

# Homebrew no longer bottles Docker for Intel macOS; avoid compiling Go/Docker
# and installing Compose/Buildx, neither of which this Testcontainers harness uses.
download() {
  local url="$1" file="$2" checksum="$3"
  if [[ -f "$tools/downloads/$file" ]] && echo "$checksum  $tools/downloads/$file" | shasum -a 256 --check; then
    return
  fi
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 120 \
    "$url" -o "$tools/downloads/$file"
  echo "$checksum  $tools/downloads/$file" | shasum -a 256 --check
}

download 'https://github.com/lima-vm/lima/releases/download/v1.2.1/lima-1.2.1-Darwin-x86_64.tar.gz' \
  lima.tar.gz f6ba629f70fe245e74dbba670bfaf88aaa58f5785d9365ce826d6662449a02e7
download 'https://github.com/abiosoft/colima/releases/download/v0.9.1/colima-Darwin-x86_64' \
  colima d90efd431713d4db57a2083fbf4154c57c63d7e5a2292170c8eaa89fb2e3efed
download 'https://download.docker.com/mac/static/stable/x86_64/docker-28.3.3.tgz' \
  docker.tgz e1d2a1a46ecdb4942bc12e1a6759bca3f2b2f1cfc1a5f3f921719b4d52fd3076

tar -xzf "$tools/downloads/lima.tar.gz" -C "$tools"
tar -xzf "$tools/downloads/docker.tgz" -C "$tools/downloads"
install -m 755 "$tools/downloads/colima" "$tools/bin/colima"
install -m 755 "$tools/downloads/docker/docker" "$tools/bin/docker"
export PATH="$tools/bin:$PATH"
echo "$tools/bin" >> "$GITHUB_PATH"

# Leave host headroom for Xcode/Simulator. The previous 14-GiB guest used <1 GiB
# at readiness; 4 GiB keeps margin without offering it the host's entire RAM.
colima start --cpu 2 --memory 4 --arch x86_64 --vm-type=vz --mount-type=virtiofs
docker_host="$(docker context inspect colima --format '{{.Endpoints.docker.Host}}')"
docker --host "$docker_host" info
echo "DOCKER_HOST=$docker_host" >> "$GITHUB_ENV"
echo 'TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock' >> "$GITHUB_ENV"
