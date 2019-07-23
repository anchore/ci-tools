#!/usr/bin/env bash

set -exo pipefail

main() {
    # use 'debug' as the first input param for script. This starts all services, then execs all proceeding inputs
    if [[ "$1" = 'debug' ]]; then
        start_services
        exec "${@:2}"
    # use 'start' as the first input param for script. This will start all services & execs anchore-manager.
    elif [[ "$1" = 'start' ]]; then
        start_services 'exec'
    elif [[ "$1" == 'scan' ]]; then
        start_services
        exec image_vuln_scan.sh "${@:2}"
    elif [[ "$1" == 'analyze' ]]; then
        setup_env
        exec image_analysis.sh "${@:2}"
    else
        exec "$@"
    fi
}

setup_env() {
    export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"
    export ANCHORE_DB_PASSWORD="$POSTGRES_PASSWORD"
    export ANCHORE_DB_USER="$POSTGRES_USER"
    export ANCHORE_DB_NAME="$POSTGRES_DB"
    export ANCHORE_DB_HOST="$ANCHORE_ENDPOINT_HOSTNAME"
    export ANCHORE_HOST_ID="$ANCHORE_ENDPOINT_HOSTNAME"
    export ANCHORE_CLI_URL="http://${ANCHORE_ENDPOINT_HOSTNAME}:8228/v1"
    export PATH=${PATH}:/usr/pgsql-${PG_MAJOR}/bin/
    export TIMEOUT=${TIMEOUT:=300}
}

start_services() {
    setup_env
    local exec_anchore="$1"

    if [ -f "/opt/rh/rh-python36/enable" ]; then
        source /opt/rh/rh-python36/enable
    fi

    if [[ ! "$exec_anchore" = "exec" ]] && [[ ! $(pgrep anchore-manager) ]]; then
        echo "Starting Anchore Engine..."
        nohup anchore-manager service start --all &> /var/log/anchore.log &
    fi
    
    if [[ ! $(pg_isready -d postgres --quiet) ]]; then
        printf '%s' "Starting Postgresql... "
        nohup bash -c 'postgres &> /var/log/postgres.log &' &> /dev/null
        sleep 3 && pg_isready -d postgres --quiet && printf '%s\n' "Postgresql started successfully!"
    fi

    if [[ ! $(curl --silent "${ANCHORE_ENDPOINT_HOSTNAME}:5000") ]]; then
        printf '%s' "Starting Docker registry... "
        nohup registry serve /etc/docker/registry/config.yml &> /var/log/registry.log &
        sleep 3 && curl --silent --retry 3 "${ANCHORE_ENDPOINT_HOSTNAME}:5000" && printf '%s\n' "Docker registry started successfully!"
    fi

    if [[ "$exec_anchore" = "exec" ]]; then
        echo "Starting Anchore Engine..."
        exec anchore-manager service start --all
    fi

    echo "Waiting for Anchore Engine to be available."
    # pass python script to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    anchore_ci_tools.py --wait --timeout "$TIMEOUT" &
    local wait_proc="$!"
    wait "$wait_proc"
}

main "$@"