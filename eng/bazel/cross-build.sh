#!/usr/bin/env bash
# Cross-build and test arm64 targets via Helix.
#
# This script runs inside an already-running cross-build container.
# The caller is responsible for pulling the image and starting the
# container with the repo mounted at /repo.
#
# Steps:
#   1. Builds all targets for arm64 inside the container
#   2. Uploads testhost to Helix blob storage (once)
#   3. Runs library tests — each test dispatches to Helix, polls, reports
#
# Bazel test caching works naturally: only tests whose inputs changed
# will re-run and dispatch to Helix.
#
# Usage:
#   # Start the container yourself:
#   docker run -d --name arm64-cross-ci -v "$PWD:/repo" \
#     mcr.microsoft.com/dotnet-buildtools/prereqs:azurelinux-3.0-net11.0-cross-arm64 \
#     sleep infinity
#
#   # Then run the script:
#   eng/bazel/cross-build.sh [OPTIONS]
#
# Options:
#   --container NAME       Container name (default: arm64-cross-ci)
#   --disk-cache DIR       Host-side Bazel disk cache (mounted into container as /disk-cache)
#   --bazel-config FLAGS   Bazel --config flags (default: --config=clr_release --config=libs_release)
#   --platforms LABEL      Bazel --platforms target
#   --send-to-helix        Enable Helix dispatch for tests (off by default)
#   --creator NAME         Helix Creator field (default: $USER)
#   --source SOURCE        Helix Source field
#   --build-only           Only build, skip tests
#
# The script is designed to work both in CI and locally.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# ---------- Parse arguments ----------
DISK_CACHE=""
BAZEL_CONFIG="--config=clr_release --config=libs_release"
PLATFORMS="//platforms:linux_arm64"
CONTAINER_NAME="arm64-cross-ci"
SEND_TO_HELIX=""
HELIX_CREATOR="${USER:-local}"
HELIX_SOURCE="pr/agocke/rbz/bazel/"
BUILD_ONLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk-cache) DISK_CACHE="$2"; shift 2 ;;
        --bazel-config) BAZEL_CONFIG="$2"; shift 2 ;;
        --platforms) PLATFORMS="$2"; shift 2 ;;
        --container) CONTAINER_NAME="$2"; shift 2 ;;
        --send-to-helix) SEND_TO_HELIX="1"; shift ;;
        --creator) HELIX_CREATOR="$2"; shift 2 ;;
        --source) HELIX_SOURCE="$2"; shift 2 ;;
        --build-only) BUILD_ONLY="1"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------- Verify container is running ----------
if ! docker inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "ERROR: Container '$CONTAINER_NAME' is not running." >&2
    echo "Start it first, e.g.:" >&2
    echo "  docker run -d --name $CONTAINER_NAME -v \"\$PWD:/repo\" \\" >&2
    echo "    mcr.microsoft.com/dotnet-buildtools/prereqs:azurelinux-3.0-net11.0-cross-arm64 \\" >&2
    echo "    sleep infinity" >&2
    exit 1
fi

CACHE_FLAG=""
if [[ -n "$DISK_CACHE" ]]; then
    CACHE_FLAG="--disk_cache=/disk-cache"
fi

# ---------- Step 1: Build ----------
echo "==> Building arm64 targets..."
docker exec "$CONTAINER_NAME" sh -c "
    export HOME=/tmp/bazel-home
    cd /repo
    bazel --nohome_rc build --keep_going \
        --config=cross_container \
        $BAZEL_CONFIG \
        --platforms=$PLATFORMS \
        $CACHE_FLAG \
        //src/...
"

if [[ -n "$BUILD_ONLY" ]]; then
    echo "==> Build complete (tests skipped)."
    exit 0
fi

# ---------- Step 2: Upload testhost (if sending to Helix) ----------
HELIX_ENV_FLAGS=""
if [[ -n "$SEND_TO_HELIX" ]]; then
    CONTAINER_INFO="/repo/artifacts/helix/container.json"

    echo "==> Uploading testhost to Helix..."
    # Resolve the testhost directory from bazel's output
    TESTHOST_DIR=$(docker exec "$CONTAINER_NAME" sh -c "
        export HOME=/tmp/bazel-home
        cd /repo
        bazel --nohome_rc cquery --output=files \
            --config=cross_container \
            $BAZEL_CONFIG \
            --platforms=$PLATFORMS \
            //src/tests:shared_testhost 2>/dev/null | tail -1
    ")

    docker exec "$CONTAINER_NAME" sh -c "
        cd /repo
        eng/bazel/helix-create-container.sh \
            --testhost-dir '$TESTHOST_DIR' \
            --output '$CONTAINER_INFO' \
            --creator '$HELIX_CREATOR' \
            --source '$HELIX_SOURCE'
    "

    HELIX_ENV_FLAGS="--test_env=HELIX_CONTAINER_INFO=$CONTAINER_INFO"
fi

# ---------- Step 3: Run tests ----------
echo "==> Running library tests..."
docker exec "$CONTAINER_NAME" sh -c "
    export HOME=/tmp/bazel-home
    cd /repo
    bazel --nohome_rc test --keep_going \
        --config=cross_container \
        $BAZEL_CONFIG \
        --platforms=$PLATFORMS \
        $CACHE_FLAG \
        $HELIX_ENV_FLAGS \
        --test_timeout=3300 \
        --test_output=errors \
        --local_test_jobs=64 \
        --jobs=64 \
        //src/libraries/...
" || {
    EXIT_CODE=$?
    echo "==> Some tests failed (exit code: $EXIT_CODE)"
    exit $EXIT_CODE
}

# Fix ownership — container runs as root
if [[ -d "$REPO_ROOT/artifacts/helix" ]]; then
    if command -v sudo &>/dev/null; then
        sudo chown -R "$(id -u):$(id -g)" "$REPO_ROOT/artifacts/helix" 2>/dev/null || true
    fi
fi

echo "==> Cross-build complete."
