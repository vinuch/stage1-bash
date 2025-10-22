#!/usr/bin/env bash
# deploy.sh - Automated Dockerized app deploy to remote Linux server
# Requirements: bash, ssh, rsync, git, curl/wget (local)
# Notes: This script asks for secrets interactively and avoids echoing them to logs.

set -o errexit
set -o nounset
set -o pipefail

### Constants and defaults ###
LOG_DIR="${PWD}"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/deploy_${TIMESTAMP}.log"

DEFAULT_BRANCH="main"
SSH_TIMEOUT=10
RSYNC_OPTS="-az --delete --rsync-path='mkdir -p \"%s\" && rsync'"

# Exit codes (chosen for clarity)
EX_OK=0
EX_INVALID_ARGS=10
EX_CLONE_FAIL=20
EX_SSH_FAIL=30
EX_REMOTE_PREP_FAIL=40
EX_DEPLOY_FAIL=50
EX_NGINX_FAIL=60
EX_VALIDATION_FAIL=70
EX_CLEANUP_FAIL=80

### Logging helpers ###
log() {
  printf '%s %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE" >&2
}

log_debug() {
  [ "${DEBUG:-0}" -eq 1 ] && log "DEBUG: $*"
}

fail() {
  local rc=${1:-1}
  shift || true
  log "ERROR: $*"
  exit "$rc"
}

mask_token() {
  local t="$1"
  if [ -z "$t" ]; then
    echo ""
  else
    printf '%s' "${t:0:6}...${t: -4}"
  fi
}

### Trap / cleanup ###
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    log "Script exited with errors (code $rc). See ${LOG_FILE}."
  else
    log "Script completed successfully."
  fi
}
trap on_exit EXIT

### Argument parsing ###
CLEANUP_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP_MODE=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) echo "Usage: $0 [--cleanup] [--debug]"; exit 0 ;;
    *) echo "Unknown option: $1"; exit $EX_INVALID_ARGS ;;
  esac
done

### Interactive prompts (no repeating questions) ###
read_input() {
  local prompt="$1" varname="$2" required="${3:-1}" default="${4:-}"
  local value=""
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi
  # Use -r to avoid backslash escapes
  read -r value
  if [ -z "$value" ] && [ -n "$default" ]; then
    value="$default"
  fi
  if [ "$required" -eq 1 ] && [ -z "$value" ]; then
    fail $EX_INVALID_ARGS "Required value for ${varname} not provided."
  fi
  printf -v "$varname" '%s' "$value"
}

log "Starting deploy script. Log: ${LOG_FILE}"

read_input "Git repository URL (HTTPS, e.g. https://github.com/user/repo.git)" GIT_REPO 1
# PAT - hide echo
printf "Personal Access Token (PAT) (input is hidden): "
stty -echo
read -r GIT_PAT || true
stty echo
printf "\n"
if [ -z "$GIT_PAT" ]; then
  fail $EX_INVALID_ARGS "PAT is required for authenticated clone (private repos)."
fi

read_input "Branch name" GIT_BRANCH 0 "$DEFAULT_BRANCH"
read_input "Remote server SSH username" REMOTE_USER 1
read_input "Remote server IP / hostname" REMOTE_HOST 1
read_input "SSH key path (private key, e.g. ~/.ssh/id_rsa)" SSH_KEY_PATH 1
read_input "Application internal port (container listen port, e.g. 3000)" APP_PORT 1

# Derive app name and directory
REPO_BASENAME="$(basename -s .git "$GIT_REPO")"
LOCAL_CLONE_DIR="${PWD}/${REPO_BASENAME}"

# Basic validation
if [ ! -f "${SSH_KEY_PATH}" ]; then
  fail $EX_INVALID_ARGS "SSH key not found at ${SSH_KEY_PATH}"
fi

log "Parameters summary:"
log "  Repo: ${GIT_REPO}"
log "  Branch: ${GIT_BRANCH}"
log "  Remote: ${REMOTE_USER}@${REMOTE_HOST}"
log "  SSH key: ${SSH_KEY_PATH}"
log "  App internal port: ${APP_PORT}"
log "  Local clone dir: ${LOCAL_CLONE_DIR}"
log "  PAT (masked): $(mask_token "$GIT_PAT")"

### Helper: run SSH command (with strict args) ###
ssh_run() {
  local cmd="$1"
  ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT}" \
    "${REMOTE_USER}@${REMOTE_HOST}" "$cmd"
}

ssh_run_quiet() {
  local cmd="$1"
  ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT}" \
    "${REMOTE_USER}@${REMOTE_HOST}" "$cmd" >/dev/null 2>&1 || return 1
}

### Connectivity check ###
log "Checking SSH connectivity to ${REMOTE_USER}@${REMOTE_HOST}..."
if ! ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT}" "${REMOTE_USER}@${REMOTE_HOST}" "echo SSH_OK" >/dev/null 2>&1; then
  fail $EX_SSH_FAIL "Unable to SSH to ${REMOTE_USER}@${REMOTE_HOST} with supplied key."
fi
log "SSH connectivity OK."

### If cleanup mode requested, perform remote cleanup then exit ###
if [ "${CLEANUP_MODE}" -eq 1 ]; then
  log "Running cleanup mode: will attempt to remove deployed resources on remote host."
  REMOTE_APP_DIR="~/deployments/${REPO_BASENAME}"
  REMOTE_CONTAINER_NAME="${REPO_BASENAME}_app"
  CLEAN_CMD=$(cat <<EOF
set -e
echo "Stopping and removing containers named ${REMOTE_CONTAINER_NAME} (if exist)..."
docker ps -a --filter "name=${REMOTE_CONTAINER_NAME}" --format '{{.ID}}' | xargs -r docker rm -f || true
echo "Removing remote app dir ${REMOTE_APP_DIR}"
rm -rf "${REMOTE_APP_DIR}" || true
echo "Removing nginx site for ${REPO_BASENAME} (if exist)"
if [ -f /etc/nginx/sites-enabled/${REPO_BASENAME} ]; then
  sudo rm -f /etc/nginx/sites-enabled/${REPO_BASENAME} /etc/nginx/sites-available/${REPO_BASENAME} || true
  sudo nginx -t || true
  sudo systemctl reload nginx || true
fi
echo "Cleanup done."
EOF
)
  ssh_run "${CLEAN_CMD}" || fail $EX_CLEANUP_FAIL "Remote cleanup failed."
  log "Cleanup completed successfully."
  exit $EX_OK
fi

### Clone or update repository locally ###
log "Cloning or updating repository locally..."
if [ -d "${LOCAL_CLONE_DIR}/.git" ]; then
  log "Repository already exists locally. Fetching latest..."
  (
    cd "$LOCAL_CLONE_DIR"
    # Configure a temporary remote url containing token (do not log it)
    git remote set-url origin "${GIT_REPO}" || true
    # Use token for fetch via HTTPS by embedding (but be careful to not print)
    # We'll use env GIT_ASKPASS to provide token securely
    GIT_ASKPASS="$(mktemp)"
    cat >"$GIT_ASKPASS" <<EOF
#!/bin/sh
echo "${GIT_PAT}"
EOF
    chmod +x "$GIT_ASKPASS"
    GIT_ASKPASS="$GIT_ASKPASS" git fetch origin --depth=1 || { rm -f "$GIT_ASKPASS"; fail $EX_CLONE_FAIL "git fetch failed"; }
    rm -f "$GIT_ASKPASS"
    git checkout "${GIT_BRANCH}" || git checkout -b "${GIT_BRANCH}" "origin/${GIT_BRANCH}" || true
    git pull origin "${GIT_BRANCH}" || true
  )
else
  # Clone fresh
  GIT_ASKPASS="$(mktemp)"
  cat >"$GIT_ASKPASS" <<EOF
#!/bin/sh
echo "${GIT_PAT}"
EOF
  chmod +x "$GIT_ASKPASS"
  GIT_ASKPASS="$GIT_ASKPASS" git clone --depth=1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${LOCAL_CLONE_DIR}" || { rm -f "$GIT_ASKPASS"; fail $EX_CLONE_FAIL "git clone failed"; }
  rm -f "$GIT_ASKPASS"
fi
log "Local repository ready at ${LOCAL_CLONE_DIR}."

### Verify Dockerfile or docker-compose.yml exists ###
if [ -f "${LOCAL_CLONE_DIR}/Dockerfile" ]; then
  START_MODE="dockerfile"
  log "Found Dockerfile."
elif [ -f "${LOCAL_CLONE_DIR}/docker-compose.yml" ] || [ -f "${LOCAL_CLONE_DIR}/docker-compose.yaml" ]; then
  START_MODE="compose"
  log "Found docker-compose.yml."
else
  log "No Dockerfile or docker-compose.yml found in project root."
  # Perhaps project in subdir? try to detect typical dirs
  if [ -d "${LOCAL_CLONE_DIR}/deploy" ]; then
    log "Found deploy/ - using that folder by default."
    # Not changing START_MODE; will re-check when rsync'd remote
  else
    fail $EX_DEPLOY_FAIL "No Dockerfile or docker-compose.yml found. Cannot continue."
  fi
fi

### Prepare remote environment ###
REMOTE_APP_DIR="~/deployments/${REPO_BASENAME}"
REMOTE_CONTAINER_NAME="${REPO_BASENAME}_app"

log "Preparing remote server environment..."

REMOTE_PREP_CMDS=$(cat <<'EOF'
set -e
# Update packages
echo "Updating packages..."
if [ -x "$(command -v apt-get)" ]; then
  sudo apt-get update -y && sudo apt-get upgrade -y
elif [ -x "$(command -v yum)" ]; then
  sudo yum makecache -y
else
  echo "Unknown package manager; skipping package update"
fi

# Install docker if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  # Install generic Docker using get.docker.com for Ubuntu/CentOS family
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

# Install docker-compose as plugin or binary if missing
if ! docker compose version >/dev/null 2>&1; then
  echo "Installing docker-compose..."
  # Try plugin install
  sudo mkdir -p /usr/local/lib/docker/cli-plugins || true
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose || true
fi

# Install nginx if missing
if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  if [ -x "$(command -v apt-get)" ]; then
    sudo apt-get install -y nginx
  elif [ -x "$(command -v yum)" ]; then
    sudo yum install -y epel-release && sudo yum install -y nginx
  else
    echo "Unknown package manager; cannot auto-install nginx"
  fi
fi

# Add user to docker group if not already
if ! groups "$USER" | grep -q docker; then
  echo "Adding $USER to docker group (requires re-login to take effect)..."
  sudo usermod -aG docker "$USER" || true
fi

# Enable and start services
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable docker || true
  sudo systemctl start docker || true
  sudo systemctl enable nginx || true
  sudo systemctl start nginx || true
fi

# Print versions
echo "Docker version:"
docker --version || true
echo "Docker Compose version:"
docker compose version || true
echo "Nginx version:"
nginx -v || true

EOF
)

log "Running remote environment preparation..."
ssh_run "$REMOTE_PREP_CMDS" || fail $EX_REMOTE_PREP_FAIL "Remote environment preparation failed."

log "Remote environment prepared."

### Transfer project files ###
log "Transferring project files to remote: ${REMOTE_APP_DIR}"
# Create remote dir
ssh_run "mkdir -p ${REMOTE_APP_DIR}" || fail $EX_DEPLOY_FAIL "Failed to create remote app directory"

# Use rsync if available locally; fallback to scp for portability
if command -v rsync >/dev/null 2>&1; then
  # prepare rsync command - note: cannot directly format %s into remote path in string; use printf
  RSYNC_CMD="rsync -az --delete -e \"ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no\" \"${LOCAL_CLONE_DIR%/}/\" \"${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR%/}/\""
  log_debug "Running: ${RSYNC_CMD}"
  # shellcheck disable=SC2029,SC2086
  eval "${RSYNC_CMD}" | tee -a "${LOG_FILE}" || fail $EX_DEPLOY_FAIL "rsync failed"
else
  log "rsync not found locally, using scp (slower)."
  scp -i "${SSH_KEY_PATH}" -r "${LOCAL_CLONE_DIR}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}" || fail $EX_DEPLOY_FAIL "scp failed"
fi
log "Files transferred."

### Build and run containers remotely ###
log "Deploying application on remote host..."

REMOTE_BUILD_CMDS=$(cat <<EOF
set -e
cd ${REMOTE_APP_DIR}
# Stop and remove any previously-running container with same name
if docker ps -a --filter "name=${REMOTE_CONTAINER_NAME}" --format '{{.ID}}' | grep -q .; then
  echo "Stopping existing containers named ${REMOTE_CONTAINER_NAME}..."
  docker ps -a --filter "name=${REMOTE_CONTAINER_NAME}" --format '{{.ID}}' | xargs -r docker rm -f || true
fi

# Decide how to start app
if [ -f ./docker-compose.yml ] || [ -f ./docker-compose.yaml ]; then
  echo "Using docker-compose for deployment..."
  # Bring up
  docker compose pull || true
  docker compose up -d --remove-orphans --build
else
  if [ -f ./Dockerfile ]; then
    echo "Building image ${REMOTE_CONTAINER_NAME}:latest ..."
    docker build -t ${REMOTE_CONTAINER_NAME}:latest .
    # Remove existing same-name container and run new one
    docker run -d --name ${REMOTE_CONTAINER_NAME} -p ${APP_PORT}:${APP_PORT} --restart unless-stopped ${REMOTE_CONTAINER_NAME}:latest || true
  else
    echo "No Dockerfile or docker-compose found in remote dir. Aborting."
    exit 2
  fi
fi

# Wait for container health (if HEALTHCHECK present) or check up status
sleep 3
CONTAINER_IDS=\$(docker ps --filter "name=${REMOTE_CONTAINER_NAME}" --format '{{.ID}}')
if [ -z "\$CONTAINER_IDS" ]; then
  echo "No running container found for ${REMOTE_CONTAINER_NAME}"
  exit 3
fi

# If containers expose healthcheck, wait up to 30s
for cid in \$CONTAINER_IDS; do
  if docker inspect --format '{{json .State.Health}}' "\$cid" >/dev/null 2>&1; then
    echo "Container \$cid has healthcheck. Waiting for 'healthy' (up to 30s)..."
    tries=0
    until [ "\$(docker inspect --format '{{.State.Health.Status}}' \$cid)" = "healthy" ] || [ \$tries -ge 15 ]; do
      sleep 2
      tries=\$((tries+1))
    done
    echo "Health status: \$(docker inspect --format '{{.State.Health.Status}}' \$cid || true)"
  else
    echo "No healthcheck for container \$cid; skipping health wait."
  fi
done

echo "Deployment complete (containers running)."
EOF
)

# Replace placeholder APP_PORT with actual value in the remote command
REMOTE_BUILD_CMDS_WITH_PORT="$(printf '%s\n' "$REMOTE_BUILD_CMDS" | sed "s/\${APP_PORT}/${APP_PORT}/g" | sed "s/\${REMOTE_CONTAINER_NAME}/${REMOTE_CONTAINER_NAME}/g" )"

ssh_run "$REMOTE_BUILD_CMDS_WITH_PORT" || fail $EX_DEPLOY_FAIL "Remote build/deploy failed"

log "Containers deployed."

### Configure Nginx as reverse proxy ###
log "Configuring Nginx reverse proxy on remote..."

REMOTE_NGINX_CONF="/etc/nginx/sites-available/${REPO_BASENAME}"
REMOTE_NGINX_ENABLED="/etc/nginx/sites-enabled/${REPO_BASENAME}"

# Build nginx config (proxy http 80 to container internal port)
NGINX_CONF_CONTENT=$(cat <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_read_timeout 90;
        proxy_connect_timeout 5s;
    }
}
EOF
)

# Use a heredoc to create the remote config securely
SSH_NGINX_CMDS=$(cat <<EOF
set -e
echo "Writing nginx config to ${REMOTE_NGINX_CONF} ..."
sudo bash -c 'cat > "${REMOTE_NGINX_CONF}" <<'NGCONF'
${NGINX_CONF_CONTENT}
NGCONF
sudo ln -sf "${REMOTE_NGINX_CONF}" "${REMOTE_NGINX_ENABLED}"
sudo nginx -t
sudo systemctl reload nginx || true
echo "Nginx proxied to 127.0.0.1:${APP_PORT}"
EOF
)

# send commands, but avoid exposing token; safe to run
ssh_run "$SSH_NGINX_CMDS" || fail $EX_NGINX_FAIL "Nginx configuration failed"

log "Nginx configured."

### Validation ###
log "Validating deployment..."

# 1) Check Docker running on remote
if ! ssh_run_quiet "docker info >/dev/null 2>&1"; then
  fail $EX_VALIDATION_FAIL "Docker not responding on remote."
fi
log "Docker is running on remote."

# 2) Check container running
CNT_CHECK_CMD="docker ps --format '{{.Names}} {{.Ports}}' | grep -E '^${REMOTE_CONTAINER_NAME}' || true"
CNT_INFO="$(ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT}" "${REMOTE_USER}@${REMOTE_HOST}" "${CNT_CHECK_CMD}")"
if [ -z "$CNT_INFO" ]; then
  fail $EX_VALIDATION_FAIL "Target container ${REMOTE_CONTAINER_NAME} not running on remote. Check logs."
fi
log "Container is running: ${CNT_INFO}"

# 3) Test HTTP locally on remote (curl)
REMOTE_CURL_CMD="curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT} || true"
HTTP_STATUS_REMOTE="$(ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT}" "${REMOTE_USER}@${REMOTE_HOST}" "${REMOTE_CURL_CMD}")"
log "Remote HTTP status to 127.0.0.1:${APP_PORT} -> ${HTTP_STATUS_REMOTE}"

# 4) Test via nginx public (from local)
HTTP_STATUS_PUBLIC="$(curl -s -o /dev/null -w '%{http_code}' "http://${REMOTE_HOST}/" || true)"
log "Public HTTP status via nginx -> ${HTTP_STATUS_PUBLIC}"

if [ "$HTTP_STATUS_REMOTE" = "000" ] || [ -z "$HTTP_STATUS_REMOTE" ]; then
  log "Warning: could not fetch internal app endpoint on remote. It might still be starting."
fi

if [ "$HTTP_STATUS_PUBLIC" = "000" ] || [ -z "$HTTP_STATUS_PUBLIC" ]; then
  log "Warning: could not fetch public endpoint via nginx. Firewall / security groups might be blocking port 80."
else
  log "Public endpoint returned HTTP ${HTTP_STATUS_PUBLIC}"
fi

### Provide container logs for quick debugging ###
log "Fetching last 200 lines of container logs (if available)..."
ssh_run "docker logs --tail 200 ${REMOTE_CONTAINER_NAME} || true" | tee -a "${LOG_FILE}" || true

log "Deployment validation steps completed. Check above outputs and ${LOG_FILE} for details."

exit $EX_OK
