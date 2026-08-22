#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deployment_env_file="${script_directory}/.env"
pull_images=true

usage() {
  printf '%s\n' 'Usage: ./install.sh [--no-pull] [--env-file PATH]'
  printf '%s\n' '  --no-pull       Use container images already present on the host.'
  printf '%s\n' '  --env-file PATH Use a Compose environment file other than ./.env.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)
      pull_images=false
      shift
      ;;
    --env-file)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      deployment_env_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "${deployment_env_file}" ]]; then
  printf 'Missing %s. Copy .env.example to .env and configure it first.\n' \
    "${deployment_env_file}" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' 'Docker is required to install Open-ASM.' >&2
  exit 1
fi

compose() {
  docker compose \
    --env-file "${deployment_env_file}" \
    -f "${script_directory}/docker-compose.yml" \
    "$@"
}

compose version >/dev/null
compose config --quiet

if [[ "${pull_images}" == true ]]; then
  printf '%s\n' 'Pulling Open-ASM images...'
  compose pull
fi

if ! compose --profile setup run --rm -T --no-deps \
  --entrypoint /bin/sh admin-provisioner \
  -c 'test -f /app/dist/provision-admin.js'; then
  printf '%s\n' \
    'The selected API image does not support private administrator provisioning. Select a current IMAGE_TAG and try again.' >&2
  exit 1
fi

printf '%s\n' 'Starting the database and applying migrations...'
compose up -d --wait postgres redis

# The migration service runs `typeorm migration:run`, and that CLI overrides the
# DataSource with logging: ["query", "error", "schema"], so every DDL statement of
# every migration is echoed. Attaching to it buries the installer under hundreds of
# lines of SQL that say nothing about whether the install is going well. Start it
# detached instead and wait on the container, which also fixes the exit status:
# an attached `compose up` returns 0 even when the container it ran exits non-zero,
# so a failed migration used to sail straight past `set -e` into admin provisioning.
compose up -d --no-deps migration
migration_container="$(compose ps --all --quiet migration)"
if [[ -z "${migration_container}" ]]; then
  printf '%s\n' 'The migration container did not start.' >&2
  exit 1
fi
if [[ "$(docker wait "${migration_container}")" != '0' ]]; then
  printf '%s\n' 'Database migrations failed. Full migration output follows.' >&2
  docker logs "${migration_container}" >&2
  exit 1
fi

IFS= read -r -p 'Administrator email: ' admin_email
IFS= read -r -s -p 'Administrator password: ' admin_password
printf '\n'
IFS= read -r -s -p 'Confirm administrator password: ' admin_password_confirmation
printf '\n'

if [[ -z "${admin_email}" ]]; then
  printf '%s\n' 'Administrator email is required.' >&2
  exit 1
fi
if [[ "${admin_password}" != "${admin_password_confirmation}" ]]; then
  printf '%s\n' 'Administrator passwords do not match.' >&2
  exit 1
fi
if (( ${#admin_password} < 8 || ${#admin_password} > 128 )); then
  printf '%s\n' 'Administrator password must be between 8 and 128 characters.' >&2
  exit 1
fi

printf '%s\n' 'Creating the administrator account...'
printf '%s\n%s\n' "${admin_email}" "${admin_password}" | \
  compose --profile setup run --rm -T --no-deps admin-provisioner
unset admin_password admin_password_confirmation

printf '%s\n' 'Starting Open-ASM...'
compose up -d
printf '%s\n' 'Open-ASM is ready. Sign in through the deployment console (default: http://localhost:9090).'
