#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=""
TARGET_DIR=""
IMAGE_VERSION=""
EXTENSIONS=".yml,.yaml,.json,.toml,.conf,.ini,.env,.properties,.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --target-dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --image-version)
      IMAGE_VERSION="$2"
      shift 2
      ;;
    --extensions)
      EXTENSIONS="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_DIR" || -z "$TARGET_DIR" || -z "$IMAGE_VERSION" ]]; then
  echo "source-dir, target-dir and image-version are required" >&2
  exit 1
fi

SOURCE_DIR="$(python3 - <<PY
import os
print(os.path.realpath("$SOURCE_DIR"))
PY
)"

TARGET_DIR="$(python3 - <<PY
import os
print(os.path.realpath("$TARGET_DIR"))
PY
)"

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

export IMAGE_VERSION

if [[ "$TARGET_DIR" == "/" ]]; then
  echo "Refusing to write to /" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RENDERED_DIR="$TMP_DIR/rendered"
mkdir -p "$RENDERED_DIR"
rsync -a --delete "$SOURCE_DIR"/ "$RENDERED_DIR"/

IFS=',' read -r -a SUPPORTED_EXTENSIONS <<<"$EXTENSIONS"

supports_file() {
  local file="$1"
  local extension
  for extension in "${SUPPORTED_EXTENSIONS[@]}"; do
    extension="${extension# }"
    extension="${extension% }"
    if [[ "$file" == *"$extension" ]]; then
      return 0
    fi
  done
  return 1
}

while IFS= read -r -d '' file; do
  if supports_file "$file"; then
    python3 - <<'PY' "$file" "$IMAGE_VERSION"
from pathlib import Path
import sys

path = Path(sys.argv[1])
image_version = sys.argv[2]
path.write_text(path.read_text(encoding="utf-8").replace("@@IMAGE_VERSION@@", image_version), encoding="utf-8")
PY
    if grep -q '@@IMAGE_VERSION@@' "$file"; then
      echo "Unresolved placeholder in: $file" >&2
      exit 1
    fi
  fi
done < <(find "$RENDERED_DIR" -type f -print0)

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
rsync -a --delete "$RENDERED_DIR"/ "$TARGET_DIR"/
