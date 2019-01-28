#!/bin/bash

export POSTGRES_USER=postgres
export POSTGRES_DB=postgres

eval 'initdb --username=${POSTGRES_USER} --pwfile=<(echo "$POSTGRES_PASSWORD")'

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
pg_ctl -D "$PGDATA" \
    -o "-c listen_addresses=''" \
    -w start

export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password )
psql+=( --dbname "$POSTGRES_DB" )

echo
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
done

PGUSER="${PGUSER:-$POSTGRES_USER}" \
pg_ctl -D "$PGDATA" -m fast -w stop

unset PGPASSWORD

echo
echo 'PostgreSQL init process complete; ready for start up.'
echo