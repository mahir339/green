#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_FILE="${APP_FILE:-index-v2.html}"

PORT_MIN=2000
PORT_MAX=2100
IMAGE_NAME="green-app"
NGINX_HELPER="/usr/local/sbin/blue-green-nginx-switch"

STATE_DIR="$HOME/.local/state/blue-green-deployment"
STATE_FILE="$STATE_DIR/deployment.state"
LOG_FILE="$STATE_DIR/deployment.log"
LOCK_FILE="$STATE_DIR/deployment.lock"

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

port_in_use() {
    local port="$1"

    if ss -H -ltn "sport = :$port" | grep -q .; then
        return 0
    fi

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
            printf '%s\n' "$port"
            return 0
        fi

        attempts=$((attempts + 1))
    done

    return 1
}

wait_for_health() {
    local port="$1"
    local attempt

    for attempt in $(seq 1 30); do
        if curl --fail --silent --max-time 2 \
            "http://127.0.0.1:${port}/" >/dev/null; then
            log "Health check passed on port $port"
            return 0
        fi

        sleep 2
    done

    return 1
}

save_state() {
    local slot="$1"
    local port="$2"
    local temp_file

    temp_file="$(mktemp "$STATE_DIR/.state.XXXXXX")"

    {
        printf 'ACTIVE_SLOT=%s\n' "$slot"
        printf 'ACTIVE_PORT=%s\n' "$port"
    } > "$temp_file"

    chmod 600 "$temp_file"
    mv -f "$temp_file" "$STATE_FILE"
}

deploy() {
    local active_slot=""
    local active_port=""
    local candidate_slot=""
    local candidate_port=""
    local image_tag
    local version_label

    cd "$APP_DIR"

    [[ "$APP_FILE" == "index.html" ||
       "$APP_FILE" == "index-v2.html" ]] ||
        die "APP_FILE must be index.html or index-v2.html"

    [[ -f Dockerfile ]] || die "Dockerfile is missing"
    [[ -f "$APP_FILE" ]] || die "$APP_FILE is missing"

    command -v docker >/dev/null || die "Docker is not installed"
    command -v curl >/dev/null || die "curl is not installed"
    command -v ss >/dev/null || die "ss is not installed"
    command -v shuf >/dev/null || die "shuf is not installed"
    command -v flock >/dev/null || die "flock is not installed"

    [[ -x "$NGINX_HELPER" ]] ||
        die "Nginx helper is missing or not executable: $NGINX_HELPER"

    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another deployment is already running"

    docker info >/dev/null 2>&1 ||
        die "Docker is unavailable to this user"

    if [[ "$APP_FILE" == "index.html" ]]; then
        version_label="GREEN"
    else
        version_label="BLUE"
    fi

    if [[ -f "$STATE_FILE" ]]; then
        active_slot="$(sed -n 's/^ACTIVE_SLOT=//p' "$STATE_FILE")"
        active_port="$(sed -n 's/^ACTIVE_PORT=//p' "$STATE_FILE")"

        [[ "$active_slot" == "green" || "$active_slot" == "blue" ]] ||
            die "Invalid active slot in deployment state"

        [[ "$active_port" =~ ^[0-9]+$ ]] &&
            (( active_port >= PORT_MIN && active_port <= PORT_MAX )) ||
            die "Invalid active port in deployment state"

        container_exists "$active_slot" ||
            die "State points to a missing active container"

        [[ "$(docker inspect -f '{{.State.Running}}' "$active_slot")" == "true" ]] ||
            die "Active container is not running"

        wait_for_health "$active_port" ||
            die "Active application is unhealthy; refusing deployment"

        if [[ "$active_slot" == "green" ]]; then
            candidate_slot="blue"
        else
            candidate_slot="green"
        fi
    else
        if container_exists green || container_exists blue; then
            die "Green/blue containers exist but state is missing; inspect before proceeding"
        fi

        candidate_slot="green"
        log "First deployment: preparing the Green slot"
    fi

    if container_exists "$candidate_slot"; then
        log "Removing previous inactive container: $candidate_slot"
        docker rm -f "$candidate_slot"
    fi

    candidate_port="$(find_available_port)" ||
        die "No available port found between $PORT_MIN and $PORT_MAX"

    image_tag="${GITHUB_SHA:-local}-$(date +%s)"

    log "Building $APP_FILE as ${IMAGE_NAME}:${image_tag}"

    docker build \
        --build-arg "APP_FILE=$APP_FILE" \
        -t "${IMAGE_NAME}:${image_tag}" .

    log "Starting candidate $candidate_slot on port $candidate_port"

    docker run -d \
        --name "$candidate_slot" \
        --restart unless-stopped \
        -p "127.0.0.1:${candidate_port}:80" \
        "${IMAGE_NAME}:${image_tag}"

    if ! wait_for_health "$candidate_port"; then
        docker rm -f "$candidate_slot" || true
        die "Candidate health check failed; traffic was not switched"
    fi

    if ! curl --fail --silent --max-time 5 \
        "http://127.0.0.1:${candidate_port}/" |
        grep -Fq "Version: $([[ "$version_label" == "GREEN" ]] && echo 1 || echo 2)"; then
        docker rm -f "$candidate_slot" || true
        die "Candidate content does not match the requested version"
    fi

    log "Candidate is healthy. Asking the privileged helper to switch Nginx."

    if ! sudo -n "$NGINX_HELPER" "$candidate_port" "$version_label"; then
        log "Nginx switch failed; removing the candidate container"
        docker rm -f "$candidate_slot" || true
        die "Switch failed; the helper should restore its previous upstream"
    fi

    if ! save_state "$candidate_slot" "$candidate_port"; then
        die "Could not save deployment state; inspect Nginx and containers"
    fi

    log "Deployment successful"
    log "Active slot: $candidate_slot"
    log "Active port: $candidate_port"
    log "Application file: $APP_FILE"
    log "Version label: $version_label"
    log "Application URL: http://127.0.0.1/"
    log "Previous slot is retained until the next deployment"
}

deploy "$@"
