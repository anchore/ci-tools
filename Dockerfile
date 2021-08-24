ARG ANCHORE_REPO="anchore/anchore-engine"
ARG ANCHORE_VERSION="latest"
FROM ${ANCHORE_REPO}:${ANCHORE_VERSION}

USER root:root

ENV JQ_VERSION=1.6
ENV GOSU_VERSION=1.11

RUN set -ex; \
    yum -y upgrade; \
    yum install -y ca-certificates; \
    curl -Lo /usr/local/bin/jq "https://github.com/stedolan/jq/releases/download/jq-${JQ_VERSION}/jq-linux64"; \
    curl -o /usr/local/bin/jq.asc "https://raw.githubusercontent.com/stedolan/jq/master/sig/v${JQ_VERSION}/jq-linux64.asc";\
    curl -o /usr/local/bin/jq-public.asc "https://raw.githubusercontent.com/stedolan/jq/master/sig/jq-release.key"; \
    curl -Lo /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64"; \
    curl -Lo /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
    gpg --batch --import /usr/local/bin/jq-public.asc; \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
    gpg --batch --verify /usr/local/bin/jq.asc /usr/local/bin/jq; \
    command -v gpgconf && gpgconf --kill all || :; \
    chmod +x /usr/local/bin/jq; \
    chmod +x /usr/local/bin/gosu; \
    rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc /usr/local/bin/jq.asc; \
    rm -rf /anchore-engine/* /root/.cache /config/config.yaml

ENV PG_MAJOR="9.6"
ENV PGDATA="/var/lib/postgresql/data"

RUN set -eux; \
    yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm && \
    yum install -y postgresql96 postgresql96-server

RUN set -eux; \
    mkdir -p /var/lib/postgresql; \
    chown -R anchore:anchore /var/lib/postgresql; \
    mkdir /docker-entrypoint-initdb.d; \
    touch /var/log/postgres.log; \
    chown anchore:anchore /var/log/postgres.log; \
    mkdir -p /var/run/postgresql; \
    chown -R anchore:anchore /var/run/postgresql; \
    chmod 2775 /var/run/postgresql; \
    mkdir -p "$PGDATA"; \
    chown -R anchore:anchore "$PGDATA"; \
    chmod 700 "$PGDATA"

COPY anchore-bootstrap.sql.gz /docker-entrypoint-initdb.d/

ENV POSTGRES_USER="postgres" \
    POSTGRES_DB="postgres" \
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"

RUN set -eux; \
    export PATH=${PATH}:/usr/pgsql-${PG_MAJOR}/bin/; \
    gosu anchore bash -c 'initdb --username=${POSTGRES_USER} --pwfile=<(echo "$POSTGRES_PASSWORD")'; \
    PGUSER="${PGUSER:-$POSTGRES_USER}" \
    gosu anchore bash -c 'pg_ctl -D "$PGDATA" -o "-c listen_addresses='*'" -w start'; \
    printf '\n%s' 'host all all 0.0.0.0/0 md5' >> ${PGDATA}/pg_hba.conf; \
    export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"; \
    gosu anchore bash -c '\
        export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"; \
        export psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password --dbname "$POSTGRES_DB" ); \
        for f in /docker-entrypoint-initdb.d/*; do \
            echo running "$f"; gunzip -c "$f" | "${psql[@]}"; echo ; \
        done'; \
    PGUSER="${PGUSER:-$POSTGRES_USER}" \
    gosu anchore bash -c 'pg_ctl -D "$PGDATA" -m fast -w stop'; \
    unset PGPASSWORD; \
    rm -f /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz

ENV REGISTRY_VERSION 2.7

RUN set -eux; \
    mkdir -p /etc/docker/registry; \
    mkdir /var/lib/registry; \
    chown anchore:anchore /var/lib/registry; \
    curl -LH 'Accept: application/octet-stream' -o /usr/local/bin/registry https://github.com/docker/distribution-library-image/raw/release/${REGISTRY_VERSION}/amd64/registry; \
    chmod +x /usr/local/bin/registry; \
    curl -Lo /etc/docker/registry/config.yml https://raw.githubusercontent.com/docker/distribution-library-image/release/${REGISTRY_VERSION}/amd64/config-example.yml; \
    touch /var/log/registry.log; \
    chown anchore:anchore /var/log/registry.log

ENV ANCHORE_ENDPOINT_HOSTNAME="localhost"
RUN set -eux; \
    echo "127.0.0.1 $ANCHORE_ENDPOINT_HOSTNAME" >> /etc/hosts; \
    touch /var/log/anchore.log; \
    chown anchore:anchore /var/log/anchore.log; \
    chown anchore:anchore /anchore-engine

COPY conf/stateless_ci_config.yaml /config/config.yaml
COPY scripts/anchore_ci_tools.py  \
     scripts/docker-entrypoint.sh \
     scripts/image_analysis.sh \
     scripts/image_vuln_scan.sh /usr/local/bin/

USER anchore:anchore
WORKDIR /anchore-engine
ENV PATH ${PATH}:/anchore-cli/bin

EXPOSE 5432 5000
ENTRYPOINT ["docker-entrypoint.sh"]
