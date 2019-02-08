#!/bin/bash 

set -eux -o pipefail

final_image_name=${IMAGE_NAME:-'docker.io/anchore/private_testing'}
final_image_tag=${IMAGE_TAG:-'stateless_anchore'}
anchore_engine_version=${ANCHORE_VERSION:-'v0.3.2'}

docker build -t stateless_anchore:ci .
pushd /tmp/
echo "Copying anchore-bootstrap.sql.gz from anchore/engine-db-preload:${anchore_engine_version} image..."
db_preload_id=$(docker run -d --entrypoint tail "docker.io/anchore/engine-db-preload:${anchore_engine_version}" /dev/null | tail -n1)
docker cp "${db_preload_id}:/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz" "${PWD}/anchore-bootstrap.sql.gz"
stateless_anchore_name="$RANDOM"
docker run -d --name "$stateless_anchore_name" --mount type=bind,source=${PWD}/anchore-bootstrap.sql.gz,target=/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz stateless_anchore:ci preload
stateless_anchore_id=$(docker ps --filter "name=${stateless_anchore_name}" | awk '{print $1}' | tail -n+2)
docker logs -f "$stateless_anchore_id"
docker commit --change="CMD []" "$stateless_anchore_id" stateless_anchore_preload:ci
docker tag stateless_anchore_preload:ci "${final_image_name}:${final_image_tag}"
rm anchore-bootstrap.sql.gz
docker rm $stateless_anchore_id
docker rm $db_preload_id
popd