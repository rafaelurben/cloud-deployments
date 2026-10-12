#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "Assertion failed: $message" >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    exit 1
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# detect-changes
mkdir -p "$tmp/repo"
cd "$tmp/repo"
git init -q
git config user.name test
git config user.email test@example.com
mkdir -p deploy/dev services/api
cat > services/api/Dockerfile <<'DOCKER'
FROM busybox
DOCKER
cat > deploy/dev/docker-compose.yml <<'YAML'
services:
  api:
    image: registry.example.com/org/app-api:@@IMAGE_VERSION@@
YAML
git add .
git commit -qm "init"
base_sha="$(git rev-parse HEAD)"
echo "docs" > README.md
git add README.md
git commit -qm "docs"
head_sha="$(git rev-parse HEAD)"

output="$($ROOT/scripts/detect-changes.sh \
  --base "$base_sha" \
  --head "$head_sha" \
  --images-json '[{"context":"services/api","dockerfile":"services/api/Dockerfile","suffix":"-api"}]' \
  --deployment-source-root deploy \
  --shared-watch-paths-json '["shared"]')"

assert_eq "false" "$(awk -F= '/image_changes=/{print $2}' <<<"$output")" "docs change should not trigger image changes"
assert_eq "false" "$(awk -F= '/deployment_changes=/{print $2}' <<<"$output")" "docs change should not trigger deployment changes"

# render + validate
mkdir -p "$tmp/source/deploy/dev"
cat > "$tmp/source/deploy/dev/docker-compose.yml" <<'YAML'
services:
  api:
    image: registry.example.com/org/app-api:@@IMAGE_VERSION@@
    environment:
      DATABASE_URL: ${DATABASE_URL}
YAML
cat > "$tmp/source/deploy/dev/service.env" <<'ENV'
IMAGE_TAG=@@IMAGE_VERSION@@
ENV

"$ROOT/scripts/render-deployment.sh" \
  --source-dir "$tmp/source/deploy/dev" \
  --target-dir "$tmp/rendered" \
  --image-version v1.2.3

if ! grep -q 'registry.example.com/org/app-api:v1.2.3' "$tmp/rendered/docker-compose.yml"; then
  echo "render-deployment did not replace compose image placeholder" >&2
  exit 1
fi

if ! grep -q '${DATABASE_URL}' "$tmp/rendered/docker-compose.yml"; then
  echo "render-deployment unexpectedly changed runtime interpolation" >&2
  exit 1
fi

mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "compose" ]]; then
  exit 0
fi
exit 1
DOCKER
chmod +x "$tmp/bin/docker"

PATH="$tmp/bin:$PATH" VALIDATE_SKIP_COMPOSE=0 "$ROOT/scripts/validate-deployment.sh" \
  --directory "$tmp/rendered" \
  --compose-file docker-compose.yml \
  --image-version v1.2.3 \
  --expected-images-json '["registry.example.com/org/app-api"]'

echo "All script tests passed"
