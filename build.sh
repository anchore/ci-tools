#!/usr/bin/env bash

# Fail on any errors, including in pipelines
# Don't allow unset variables. Trace all functions with DEBUG trap
set -euo pipefail -o functrace 


#######################################
###   GLOBAL ENVIRONMENT VARIABLES  ###
#######################################

# Expand (or set to default values with := variable expansion) all required ENV vars
export IMAGE_NAME="${!IMAGE_NAME:=anchore/inline_scan}"
export CIRCLE_PROJECT_REPONAME="${!CIRCLE_PROJECT_REPONAME:=ci-tools}"
export CIRCLE_BRANCH="${!CIRCLE_BRANCH:=dev}"
export CI="${!CI:=false}"
# Use eval to ensure ~ gets expanded to the absolute path (workaround for default CIRCLE_WORKING_DIRECTORY)
export WORKSPACE=$(eval echo ${WORKSPACE:=${CIRCLE_WORKING_DIRECTORY:-$HOME}/workspace})


#################################################
###   HELPER FUNCTIONS - ALPHABETICAL ORDER   ###
#################################################

build_image() {
    if [[ "$1" == 'dev' ]]; then
        local dev=true
        local anchore_version='latest'
    else
        local anchore_version="$1"
    fi
    docker pull "anchore/engine-db-preload:${anchore_version}"
    echo "Copying anchore-bootstrap.sql.gz from anchore/engine-db-preload:${anchore_version} image..."
    db_preload_id=$(docker run -d --entrypoint tail "docker.io/anchore/engine-db-preload:${anchore_version}" /dev/null | tail -n1)
    docker cp "${db_preload_id}:/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz" "anchore-bootstrap.sql.gz"
    # If $dev is set to 'true' build with anchore-engine:dev - $dev defaults to false
    if ${dev:-false}; then
        # REMOVE BUILD-ARG WHEN DOCKERFILE GETS UPDATED FOR v0.4.0
        docker build --build-arg "ANCHORE_VERSION=v0.3.3" -t "${IMAGE_NAME}:dev" .
    else
        docker build --build-arg "ANCHORE_VERSION=${anchore_version}" -t "${IMAGE_NAME}:dev" .
        docker tag "${IMAGE_NAME}:dev" "${IMAGE_NAME}:dev-${version}"
    fi
}

cleanup() {
    ret="$?"
    set +euxo pipefail
    popd 2> /dev/null
    if ! "$CI"; then
        rm -rf "${HOME}/workspace/" anchore-bootstrap.sql.gz anchore-reports/
        if [[ ! -z "$db_preload_id" ]]; then
            docker kill "$db_preload_id"
            docker rm "$db_preload_id"
        fi
    fi
    exit "$ret"
}

load_image() {
    local anchore_version="$1"
    if [[ "$anchore_version" == 'dev' ]]; then
        docker load -i "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-dev.tar"
    else
        docker load -i "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-dev.tar"
    fi
}

pull_test_images() {
    local img_array=("$@")
    mkdir -p "${HOME}/workspace/images"
    for i in "${img_array[@]}"; do
        docker pull "$i"
        img=$(echo "${i##*/}" | sed 's/:/+/g' )
        docker save "$i" -o "${HOME}/workspace/images/"${img}".tar"
    done
}

push_dockerhub() {
    local anchore_version="$1"
    if "$CI"; then
        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    fi
    if [[ "$CIRCLE_BRANCH" == 'master' ]] && [[ "$CI" == true ]] && [[ ! "$anchore_version" == 'dev' ]]; then
        docker tag "${IMAGE_NAME}:dev-${anchore_version}" "${IMAGE_NAME}:${anchore_version}"
        echo "Pushing to DockerHub - ${IMAGE_NAME}:${anchore_version}"
        docker push "${IMAGE_NAME}:${anchore_version}"
        local anchore_latest_tag=$(git ls-remote --tags --refs --sort="v:refname" git://github.com/anchore/anchore-engine.git | tail -n1 | sed 's/.*\///')
        if [ "$anchore_version" == "$anchore_latest_tag" ]; then
            docker tag "${IMAGE_NAME}:dev-${anchore_version}" "${IMAGE_NAME}:latest"
            echo "Pushing to DockerHub - ${IMAGE_NAME}:latest"
            docker push "${IMAGE_NAME}:latest"
        fi
    else
        if [[ "$anchore_version" == 'dev' ]]; then
            if "$CI"; then
                docker tag "${IMAGE_NAME}:dev" "anchore/private_testing:inline_scan-${CIRCLE_BRANCH}-${anchore_version}"
            else
                docker tag "${IMAGE_NAME}:dev" "anchore/private_testing:inline_scan-${anchore_version}"
            fi
        else
            docker tag "${IMAGE_NAME}:dev-${anchore_version}" "anchore/private_testing:inline_scan-${CIRCLE_BRANCH}-${anchore_version}"
        fi
        echo "Pushing to DockerHub - anchore/private_testing:inline_scan-${CIRCLE_BRANCH}-${anchore_version}"
        docker push "anchore/private_testing:inline_scan-${CIRCLE_BRANCH}-${anchore_version}"
    fi
}

save_image() {
    local anchore_version="$1"
    mkdir -p "${HOME}/workspace/caches/"
    if [[ "$anchore_version" == 'dev' ]]; then
        docker save -o "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-dev.tar" "${IMAGE_NAME}:dev"
    else
        docker save -o "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-dev.tar" "${IMAGE_NAME}:dev-${anchore_version}"
    fi
}

test_bulk_image_volume() {
    local anchore_version="$1"
    if [[ "$anchore_version" == 'dev' ]]; then
        export ANCHORE_CI_IMAGE="${IMAGE_NAME}:dev"
    else
        git checkout "tags/${anchore_version}"
        export ANCHORE_CI_IMAGE="${IMAGE_NAME}:dev-${anchore_version}"
    fi
    if "$CI"; then
        ssh remote-docker 'mkdir -p ${HOME}/workspace'
        scp build.sh remote-docker:"\${HOME}/workspace/build.sh"
        ssh -fN remote-docker '${HOME}/workspace/build.sh pull_test_images alpine:latest java:latest nginx:latest'
    else
        pull_test_images alpine:latest java:latest nginx:latest
    fi
    cat scripts/inline_scan | bash -x scripts/inline_scan -v "${HOME}/workspace/images" -t 500
}

test_inline_image() {
    local anchore_version="$1"
    if [[ "$anchore_version" == 'dev' ]]; then
        export ANCHORE_CI_IMAGE="${IMAGE_NAME}:dev"
    else
        git checkout "tags/${anchore_version}"
        export ANCHORE_CI_IMAGE="${IMAGE_NAME}:dev-${anchore_version}"
    fi
    cat scripts/inline_scan | bash -xs -- -d ".circleci/Dockerfile" -b ".circleci/.anchore/policy_bundle.json" -p -r node
}

test_inline_script() {
    local INLINE_URL="$1"
    curl -s "$INLINE_URL" | bash -s -- -p centos:latest
    # test script with dockerfile
    docker pull docker:stable-git
    curl -s "$INLINE_URL" | bash -s -- -d ".circleci/Dockerfile" docker:stable-git
    # test script with policy bundle
    curl -s "$INLINE_URL" | bash -s -- -p -b ".circleci/.anchore/policy_bundle.json" "anchore/inline-scan:dev"
    # test script with policy bundle & dockerfile
    pushd .circleci/node_critical_pass/
    docker build -t example.com:5000/ci-test_1/node_critical-pass:latest .
    popd
    curl -s "$INLINE_URL" | bash -s -- -t 500 -d ".circleci/node_critical_pass/Dockerfile" -b ".circleci/.anchore/policy_bundle.json" example.com:5000/ci-test_1/node_critical-pass
}


#################################################
###   FUNCTIONS CALLED DIRECTLY BY CIRCLECI   ###
#################################################

build_and_save_images() {
    # Loop through build_versions.txt and build images for every specified version
    if [[ "$1" == 'dev' ]]; then
        echo "Buiding ${IMAGE_NAME}:dev"
        build_image dev
        test_inline_image dev
        save_image dev
    else
        for version in $(cat versions.txt); do
            echo "Building ${IMAGE_NAME}:dev-${version}"
            git checkout "tags/${version}"
            build_image "$version"
            test_inline_image "$version"
            save_image "$version"
        done
    fi
}

run_inline_tests() {
    if [[ "$1" == 'dev' ]]; then
        export ANCHORE_CI_IMAGE="${IMAGE_NAME}:dev"
        test_bulk_image_volume dev
        test_inline_script "https://raw.githubusercontent.com/anchore/ci-tools/master/scripts/inline_scan"
    else
        for version in $(cat versions.txt); do
            unset ANCHORE_CI_IMAGE
            export ANCHORE_CI_IMAGE="${IMAGE_NAME}:dev-${version}"
            git checkout "tags/${anchore_version}"
            test_bulk_image_volume ${anchore_version}
            test_inline_script "https://raw.githubusercontent.com/anchore/ci-tools/${version}/scripts/inline_scan"
        done
    fi
}

load_image_and_push_dockerhub() {
    if [[ "$1" == 'dev' ]]; then
        load_image dev
        push_dockerhub dev
    else
        for version in $(cat versions.txt); do
            load_image "$version"
            push_dockerhub "$version"
        done
    fi
}


################################
### MAIN PROGRAM BEGINS HERE ###
################################

# Trap all signals that exit script & run cleanup function before exiting
trap 'cleanup' EXIT SIGINT SIGTERM ERR

# Setup terminal colors for printing
color_normal=$(tput sgr0)
color_red=$(tput setaf 1)
color_yellow=$(tput setaf 3)

# Display values of all required ENV vars
echo ${color_yellow}
printf "%s\n\n" "- ENVIRONMENT VARIABLES SET -"
echo "IMAGE_NAME=$IMAGE_NAME"
echo "CIRCLE_PROJECT_REPONAME=$CIRCLE_PROJECT_REPONAME"
echo "CIRCLE_BRANCH=$CIRCLE_BRANCH"
echo "CI=$CI"
echo "WORKSPACE=$WORKSPACE"
echo ${color_normal}

# If running tests manually, sleep for a few seconds to give time to visually double check that ENV is setup correctly
if [[ "$CI" == false ]] && [[ "$#" -ne 0 ]]; then
    sleep 5
fi

# Trap all bash commands & print to screen. Like using set -v but allows printing in color
trap 'printf "%s\n" "${color_red}+ ${BASH_COMMAND}${color_normal}" >&2' DEBUG

# Function for testing a full CircleCI pipeline
run_full_ci_test() {
    build_and_save_images dev
    run_inline_tests dev
    load_image_and_push_dockerhub dev
    build_and_save_images
    run_inline_tests
    load_image_and_push_dockerhub
}

# If no params are passed to script, build image using latest DB & Engine
if [[ $# -eq 0 ]]; then
    build_image dev
# Run full test suite if 'test' param is passed - used for testing pipeline locally
elif [[ "$1" == 'test' ]]; then
    run_full_ci_test
# If first param is a valid function name, execute the function & pass all following params to function
else
    if declare -f "$1" > /dev/null; then
        "$@"
    else
        set +x
        echo "$1 is not a valid function name"
        exit 1
    fi
fi