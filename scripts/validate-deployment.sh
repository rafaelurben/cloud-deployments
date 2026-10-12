#!/usr/bin/env bash
set -euo pipefail

DIRECTORY=""
COMPOSE_FILE="docker-compose.yml"
IMAGE_VERSION=""
EXPECTED_IMAGES_JSON='[]'
EXTENSIONS=".yml,.yaml,.json,.toml,.conf,.ini,.env,.properties,.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --directory)
      DIRECTORY="$2"
      shift 2
      ;;
    --compose-file)
      COMPOSE_FILE="$2"
      shift 2
      ;;
    --image-version)
      IMAGE_VERSION="$2"
      shift 2
      ;;
    --expected-images-json)
      EXPECTED_IMAGES_JSON="$2"
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

if [[ -z "$DIRECTORY" || -z "$IMAGE_VERSION" ]]; then
  echo "directory and image-version are required" >&2
  exit 1
fi

DIRECTORY="$(python3 - <<PY
import os
print(os.path.realpath("$DIRECTORY"))
PY
)"

if [[ ! -d "$DIRECTORY" ]]; then
  echo "Directory not found: $DIRECTORY" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if ! jq -e 'type == "array"' >/dev/null <<<"$EXPECTED_IMAGES_JSON"; then
  echo "expected-images-json must be a JSON array" >&2
  exit 1
fi

python3 - <<'PY' "$DIRECTORY"
import pathlib
import sys
import yaml

base = pathlib.Path(sys.argv[1])
for path in base.rglob("*"):
    if path.is_file() and path.suffix in {".yml", ".yaml"}:
        try:
            with path.open("r", encoding="utf-8") as handle:
                yaml.safe_load(handle)
        except Exception as exc:
            print(f"Invalid YAML in {path}: {exc}", file=sys.stderr)
            sys.exit(1)
PY

COMPOSE_PATH="$DIRECTORY/${COMPOSE_FILE#./}"
if [[ ! -f "$COMPOSE_PATH" ]]; then
  echo "Compose file not found: $COMPOSE_PATH" >&2
  exit 1
fi

if [[ "${VALIDATE_SKIP_COMPOSE:-0}" != "1" ]]; then
  docker compose -f "$COMPOSE_PATH" config --quiet --no-interpolate
fi

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
  if supports_file "$file" && grep -q '@@IMAGE_VERSION@@' "$file"; then
    echo "Unresolved image placeholder in $file" >&2
    exit 1
  fi
done < <(find "$DIRECTORY" -type f -print0)

while IFS= read -r expected; do
  [[ -z "$expected" ]] && continue
  if ! grep -R --include='*.yml' --include='*.yaml' --fixed-strings --quiet "$expected:$IMAGE_VERSION" "$DIRECTORY"; then
    echo "Expected image reference not found: $expected:$IMAGE_VERSION" >&2
    exit 1
  fi
done < <(jq -r '.[]' <<<"$EXPECTED_IMAGES_JSON")
