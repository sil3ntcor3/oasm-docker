# Administrator provisioning

Open-ASM creates its first administrator through a one-time container process
run from the deployment host. The public API does not expose an administrator
creation endpoint, and the browser never accepts a bootstrap token or initial
administrator credentials.

Only the `oasm-docker` repository and published container images are required.
The Open-ASM source repository is not needed on the deployment host.

## Prerequisites

- Docker Engine with the Compose plugin
- Bash
- A clone of `oasm-docker`
- Permission to control Docker on the deployment host

Docker control is the authorization boundary for initial provisioning. Anyone
who can control the Docker daemon can already control the application
containers and their data. Run provisioning only as a trusted host operator.

## Prepare the deployment

From the `oasm-docker` directory, create the local configuration files:

```bash
cp .env.example .env
cp provider-config.example.yaml provider-config.yaml
chmod 600 .env provider-config.yaml
```

At minimum, set these values in `.env` before installation:

- `IMAGE_TAG`: an Open-ASM image release that contains the administrator
  provisioner.
- `BETTER_AUTH_SECRET`: a unique, persistent secret of at least 32 characters.
- `BETTER_AUTH_URL`: the public console origin, including its scheme and port.
  The local default is `http://localhost:9090`.
- `WORKER_ENROLLMENT_TOKEN`: a unique secret of at least 32 characters.
- PostgreSQL, Redis, and RustFS credentials appropriate for the deployment.

A suitable authentication secret can be generated with:

```bash
openssl rand -hex 32
```

Store `BETTER_AUTH_SECRET` securely and keep it stable between updates. Changing
it invalidates existing authentication state. When changing `REDIS_PASSWORD`,
also update the password embedded in `REDIS_URL`. Do not commit `.env` or a
populated provider configuration.

## Install and create the first administrator

Run:

```bash
./install.sh
```

The equivalent Make target is:

```bash
make install
```

The installer performs these operations in order:

1. Reads `.env` from the `oasm-docker` checkout and validates the rendered
   Compose configuration.
2. Pulls the configured published images.
3. Verifies that the selected API image contains the private provisioning
   entry point before starting deployment services.
4. Starts PostgreSQL and Redis and waits for them to become healthy.
5. Applies all pending database migrations.
6. Prompts for the first administrator email, password, and password
   confirmation.
7. Pipes the email and password over standard input to the profile-gated
   `admin-provisioner` container.
8. Starts the complete Open-ASM deployment after provisioning succeeds.

The password prompts are hidden. The password is not placed in a command-line
argument, environment variable, Compose file, URL, or Docker log. The
provisioner has no published port, uses a read-only root filesystem, drops all
Linux capabilities, exits after creating the account, and is removed by the
installer.

If the images have already been pulled, use:

```bash
./install.sh --no-pull
```

To use another Compose environment file, use:

```bash
./install.sh --env-file /secure/path/oasm.env
```

## Verify the installation

Check the running services:

```bash
docker compose --env-file .env ps
```

Check the API health and initialization state through the console proxy:

```bash
curl -fsS http://localhost:9090/api/health
curl -fsS http://localhost:9090/api/metadata
```

The metadata response must contain `"isInit":true`. Confirm that the retired
public administrator endpoint is absent:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST http://localhost:9090/api/init-admin
```

The expected status is `404`. Initial administrator creation is not an HTTP
operation. Sign in at `http://localhost:9090` using the credentials entered in
the deployment terminal.

## One-time and concurrent behavior

The provisioner acquires a PostgreSQL advisory transaction lock before checking
for an existing administrator. Concurrent provisioning attempts are
serialized, and only the first can create an account. Once any administrator
exists, all later provisioning attempts are refused without changing the
existing account.

Do not rerun the installer merely to start or update an initialized deployment.
Use the normal Compose or Make workflow instead:

```bash
docker compose --env-file .env up -d
# or
make run
```

## Failure and recovery

If installation fails before it reports that the administrator was created,
correct the reported image, environment, database, or migration problem and
run the installer again.

If the administrator was created but a later service fails to start, do not
rerun provisioning. Start or troubleshoot the existing deployment:

```bash
docker compose --env-file .env up -d
docker compose --env-file .env ps
docker compose --env-file .env logs core-api
```

If the provisioner reports that an administrator already exists, it will not
overwrite that account or create a second one. Sign in with the existing
credentials. Account recovery must use an authenticated administrator or a
verified backup/recovery process; there is intentionally no unauthenticated
bootstrap bypass.

For a new disposable installation with no data worth retaining, the operator
may remove the deployment and its volumes before reinstalling. Removing volumes
permanently deletes application data. Back up the deployment and verify the
exact Compose project before taking that action.

## Updating an existing deployment

Updates do not run the administrator provisioner. Pull the new images, apply
migrations, and restart using the normal deployment workflow:

```bash
make update
```

When upgrading an older deployment, add and preserve `BETTER_AUTH_SECRET` in
`.env` before starting an image that requires it. If an administrator already
exists, do not run `install.sh`.

## Security properties

- No public route creates the first administrator.
- Public email-and-password sign-up is disabled by the API image.
- Provisioning requires Docker-host control and runs on the private Compose
  network.
- Initial credentials travel only over the one-shot process standard input.
- PostgreSQL serialization prevents concurrent first-administrator creation.
- The provisioner refuses to run after initialization and never changes an
  existing administrator.
