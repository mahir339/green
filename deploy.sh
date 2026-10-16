
#!/usr/bin/env bash
set -Eeuo pipefail

# Blue-Green deployment configuration
APP_DIR="$HOME/green"
STATE_FILE="$APP_DIR/deployment.state"
LOG_DIR="$APP_DIR/logs"
LOG_FILE="$LOG_DIR/deployment.log"

PORT_MIN=2000
PORT_MAX=2100

# This deployment uses Nginx on port 8080 to avoid
# changing an unrelated existing Nginx site on port 80.
NGINX_PORT=8080
NGINX_CONF="/etc/nginx/conf.d/blue-green.conf"

ACTIVE_NAME="green"
CANDIDATE_NAME="blue"
IMAGE_NAME="green-app"
PREVIOUS_NAME="green-previous"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_commands() {
    local command_name
    for command_name in docker curl ss shuf; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required command not found: $command_name"
    done

    command -v nginx >/dev/null 2>&1 ||
        die "Nginx is not installed or nginx is not in PATH"

    sudo -n true ||
        die "Deployment user needs non-interactive sudo permissions for Nginx operations"
}

container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

port_in_use() {
    local port="$1"

    # Check host listening sockets.
    if ss -H -ltn "sport = :$port" | grep -q .; then
        return 0
    fi

    # Check Docker-published ports, including containers that may
    # not be represented clearly by the host socket listing.
    if docker ps -a --format '{{.Ports}}' |
        grep -Eq "(^|[,: ])(0\\.0\\.0\\.0:|127\\.0\\.0\\.1:|\\[::\\]:)?${port}->"; then
        return 0
    fi

    return 1
}

find_available_port() {
    local port
    local attempts=0

    while (( attempts < 300 )); do
        port="$(shuf -i "$PORT_MIN-$PORT_MAX" -n 1)"

        if ! port_in_use "$port"; then
            log "Selected available port: $port"
            printf '%s\n' "$port"
            return 0
        fi

        attempts=$((attempts + 1))
    done

    die "Could not find a free port between $PORT_MIN and $PORT_MAX"
}

wait_for_health() {
    local port="$1"
    local attempt

    log "Checking application health on port $port"

    for attempt in $(seq 1 30); do
        if curl --fail --silent --show-error \
            --max-time 2 "http://127.0.0.1:$port/" >/dev/null 2>&1; then
            log "Application is healthy on port $port"
            return 0
        fi

        sleep 2
    done

    return 1
}

write_nginx_config() {
    local port="$1"
    local temporary_file

    temporary_file="$(mktemp)"

    cat > "$temporary_file" <<EOF
server {
    listen ${NGINX_PORT};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    sudo -n install -m 0644 "$temporary_file" "$NGINX_CONF"
    rm -f "$temporary_file"
}

reload_nginx() {
    sudo -n nginx -t
    sudo -n systemctl reload nginx
}

save_state() {
    local port="$1"
    local temporary_file

    temporary_file="$(mktemp "$APP_DIR/.deployment.state.XXXXXX")"

    {
        printf 'ACTIVE_SLOT=green\n'
        printf 'ACTIVE_PORT=%s\n' "$port"
    } > "$temporary_file"

    chmod 600 "$temporary_file"
    mv -f "$temporary_file" "$STATE_FILE"
}

rollback_nginx() {
    log "Restoring the previous Nginx configuration"

    if [[ -n "${OLD_CONFIG_BACKUP:-}" && -f "$OLD_CONFIG_BACKUP" ]]; then
        sudo -n cp "$OLD_CONFIG_BACKUP" "$NGINX_CONF"
        reload_nginx || log "WARNING: Nginx reload failed during rollback"
    else
        log "No previous Nginx configuration backup is available"
    fi
}

cleanup_candidate() {
    if container_exists "$CANDIDATE_NAME"; then
        log "Removing failed candidate container"
        docker rm -f "$CANDIDATE_NAME" || true
    fi
}

deploy() {
    local candidate_port
    local active_port=""
    local old_config_backup=""
    local had_previous_config=0
    local previous_state_backup=""
    local bootstrap=0
    local switched=0

    cd "$APP_DIR"

    require_commands

    [[ -f Dockerfile ]] || die "Dockerfile not found in $APP_DIR"
    [[ -f index.html ]] || die "index.html not found"
    [[ -f index-v2.html ]] || die "index-v2.html not found"

    # Refuse to overwrite an unexpected container.
    if container_exists "$CANDIDATE_NAME"; then
        die "Container '$CANDIDATE_NAME' already exists; investigate before continuing"
    fi

    if container_exists "$PREVIOUS_NAME"; then
        die "Container '$PREVIOUS_NAME' already exists; investigate before continuing"
    fi

    # Bootstrap the stable Version 1 container on the first run.
    if ! container_exists "$ACTIVE_NAME"; then
        bootstrap=1
        log "No active Green container found; bootstrapping Version 1"

        local bootstrap_port
        bootstrap_port="$(find_available_port | tail -n 1)"

        docker build \
            --build-arg APP_FILE=index.html \
            -t "${IMAGE_NAME}:v1" .

        docker run -d \
            --name "$ACTIVE_NAME" \
            --restart unless-stopped \
            -p "${bootstrap_port}:80" \
            "${IMAGE_NAME}:v1"

        if ! wait_for_health "$bootstrap_port"; then
            docker rm -f "$ACTIVE_NAME" || true
            die "Version 1 bootstrap health check failed"
        fi

        write_nginx_config "$bootstrap_port"
        reload_nginx

        if ! curl --fail --silent \
            "http://127.0.0.1:${NGINX_PORT}/" >/dev/null; then
            docker rm -f "$ACTIVE_NAME" || true
            die "Nginx could not reach the bootstrap application"
        fi

        save_state "$bootstrap_port"
        log "Version 1 is now the stable Green deployment"
    fi

    # Read the actual published port from the active container.
    active_port="$(
        docker port "$ACTIVE_NAME" 80/tcp |
        head -n 1 |
        awk -F: '{print $NF}'
    )"

    [[ "$active_port" =~ ^[0-9]+$ ]] ||
        die "Could not determine the active Green container port"

    log "Current Green deployment is running on port $active_port"

    # Preserve the current Nginx configuration for rollback.
    if sudo -n test -f "$NGINX_CONF"; then
        old_config_backup="$(mktemp)"
        sudo -n cp "$NGINX_CONF" "$old_config_backup"
        had_previous_config=1
    fi

    # Choose a fresh port and deploy the incoming Version 2 container.
    candidate_port="$(find_available_port | tail -n 1)"

    docker build \
        --build-arg APP_FILE=index-v2.html \
        -t "${IMAGE_NAME}:incoming" .

    docker run -d \
        --name "$CANDIDATE_NAME" \
        --restart unless-stopped \
        -p "${candidate_port}:80" \
        "${IMAGE_NAME}:incoming"

    if ! wait_for_health "$candidate_port"; then
        cleanup_candidate
        die "Candidate health check failed; active Green remains unchanged"
    fi

    log "Candidate passed its direct health check"

    # Switch traffic only after the candidate is healthy.
    write_nginx_config "$candidate_port"

    if ! reload_nginx; then
        log "Nginx configuration test or reload failed"

        if (( had_previous_config )); then
            sudo -n cp "$old_config_backup" "$NGINX_CONF"
            reload_nginx || log "WARNING: Nginx rollback reload failed"
        fi

        cleanup_candidate
        die "Traffic switch failed; old Green container was preserved"
    fi

    switched=1

    # Verify the new version through Nginx before promoting it.
    if ! curl --fail --silent \
        "http://127.0.0.1:${NGINX_PORT}/" >/dev/null; then
        log "Nginx verification failed; rolling back"

        if (( had_previous_config )); then
            sudo -n cp "$old_config_backup" "$NGINX_CONF"
            reload_nginx || log "WARNING: Nginx rollback reload failed"
        fi

        cleanup_candidate
        die "Post-switch verification failed"
    fi

    # Preserve the old container until traffic has been verified.
    docker rename "$ACTIVE_NAME" "$PREVIOUS_NAME"
    docker rename "$CANDIDATE_NAME" "$ACTIVE_NAME"

    save_state "$candidate_port"

    # The new Green is active and verified. Remove the old container.
    docker rm -f "$PREVIOUS_NAME"

    [[ -z "$old_config_backup" ]] || rm -f "$old_config_backup"

    log "Deployment successful"
    log "New stable Green port: $candidate_port"
    log "Application URL: http://127.0.0.1:${NGINX_PORT}/"
}

deploy "$@"

