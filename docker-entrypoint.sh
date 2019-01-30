#!/bin/bash -ex

export POSTGRES_USER="${POSTGRES_USER:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-postgres}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"

export ANCHORE_DB_PASSWORD="$POSTGRES_PASSWORD"
export ANCHORE_DB_USER="$POSTGRES_USER"
export ANCHORE_DB_NAME="$POSTGRES_DB"
export ANCHORE_DB_HOST='anchore-ci'

export PATH=$PATH:/usr/lib/postgresql/9.6/bin/
echo "127.0.0.1 anchore-ci" >> /etc/hosts

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

        {
            echo
            echo "host all all all $authMethod"
        } >> "$PGDATA/pg_hba.conf"

        # internal start of server in order to allow set-up using psql-client
        # does not listen on external TCP/IP and waits until start finishes
        PGUSER="${PGUSER:-$POSTGRES_USER}" \
        gosu postgres bash -c 'pg_ctl -D "$PGDATA" \
            -o "-c listen_addresses=''" \
            -w start'

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

        echo
        echo 'PostgreSQL init process complete; ready for start up.'
        echo
    fi
}

start_services () {
    touch /var/log/postgres.log && chown postgres:postgres /var/log/postgres.log
    echo "starting postgresql."
    nohup gosu postgres bash -c 'postgres &> /var/log/postgres.log &'
    echo "starting docker registry."
    nohup registry serve /etc/docker/registry/config.yml &> /var/log/registry.log &
    echo "starting anchore engine."
    nohup anchore-manager service start --all &> /var/log/anchore.log &
}

anchore_analysis () {
    echo "$1"
    image_name="${1%.*}"
    echo "$image_name"
    skopeo copy --dest-tls-verify=false docker-archive:/anchore-engine/${1} docker://anchore-ci:5000/${image_name}:latest
    anchore-cli image add anchore-ci:5000/${image_name}:latest
    anchore-cli image wait anchore-ci:5000/${image_name}:latest
    anchore-cli --json evaluate check anchore-ci:5000/${image_name}:latest
    anchore-cli --json image vuln anchore-ci:5000/${image_name}:latest all
    anchore-cli --json image content anchore-ci:5000/${image_name}:latest os
}

if [ ! $# -eq 0 ]; then
    if [ $1 = 'debug' ]; then
        init_db
        start_services
        exec "${@:2}"
    elif [ $1 = 'preload' ]; then
        init_db
        exec "${@:2}"
    else
        exec "$@"
    fi
else
    init_db
    start_services
    anchore-cli system wait
    export -f anchore_analysis
    find /anchore-engine/ -type f -name "*.tar" -exec bash -c 'anchore_analysis `basename "$0"`' {} \;
fi