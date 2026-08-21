#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
provider_config=$(mktemp)
compose_env=$(mktemp)
rendered_config=$(mktemp)

cleanup() {
  rm -f "$provider_config" "$compose_env" "$rendered_config"
}
trap cleanup EXIT HUP INT TERM

credential_sentinel='must-not-appear-in-rendered-compose-config'

cat >"$provider_config" <<EOF
securitytrails:
  - $credential_sentinel
EOF

cat >"$compose_env" <<EOF
BETTER_AUTH_SECRET=test-auth-secret-with-at-least-32-characters
WORKER_ENROLLMENT_TOKEN=test-enrollment-token-with-at-least-32-characters
REDIS_PASSWORD=test-redis-password
SUBFINDER_PROVIDER_CONFIG_PATH=$provider_config
EOF

docker compose \
  --env-file "$compose_env" \
  -f "$repo_root/docker-compose.yml" \
  config \
  --format json >"$rendered_config"

python3 - "$rendered_config" "$provider_config" "$credential_sentinel" <<'PY'
import json
import os
import sys

rendered_path, provider_path, credential_sentinel = sys.argv[1:]

with open(rendered_path, encoding='utf-8') as rendered_file:
    rendered_text = rendered_file.read()

if credential_sentinel in rendered_text:
    raise AssertionError('provider credentials leaked into rendered Compose configuration')

compose = json.loads(rendered_text)
worker = compose['services']['oasm-worker']
expected_target = '/run/secrets/subfinder-provider-config.yaml'

actual_target = worker['environment'].get('SUBFINDER_PROVIDER_CONFIG')
if actual_target != expected_target:
    raise AssertionError(
        f'SUBFINDER_PROVIDER_CONFIG must be {expected_target!r}, got {actual_target!r}'
    )

provider_mounts = [
    mount
    for mount in worker.get('volumes', [])
    if mount.get('target') == expected_target
]
if len(provider_mounts) != 1:
    raise AssertionError(
        f'expected exactly one provider configuration mount, got {provider_mounts!r}'
    )

provider_mount = provider_mounts[0]
actual_source = provider_mount.get('source')
if provider_mount.get('type') != 'bind':
    raise AssertionError('provider configuration must use a bind mount')
if not actual_source or not os.path.samefile(actual_source, provider_path):
    raise AssertionError(
        f'provider configuration source must reference {provider_path!r}, '
        f'got {actual_source!r}'
    )
if provider_mount.get('read_only') is not True:
    raise AssertionError('provider configuration mount must be read-only')
if provider_mount.get('bind', {}).get('create_host_path') is not False:
    raise AssertionError('provider configuration mount must not auto-create a missing path')
PY

git -C "$repo_root" check-ignore --quiet provider-config.yaml

echo 'Subfinder provider configuration Compose checks passed.'
