#!/bin/bash 

set -euxo pipefail

final_image_name=${IMAGE_NAME:-'stateless_anchore'}
anchore_engine_version=${ANCHORE_VERSION:-'v0.3.2'}

echo "Copying anchore-bootstrap.sql.gz from anchore/engine-db-preload:${anchore_engine_version} image..."
db_preload_id=$(docker run -d --entrypoint tail "docker.io/anchore/engine-db-preload:${anchore_engine_version}" /dev/null | tail -n1)
docker cp "${db_preload_id}:/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz" anchore-bootstrap.sql.gz
docker build -t ${final_image_name}:ci .
rm anchore-bootstrap.sql.gz
docker rm $db_preload_id