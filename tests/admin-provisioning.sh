#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer="$repo_root/install.sh"
temp_dir=$(mktemp -d)
compose_env="$temp_dir/deployment.env"
provider_config="$temp_dir/provider-config.yaml"
rendered_config="$temp_dir/compose.json"
docker_log="$temp_dir/docker.log"
provisioner_input="$temp_dir/provisioner-input"
fake_bin="$temp_dir/bin"

cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$installer" ]; then
  echo 'install.sh must exist and be executable in the oasm-docker repository.' >&2
  exit 1
fi

mkdir -p "$fake_bin"
printf '%s\n' '{}' >"$provider_config"
cat >"$compose_env" <<EOF
IMAGE_TAG=dev
BETTER_AUTH_SECRET=test-auth-secret-with-at-least-32-characters
BETTER_AUTH_URL=http://localhost:9090
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=test-postgres-password
POSTGRES_PORT=5432
POSTGRES_DB=open_asm
POSTGRES_SSL=false
REDIS_PASSWORD=test-redis-password
REDIS_URL=redis://:test-redis-password@redis:6379/0
RUSTFS_ACCESS_KEY=test-rustfs-access-key
RUSTFS_SECRET_KEY=test-rustfs-secret-key
WORKER_ENROLLMENT_TOKEN=test-enrollment-token-with-at-least-32-characters
SUBFINDER_PROVIDER_CONFIG_PATH=$provider_config
EOF

COMPOSE_PROFILES=setup docker compose \
  --env-file "$compose_env" \
  -f "$repo_root/docker-compose.yml" \
  config \
  --format json >"$rendered_config"

python3 - "$rendered_config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as rendered_file:
    compose = json.load(rendered_file)

services = compose['services']
provisioner = services.get('admin-provisioner')
if provisioner is None:
    raise AssertionError('admin-provisioner service is missing')
if provisioner.get('profiles') != ['setup']:
    raise AssertionError('admin-provisioner must require the setup profile')
if provisioner.get('ports', []) != []:
    raise AssertionError('admin-provisioner must not publish ports')
if provisioner.get('volumes', []) != []:
    raise AssertionError('admin-provisioner must not mount application source')
if provisioner.get('build') is not None:
    raise AssertionError('admin-provisioner must use a published image')
if provisioner.get('command') != ['node', 'dist/provision-admin.js']:
    raise AssertionError('admin-provisioner must run the image provisioner entry point')
if provisioner.get('image') != services['core-api'].get('image'):
    raise AssertionError('admin-provisioner and core-api must use the same image')
if provisioner.get('read_only') is not True:
    raise AssertionError('admin-provisioner root filesystem must be read-only')
if provisioner.get('cap_drop') != ['ALL']:
    raise AssertionError('admin-provisioner must drop all Linux capabilities')
if 'no-new-privileges:true' not in provisioner.get('security_opt', []):
    raise AssertionError('admin-provisioner must prevent privilege escalation')

environment = provisioner.get('environment', {})
for required_name in (
    'BETTER_AUTH_SECRET',
    'BETTER_AUTH_URL',
    'POSTGRES_HOST',
    'POSTGRES_USERNAME',
    'POSTGRES_PASSWORD',
    'POSTGRES_PORT',
    'POSTGRES_DB',
    'POSTGRES_SSL',
    'REDIS_URL',
):
    if required_name not in environment:
        raise AssertionError(f'admin-provisioner is missing {required_name}')
for unrelated_name in ('OASM_CLOUD_APIKEY', 'RUSTFS_SECRET_KEY', 'WORKER_ENROLLMENT_TOKEN'):
    if unrelated_name in environment:
        raise AssertionError(f'admin-provisioner must not receive {unrelated_name}')

core_environment = services['core-api'].get('environment', {})
if core_environment.get('BETTER_AUTH_SECRET') != environment['BETTER_AUTH_SECRET']:
    raise AssertionError('core-api and provisioner must share BETTER_AUTH_SECRET')
if core_environment.get('REDIS_URL') != environment['REDIS_URL']:
    raise AssertionError('core-api and provisioner must share REDIS_URL')
if services['migration'].get('environment', {}).get('REDIS_URL') != core_environment.get('REDIS_URL'):
    raise AssertionError('core-api and migration must share REDIS_URL')
if provisioner.get('depends_on', {}).get('redis', {}).get('condition') != 'service_healthy':
    raise AssertionError('admin-provisioner must wait for healthy Redis')
rustfs_environment = services['rustfs'].get('environment', {})
for credential_name in ('RUSTFS_ACCESS_KEY', 'RUSTFS_SECRET_KEY'):
    if core_environment.get(credential_name) != rustfs_environment.get(credential_name):
        raise AssertionError(f'core-api and RustFS must share {credential_name}')
PY

cat >"$fake_bin/docker" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$OASM_TEST_DOCKER_LOG"
case "$*" in
  *'--entrypoint /bin/sh admin-provisioner'*) : ;;
  *admin-provisioner*) cat >"$OASM_TEST_PROVISIONER_INPUT" ;;
esac
SH
chmod 755 "$fake_bin/docker"

password='correct horse battery staple'
PATH="$fake_bin:$PATH" \
OASM_TEST_DOCKER_LOG="$docker_log" \
OASM_TEST_PROVISIONER_INPUT="$provisioner_input" \
"$installer" --no-pull --env-file "$compose_env" <<EOF
admin@example.com
$password
$password
EOF

if grep -Fq "$password" "$docker_log"; then
  echo 'administrator password leaked into a Docker command' >&2
  exit 1
fi
grep -F -- '--entrypoint /bin/sh admin-provisioner -c test -f /app/dist/provision-admin.js' "$docker_log" >/dev/null
grep -F -- '--profile setup run --rm -T --no-deps admin-provisioner' "$docker_log" >/dev/null
printf 'admin@example.com\n%s\n' "$password" | cmp -s - "$provisioner_input"

echo 'Administrator provisioning deployment checks passed.'
