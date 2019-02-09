#!/bin/bash

set -e

stateless_anchore_image="${ANCHORE_CI_IMAGE:-docker.io/anchore/private_testing:stateless_ci}"

display_usage() {
    echo "${0} - Script for analyzing local docker images using Anchore Engine in stateless mode."
    printf '\n\t%s\n\n' "Usage: ${0} image_1 [ image_2 ... ]"
}

if [[ "$#" -eq 0 ]]; then
    printf '\n%s\n\n' "Error executing script - requires at least 1 image name as input."
    display_usage
    exit 1
fi

declare -a image_names=()

for i in "$@"; do
    image_names+=("${i}")
done

fail_count=0
declare -a failed_images=()
declare -a scan_images=()

for i in "${image_names[@]}"; do
    docker inspect "${i}" &> /dev/null || failed_images+=("${i}")
    if [[ "${failed_images[@]}" =~ "${i}" ]]; then
        ((fail_count+=1))
    else
        scan_images+=("${i}")
    fi
done

if [[ "${#failed_images[@]}" -gt 0 ]]; then
    printf '\n%s\n\n' "## Please pull, build and/or tag all images before attempting analysis again. ##"
    if [[ ${fail_count} -ge "${#image_names[@]}" ]]; then
        printf '%s\n\n' "ERROR - no local docker images specified in script input: ${0} ${image_names[*]}"
        display_usage
        exit 1
    fi
    for i in "${failed_images[@]}"; do
        printf '\t%s\n' "Could not find image locally - ${i}"
    done
    echo
fi

if [[ -z "$ANCHORE_CI_IMAGE" ]]; then
    docker pull "${stateless_anchore_image}"
fi

for i in "${scan_images[@]}"; do
    echo "Preparing ${i} for analysis..."
    name="${RANDOM:-stateless}-anchore-engine"
    docker save "${i}" | docker run -i --name "${name}" "${stateless_anchore_image}" ${i}
    docker cp "${name}:/anchore-engine/anchore-reports/" ./
    docker rm "${name}" > /dev/null
done