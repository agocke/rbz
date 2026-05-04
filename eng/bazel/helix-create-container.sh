#!/usr/bin/env bash
# Create a Helix blob storage container and upload the shared testhost.
#
# This is the "pre-step" that runs once before `bazel test`. It:
#   1. Creates an Azure Blob Storage container via the Helix API
#   2. Zips and uploads the shared testhost directory
#   3. Writes container.json with SAS tokens and testhost URI
#
# Individual test launchers read container.json to upload their own
# test payloads and create Helix jobs.
#
# Usage:
#   eng/bazel/helix-create-container.sh \
#     --testhost-dir /path/to/testhost \
#     --output /path/to/container.json \
#     [--queue QUEUE_ID] \
#     [--docker-tag IMAGE] \
#     [--source SOURCE] \
#     [--creator CREATOR]

set -euo pipefail

HELIX_BASE="https://helix.dot.net"
API_VER="api-version=2019-06-17"

# Defaults
TESTHOST_DIR=""
OUTPUT_FILE=""
QUEUE_ID="AzureLinux.3.Arm64.Open"
DOCKER_TAG="mcr.microsoft.com/dotnet-buildtools/prereqs:ubuntu-22.04-helix-arm64v8"
SOURCE="pr/agocke/rbz/bazel/"
CREATOR="${USER:-local}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --testhost-dir) TESTHOST_DIR="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --queue) QUEUE_ID="$2"; shift 2 ;;
        --docker-tag) DOCKER_TAG="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --creator) CREATOR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$TESTHOST_DIR" || ! -d "$TESTHOST_DIR" ]]; then
    echo "ERROR: --testhost-dir is required and must be a directory" >&2
    exit 1
fi
if [[ -z "$OUTPUT_FILE" ]]; then
    echo "ERROR: --output is required" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

# ---------- Step 1: Create Helix storage container ----------
echo "==> Creating Helix storage container..."

CONTAINER_JSON=$(curl -sf -X POST \
    "${HELIX_BASE}/api/storage?${API_VER}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"ExpirationInDays\":1,\"DesiredName\":\"bazel-helix-tests\",\"TargetQueue\":\"${QUEUE_ID}\"}")

STORAGE_ACCOUNT=$(echo "$CONTAINER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['StorageAccountName'])")
CONTAINER_NAME=$(echo "$CONTAINER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['ContainerName'])")
WRITE_TOKEN=$(echo "$CONTAINER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['WriteToken'])")
READ_TOKEN=$(echo "$CONTAINER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['ReadToken'])")
BLOB_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}"

echo "   Storage account: $STORAGE_ACCOUNT"
echo "   Container: $CONTAINER_NAME"

# ---------- Step 2: Zip and upload testhost ----------
echo "==> Zipping testhost..."
TESTHOST_ZIP="$(mktemp -d)/testhost.zip"
(cd "$TESTHOST_DIR" && python3 -c "
import zipfile, os, sys
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk('.'):
        for f in files:
            filepath = os.path.join(root, f)
            arcname = os.path.relpath(filepath, '.')
            zf.write(filepath, arcname)
print(f'   Zipped {os.path.getsize(sys.argv[1]) / 1048576:.1f} MB')
" "$TESTHOST_ZIP")

TESTHOST_BLOB="testhost-$(python3 -c "import uuid; print(uuid.uuid4())").zip"
echo "==> Uploading testhost to blob storage..."
curl -sf -X PUT \
    "${BLOB_BASE}/${TESTHOST_BLOB}${WRITE_TOKEN}" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Type: application/zip" \
    --data-binary "@${TESTHOST_ZIP}"

TESTHOST_URI="${BLOB_BASE}/${TESTHOST_BLOB}${READ_TOKEN}"
echo "   Uploaded: $TESTHOST_BLOB"

# Clean up temp zip
rm -f "$TESTHOST_ZIP"

# ---------- Step 3: Write container.json ----------
python3 -c "
import json, sys
info = {
    'storage_account': sys.argv[1],
    'container_name': sys.argv[2],
    'write_token': sys.argv[3],
    'read_token': sys.argv[4],
    'blob_base': sys.argv[5],
    'testhost_uri': sys.argv[6],
    'queue_id': sys.argv[7],
    'docker_tag': sys.argv[8],
    'source': sys.argv[9],
    'creator': sys.argv[10],
}
with open(sys.argv[11], 'w') as f:
    json.dump(info, f, indent=2)
" "$STORAGE_ACCOUNT" "$CONTAINER_NAME" "$WRITE_TOKEN" "$READ_TOKEN" \
  "$BLOB_BASE" "$TESTHOST_URI" "$QUEUE_ID" "$DOCKER_TAG" "$SOURCE" "$CREATOR" \
  "$OUTPUT_FILE"

echo "==> Container info written to: $OUTPUT_FILE"
