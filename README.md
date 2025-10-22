# `README.md`

````markdown
# deploy.sh — Automated Docker Deploy to Remote Linux Host

This repository provides `deploy.sh`, an interactive Bash script that automates deploying a Dockerized application to a remote Linux server. The script:

- Prompts for repository URL, PAT, branch, SSH credentials, and application port
- Clones (or pulls) the Git repository locally
- Validates presence of `Dockerfile` or `docker-compose.yml`
- SSHes into the remote host to prepare environment (Docker, Docker Compose, nginx)
- Transfers files via `rsync` (or `scp`) and builds/starts containers
- Configures `nginx` as a reverse proxy (listening on port 80)
- Performs validation checks and logs everything to a timestamped logfile
- Supports `--cleanup` to remove deployed resources

> **Important:** This script is intended for Linux remote servers with `systemd` and a standard package manager (`apt`/`yum`). It uses `curl` to install Docker if missing. Adjust to your distro/policy as required.

## Requirements (local)
- `bash` (script written for Bash)
- `git`
- `ssh` and `scp` (or `rsync` for faster transfer)
- `rsync` (recommended but optional)
- `curl` (for some checks)

## Requirements (remote)
- A Linux server reachable via SSH
- The SSH user must have `sudo` rights to install packages / reload nginx
- Ports: 22 (ssh), 80 (http) accessible (or adjust firewall accordingly)

## Usage

Make the script executable:

```bash
chmod +x deploy.sh
````

Run interactive deploy:

```bash
./deploy.sh
```

Optional flags:

* `--cleanup` — Remove deployed resources (containers, app directory, nginx config) on remote and exit.
* `--debug` — Show extra debug logs.

Example:

```bash
./deploy.sh --debug
# or cleanup
./deploy.sh --cleanup
```

## How it works (high level)

1. Prompts you for:

   * Git repo URL (HTTPS)
   * Personal Access Token (PAT) — hidden input
   * Branch (defaults to `main`)
   * Remote SSH username, host, private key path
   * Internal application port (container listens on this port)

2. Clones or updates the repo locally, checks for `Dockerfile` or `docker-compose.yml`.

3. Prepares remote server:

   * Updates packages
   * Installs Docker via `get.docker.com` if missing
   * Installs `docker-compose` CLI plugin if needed
   * Installs `nginx` if needed
   * Enables/starts services

4. Transfers project files (rsync preferred), builds images and starts containers (compose or docker run).

5. Writes an nginx config to `/etc/nginx/sites-available/<repo>` and enables it, proxying port 80 to the application port.

6. Validates Docker, container presence, and performs HTTP checks internally and externally.

7. Writes a comprehensive log file `deploy_YYYYMMDD_HHMMSS.log` in the working directory.

## Notes & Security

* The script temporarily uses a helper to supply the PAT to `git` (`GIT_ASKPASS`) and cleans it up. The PAT is not printed to logs, but treat it carefully and revoke it if compromise suspected.
* The script runs commands on a remote host with `sudo`. Ensure the SSH user is permitted to `sudo`.
* The nginx configuration created uses `server_name _;` (catch-all). If you have a specific domain, adjust the server_name and consider adding SSL (Certbot). The script includes a placeholder mention about SSL readiness.
* Idempotency: the script stops/removes existing container(s) with the same name before deploying. Re-running is safe.

## Exit codes

* `0` success
* `10` invalid args
* `20` git clone/fetch failure
* `30` ssh/connectivity failure
* `40` remote prep failure
* `50` deploy failure
* `60` nginx failure
* `70` validation failure
* `80` cleanup failure

## Troubleshooting

* If nginx fails to reload, check `sudo journalctl -u nginx -n 200` on the remote.
* Container not starting: see `docker logs <container>` on the remote (the script prints last 200 lines to the log).
* Firewall/security group may block external port 80 — ensure it's open.

## Extensibility

* Add optional SSL automation via Certbot when you have a domain.
* Add environment variable secret transfer (e.g., from Vault or encrypted files).
* Integrate with CI to run this from a pipeline instead of locally.

---

If you want, I can:

* Add SSL automation (Certbot + Let's Encrypt) if you provide a domain.
* Make a non-interactive mode that accepts all variables via environment variables or CLI flags for CI.
* Add more robust distro detection and package manager handling.

```

---

## Final notes

- Save `deploy.sh` and `README.md` to your repository, `chmod +x deploy.sh`, then run `./deploy.sh`.
- If you want a non-interactive/CI-capable version (all inputs passed via flags or env vars), tell me the expected environment and I’ll produce it next.
```
