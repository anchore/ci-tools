#!/bin/bash

set -eo pipefail

export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"
export ANCHORE_DB_PASSWORD="$POSTGRES_PASSWORD"
export ANCHORE_DB_USER="$POSTGRES_USER"
export ANCHORE_DB_NAME="$POSTGRES_DB"
export ANCHORE_DB_HOST="$ANCHORE_ENDPOINT_HOSTNAME"
export ANCHORE_HOST_ID="$ANCHORE_ENDPOINT_HOSTNAME"
export ANCHORE_CLI_URL="http://${ANCHORE_ENDPOINT_HOSTNAME}:8228/v1"

export PATH=$PATH:/usr/lib/postgresql/9.6/bin/

start_services () {
    echo "127.0.0.1 $ANCHORE_ENDPOINT_HOSTNAME" >> /etc/hosts
    
    printf '%s\n\n' "Starting anchore engine..."
    nohup anchore-manager service start --all &> /var/log/anchore.log &

    printf '%s\n' "Starting postgresql..."
    touch /var/log/postgres.log && chown postgres:postgres /var/log/postgres.log
    nohup gosu postgres bash -c 'postgres &> /var/log/postgres.log &' &> /dev/null
    sleep 3 && gosu postgres pg_isready -d postgres --quiet && echo "Postgresql started successfully!"
    
    printf '\n%s\n' "Starting docker registry..."
    nohup registry serve /etc/docker/registry/config.yml &> /var/log/registry.log &
    curl --silent --retry 3 --retry-connrefused "${ANCHORE_ENDPOINT_HOSTNAME}:5000" && printf '%s\n\n' "Docker registry started successfully!"
}

anchore_analysis () {
    image_name="${1%.*}"
    skopeo copy --dest-tls-verify=false "docker-archive:/anchore-engine/${1}" "docker://${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_name}:analyze"
    anchore_ci_tools.py -ar --image "${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_name}:analyze"
}

if [ ! $# -eq 0 ]; then
    # use 'debug' as the first input param for script. This starts all services, then execs all proceeding inputs
    if [ $1 = 'debug' ]; then
        start_services
        exec "${@:2}"
    else
        exec "$@"
    fi
else
    start_services
    anchore-cli system wait --feedsready "vulnerabilities,nvd" && printf '\n%s\n' "Anchore Engine started successfully!"
    printf '\n%s\n\n' "Searching for docker image archive files in /anchore-engine."
    find /anchore-engine -type f -exec bash -c 'if [[ $(skopeo inspect "docker-archive:${0}" 2> /dev/null) ]];then echo "$0" >> /tmp/scan_files.txt; else echo "Ignoring invalid docker archive: $0"; fi' {} \;
    if [ -e /tmp/scan_files.txt ]; then
        for i in $(uniq /tmp/scan_files.txt); do
            printf '\n%s\n\n' "Preparing docker image archive for analysis: $(basename $i)"
            anchore_analysis $(basename "$i")
        done
    else
        printf '\n%s\n\n' "ERROR - No valid docker image archives found on mounted volume."
    fi
fi