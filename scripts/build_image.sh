#!/bin/bash 

set -euxo pipefail

cleanup() {
    ret="$?"
    set +e
    rm anchore-bootstrap.sql.gz
    if [[ ! -z $db_preload_id ]]; then
        docker rm $db_preload_id
    fi
    exit "$ret"
}

trap 'cleanup' EXIT SIGINT SIGTERM ERR

final_image_name=${IMAGE_NAME:-'stateless_anchore'}
anchore_engine_version=${ANCHORE_VERSION:-'dev'}
engine_db_preload_version=${ANCHORE_VERSION:-'latest'}

docker pull anchore/engine-db-preload:${engine_db_preload_version}
echo "Copying anchore-bootstrap.sql.gz from anchore/engine-db-preload:${engine_db_preload_version} image..."
db_preload_id=$(docker run -d --entrypoint tail "docker.io/anchore/engine-db-preload:${engine_db_preload_version}" /dev/null | tail -n1)
docker cp "${db_preload_id}:/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz" anchore-bootstrap.sql.gz
docker build --build-arg ANCHORE_VERSION=${anchore_engine_version} -t ${final_image_name}:ci .