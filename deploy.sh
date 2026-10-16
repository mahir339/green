#!/bin/bash

# Find a free port between 2000 and 2100
find_available_port() {
    local available_ports=()
    local port

    for port in $(seq 2000 2100); do
        # Check whether a process is listening on this port
        if ! sudo ss -H -ltn "sport = :$port" | grep -q .; then
            # Also check Docker's published ports
            if ! sudo docker ps --format '{{.Ports}}' |
                grep -qE "[:.]${port}->"; then
                available_ports+=("$port")
            fi
        fi
    done

    if [ ${#available_ports[@]} -eq 0 ]; then
        echo "ERROR: No available port found between 2000 and 2100." >&2
        return 1
    fi

    # Select a random port from the available ports
    local index=$(( RANDOM % ${#available_ports[@]} ))
    echo "${available_ports[$index]}"
}

# Test port selection

# Project paths
PROJECT_DIR="/home/mahir/green"
STATE_FILE="$PROJECT_DIR/deployment.state"

# Read the current deployment state
get_deployment_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        echo "No deployment state file exists yet."
        return 1
    fi
}

# Display the current deployment state
if get_deployment_state; then
    echo "Active slot: $ACTIVE_SLOT"
    echo "Active port: $ACTIVE_PORT"
else
    echo "Deployment state has not been initialized."
fi

