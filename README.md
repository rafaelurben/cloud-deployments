# Cloud Deployments

Reusable GitHub Actions workflows for Docker image publishing and Coolify deployment via centralized environment directories.

## Repository layout

- `.github/workflows/release.yml`: orchestrates builds, promotion, and deployments.
- `.github/workflows/build-images.yml`: reusable image build/publish workflow.
- `.github/workflows/promote-release.yml`: reusable image promotion workflow (SHA tag -> release tag).
- `.github/workflows/deploy-environment.yml`: reusable rendering, validation, and publishing workflow.
- `scripts/render-deployment.sh`: renders complete environment directories by replacing `@@IMAGE_VERSION@@`.
- `scripts/validate-deployment.sh`: YAML + Compose validation and image reference checks.
- `projects/`: central rendered deployment state consumed by Coolify.

## Workflow architecture

Application repositories should call `release.yml` from a push/tag workflow. This repository keeps deployment outputs under `projects/<project>/<environment>/`.

### `release.yml` inputs

- `project-name`
- `registry-host`
- `deployment-repository` (`owner/repository`)
- `deployment-source-root` (default `deploy`)
- `deployment-target-root` (default `projects`)
- `compose-file` (default `docker-compose.yml`)
- `images` (JSON image matrix)
- `global-build-args-json` (optional JSON object)
- `environments` (optional JSON object, default: `{"dev":{"url":"","enabled":true},"test":{"url":"","enabled":true},"prod":{"url":"","enabled":true}}`)

Secrets:

- `REGISTRY_USERNAME`
- `REGISTRY_PASSWORD`
- `DEPLOYMENT_TOKEN`

### Image matrix format

```json
[
  {
    "context": "./services/api",
    "dockerfile": "./services/api/Dockerfile",
    "suffix": "-api",
    "target": "runtime",
    "build_args": {
      "NODE_ENV": "production"
    },
    "artifact_name": "api-build",
    "artifact_path": "build"
  }
]
```

Image naming rule:

`<registry-host>/<owner>/<repository><suffix>:<tag>`

`<tag>` is the full commit SHA for main-branch publishes and the release version for promoted tags.

## Build preparation and artifact transfer

Use an application-specific workflow/job for preparation, then call `build-images.yml` (Approach A). Prepared artifacts can be uploaded and downloaded into each image context via `artifact_name` + `artifact_path` matrix fields.

Approach B is also supported by preparing directories before calling the reusable workflow and setting `context` accordingly.

Do not pass arbitrary shell commands via JSON inputs. Keep required artifacts inside Docker build contexts and ensure `.dockerignore` does not exclude them.

## Deployment rendering and validation

Rendering replaces `@@IMAGE_VERSION@@` in supported text files:

- `.yml`, `.yaml`, `.json`, `.toml`, `.conf`, `.ini`, `.env`, `.properties`, `.sh`

Validation checks:

- YAML syntax for all YAML files.
- Compose file existence.
- `docker compose config --quiet --no-interpolate`.
- No unresolved `@@IMAGE_VERSION@@` placeholders.
- Expected image references present.

`${VAR}` and default-style interpolation such as `${LOG_LEVEL:-info}` remain untouched.

## Test/prod flow

For version tags (`v*`):

1. Promote SHA images to release tag.
2. Render/validate `deploy/test/`, publish to `projects/<project>/test/` (if enabled).
3. Render/validate `deploy/prod/`, publish to `projects/<project>/prod/`.
4. Publish jobs always declare `environment: <input-environment>` (for example `test` and `prod`) and can set `environment.url` from `environments.<name>.url`.

The workflow can confirm central repository updates, but cannot reliably prove Coolify runtime health without external integration.

## Security and credentials

- Registry auth: `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` (caller repo secrets).
- Central repository write: `DEPLOYMENT_TOKEN` with push permissions.
- Do not store secrets in `projects/`.
- Avoid build-arg secrets; prefer BuildKit secret mounts when needed.

## Concurrency and publishing behavior

- Release workflows use non-cancelling concurrency groups.
- Deploy publishing uses per-project/per-environment concurrency groups (`cancel-in-progress: false`).
- Only target environment directory is replaced; other projects/environments are preserved.
- Commit happens only when directory content changes.

## Manual redeploy and promote patterns

- Manual redeploy: call `deploy-environment.yml` directly with an existing image version.
- Manual promotion: call `promote-release.yml` with `release-version` and `commit-sha` to retag existing SHA images.

## Suggested caller workflow (application repository)

```yaml
name: Release

on:
  push:
    branches: [main]
    tags: [v*]

jobs:
  release:
    uses: rafaelurben/cloud-deployments/.github/workflows/release.yml@main
    with:
      project-name: project1
      registry-host: registry.example.com
      deployment-repository: rafaelurben/cloud-deployments
      deployment-source-root: deploy
      deployment-target-root: projects
      compose-file: docker-compose.yml
      images: >-
        [{"context":"./services/api","dockerfile":"./services/api/Dockerfile","suffix":"-api"}]
      environments: >-
        {"dev":{"url":"https://dev.example.com","enabled":true},"test":{"url":"https://test.example.com","enabled":true},"prod":{"url":"https://app.example.com","enabled":false}}
    secrets:
      REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
      DEPLOYMENT_TOKEN: ${{ secrets.DEPLOYMENT_TOKEN }}
```

## PR validation recommendation

Use a separate PR workflow in application repositories to run tests and optionally call rendering/validation paths without publishing images or deployment directories.
