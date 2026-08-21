# Open Attack Surface Management (OASM) Platform

## 🛠 Prerequisites

- Docker
- Docker Compose
- Make
- Bash
- Minimum System Requirements:
  - 4 CPU cores
  - 4GB RAM
  - 20GB free disk space

## 🚀 Try it now

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://github.com/codespaces/new/oasm-platform/oasm-docker?skip_quickstart=true&machine=standardLinux32gb&repo=1080874592&ref=main)

## ⚡ Quick Start

1. **Prepare configuration**:

   ```bash
   cp .env.example .env
   cp provider-config.example.yaml provider-config.yaml
   chmod 600 provider-config.yaml
   ```

   Add credentials only for the Subfinder providers you use. The populated
   `provider-config.yaml` file is ignored by Git.

2. Set unique deployment secrets in `.env`. In particular, configure
   `BETTER_AUTH_SECRET`, `BETTER_AUTH_URL`, and `WORKER_ENROLLMENT_TOKEN`.

3. **Install and create the first administrator**:

   ```bash
   ./install.sh
   ```

   The installer pulls the published images, starts the database, applies
   migrations, and prompts privately for the initial administrator credentials.
   The Open-ASM source repository is not required.

See [Administrator provisioning](docs/administrator-provisioning.md) for the
complete installation, verification, recovery, and update process.

## 🔗 Access the Platform

Web Console: http://localhost:9090

## 📋 Configuration

Edit the `.env` file to customize your deployment:

- `IMAGE_TAG`: Docker image version (default: `latest`)
- `BETTER_AUTH_SECRET`: persistent application authentication secret
- `BETTER_AUTH_URL`: public console origin used by authentication
- `WORKER_ENROLLMENT_TOKEN`: shared API/worker enrollment secret
- `POSTGRES_*`: Database connection settings
- `REDIS_PASSWORD`: Redis authentication password
- `LLM_*`: AI assistant configuration (if enabled)
- `SUBFINDER_PROVIDER_CONFIG_PATH`: Host path to the Subfinder provider
  configuration (default: `./provider-config.yaml`)

### Subfinder provider credentials

The populated provider configuration is mounted read-only into every worker at
`/run/secrets/subfinder-provider-config.yaml`. It is not passed as an
environment-variable value and is not stored in the worker image.

Simple provider credentials use one YAML list entry per key:

```yaml
securitytrails:
  - SECURITYTRAILS_API_KEY
github:
  - GITHUB_TOKEN
```

Providers requiring multiple values use one colon-delimited entry:

```yaml
censys:
  - "API_ID:API_SECRET"
fofa:
  - "EMAIL:API_KEY"
```

To keep the populated file outside this repository, set an absolute host path
in `.env`:

```dotenv
SUBFINDER_PROVIDER_CONFIG_PATH=/etc/oasm/subfinder/provider-config.yaml
```

On native Linux hosts, make the file readable by the UID/GID used by the worker
container while denying access to unrelated users. Recreate the workers after
rotating credentials so every replica opens the replacement file.

## 🔧 Useful Commands

```bash
# View all logs
docker compose logs -f

# Stop all services
docker compose down

# Scale worker instances
docker compose up --scale oasm-worker=5
```

## 🛠️ Make Commands

| Command                 | Description                                                                |
| ----------------------- | -------------------------------------------------------------------------- |
| `make install`          | One-time installation and first-administrator provisioning                |
| `make` or `make all`    | Default target - pulls latest images and runs the full system              |
| `make pull`             | Pull the latest images from both docker-compose files (main and assistant) |
| `make run`              | Run services (without pulling new images)                                  |
| `make update`           | Pull new images and restart both compose files (main and assistant)        |
| `make update-main`      | Update only main services                                                  |
| `make update-assistant` | Update only assistant services (assistant, searxng)                        |
| `make down`             | Stop all services                                                          |
| `make clean`            | Clean up everything (stop services and remove volumes)                     |

---

**Note**: This platform is designed for authorized security testing only. Always ensure you have proper authorization before scanning systems you don't own.
