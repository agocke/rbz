#!/usr/bin/env bash
# Self-contained Helix test launcher for cross-compiled arm64 tests.
#
# Instead of running the test locally, this script:
#   1. Reads Helix container info from $HELIX_CONTAINER_INFO
#   2. Zips test files from Bazel's assembled output directory
#   3. Uploads the test payload to the shared blob container
#   4. Creates a single-work-item Helix job
#   5. Polls for completion and reports pass/fail
#
# Bazel test caching works naturally: if test inputs haven't changed,
# the cached result is reused without dispatching to Helix.

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

HELIX_BASE="https://helix.dot.net"
API_VER="api-version=2019-06-17"
TEST_NAME="TEMPLATED_test_name"

# Resolve paths via runfiles
ENTRY_DLL="$(rlocation TEMPLATED_entry_dll)"
XUNIT_CONSOLE="$(rlocation TEMPLATED_xunit_console)"
DEPSFILE="$(rlocation TEMPLATED_depsfile)"
RUNTIMECONFIG="$(rlocation TEMPLATED_runtimeconfig)"

# Validate
if [[ -z "${HELIX_CONTAINER_INFO:-}" ]]; then
    echo >&2 "ERROR: HELIX_CONTAINER_INFO env var not set."
    echo >&2 "Run eng/bazel/helix-create-container.sh first and pass via --test_env."
    exit 1
fi
if [[ ! -f "$HELIX_CONTAINER_INFO" ]]; then
    echo >&2 "ERROR: HELIX_CONTAINER_INFO file not found: $HELIX_CONTAINER_INFO"
    exit 1
fi
for var_name in ENTRY_DLL XUNIT_CONSOLE DEPSFILE RUNTIMECONFIG; do
    val="${!var_name}"
    if [[ -z "$val" || ! -f "$val" ]]; then
        echo >&2 "ERROR: $var_name not found: $val"
        exit 1
    fi
done

# Read container info
WRITE_TOKEN=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['write_token'])")
READ_TOKEN=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['read_token'])")
BLOB_BASE=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['blob_base'])")
TESTHOST_URI=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['testhost_uri'])")
QUEUE_ID=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['queue_id'])")
DOCKER_TAG=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['docker_tag'])")
HELIX_SOURCE=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['source'])")
HELIX_CREATOR=$(python3 -c "import json; print(json.load(open('$HELIX_CONTAINER_INFO'))['creator'])")

# ---------- Step 1: Build test payload zip ----------
TEST_DIR="$(cd "$(dirname "$ENTRY_DLL")" && pwd -P)"
WORK_DIR="${TEST_TMPDIR:-/tmp}/helix-${TEST_NAME}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Generate run.sh for Helix to execute
# $HELIX_CORRELATION_PAYLOAD contains the testhost (dotnet, shared framework, xunit runner)
cat > "$WORK_DIR/run.sh" << 'RUN_INNER_EOF'
#!/usr/bin/env bash
set -eu
export DOTNET_ROOT="$HELIX_CORRELATION_PAYLOAD"
RUN_INNER_EOF
cat >> "$WORK_DIR/run.sh" << RUN_INNER_EOF
exec "\$HELIX_CORRELATION_PAYLOAD/dotnet" exec \\
  --runtimeconfig $(basename "$RUNTIMECONFIG") \\
  --depsfile $(basename "$DEPSFILE") \\
  xunit.console.dll \\
  ${TEST_NAME}.dll \\
  -nologo \\
  -notrait "category=failing" \\
  -notrait "category=OuterLoop"
RUN_INNER_EOF
chmod +x "$WORK_DIR/run.sh"

# Zip test files: test DLL, runtimeconfig, depsfile, data files, and run.sh.
# Skip framework assemblies (in testhost), launcher scripts, and Bazel metadata.
python3 << PYEOF
import zipfile, os, sys, shutil

zip_path = "$WORK_DIR/payload.zip"
test_dir = "$TEST_DIR"
run_sh = "$WORK_DIR/run.sh"

# Skip Bazel metadata and launcher scripts
skip_extensions = {'.sh', '.bat', '.repo_mapping', '.runfiles_manifest', '.params'}
# Skip directories that are Bazel artifacts, not test data
skip_dirs = {'ref', 'runfiles'}

with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
    # Add run.sh
    zf.write(run_sh, 'run.sh')

    # Add test files from the Bazel output directory
    for entry in os.listdir(test_dir):
        filepath = os.path.join(test_dir, entry)

        if os.path.isdir(filepath):
            # Skip Bazel internal directories and runfiles
            base = os.path.basename(entry)
            if base in skip_dirs or base.endswith('.runfiles'):
                continue
            # Include test data subdirectories
            for root, dirs, files in os.walk(filepath):
                for f in files:
                    full = os.path.join(root, f)
                    arcname = os.path.relpath(full, test_dir)
                    zf.write(full, arcname)
            continue

        ext = os.path.splitext(entry)[1]
        if ext in skip_extensions:
            continue

        # Resolve symlinks
        real_path = os.path.realpath(filepath)
        if os.path.isfile(real_path):
            zf.write(real_path, entry)

size_mb = os.path.getsize(zip_path) / 1048576
print(f"   Payload: {size_mb:.1f} MB")
PYEOF

# ---------- Step 2: Upload test payload ----------
PAYLOAD_BLOB="${TEST_NAME}-$(python3 -c "import uuid; print(uuid.uuid4())").zip"
upload_blob() {
    local url="$1" file="$2" ctype="$3"
    for attempt in 1 2 3; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            "$url" \
            -H "x-ms-blob-type: BlockBlob" \
            -H "x-ms-version: 2020-10-02" \
            -H "Content-Type: $ctype" \
            --data-binary "@$file" \
            --connect-timeout 30 \
            --max-time 300)
        if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then return 0; fi
        echo "   Upload attempt $attempt failed (HTTP $HTTP_CODE)" >&2
        if [[ $attempt -eq 3 ]]; then
            echo "ERROR: Upload failed after 3 attempts (HTTP $HTTP_CODE)" >&2
            return 1
        fi
        sleep $((attempt * 5))
    done
}
upload_blob "${BLOB_BASE}/${PAYLOAD_BLOB}${WRITE_TOKEN}" "${WORK_DIR}/payload.zip" "application/zip"
PAYLOAD_URI="${BLOB_BASE}/${PAYLOAD_BLOB}${READ_TOKEN}"

# ---------- Step 3: Build and upload job-list JSON ----------
JOB_LIST_BLOB="${TEST_NAME}-joblist-$(python3 -c "import uuid; print(uuid.uuid4())").json"
python3 -c "
import json, sys
job_list = [{
    'WorkItemId': '$TEST_NAME',
    'Command': 'chmod +x run.sh && ./run.sh',
    'TimeoutInSeconds': 2700,
    'PayloadUri': '$PAYLOAD_URI',
    'CorrelationPayloadUrisWithDestinations': {
        '$TESTHOST_URI': ''
    }
}]
with open('$WORK_DIR/job-list.json', 'w') as f:
    json.dump(job_list, f)
"
upload_blob "${BLOB_BASE}/${JOB_LIST_BLOB}${WRITE_TOKEN}" "${WORK_DIR}/job-list.json" "application/json"
LIST_URI="${BLOB_BASE}/${JOB_LIST_BLOB}${READ_TOKEN}"

# ---------- Step 4: Create Helix job ----------
IDEMPOTENCY_KEY=$(python3 -c "import uuid; print(uuid.uuid4())")
JOB_RESULT=$(curl -sf -X POST \
    "${HELIX_BASE}/api/jobs?${API_VER}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "Idempotency-Key: ${IDEMPOTENCY_KEY}" \
    -d "$(python3 -c "
import json
job = {
    'Type': 'test/bazel/arm64/',
    'QueueId': '$QUEUE_ID',
    'ListUri': '$LIST_URI',
    'Creator': '$HELIX_CREATOR',
    'Source': '$HELIX_SOURCE',
    'DockerTag': '$DOCKER_TAG',
    'Properties': {
        'TestName': '$TEST_NAME'
    }
}
print(json.dumps(job))
")")

JOB_NAME=$(echo "$JOB_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['Name'])")
HELIX_CONSOLE_URL="${HELIX_BASE}/api/jobs/${JOB_NAME}/workitems/${TEST_NAME}/console?${API_VER}"
echo "   Helix job: $JOB_NAME (${TEST_NAME})"
echo "   Details: ${HELIX_BASE}/api/jobs/${JOB_NAME}/details?${API_VER}"

# On any exit (including SIGTERM from Bazel timeout), dump the Helix console log
dump_helix_output() {
    echo >&2 ""
    echo >&2 "=== Helix console: ${TEST_NAME} (job: $JOB_NAME) ==="
    curl -sfL "$HELIX_CONSOLE_URL" >&2 || echo >&2 "(console log not yet available)"
    echo >&2 "=== End Helix console ==="
}
trap dump_helix_output EXIT

# ---------- Step 5: Poll for completion ----------
# No script-side timeout — Bazel's --test_timeout is the single source of truth.
# If Bazel kills us (SIGTERM), the EXIT trap dumps whatever Helix output is available.
POLL_INTERVAL=10

while true; do
    PF=$(curl -sf "${HELIX_BASE}/api/jobs/${JOB_NAME}/pf?${API_VER}" 2>/dev/null || echo '{}')
    WORKING=$(echo "$PF" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Working', -1))" 2>/dev/null || echo "-1")
    TOTAL=$(echo "$PF" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Total', 0))" 2>/dev/null || echo "0")

    if [[ "$WORKING" == "0" && "$TOTAL" != "0" ]]; then
        break
    fi

    sleep $POLL_INTERVAL
done

# ---------- Step 6: Check results ----------
FAILED=$(echo "$PF" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('Failed', [])))")
PASSED=$(echo "$PF" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('Passed', [])))")

# Clean up temp files
rm -rf "$WORK_DIR"

if [[ "$FAILED" != "0" ]]; then
    echo >&2 "FAILED: ${TEST_NAME} (Helix job: $JOB_NAME)"
    exit 1
fi

# Suppress the EXIT trap output on success
trap - EXIT
echo "PASSED: ${TEST_NAME} (Helix job: $JOB_NAME)"
exit 0
