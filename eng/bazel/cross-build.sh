#!/usr/bin/env bash
# Cross-build and prepare Helix payloads for linux-arm64.
#
# This script:
#   1. Starts a cross-build container with the arm64 toolchain
#   2. Builds all targets for arm64 inside the container
#   3. Runs library tests (which produce helix manifests instead of executing)
#   4. Collects manifests and packages Helix payloads
#
# Usage:
#   eng/bazel/cross-build.sh [--image IMAGE] [--disk-cache DIR] [--bazel-config FLAGS]
#
# Output:
#   artifacts/helix/testhost/   — shared testhost (Helix correlation payload)
#   artifacts/helix/tests/NAME/ — per-test work items
#
# The script is designed to work both in CI and locally.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# ---------- Parse arguments ----------
CROSS_IMAGE="mcr.microsoft.com/dotnet-buildtools/prereqs:azurelinux-3.0-net11.0-cross-arm64"
DISK_CACHE=""
BAZEL_CONFIG="--config=clr_release --config=libs_release"
PLATFORMS="//platforms:linux_arm64"
CONTAINER_NAME="arm64-cross-ci"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) CROSS_IMAGE="$2"; shift 2 ;;
        --disk-cache) DISK_CACHE="$2"; shift 2 ;;
        --bazel-config) BAZEL_CONFIG="$2"; shift 2 ;;
        --platforms) PLATFORMS="$2"; shift 2 ;;
        --container) CONTAINER_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------- Step 1: Start container ----------
echo "==> Starting cross-build container ($CROSS_IMAGE)..."

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

DOCKER_ARGS=(
    -d --name "$CONTAINER_NAME"
    -v "$REPO_ROOT:/repo"
)

# Mount bazelisk/bazel binary into the container
BAZEL_BIN="$(which bazelisk 2>/dev/null || which bazel 2>/dev/null || true)"
if [[ -n "$BAZEL_BIN" ]]; then
    DOCKER_ARGS+=(-v "$BAZEL_BIN:/usr/local/bin/bazel")
fi

# Mount disk cache if provided
if [[ -n "$DISK_CACHE" ]]; then
    mkdir -p "$DISK_CACHE"
    DOCKER_ARGS+=(-v "$DISK_CACHE:/disk-cache")
fi

docker run "${DOCKER_ARGS[@]}" "$CROSS_IMAGE" sleep infinity

# Create ICU symlink for Bazel's icu4c_repository rule.
# The container has ICU headers at /crossrootfs/arm64/usr/include/unicode
# but the repo rule looks at /usr/include/unicode.
docker exec "$CONTAINER_NAME" sh -c '
    mkdir -p /usr/include
    ln -sf /crossrootfs/arm64/usr/include/unicode /usr/include/unicode
'

# The container has LLVM tools but no GNU binutils — create symlinks
# so Bazel's auto-detected host CC toolchain can find ar/strip/etc.
docker exec "$CONTAINER_NAME" sh -c '
    for tool in ar nm strip ranlib objdump; do
        ln -sf /usr/local/bin/llvm-$tool /usr/local/bin/$tool 2>/dev/null || true
    done
'

# If no bazel binary was mounted, install bazelisk
if [[ -z "$BAZEL_BIN" ]]; then
    echo "   Installing bazelisk in container..."
    docker exec "$CONTAINER_NAME" sh -c '
        curl -fsSL https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-amd64 \
            -o /usr/local/bin/bazel && chmod +x /usr/local/bin/bazel
    '
fi

# Build the disk cache flag
CACHE_FLAG=""
if [[ -n "$DISK_CACHE" ]]; then
    CACHE_FLAG="--disk_cache=/disk-cache"
fi

# ---------- Step 2: Build ----------
echo "==> Building arm64 targets..."
docker exec "$CONTAINER_NAME" sh -c "
    export HOME=/tmp/bazel-home
    cd /repo
    bazel --nohome_rc build --keep_going \
        $BAZEL_CONFIG \
        --platforms=$PLATFORMS \
        $CACHE_FLAG \
        //src/...
"

# ---------- Step 3: Run tests (produces helix manifests) ----------
echo "==> Running library tests (helix manifest mode)..."
docker exec "$CONTAINER_NAME" sh -c "
    export HOME=/tmp/bazel-home
    cd /repo
    bazel --nohome_rc test --keep_going \
        $BAZEL_CONFIG \
        --platforms=$PLATFORMS \
        $CACHE_FLAG \
        --nozip_undeclared_test_outputs \
        //src/libraries/...
"

# ---------- Step 4: Collect manifests and package payloads ----------
echo "==> Collecting helix manifests and packaging payloads..."
docker exec "$CONTAINER_NAME" sh -c "
    export HOME=/tmp/bazel-home
    cd /repo
    eng/bazel/prepare-helix-payloads.sh
"

# Fix ownership — container runs as root
if [[ -d "$REPO_ROOT/artifacts/helix" ]]; then
    if command -v sudo &>/dev/null; then
        sudo chown -R "$(id -u):$(id -g)" "$REPO_ROOT/artifacts/helix"
    fi
fi

echo "==> Cross-build complete. Helix payloads at: artifacts/helix/"
