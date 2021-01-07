#!/usr/bin/env bash

# Fail on any errors, including in pipelines
# Don't allow unset variables. Trace all functions with DEBUG trap
set -eo pipefail -o functrace

display_usage() {
    echo "${color_yellow}"
    cat << EOF
    Anchore Build Pipeline ---

    CI pipeline script for Anchore container images.
    Allows building container images & mocking CI pipelines.

    The following overide environment variables are available:
        
        SKIP_CLEANUP = [ true | false ] - skips cleanup job that runs on exit (kills containers & removes workspace)
        IMAGE_REPO = docker.io/example/test - specify a custom image repo to build/test
        WORKING_DIRECTORY = /home/test/workdir - used as a temporary workspace for build/test
        WORKSPACE = /home/test/workspace - used to store temporary artifacts

    Usage: ${0##*/} [ -s ] [ build | test | ci | function_name ] < build_version >
        
        s - Build slim preloaded image without nvd2 feed data
        build - Build image tagged IMAGE_REPO:dev using specified version of anchore-engine & engine-db-preload
        test - Run test pipeline on specified image version locally on your workstation
        ci - Run mocked CircleCI pipeline using Docker-in-Docker
        function_name - Invoke a function directly using build environment
EOF
    echo "${color_normal}"
}

##############################################
###   PROJECT SPECIFIC ENVIRONMENT SETUP   ###
##############################################

# Specify what versions to build & what version should get 'latest' tag
export BUILD_VERSIONS=('v0.9.0' 'v0.8.2' 'v0.8.1' 'v0.8.0' 'v0.7.3' 'issue-712')
export LATEST_VERSION='v0.9.0'

# PROJECT_VARS are custom vars that are modified between projects
# Expand all required ENV vars or set to default values with := variable substitution
# Use eval on $CIRCLE_WORKING_DIRECTORY to ensure default value (~/project) gets expanded to the absolute path
PROJECT_VARS=( \
    "IMAGE_REPO=${IMAGE_REPO:=anchore/inline-scan}" \
    "PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME:=ci-tools}" \
    "WORKING_DIRECTORY=${WORKING_DIRECTORY:=$(eval echo ${CIRCLE_WORKING_DIRECTORY:="${HOME}/tempci_${IMAGE_REPO##*/}_${RANDOM}/project"})}" \
    "WORKSPACE=${WORKSPACE:=$(dirname "$WORKING_DIRECTORY")/workspace}" \
)
# These vars are static & defaults should not need to be changed
PROJECT_VARS+=( \
    "CI=${CI:=false}" \
    "GIT_BRANCH=${CIRCLE_BRANCH:=$(git rev-parse --abbrev-ref HEAD || echo 'dev')}" \
    "SKIP_FINAL_CLEANUP=${SKIP_FINAL_CLEANUP:=false}" \
)


########################################
###   MAIN PROGRAM BOOTSTRAP LOGIC   ###
########################################

main() {
    if [[ "$#" -eq 0 ]]; then
        echo "ERROR - $0 requires at least 1 input" >&2
        display_usage >&2
        exit 1
    fi

    while getopts ':sh' option; do
        case "${option}" in
            s  ) s_flag=true;;
            h  ) display_usage; exit;;
            \? ) printf "\n\t%s\n\n" "Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
            :  ) printf "\n\t%s\n\n%s\n\n" "Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
        esac
    done
    shift "$((OPTIND - 1))"

    PROJECT_VARS+=( \
        "SLIM_BUILD=${s_flag:=false}" \
    )

    # Save current working directory for cleanup on exit
    pushd . &> /dev/null

    # Trap all signals that cause script to exit & run cleanup function before exiting
    trap 'cleanup' SIGINT SIGTERM ERR EXIT
    trap 'printf "\n%s+ PIPELINE ERROR - exit code %s - cleaning up %s\n" "${color_red}" "$?" "${color_normal}"' SIGINT SIGTERM ERR

    # Get ci_utils.sh from anchore test-infra repo - used for common functions
    # If running on test-infra container ci_utils.sh is installed to /usr/local/bin/
    # if [[ -f /usr/local/bin/ci_utils.sh ]]; then
    #     source ci_utils.sh
    # elif [[ -f "${WORKSPACE}/test-infra/scripts/ci_utils.sh" ]]; then
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

    setup_and_print_env_vars

    # Trap all bash commands & print to screen. Like using set -v but allows printing in color
    trap 'printf "%s+ %s%s\n" "${color_cyan}" "$BASH_COMMAND" "${color_normal}" >&2' DEBUG

    # Use the 'build' param to build the latest image
    if [[ "$1" == 'build' ]]; then
        setup_build_environment
        build_image "${2:-latest}"
    # Use the 'test' param to execute the full pipeline locally on latest versions
    elif [[ "$1" == 'test' ]]; then
        build_and_save_images "${2:-dev}"
        test_built_images "${2:-dev}"
        load_image_and_push_dockerhub "${2:-dev}"
    # Use the 'ci' param to execute a fully mocked CircleCI pipeline, utilizing docker in docker
    elif [[ "$1" == 'ci' ]]; then
        setup_build_environment
        ci_test_job 'docker.io/anchore/test-infra:latest' 'build_and_save_images'
        ci_test_job 'docker.io/anchore/test-infra:latest' 'test_built_images'
        ci_test_job 'docker.io/anchore/test-infra:latest' 'load_image_and_push_dockerhub'
    else
        # If first param is a valid function name, execute the function & pass all following params to function
        export SKIP_FINAL_CLEANUP=true
        if declare -f "$1" > /dev/null; then
            "$@"
        else
            display_usage >&2
            printf "%sERROR - %s is not a valid function name %s\n" "${color_red}" "$1" "${color_normal}" >&2
            exit 1
        fi
    fi
}

# The cleanup() function that runs whenever the script exits
cleanup() {
    ret="$?"
    set +euo pipefail
    if [[ "${ret}" -eq 0 ]]; then
        set +o functrace
    fi
    if [[ "${SKIP_FINAL_CLEANUP}" == false ]]; then
        deactivate 2> /dev/null
        docker-compose down --volumes 2> /dev/null
        if [[ "${#DOCKER_RUN_IDS[@]}" -ne 0 ]]; then
            for i in "${DOCKER_RUN_IDS[@]}"; do
                docker kill $i 2> /dev/null
                docker rm $i 2> /dev/null
            done
        fi
        popd &> /dev/null
        if [[ "${WORKING_DIRECTORY}" =~ 'tempci' ]]; then
            rm -rf "$(dirname ${WORKING_DIRECTORY})"
        fi
    else
        echo "Workspace Dir: ${WORKSPACE}"
        echo "Working Dir: ${WORKING_DIRECTORY}"
    fi
    popd &> /dev/null
    exit "${ret}"
}

#################################################################
###   FUNCTIONS CALLED DIRECTLY BY CIRCLECI - RUNTIME ORDER   ###
#################################################################

build_and_save_images() {
    local build_version="$1"
    echo "build_version=${build_version}"
    setup_build_environment
    # build images for every specified version
    if [[ "${build_version}" == 'all' ]]; then
        for version in ${BUILD_VERSIONS[@]}; do
            echo "Building ${IMAGE_REPO}:dev-${version}"
            git reset --hard
            # exit script if tag does not exist
            git checkout "tags/${version}" || { if [[ "${CI}" == 'false' ]]; then true && local no_tag=true; else exit 1; fi; };
            build_image "${version}"
            test_inline_image "${version}"
            save_image "${version}"
            # Move back to previously checked out branch
            if ! "${no_tag:=false}"; then
                git reset --hard
                git checkout @{-1}
            fi
            unset no_tag
        done
    else
        echo "Buiding ${IMAGE_REPO}:${build_version}"
        if [[ "${build_version}" == 'latest' ]]; then
            git reset --hard
            git checkout "tags/${LATEST_VERSION}"
        elif [[ ! "${build_version}" == 'dev' ]]; then
            git reset --hard
            git checkout "tags/${build_version}"
        fi
        build_image "${build_version}"
        test_inline_image "${build_version}"
        save_image "${build_version}"
        if [[ ! "${build_version}" == 'dev' ]]; then
            git reset --hard
            git checkout @{-1}
        fi
    fi
}

test_built_images() {
    local build_version="$1"
    echo "build_version=${build_version}"
    setup_build_environment
    if [[ "${build_version}" == 'all' ]]; then
        for version in ${BUILD_VERSIONS[@]}; do
            unset ANCHORE_CI_IMAGE
            load_image "${version}"
            export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev-${version}"
            git reset --hard
            git checkout "tags/${version}" || { if [[ "$CI" == 'false' ]]; then true && local no_tag=true; else exit 1; fi; };
            if [[ "${CI}" == 'true' ]]; then
                test_inline_script "https://raw.githubusercontent.com/anchore/ci-tools/${version}/scripts/inline_scan"
            else
                test_inline_script "${WORKING_DIRECTORY}/scripts/inline_scan"
            fi
            # Move back to previously checked out branch
            if ! "${no_tag:=false}"; then
                git reset --hard
                git checkout @{-1}
            fi
            unset no_tag
        done
    else
        load_image "${build_version}"
        export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev"
        if [[ "${build_version}" == 'latest' || "${build_version}" == 'dev' ]] && [[ "${CI}" == 'true' ]] ; then
            test_inline_script "https://raw.githubusercontent.com/anchore/ci-tools/${GIT_BRANCH}/scripts/inline_scan"
        elif [[ "${build_version}" == 'latest' || "${build_version}" == 'dev' ]] && [[ "${CI}" == 'false' ]] ; then
            test_inline_script "${WORKING_DIRECTORY}/scripts/inline_scan"
        else
            test_inline_script "https://raw.githubusercontent.com/anchore/ci-tools/${build_version}/scripts/inline_scan"
        fi
    fi
}

load_image_and_push_dockerhub() {
    local build_version="$1"
    echo "build_version=${build_version}"
    setup_build_environment
    if [[ "${build_version}" == 'all' ]]; then
        for version in ${BUILD_VERSIONS[@]}; do
            load_image "${version}"
            push_dockerhub "${version}"
        done
    else
        load_image "${build_version}"
        push_dockerhub "${build_version}"
    fi
}


###########################################################
###   PROJECT SPECIFIC FUNCTIONS - ALPHABETICAL ORDER   ###
###########################################################

build_image() {
    local anchore_version="$1"
    echo "anchore_version=${anchore_version}"
    # if the DB_PRELOAD_IMAGE variable is set, use it as the engine-db-preload image
    if [[ -z "${DB_PRELOAD_IMAGE}" ]]; then
        if [[ "${SLIM_BUILD}" == 'true' ]]; then
            local db_image="anchore/engine-db-preload-slim:${anchore_version}"
        else
            local db_image="anchore/engine-db-preload:${anchore_version}"
        fi
    else
        local db_image="${DB_PRELOAD_IMAGE}"
    fi
    if ! docker pull "${db_image}" &>/dev/null && ! docker inspect "${db_image}" &>/dev/null; then
        db_image="anchore/engine-db-preload:latest"
        docker pull "${db_image}"
    fi

    echo "Copying anchore-bootstrap.sql.gz from ${db_image} image..."
    db_preload_id=$(docker run -d --entrypoint tail "${db_image}" /dev/null | tail -n1)
    docker cp "${db_preload_id}:/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz" "${WORKING_DIRECTORY}/anchore-bootstrap.sql.gz"
    DOCKER_RUN_IDS+=("${db_preload_id:0:6}")

    if [[ "${anchore_version}" == "dev" ]]; then
        docker build --build-arg "ANCHORE_REPO=anchore/anchore-engine-dev" --build-arg "ANCHORE_VERSION=latest" -t "${IMAGE_REPO}:dev" .
    elif [[ "${anchore_version}" == "issue-712" ]]; then
        docker build --build-arg "ANCHORE_REPO=anchore/anchore-engine-dev" --build-arg "ANCHORE_VERSION=issue-712" -t "${IMAGE_REPO}:dev" .
    else
        docker build --build-arg "ANCHORE_VERSION=${anchore_version}" -t "${IMAGE_REPO}:dev" .
    fi
    local docker_name="${RANDOM:-temp}-db-preload"
    docker run -it --name "${docker_name}" "${IMAGE_REPO}:dev" debug /bin/bash -c "anchore-cli system wait --feedsready 'vulnerabilities' && anchore-cli system status && anchore-cli system feeds list"
    local docker_id=$(docker inspect ${docker_name} | jq '.[].Id')
    docker kill "${docker_id}" && docker rm "${docker_id}"
    DOCKER_RUN_IDS+=("${docker_id:0:6}")
    rm -f "${WORKING_DIRECTORY}/anchore-bootstrap.sql.gz"

    docker tag  "${IMAGE_REPO}:dev" "${IMAGE_REPO}:dev-${anchore_version}"
}

install_dependencies() {
    # No dependencies to install for this project
    true
}

test_inline_image() {
    local anchore_version="$1"
    echo "anchore_version=${anchore_version}"
    export ANCHORE_CI_IMAGE="${IMAGE_REPO}:dev"
    cat "${WORKING_DIRECTORY}/scripts/inline_scan" | bash -s -- -p  alpine:latest ubuntu:latest
}

test_inline_script() {
    local INLINE_URL="$1"
    if [[ "${INLINE_URL}" =~ 'http' ]]; then
        local exec_cmd=curl
    else
        local exec_cmd=cat
    fi
    ${exec_cmd} -s "${INLINE_URL}" | bash -s -- -p  centos:latest
    # test script with dockerfile
    docker pull docker:stable-git
    ${exec_cmd} -s "${INLINE_URL}" | bash -s -- -d ".circleci/Dockerfile" docker:stable-git
    # test script with policy bundle
    ${exec_cmd} -s "${INLINE_URL}" | bash -s -- -p  -t 1500 -b ".circleci/.anchore/policy_bundle.json" "anchore/anchore-engine:latest"
    # test script with policy bundle & dockerfile
    pushd "${WORKING_DIRECTORY}/.circleci/node_critical_pass/"
    docker build -t example.com:5000/ci-test_1/node_critical-pass:latest .
    popd
    ${exec_cmd} -s "${INLINE_URL}" | bash -s -- -t 500 -d ".circleci/node_critical_pass/Dockerfile" -b ".circleci/.anchore/policy_bundle.json" example.com:5000/ci-test_1/node_critical-pass
}


########################################################
###   COMMON HELPER FUNCTIONS - ALPHABETICAL ORDER   ###
########################################################

ci_test_job() {
    local ci_image=$1
    local ci_function=$2
    local docker_name="${RANDOM:-TEMP}-ci-test"
    docker run --net host -it --name "${docker_name}" -v $(dirname "${WORKING_DIRECTORY}"):$(dirname "${WORKING_DIRECTORY}"):delegated -v /var/run/docker.sock:/var/run/docker.sock "${ci_image}" /bin/sh -c "\
        cd $(dirname "${WORKING_DIRECTORY}") && \
        cp ${WORKING_DIRECTORY}/scripts/build.sh $(dirname "${WORKING_DIRECTORY}")/build.sh && \
        export WORKING_DIRECTORY=${WORKING_DIRECTORY} && \
        sudo -E bash $(dirname "${WORKING_DIRECTORY}")/build.sh ${ci_function} \
    "
    local docker_id=$(docker inspect ${docker_name} | jq '.[].Id')
    docker kill "${docker_id}" && docker rm "${docker_id}"
    DOCKER_RUN_IDS+=("${docker_id:0:6}")
}

load_image() {
    local anchore_version="$1"
    docker load -i "${WORKSPACE}/caches/${PROJECT_REPONAME}-${anchore_version}-dev.tar"
    docker tag ${IMAGE_REPO}:dev ${IMAGE_REPO}:dev-${anchore_version}
}

push_dockerhub() {
    local anchore_version="$1"
    if [[ "${CI}" == true ]]; then
        echo "${DOCKER_PASS}" | docker login -u "${DOCKER_USER}" --password-stdin
    fi
    # Push :latest or :[semver] tags to Dockerhub if on 'master' branch or a vX.X semver tag, and running in CircleCI
    if [[ "${GIT_BRANCH}" == 'master' || "${CIRCLE_TAG:=false}" =~ ^v[0-9]+(\.[0-9]+)*$ ]] && [[ "${CI}" == true ]] && [[ ! "${anchore_version}" == 'latest' ]]; then
        docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:${anchore_version}"
        echo "Pushing to DockerHub - ${IMAGE_REPO}:${anchore_version}"
        docker push "${IMAGE_REPO}:${anchore_version}"
        if [ "${anchore_version}" == "${LATEST_VERSION}" ]; then
            docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:latest"
            echo "Pushing to DockerHub - ${IMAGE_REPO}:latest"
            docker push "${IMAGE_REPO}:latest"
        fi
    else
        docker tag "${IMAGE_REPO}:dev-${anchore_version}" "anchore/private_testing:${IMAGE_REPO##*/}-${anchore_version}"
        echo "Pushing to DockerHub - anchore/private_testing:${IMAGE_REPO##*/}-${anchore_version}"
        if [[ "${CI}" == false ]]; then
            sleep 10
        fi
        docker push "anchore/private_testing:${IMAGE_REPO##*/}-${anchore_version}"
    fi
}

save_image() {
    local anchore_version="$1"
    mkdir -p "${WORKSPACE}/caches"
    docker save -o "${WORKSPACE}/caches/${PROJECT_REPONAME}-${anchore_version}-dev.tar" "${IMAGE_REPO}:dev"
}

setup_and_print_env_vars() {
    # Export & print all project env vars to the screen
    echo "${color_yellow}"
    printf "%s\n\n" "- ENVIRONMENT VARIABLES SET -"
    echo "BUILD_VERSIONS=${BUILD_VERSIONS[@]}"
    printf "%s\n" "LATEST_VERSION=${LATEST_VERSION}"
    for var in ${PROJECT_VARS[@]}; do
        export "${var}"
        printf "%s" "${color_yellow}"
        printf "%s\n" "${var}"
    done
    echo "${color_normal}"
    # If running tests manually, sleep for a few seconds to give time to visually double check that ENV is setup correctly
    if [[ "$CI" == false ]]; then
        sleep 5
    fi
    # Setup a variable for docker image cleanup at end of script
    declare -a DOCKER_RUN_IDS
    export DOCKER_RUN_IDS
}

setup_build_environment() {
    # Copy source code to $WORKING_DIRECTORY for mounting to docker volume as working dir
    if [[ ! -d "${WORKING_DIRECTORY}" ]]; then
        mkdir -p "${WORKING_DIRECTORY}"
        cp -a . "${WORKING_DIRECTORY}"
    fi
    mkdir -p "${WORKSPACE}/caches"
    pushd "${WORKING_DIRECTORY}"
    install_dependencies || true
}

main "$@"
