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
    
    printf '\n%s\n' "Starting Anchore Engine."
    nohup anchore-manager service start --all &> /var/log/anchore.log &

    echo "Starting Postgresql."
    touch /var/log/postgres.log && chown postgres:postgres /var/log/postgres.log
    nohup gosu postgres bash -c 'postgres &> /var/log/postgres.log &' &> /dev/null
    sleep 3 && gosu postgres pg_isready -d postgres --quiet && echo "Postgresql started successfully!"
    
    echo "Starting Docker registry."
    nohup registry serve /etc/docker/registry/config.yml &> /var/log/registry.log &
    curl --silent --retry 3 --retry-connrefused "${ANCHORE_ENDPOINT_HOSTNAME}:5000" && echo "Docker registry started successfully!"
}

anchore_analysis () {
    image_name="${1%.*}"
    image_repo="${image_name%_*}"
    image_tag="${image_name#*_}"
    skopeo copy --dest-tls-verify=false "docker-archive:/anchore-engine/${1}" "docker://${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_repo}:${image_tag}"
    anchore_ci_tools.py -ar --image "${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_repo}:${image_tag}"
}

prepare_image () {
    #anchore-cli system wait --feedsready "vulnerabilities,nvd" && printf '\n%s\n' "Anchore Engine started successfully!"
    echo "Waiting for Anchore Engine to be available."
    anchore_ci_tools.py --wait
    printf '%s\n' "Searching for Docker archive files in /anchore-engine."
    for i in $(find /anchore-engine -type f); do
        if [[ $(skopeo inspect "docker-archive:${i}" 2> /dev/null) ]]; then 
            scan_files+=("$i")
            echo "Found docker archive: $i"
        else 
            echo "Ignoring invalid docker archive: $i"
        fi
    done
    
    if [[ "${#scan_files[@]}" -gt 0 ]]; then
        for i in $((IFS=$'\n'; sort <<< "${scan_files[*]}") | uniq); do
            printf '\n%s\n' "Adding image to Anchore Engine: $(basename $i)"
            anchore_analysis $(basename "$i")
        done
    else
        printf '\n%s\n\n' "ERROR - No valid docker archives provided."
    fi
}

if [[ "$#" -ne 0 ]]; then
    # use 'debug' as the first input param for script. This starts all services, then execs all proceeding inputs
    if [[ "$1" = 'debug' ]]; then
        start_services
        exec "${@:2}"
    elif [[ "$1" = '/bin/bash' || "$1" = '/bin/sh' ]]; then
        exec "$@"
    else
        image_name="$(echo $1 | rev | cut -d'/' -f1 | rev)"
        cat <&0 > "/anchore-engine/$(echo $image_name | sed 's/:/_/g').tar"
        start_services
        prepare_image
    fi
else
    start_services
    prepare_image
fi