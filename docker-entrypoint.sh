#!/bin/bash

set -e -o pipefail

export POSTGRES_USER="${POSTGRES_USER:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-postgres}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"

export ANCHORE_DB_PASSWORD="$POSTGRES_PASSWORD"
export ANCHORE_DB_USER="$POSTGRES_USER"
export ANCHORE_DB_NAME="$POSTGRES_DB"
export ANCHORE_DB_HOST="$ANCHORE_ENDPOINT_HOSTNAME"
export ANCHORE_HOST_ID="$ANCHORE_ENDPOINT_HOSTNAME"
export ANCHORE_CLI_URL="http://${ANCHORE_ENDPOINT_HOSTNAME}:8228/v1"

export PATH=$PATH:/usr/lib/postgresql/9.6/bin/

init_db () {
    # look specifically for PG_VERSION, as it is expected in the DB dir. 
    # Prevents DB initialization if data exists in $PGDATA
    if [ ! -s "$PGDATA/PG_VERSION" ]; then

        gosu postgres bash -c 'initdb --username=postgres --pwfile=<(echo "$POSTGRES_PASSWORD")'

        if [ -n "$POSTGRES_PASSWORD" ]; then
            authMethod=md5
        else
            authMethod=trust
        fi
            printf '\n%s' "host all all all $authMethod" >> "${PGDATA}/pg_hba.conf"

        # internal start of server in order to allow set-up using psql-client
        # does not listen on external TCP/IP and waits until start finishes
        PGUSER="${PGUSER:-$POSTGRES_USER}" \
        gosu postgres bash -c 'pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start'

        export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
        psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password )
        psql+=( --dbname "$POSTGRES_DB" )
        export psql

        echo
        gosu postgres bash -c '\
            export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
            psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password )
            psql+=( --dbname "$POSTGRES_DB" )
            export psql
            for f in /docker-entrypoint-initdb.d/*; do
                case "$f" in
                    *.sh)
                        # https://github.com/docker-library/postgres/issues/450#issuecomment-393167936
                        # https://github.com/docker-library/postgres/pull/452
                        if [ -x "$f" ]; then
                            echo "$0: running $f"
                            "$f"
                        else
                            echo "$0: sourcing $f"
                            . "$f"
                        fi
                        ;;
                    *.sql)    echo "$0: running $f"; "${psql[@]}" -f "$f"; echo ;;
                    *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${psql[@]}"; echo ;;
                    *)        echo "$0: ignoring $f" ;;
                esac
                echo
            done'

        PGUSER="${PGUSER:-$POSTGRES_USER}" \
        gosu postgres bash -c 'pg_ctl -D "$PGDATA" -m fast -w stop'

        unset PGPASSWORD

        printf '\n%s\n\n' 'PostgreSQL init process complete; ready for start up.'
    fi
}

start_services () {
    echo "127.0.0.1 $ANCHORE_ENDPOINT_HOSTNAME" >> /etc/hosts

    printf '%s\n' "Starting postgresql..."
    touch /var/log/postgres.log && chown postgres:postgres /var/log/postgres.log
    nohup gosu postgres bash -c 'postgres &> /var/log/postgres.log &' &> /dev/null
    sleep 3 && gosu postgres pg_isready -d postgres --quiet && echo "Postgresql started successfully!"
    
    printf '\n%s\n' "Starting docker registry..."
    nohup registry serve /etc/docker/registry/config.yml &> /var/log/registry.log &
    curl --silent --retry 3 --retry-connrefused "${ANCHORE_ENDPOINT_HOSTNAME}:5000" && echo "Docker registry started successfully!"
    
    printf '\n%s\n' "Starting anchore engine..."
    nohup anchore-manager service start --all &> /var/log/anchore.log &
}

anchore_analysis () {
    image_name="${1%.*}"
    skopeo copy --dest-tls-verify=false "docker-archive:/anchore-engine/${1}" "docker://${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_name}:anchore-analyze"
    anchore_ci_tools.py -ar --image "${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_name}:anchore-analyze"
}

if [ ! $# -eq 0 ]; then
    # use 'debug' as the first input param for script. This starts all services, then execs all proceeding inputs
    if [ $1 = 'debug' ]; then
        init_db
        start_services
        exec "${@:2}"
    # use 'preload' as the first input param for script. This initialized db, then execs all proceeding inputs
    elif [ $1 = 'preload' ]; then
        init_db
        exec "${@:2}"
    else
        exec "$@"
    fi
else
    init_db
    start_services
    anchore-cli system wait --feedsready "vulnerabilities,nvd"
    printf '\n%s\n\n' "Searching for docker image archive files in /anchore-engine."
    find /anchore-engine -type f -exec bash -c 'if [[ $(skopeo inspect "docker-archive:${0}" 2> /dev/null) ]];then echo "$0" >> /tmp/scan_files.txt; else echo "Invalid docker archive: $0"; fi' {} \;
    for i in $(uniq /tmp/scan_files.txt); do
        printf '\n%s\n\n' "Preparing docker image archive for analysis: $i"
        anchore_analysis $(basename "$i")
    done
fi