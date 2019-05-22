#!/usr/bin/env bash

# Fail on any errors, including in pipelines
# Don't allow unset variables. Trace all functions with DEBUG trap
set -euo pipefail -o functrace

display_usage() {
    echo "${color_yellow}"
    cat << EOF
    Anchore Build Pipeline ---

    CI pipeline script for Anchore container images.
    Allows building container images & mocking CI pipelines.

    The following overide environment variables are available:
        
        SKIP_CLEANUP = [ true | false ] - skips cleanup job that runs on exit (kills containers & removes workspace)
        IMAGE_REPO = docker.io/example/test - specify a custom image repo to build/test
        WORKING_DIRECTORY = /home/test/workspace - used as a temporary workspace for build/test

    Usage: ${0##*/} <build> <test> <ci> <function_name>  [ function_args ] [ ... ] 
        
        build - Build a dev image tagged IMAGE_REPO:dev'
        test - Run test pipeline locally on your workstation
        ci - Run mocked CircleCI pipeline using Docker-in-Docker
        function_name - Invoke a function directly using build environment
EOF
    echo "${color_normal}"
}

##############################################
###   PROJECT SPECIFIC ENVIRONMENT SETUP   ###
##############################################

# Specify what versions to build & what version should get 'latest' tag
export BUILD_VERSIONS=('v0.3.3')
export LATEST_VERSION='v0.3.3'

set_environment_variables() {
    # PROJECT_VARS are custom vars that are modified between projects
    # Expand all required ENV vars or set to default values with := variable substitution
    # Use eval on $CIRCLE_WORKING_DIRECTORY to ensure ~ gets expanded to the absolute path
    export PROJECT_VARS=( \
        IMAGE_REPO=${IMAGE_REPO:=anchore/inline-scan} \
        CIRCLE_PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME:=inline-scan} \
        WORKING_DIRECTORY=${WORKING_DIRECTORY:=$(eval echo ${CIRCLE_WORKING_DIRECTORY:="${HOME}/ci_test_temp"})} \
    )
    setup_and_print_env_vars
}


#######################################################
###   MAIN PROGRAM FUNCTIONS - ALPHABETICAL ORDER   ###
###   functions are called by main bootsrap logic   ###
#######################################################

# The build() function is used to locally build the project image - ${IMAGE_REPO}:dev
build() {
    setup_build_environment
    build_image dev
}

# The cleanup() function that runs whenever the script exits
cleanup() {
    ret="$?"
    set +euo pipefail
    if [[ "$ret" -eq 0 ]]; then
        set +o functrace
    fi
    if [[ "$SKIP_FINAL_CLEANUP" == false ]]; then
        deactivate 2> /dev/null
        docker-compose down --volumes 2> /dev/null
        if [[ ! -z "$db_preload_id" ]]; then
            docker kill "$db_preload_id" 2> /dev/null
            docker rm "$db_preload_id" 2> /dev/null
        fi
        popd &> /dev/null
        rm -rf "$WORKING_DIRECTORY" anchore-bootstrap.sql.gz anchore-reports/
    fi
    popd &> /dev/null
    exit "$ret"
}

# All ci_test_*() functions are used to mock a CircleCI environment pipeline utilizing Docker-in-Docker
ci_test_run_workflow() {
    setup_build_environment
    ci_test_job 'docker.io/anchore/test-infra:latest' 'build_and_save_images'
    ci_test_job 'docker.io/anchore/test-infra:latest' 'test_built_images'
    ci_test_job 'docker.io/anchore/test-infra:latest' 'load_image_and_push_dockerhub'
}

# The main() function represents the full CI pipeline flow, can be used to run the test pipeline locally
main() {
    build_and_save_images dev
    test_built_images dev
    load_image_and_push_dockerhub dev
}


#################################################################
###   FUNCTIONS CALLED DIRECTLY BY CIRCLECI - RUNTIME ORDER   ###
#################################################################

build_and_save_images() {
    anchore_version="${1:-nil}"
    setup_build_environment
    # Loop through build_versions.txt and build images for every specified version
    if [[ "$anchore_version" == 'dev' ]]; then
        echo "Buiding ${IMAGE_REPO}:dev"
        build_image dev
        test_inline_image dev
        save_image dev
    else
        for version in ${BUILD_VERSIONS[@]}; do
            echo "Building ${IMAGE_REPO}:dev-${version}"
            git checkout "tags/${version}"
            build_image "$version"
            test_inline_image "$version"
            save_image "$version"
        done
    fi
}

test_built_images() {
    anchore_version="${1:-nil}"
    setup_build_environment
    if [[ "$anchore_version" == 'dev' ]]; then
        export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev"
        test_bulk_image_volume dev
        test_inline_script "https://raw.githubusercontent.com/anchore/ci-tools/master/scripts/inline_scan"
    else
        for version in ${BUILD_VERSIONS[@]}; do
            unset ANCHORE_CI_IMAGE
            export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev-${version}"
            git checkout "tags/${anchore_version}"
            test_bulk_image_volume ${anchore_version}
            test_inline_script "https://raw.githubusercontent.com/anchore/ci-tools/${version}/scripts/inline_scan"
        done
    fi
}

load_image_and_push_dockerhub() {
    anchore_version="${1:-nil}"
    if [[ "$1" == 'dev' ]]; then
        load_image dev
        push_dockerhub dev
    else
        for version in ${BUILD_VERSIONS[@]}; do
            load_image "$version"
            push_dockerhub "$version"
        done
    fi
}


###########################################################
###   PROJECT SPECIFIC FUNCTIONS - ALPHABETICAL ORDER   ###
###########################################################

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
    docker cp "${db_preload_id}:/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz" "${WORKING_DIRECTORY}/anchore-bootstrap.sql.gz"
    # If $dev is set to 'true' build with anchore-engine:dev - $dev defaults to false
    if ${dev:-false}; then
        # REMOVE BUILD-ARG WHEN DOCKERFILE GETS UPDATED FOR v0.4.0
        docker build --build-arg "ANCHORE_VERSION=v0.3.3" -t "${IMAGE_REPO}:dev" .
    else
        docker build --build-arg "ANCHORE_VERSION=${anchore_version}" -t "${IMAGE_REPO}:dev" .
        docker tag "${IMAGE_REPO}:dev" "${IMAGE_REPO}:dev-${version}"
    fi
}

pull_test_images() {
    local img_array=("$@")
    mkdir -p "${WORKSPACE}/images"
    for img in "${img_array[@]}"; do
        docker pull "$img"
        image_file=$(echo "${img##*/}" | sed 's/:/+/g' )
        docker save "$img" -o "${WORKSPACE}/images/"${image_file}".tar"
    done
}

setup_build_environment() {
    # Copy source code to $WORKING_DIRECTORY for mounting to docker volume as working dir
    if [[ ! -d "$WORKING_DIRECTORY" ]]; then
        mkdir -p "$WORKING_DIRECTORY"
        cp -a . "$WORKING_DIRECTORY"
    fi
    mkdir -p "${WORKSPACE}/caches"
    pushd "$WORKING_DIRECTORY"
}

test_bulk_image_volume() {
    local anchore_version="$1"
    if [[ "$anchore_version" == 'dev' ]]; then
        export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev"
    else
        git checkout "tags/${anchore_version}"
        export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev-${anchore_version}"
    fi
    if [[ "$CI" == 'true' ]]; then
        mkdir -p ${WORKSPACE}/images
        ssh remote-docker "mkdir -p ${WORKSPACE}/scripts"
        scp scripts/build.sh remote-docker:"${WORKSPACE}/scripts/build.sh"
        ssh remote-docker "WORKSPACE=$WORKSPACE ${WORKSPACE}/scripts/build.sh pull_test_images alpine:latest java:latest nginx:latest"
    else
        pull_test_images alpine:latest java:latest nginx:latest
    fi
    cat "${WORKING_DIRECTORY}/scripts/inline_scan" | bash -s -- -v "${WORKSPACE}/images" -t 500
}

test_inline_image() {
    local anchore_version="$1"
    if [[ "$anchore_version" == 'dev' ]]; then
        export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev"
    else
        git checkout "tags/${anchore_version}"
        export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev-${anchore_version}"
    fi
    cat "${WORKING_DIRECTORY}/scripts/inline_scan" | bash -s -- -d ".circleci/Dockerfile" -b ".circleci/.anchore/policy_bundle.json" -p -r node
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
    pushd "${WORKING_DIRECTORY}/.circleci/node_critical_pass/"
    docker build -t example.com:5000/ci-test_1/node_critical-pass:latest .
    popd
    curl -s "$INLINE_URL" | bash -s -- -t 500 -d ".circleci/node_critical_pass/Dockerfile" -b ".circleci/.anchore/policy_bundle.json" example.com:5000/ci-test_1/node_critical-pass
}


########################################################
###   COMMON HELPER FUNCTIONS - ALPHABETICAL ORDER   ###
########################################################

ci_test_job() {
    local ci_image=$1
    local ci_function=$2
    export DOCKER_NAME="${RANDOM:-TEMP}-ci-test"
    docker run --net host -it --name "$DOCKER_NAME" -v "${WORKING_DIRECTORY}:${WORKING_DIRECTORY}" -v /var/run/docker.sock:/var/run/docker.sock "$ci_image" /bin/sh -c "\
        cd ${WORKING_DIRECTORY} && \
        export WORKING_DIRECTORY=${WORKING_DIRECTORY} && \
        sudo -E bash scripts/build.sh $ci_function \
    "
    docker stop "$DOCKER_NAME" && docker rm "$DOCKER_NAME"
}

load_image() {
    local anchore_version="$1"
    if [[ "$anchore_version" == 'dev' ]]; then
        docker load -i "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-dev.tar"
    else
        docker load -i "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-dev.tar"
    fi
}

push_dockerhub() {
    local anchore_version="$1"
    if [[ "$CI" == true ]]; then
        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    fi
    if [[ "$CIRCLE_BRANCH" == 'master' ]] && [[ "$CI" == true ]]; then
        docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:${anchore_version}"
        echo "Pushing to DockerHub - ${IMAGE_REPO}:${anchore_version}"
        docker push "${IMAGE_REPO}:${anchore_version}"
        if [ "$anchore_version" == "$LATEST_VERSION" ]; then
            docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:latest"
            echo "Pushing to DockerHub - ${IMAGE_REPO}:latest"
            docker push "${IMAGE_REPO}:latest"
        fi
    else
        if [[ "$anchore_version" == 'dev' ]]; then
            docker tag "${IMAGE_REPO}:dev" "anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
        else
            docker tag "${IMAGE_REPO}:dev-${anchore_version}" "anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
        fi
        echo "Pushing to DockerHub - anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
        if [[ "$CI" == false ]]; then
            sleep 10
        fi
        docker push "anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
    fi
}

save_image() {
    local anchore_version="$1"
    mkdir -p "${WORKSPACE}/caches"
    if [[ "$anchore_version" == 'dev' ]]; then
        docker save -o "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-dev.tar" "${IMAGE_REPO}:dev"
    else
        docker save -o "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-dev.tar" "${IMAGE_REPO}:dev-${anchore_version}"
    fi
}

setup_and_print_env_vars() {
    # Export & print all project env vars to the screen
    echo "${color_yellow}"
    printf "%s\n\n" "- ENVIRONMENT VARIABLES SET -"
    echo "BUILD_VERSIONS=${BUILD_VERSIONS[@]}"
    printf "%s\n" "LATEST_VERSION=$LATEST_VERSION"
    for var in ${PROJECT_VARS[@]}; do
        export "$var"
        printf "%s" "${color_yellow}"
        printf "%s\n" "$var"
    done
    # BUILD_VARS are static variables that don't change between projects
    declare -a BUILD_VARS=( \
        CI=${CI:=false} \
        CIRCLE_BRANCH=${CIRCLE_BRANCH:=dev} \
        SKIP_FINAL_CLEANUP=${SKIP_FINAL_CLEANUP:=false} \
        WORKSPACE=${WORKSPACE:=${WORKING_DIRECTORY}/workspace} \
    )
    # Export & print all build env vars to the screen
    for var in ${BUILD_VARS[@]}; do
        export "$var"
        printf "%s" "${color_yellow}"
        printf "%s\n" "$var"
    done
    echo "${color_normal}"
    # If running tests manually, sleep for a few seconds to give time to visually double check that ENV is setup correctly
    if [[ "$CI" == false ]]; then
        sleep 5
    fi
    # Trap all bash commands & print to screen. Like using set -v but allows printing in color
    trap 'printf "%s+ %s%s\n" "${color_cyan}" "${BASH_COMMAND}" "${color_normal}" >&2' DEBUG
}

########################################
###   MAIN PROGRAM BOOTSTRAP LOGIC   ###
########################################

# Save current working directory for cleanup on exit
pushd . &> /dev/null

# Trap all signals that cause script to exit & run cleanup function before exiting
trap 'cleanup' SIGINT SIGTERM ERR EXIT
trap 'printf "\n%s+ PIPELINE ERROR - exit code %s - cleaning up %s\n" "${color_red}" "$?" "${color_normal}"' SIGINT SIGTERM ERR

# Get ci_utils.sh from anchore test-infra repo - used for common functions
# If running on test-infra container ci_utils.sh is installed to /usr/local/bin/
# if [[ -f /usr/local/bin/ci_utils.sh ]]; then
#     source ci_utils.sh
# elif [[ -f "${WORKSPACE}/test-infra" ]]; then
#     source "${WORKSPACE}/test-infra/scripts/ci_utils.sh"
# else
#     git clone https://github.com/anchore/test-infra "${WORKSPACE}/test-infra"
#     source "${WORKSPACE}/test-infra/scripts/ci_utils.sh"
# fi

# Setup terminal colors for printing
export TERM=xterm
color_red=$(tput setaf 1)
color_cyan=$(tput setaf 6)
color_yellow=$(tput setaf 3)
color_normal=$(tput setaf 9)
echo

set_environment_variables

# If no params are passed to script, build the image
# Run script with the 'test' param to execute the full pipeline locally
# Run script with the 'ci' param to execute a fully mocked CircleCI pipeline, running in docker
# If first param is a valid function name, execute the function & pass all following params to function
if [[ "$#" -eq 0 ]]; then
    display_usage >&2
    exit 1
elif [[ "$1" == 'build' ]];then
    build
elif [[ "$1" == 'test' ]]; then
    main
elif [[ "$1" == 'ci' ]]; then
    ci_test_run_workflow
else
    export SKIP_FINAL_CLEANUP=true
    if declare -f "$1" > /dev/null; then
        "$@"
    else
        display_usage >&2
        printf "%sERROR - %s is not a valid function name %s\n" "$color_red" "$1" "$color_normal" >&2
        exit 1
    fi
fi