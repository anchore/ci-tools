FROM btodhunter/anchore-engine:latest

RUN apt-get update; \
    apt-get upgrade; \
    apt-get install -y ca-certificates wget gosu

# explicitly set user/group IDs for postgres
RUN set -ex; \
    groupadd -r postgres --gid=999; \
# https://salsa.debian.org/postgresql/postgresql-common/blob/997d842ee744687d99a2b2d95c1083a2615c79e8/debian/postgresql-common.postinst#L32-35
    useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
# also create the postgres user's home directory with appropriate permissions
# see https://github.com/docker-library/postgres/issues/274
    mkdir -p /var/lib/postgresql; \
    chown -R postgres:postgres /var/lib/postgresql; \
    mkdir /docker-entrypoint-initdb.d; \
    rm -f /config/config.yaml

ENV PG_MAJOR 9.6
ENV PGDATA /var/lib/postgresql/data

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
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2775 /var/run/postgresql
RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 700 "$PGDATA" 

ENV REGISTRY_VERSION 2.7

RUN set -eux; \
    mkdir -p /etc/docker/registry; \
    wget -O /usr/local/bin/registry https://github.com/docker/distribution-library-image/raw/release/${REGISTRY_VERSION}/amd64/registry; \
    chmod +x /usr/local/bin/registry; \
    wget -O /etc/docker/registry/config.yml https://raw.githubusercontent.com/docker/distribution-library-image/release/${REGISTRY_VERSION}/amd64/config-example.yml; \
    apt-get purge -y ca-certificates wget; \
    rm -rf /wheels /root/.cache

COPY conf/stateless_ci_config.yaml /config/config.yaml
COPY scripts/anchore_ci_tools.py /usr/local/bin/
COPY docker-entrypoint.sh /usr/local/bin/

ENV ANCHORE_CLI_URL="http://anchore-engine:8228/v1" \
    ANCHORE_HOST_ID="anchore-engine" \
    ANCHORE_ENDPOINT_HOSTNAME="anchore-engine"

VOLUME ["/var/lib/registry"]
EXPOSE 5432 5000
ENTRYPOINT ["docker-entrypoint.sh"]