# TODO - change to release version of engine
ARG ANCHORE_VERSION
FROM anchore/anchore-engine:${ANCHORE_VERSION}

RUN set -ex; \
    apt-get -y update; \
    apt-get -y upgrade; \
    apt-get install -y ca-certificates gosu jq; \
    # TODO - remove block after new CLI release
    apt-get install -y git; \
    sed -i 's|/src/anchorecli||' /usr/local/lib/python3.6/dist-packages/easy-install.pth; \
    rm -rf /src/*; \
    rm -rf /usr/local/lib/python3.6/dist-packages/anchorecli.egg-link; \
    cd /src; \
    pip3 install --upgrade -e git+git://github.com/anchore/anchore-cli.git@master\#egg=anchorecli; \
    apt-get remove -y git; \
    # TODO - remove block after new CLI release
    rm -rf /anchore-engine/* /root/.cache /config/config.yaml /docker-entrypoint.sh

RUN set -ex; \
    groupadd -r postgres --gid=999; \
    useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
    mkdir -p /var/lib/postgresql; \
    chown -R postgres:postgres /var/lib/postgresql; \
    mkdir /docker-entrypoint-initdb.d

ENV PG_MAJOR="9.6"
ENV PGDATA="/var/lib/postgresql/data"

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    export DEBCONF_NONINTERACTIVE_SEEN=true; \
    echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections; \
    echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections; \
    echo 'deb http://apt.postgresql.org/pub/repos/apt/ bionic-pgdg main' > /etc/apt/sources.list.d/pgdg.list; \
    curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-common; \
    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf; \
    apt-get install -y "postgresql-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get clean

RUN set -eux; \
    mkdir -p /var/run/postgresql; \
    chown -R postgres:postgres /var/run/postgresql; \
    chmod 2775 /var/run/postgresql; \
    mkdir -p "$PGDATA"; \ 
    chown -R postgres:postgres "$PGDATA"; \
    chmod 700 "$PGDATA"

COPY anchore-bootstrap.sql.gz /docker-entrypoint-initdb.d/

ENV POSTGRES_USER="postgres" \
    POSTGRES_DB="postgres" \
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"

RUN set -eux; \
    export PATH=${PATH}:/usr/lib/postgresql/${PG_MAJOR}/bin/; \
    gosu postgres bash -c 'initdb --username=${POSTGRES_USER} --pwfile=<(echo "$POSTGRES_PASSWORD")'; \
    printf '\n%s' "host all all all md5" >> "${PGDATA}/pg_hba.conf"; \
    PGUSER="${PGUSER:-$POSTGRES_USER}" \
    gosu postgres bash -c 'pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start'; \
    export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"; \
    gosu postgres bash -c '\
        export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"; \
        export psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password --dbname "$POSTGRES_DB" ); \
        for f in /docker-entrypoint-initdb.d/*; do \
            echo running "$f"; gunzip -c "$f" | "${psql[@]}"; echo ; \
        done'; \
    PGUSER="${PGUSER:-$POSTGRES_USER}" \
    gosu postgres bash -c 'pg_ctl -D "$PGDATA" -m fast -w stop'; \
    unset PGPASSWORD; \
    rm -f /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz

ENV REGISTRY_VERSION 2.7

RUN set -eux; \
    mkdir -p /etc/docker/registry; \
    curl -L -H 'Accept: application/octet-stream' -o /usr/local/bin/registry https://github.com/docker/distribution-library-image/raw/release/${REGISTRY_VERSION}/amd64/registry; \
    chmod +x /usr/local/bin/registry; \
    curl -L -o /etc/docker/registry/config.yml https://raw.githubusercontent.com/docker/distribution-library-image/release/${REGISTRY_VERSION}/amd64/config-example.yml

COPY conf/stateless_ci_config.yaml /config/config.yaml
COPY scripts/anchore_ci_tools.py /usr/local/bin/
COPY scripts/docker-entrypoint.sh /usr/local/bin/

ENV ANCHORE_ENDPOINT_HOSTNAME="anchore-engine"

VOLUME ["/var/lib/registry"]
EXPOSE 5432 5000
ENTRYPOINT ["docker-entrypoint.sh"]