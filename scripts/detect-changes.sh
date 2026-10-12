#!/usr/bin/env bash
set -euo pipefail

BASE_SHA=""
HEAD_SHA=""
IMAGES_JSON=""
DEPLOYMENT_SOURCE_ROOT="deploy"
SHARED_WATCH_PATHS_JSON='[]'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE_SHA="$2"
      shift 2
      ;;
    --head)
      HEAD_SHA="$2"
      shift 2
      ;;
    --images-json)
      IMAGES_JSON="$2"
      shift 2
      ;;
    --deployment-source-root)
      DEPLOYMENT_SOURCE_ROOT="$2"
      shift 2
      ;;
    --shared-watch-paths-json)
      SHARED_WATCH_PATHS_JSON="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$HEAD_SHA" ]]; then
  echo "--head is required" >&2
  exit 1
fi

if [[ -z "$IMAGES_JSON" ]]; then
  echo "--images-json is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if ! jq -e 'type == "array"' >/dev/null <<<"$IMAGES_JSON"; then
  echo "images-json must be a JSON array" >&2
  exit 1
fi

if ! jq -e 'type == "array"' >/dev/null <<<"$SHARED_WATCH_PATHS_JSON"; then
  echo "shared-watch-paths-json must be a JSON array" >&2
  exit 1
fi

normalize_path() {
  local path="$1"
  path="${path#./}"
  path="${path%/}"
  printf '%s' "$path"
}

path_matches() {
  local file="$1"
  local watched="$2"
  watched="$(normalize_path "$watched")"
  [[ -z "$watched" ]] && return 1
  [[ "$file" == "$watched" || "$file" == "$watched"/* ]]
}

is_relevant_image_file() {
  local file="$1"
  local watch

  while IFS= read -r watch; do
    if path_matches "$file" "$watch"; then
      return 0
    fi
  done < <(jq -r '.[] | (.context // empty), (.dockerfile // empty), ((.watch_paths // [])[]?)' <<<"$IMAGES_JSON")

  while IFS= read -r watch; do
    if path_matches "$file" "$watch"; then
      return 0
    fi
  done < <(jq -r '.[]?' <<<"$SHARED_WATCH_PATHS_JSON")

  return 1
}

is_relevant_deployment_file() {
  local file="$1"
  local root
  root="$(normalize_path "$DEPLOYMENT_SOURCE_ROOT")"
  [[ "$file" == "$root" || "$file" == "$root"/* ]]
}

if [[ -z "$BASE_SHA" || "$BASE_SHA" =~ ^0+$ ]] || ! git cat-file -e "$BASE_SHA^{commit}" >/dev/null 2>&1; then
  echo "image_changes=true"
  echo "deployment_changes=true"
  echo "reason=missing_or_unavailable_base"
  exit 0
fi

mapfile -t CHANGED_FILES < <(git diff --name-only "$BASE_SHA" "$HEAD_SHA")

IMAGE_CHANGES=false
DEPLOYMENT_CHANGES=false

for file in "${CHANGED_FILES[@]}"; do
  [[ -z "$file" ]] && continue
  if is_relevant_image_file "$file"; then
    IMAGE_CHANGES=true
  fi
  if is_relevant_deployment_file "$file"; then
    DEPLOYMENT_CHANGES=true
  fi
  if [[ "$IMAGE_CHANGES" == true && "$DEPLOYMENT_CHANGES" == true ]]; then
    break
  fi
done

echo "image_changes=$IMAGE_CHANGES"
echo "deployment_changes=$DEPLOYMENT_CHANGES"
