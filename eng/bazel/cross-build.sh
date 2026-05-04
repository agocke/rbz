#!/usr/bin/env bash
# Cross-build, package, and (optionally) submit arm64 tests to Helix.
#
# This script runs inside an already-running cross-build container.
# The caller is responsible for pulling the image and starting the
# container with the repo mounted at /repo.
#
# Steps:
#   1. Builds all targets for arm64 inside the container
#   2. Runs library tests (which produce helix manifests instead of executing)
#   3. Collects manifests and packages Helix payloads
#   4. Submits work items to Helix (if --send-to-helix)
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
#   --platforms LABEL       Bazel --platforms target
#   --send-to-helix        Submit work items to Helix after packaging
#   --creator NAME         Helix Creator field (default: $USER)
#   --helix-build ID       Helix Build ID (default: local-<timestamp>)
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
DISK_CACHE=""
BAZEL_CONFIG="--config=clr_release --config=libs_release"
PLATFORMS="//platforms:linux_arm64"
CONTAINER_NAME="arm64-cross-ci"
SKIP_HELIX="1"
HELIX_CREATOR="${USER:-local}"
HELIX_BUILD="local-$(date +%s)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk-cache) DISK_CACHE="$2"; shift 2 ;;
        --bazel-config) BAZEL_CONFIG="$2"; shift 2 ;;
        --platforms) PLATFORMS="$2"; shift 2 ;;
        --container) CONTAINER_NAME="$2"; shift 2 ;;
        --send-to-helix) SKIP_HELIX=""; shift ;;
        --creator) HELIX_CREATOR="$2"; shift 2 ;;
        --helix-build) HELIX_BUILD="$2"; shift 2 ;;
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

# Mount disk cache if provided (remount into running container isn't possible,
# so we expect the caller to have mounted it when starting the container).
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
        --config=cross_container \
        $BAZEL_CONFIG \
        --platforms=$PLATFORMS \
        $CACHE_FLAG \
        //src/...
"

# ---------- Step 3: Run tests (produces helix manifests) ----------
MANIFEST_DIR="/repo/artifacts/helix/manifests"
echo "==> Running library tests (helix manifest mode)..."
docker exec "$CONTAINER_NAME" sh -c "
    export HOME=/tmp/bazel-home
    cd /repo
    rm -rf $MANIFEST_DIR
    mkdir -p $MANIFEST_DIR
    bazel --nohome_rc test --keep_going \
        --config=cross_container \
        $BAZEL_CONFIG \
        --platforms=$PLATFORMS \
        $CACHE_FLAG \
        --nocache_test_results \
        --test_env=HELIX_MANIFEST_DIR=$MANIFEST_DIR \
        //src/libraries/...
"

# ---------- Step 4: Collect manifests and package payloads ----------
echo "==> Collecting helix manifests and packaging payloads..."
docker exec "$CONTAINER_NAME" sh -c "
    export HOME=/tmp/bazel-home
    cd /repo
    eng/bazel/prepare-helix-payloads.sh --manifest-dir $MANIFEST_DIR
"

# Fix ownership — container runs as root
if [[ -d "$REPO_ROOT/artifacts/helix" ]]; then
    if command -v sudo &>/dev/null; then
        sudo chown -R "$(id -u):$(id -g)" "$REPO_ROOT/artifacts/helix"
    fi
fi

# ---------- Step 5: Submit to Helix ----------
if [[ -n "$SKIP_HELIX" ]]; then
    echo "==> Cross-build complete (Helix submission skipped). Payloads at: artifacts/helix/"
    exit 0
fi

echo "==> Submitting tests to Helix..."

# Ensure .NET SDK is available
DOTNET_CMD="dotnet"
if ! command -v "$DOTNET_CMD" &>/dev/null || ! "$DOTNET_CMD" msbuild --version &>/dev/null 2>&1; then
    echo "   Installing .NET SDK..."
    SDK_VERSION=$(python3 -c "import json; print(json.load(open('$REPO_ROOT/global.json'))['tools']['dotnet'])" 2>/dev/null || true)
    if [[ -z "$SDK_VERSION" ]]; then
        SDK_VERSION=$(python3 -c "import json; print(json.load(open('$REPO_ROOT/global.json'))['sdk']['version'])" 2>/dev/null)
    fi
    curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --version "$SDK_VERSION" --install-dir "$REPO_ROOT/.dotnet"
    DOTNET_CMD="$REPO_ROOT/.dotnet/dotnet"
fi

echo "   SDK version: $("$DOTNET_CMD" --version)"

"$DOTNET_CMD" msbuild "$REPO_ROOT/eng/bazel/sendtohelix.proj" \
    /p:Creator="$HELIX_CREATOR" \
    /p:HelixBuild="$HELIX_BUILD" \
    /p:TesthostPayload="$REPO_ROOT/artifacts/helix/testhost" \
    /p:TestPayloadDir="$REPO_ROOT/artifacts/helix/tests"

echo "==> Done. Tests submitted to Helix (Build: $HELIX_BUILD)."
