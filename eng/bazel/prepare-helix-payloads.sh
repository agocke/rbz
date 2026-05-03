#!/usr/bin/env bash
# Prepares Helix payloads from Bazel build outputs for arm64 testing.
#
# This script assembles:
#   1. An arm64 testhost (correlation payload) from Bazel-built arm64 binaries
#   2. Per-test work item directories from Bazel-built test outputs
#
# Run inside the cross-build container after 'bazel build' completes.
#
# Usage:
#   eng/bazel/prepare-helix-payloads.sh [--bazel-config "FLAGS"] [--test-filter PATTERN]
#
# Output:
#   artifacts/helix/testhost/     — arm64 testhost directory
#   artifacts/helix/tests/NAME/   — per-test payload directories

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# ---------- Parse arguments ----------
bazel_config_flags="--config=clr_release --config=libs_release"
test_filter=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bazel-config)
            bazel_config_flags="$2"
            shift 2
            ;;
        --test-filter)
            test_filter="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

HELIX_DIR="$REPO_ROOT/artifacts/helix"
TESTHOST_DIR="$HELIX_DIR/testhost"
TESTS_DIR="$HELIX_DIR/tests"

# Clean previous payloads
rm -rf "$HELIX_DIR"
mkdir -p "$TESTHOST_DIR" "$TESTS_DIR"

ARM64_FLAGS="--platforms=//platforms:linux_arm64"

# ---------- Helper: resolve Bazel output path ----------
bazel_output() {
    local extra_flags="$1"
    local target="$2"
    bazel --nohome_rc cquery $extra_flags $bazel_config_flags --output=files "$target"
}

# Get the .NET SDK version
SDK_VERSION=$(python3 -c "
import json
with open('global.json') as f:
    d = json.load(f)
v = d.get('tools', {}).get('dotnet', d.get('sdk', {}).get('version', ''))
print(v)
" 2>/dev/null || echo "")
if [[ -z "$SDK_VERSION" ]]; then
    SDK_VERSION=$(grep 'PRODUCT_VERSION' eng/bazel/version.bzl | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi

# Bazel execution root — canonical base for resolving output file paths
EXEC_ROOT=$(bazel --nohome_rc info execution_root 2>/dev/null)

echo "==> SDK version: $SDK_VERSION"
echo "    Exec root:   $EXEC_ROOT"

FW_DIR="$TESTHOST_DIR/shared/Microsoft.NETCore.App/$SDK_VERSION"
FXR_DIR="$TESTHOST_DIR/host/fxr/$SDK_VERSION"
mkdir -p "$FW_DIR" "$FXR_DIR"

# Helper to resolve a cquery-returned path to an absolute path
resolve_path() {
    local p="$1"
    if [[ "$p" == /* ]]; then echo "$p"; else echo "$EXEC_ROOT/$p"; fi
}

# ---------- Step 1: Assemble arm64 testhost ----------
echo "==> Assembling arm64 testhost..."

echo "   Copying arm64 native binaries..."
cp -L "$(resolve_path "$(bazel_output "$ARM64_FLAGS" "//src/native/corehost:dotnet")")" "$TESTHOST_DIR/dotnet"
chmod +x "$TESTHOST_DIR/dotnet"

HOSTFXR_PATH=$(resolve_path "$(bazel_output "$ARM64_FLAGS" "//src/native/corehost:hostfxr")")
cp -L "$HOSTFXR_PATH" "$FXR_DIR/"
cp -L "$HOSTFXR_PATH" "$FW_DIR/"

cp -L "$(resolve_path "$(bazel_output "$ARM64_FLAGS" "//src/native/corehost:hostpolicy")")" "$FW_DIR/"
cp -L "$(resolve_path "$(bazel_output "$ARM64_FLAGS" "//src/coreclr/dlls/mscoree/coreclr:libcoreclr.so")")" "$FW_DIR/"
cp -L "$(resolve_path "$(bazel_output "$ARM64_FLAGS" "//src/coreclr/jit:libclrjit.so")")" "$FW_DIR/"

for lib_so in $(bazel_output "$ARM64_FLAGS" 'kind("cc_shared_library", //src/native/libs/...)'); do
    cp -L "$(resolve_path "$lib_so")" "$FW_DIR/"
done

echo "   Copying managed assemblies..."
CORELIB_PATH=$(resolve_path "$(bazel_output "$ARM64_FLAGS" "//src/coreclr/System.Private.CoreLib:impl_System.Private.CoreLib")")
if [[ -n "$CORELIB_PATH" && -f "$CORELIB_PATH" ]]; then
    cp -L "$CORELIB_PATH" "$FW_DIR/System.Private.CoreLib.dll"
fi

for dll in $(bazel_output "$ARM64_FLAGS" "//src/libraries:impl_netcoreapp" 2>/dev/null || true); do
    abs=$(resolve_path "$dll")
    if [[ -f "$abs" && "$abs" == *.dll ]]; then
        cp -L "$abs" "$FW_DIR/"
    fi
done

echo "   Generating testhost deps.json..."
{
    printf '{"runtimeTarget":{"name":".NETCoreApp,Version=v0.0/rid","signature":""},'
    printf '"compilationOptions":{},"targets":{".NETCoreApp,Version=v0.0":{},'
    printf '".NETCoreApp,Version=v0.0/rid":{"Microsoft.NETCore.App/%s":{"runtime":{' "$SDK_VERSION"
    first=true
    for dll in "$FW_DIR"/*.dll; do
        [ -f "$dll" ] || continue
        base=$(basename "$dll")
        if $first; then first=false; else printf ','; fi
        printf '"runtimes/rid/lib/netcoreapp0.0/%s":{}' "$base"
    done
    printf '},"native":{'
    first=true
    for native in "$FW_DIR"/*.so; do
        [ -f "$native" ] || continue
        base=$(basename "$native")
        if $first; then first=false; else printf ','; fi
        printf '"runtimes/rid/native/%s":{}' "$base"
    done
    printf '}}}},"libraries":{"Microsoft.NETCore.App/%s":{"type":"package","serviceable":false,"sha512":""}}}' "$SDK_VERSION"
} > "$FW_DIR/Microsoft.NETCore.App.deps.json"

echo "   Testhost assembled: $(find "$TESTHOST_DIR" -type f | wc -l) files"

# ---------- Step 2: Copy xunit runner ----------
echo "==> Copying xunit runner..."
for f in $(bazel --nohome_rc cquery --output=files "//eng:xunit_console_runner" 2>/dev/null || true); do
    abs=$(resolve_path "$f")
    if [[ -f "$abs" ]]; then
        cp -L "$abs" "$TESTHOST_DIR/"
    fi
done
if [[ ! -f "$TESTHOST_DIR/xunit.console.dll" ]]; then
    echo "   WARNING: xunit.console.dll not found in testhost" >&2
fi

# ---------- Step 3: Package test work items ----------
echo "==> Packaging test payloads..."

if [[ -n "$test_filter" ]]; then
    test_query="kind(test, //src/libraries/$test_filter/...)"
else
    test_query="kind(test, //src/libraries/...)"
fi

test_targets=$(bazel --nohome_rc query "$test_query" 2>/dev/null || true)
test_count=0
skip_count=0

for target in $test_targets; do
    test_name="${target##*:}"

    dll_path=$(bazel --nohome_rc cquery $ARM64_FLAGS $bazel_config_flags --output=files "$target" 2>/dev/null | head -1)
    if [[ -z "$dll_path" ]]; then
        echo "   SKIP: $test_name (target incompatible)"
        skip_count=$((skip_count + 1))
        continue
    fi

    abs_dll=$(resolve_path "$dll_path")

    if [[ ! -f "$abs_dll" ]]; then
        echo "   SKIP: $test_name (DLL not built)"
        skip_count=$((skip_count + 1))
        continue
    fi

    test_out_dir=$(dirname "$abs_dll")
    work_dir="$TESTS_DIR/$test_name"
    mkdir -p "$work_dir"

    for f in "$test_out_dir"/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        case "$base" in
            *.sh|*.bat|*.repo_mapping|*.runfiles_manifest|*.params) continue ;;
        esac
        case "$base" in
            xunit.console.*|xunit.runner.*) continue ;;
        esac
        if [[ -f "$FW_DIR/$base" ]]; then
            continue
        fi
        cp -L "$f" "$work_dir/" 2>/dev/null || true
    done

    for d in "$test_out_dir"/*/; do
        [[ -d "$d" ]] || continue
        dname=$(basename "$d")
        case "$dname" in
            *.runfiles|ref) continue ;;
        esac
        cp -rL "$d" "$work_dir/" 2>/dev/null || true
    done

    if [[ ! -f "$work_dir/$test_name.runtimeconfig.json" ]]; then
        cat > "$work_dir/$test_name.runtimeconfig.json" <<EOF
{
  "runtimeOptions": {
    "tfm": "net10.0",
    "framework": {
      "name": "Microsoft.NETCore.App",
      "version": "$SDK_VERSION"
    },
    "configProperties": {
      "System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization": false
    }
  }
}
EOF
    fi

    if [[ ! -f "$work_dir/$test_name.deps.json" ]]; then
        cat > "$work_dir/$test_name.deps.json" <<EOF
{
  "runtimeTarget": { "name": ".NETCoreApp,Version=v10.0" },
  "compilationOptions": {},
  "targets": { ".NETCoreApp,Version=v10.0": {} },
  "libraries": {}
}
EOF
    fi

    cat > "$work_dir/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -eu

DOTNET_DIR="$(mktemp -d)"
cp "$HELIX_CORRELATION_PAYLOAD/dotnet" "$DOTNET_DIR/dotnet"
chmod +x "$DOTNET_DIR/dotnet"

export DOTNET_ROOT="$HELIX_CORRELATION_PAYLOAD"

RUNEOF
    cat >> "$work_dir/run.sh" <<RUNEOF
exec "\$DOTNET_DIR/dotnet" exec \\
  --runtimeconfig $test_name.runtimeconfig.json \\
  --depsfile $test_name.deps.json \\
  \$HELIX_CORRELATION_PAYLOAD/xunit.console.dll \\
  $test_name.dll \\
  -nologo \\
  -notrait "category=failing" \\
  -notrait "category=OuterLoop"
RUNEOF
    chmod +x "$work_dir/run.sh"

    test_count=$((test_count + 1))
done

echo "==> Packaged $test_count test work items ($skip_count skipped)"
echo "==> Helix payloads ready at: $HELIX_DIR"
echo "    Testhost: $(du -sh "$TESTHOST_DIR" | cut -f1)"
echo "    Tests:    $(du -sh "$TESTS_DIR" | cut -f1)"
