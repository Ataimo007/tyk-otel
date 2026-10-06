#!/usr/bin/env bash
# Builds the key-hash Go plugin (scenario/plugin) for the pinned gateway version and the
# Docker host's architecture, using Tyk's official plugin compiler.
#
# Output: scenario/plugin/otel_custom_hash_metrics_<GATEWAY_VERSION>_linux_<arch>.so
# The gateway loads it via the API definitions as ".../otel_custom_hash_metrics.so" and picks
# the build matching its own version and architecture automatically.
#
# Skips the build when that file already exists (prebuilt linux/arm64 and linux/amd64 copies are committed).
# Usage: scripts/build-plugin.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGIN_DIR=scenario/plugin
NAME=otel_custom_hash_metrics

# GATEWAY_VERSION is pinned in otel.env (an override in .env wins, as for docker compose)
version=$( (grep -hE '^GATEWAY_VERSION=' otel.env .env 2>/dev/null || true) | tail -1 | cut -d= -f2)
[[ -n "$version" ]] || { echo "ERROR: GATEWAY_VERSION not set in otel.env"; exit 1; }

case "$(docker info --format '{{.Architecture}}')" in
  aarch64|arm64) arch=arm64 ;;
  x86_64|amd64)  arch=amd64 ;;
  *) echo "ERROR: unsupported Docker architecture $(docker info --format '{{.Architecture}}')"; exit 1 ;;
esac

target="$PLUGIN_DIR/${NAME}_${version}_linux_${arch}.so"
if [[ -f "$target" && "${1:-}" != "--force" ]]; then
  echo "Plugin: using $target"
  exit 0
fi

echo "Plugin: building $target with tykio/tyk-plugin-compiler:$version"
echo "        (first build downloads the gateway's dependencies; under emulation this can take 10-20 minutes)"
mkdir -p logs
# The compiler image is published for linux/amd64; it cross-compiles for arm64 via GOARCH.
if ! docker run --rm --platform linux/amd64 \
      -v "$PWD/$PLUGIN_DIR":/plugin-source \
      -e GOARCH="$arch" \
      "tykio/tyk-plugin-compiler:$version" "$NAME.so" > logs/plugin-build.log 2>&1; then
  echo "ERROR: plugin build failed - see logs/plugin-build.log"
  tail -5 logs/plugin-build.log
  exit 1
fi
[[ -f "$target" ]] || { echo "ERROR: compiler finished but $target was not produced - see logs/plugin-build.log"; exit 1; }
echo "Plugin: built $target"
