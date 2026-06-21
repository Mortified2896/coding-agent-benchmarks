#!/usr/bin/env bash
set -euo pipefail

# Daily Langfuse archive export wrapper.
# Prints only operational metadata. Do not echo secrets, env values, or raw records.

REPO_DIR="/home/hermes/workspace/repos/coding-agent-benchmarks"
ARCHIVE_ROOT="/home/hermes/archives/langfuse/raw"
PAGE_SIZE="${LANGFUSE_ARCHIVE_PAGE_SIZE:-25}"
TZ_NAME="Europe/Berlin"

cd "$REPO_DIR"

if [[ -n "${LANGFUSE_ARCHIVE_DATE:-}" ]]; then
  EXPORT_DATE="$LANGFUSE_ARCHIVE_DATE"
else
  EXPORT_DATE="$(TZ="$TZ_NAME" date -d 'yesterday' +%F)"
fi

case "$EXPORT_DATE" in
  ????-??-??) ;;
  *) echo "invalid export date format" >&2; exit 64 ;;
esac

# Never export the current Berlin local day in the daily job.
TODAY_BERLIN="$(TZ="$TZ_NAME" date +%F)"
if [[ "$EXPORT_DATE" == "$TODAY_BERLIN" ]]; then
  echo "refusing to export current partial Berlin day" >&2
  exit 65
fi

PARTITION_DIR="$ARCHIVE_ROOT/${EXPORT_DATE:0:4}/${EXPORT_DATE:5:2}/${EXPORT_DATE:8:2}"
MANIFEST="$PARTITION_DIR/manifest.json"

validate_archive() {
  local manifest_path="$1"
  python3 - "$manifest_path" "$ARCHIVE_ROOT" <<'PY'
import gzip
import hashlib
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1]).resolve()
archive_root = Path(sys.argv[2]).resolve()

try:
    manifest_path.relative_to(archive_root)
except ValueError:
    print("validation failed: manifest outside archive root", file=sys.stderr)
    sys.exit(1)

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"validation failed: manifest unreadable: {type(exc).__name__}", file=sys.stderr)
    sys.exit(1)

if manifest.get("schema_version") != 1:
    print("validation failed: unsupported manifest schema", file=sys.stderr)
    sys.exit(1)
if manifest.get("completed_successfully") is not True:
    print("validation failed: manifest not completed successfully", file=sys.stderr)
    sys.exit(1)

objects = manifest.get("objects")
if not isinstance(objects, dict):
    print("validation failed: manifest objects missing", file=sys.stderr)
    sys.exit(1)

base = manifest_path.parent
for name, meta in objects.items():
    if not isinstance(meta, dict):
        print(f"validation failed: object {name} metadata invalid", file=sys.stderr)
        sys.exit(1)
    status = meta.get("status")
    if status == "skipped":
        continue
    if status != "success":
        print(f"validation failed: object {name} status {status}", file=sys.stderr)
        sys.exit(1)
    file_name = meta.get("file")
    if not file_name:
        print(f"validation failed: object {name} file missing", file=sys.stderr)
        sys.exit(1)
    path = (base / file_name).resolve()
    try:
        path.relative_to(archive_root)
    except ValueError:
        print(f"validation failed: object {name} file outside archive root", file=sys.stderr)
        sys.exit(1)
    expected_hash = meta.get("sha256")
    h = hashlib.sha256()
    line_count = 0
    try:
        with path.open("rb") as raw:
            for chunk in iter(lambda: raw.read(1024 * 1024), b""):
                h.update(chunk)
        with gzip.open(path, "rt", encoding="utf-8") as f:
            for _ in f:
                line_count += 1
    except Exception as exc:
        print(f"validation failed: object {name} gzip/hash read failed: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)
    if expected_hash and h.hexdigest() != expected_hash:
        print(f"validation failed: object {name} sha256 mismatch", file=sys.stderr)
        sys.exit(1)
    if line_count != int(meta.get("record_count", -1)):
        print(f"validation failed: object {name} line count mismatch", file=sys.stderr)
        sys.exit(1)

print("validation success")
PY
}

if [[ -f "$MANIFEST" ]]; then
  echo "archive partition already has manifest for $EXPORT_DATE; validating without overwrite"
  validate_archive "$MANIFEST"
  echo "daily Langfuse archive export no-op: existing successful archive for $EXPORT_DATE"
  exit 0
fi

echo "starting daily Langfuse archive export for $EXPORT_DATE"
python3 scripts/export_langfuse_archive.py --date "$EXPORT_DATE" --page-size "$PAGE_SIZE"
validate_archive "$MANIFEST"
echo "daily Langfuse archive export completed for $EXPORT_DATE"
