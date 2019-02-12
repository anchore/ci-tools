#!/bin/bash

set -e

display_usage() {
cat << EOF

  For performing vulnerability analysis on local docker images, utilizing Anchore Engine in stateless mode.
  
  Usage: ${0##*/} [ -d ./Dockerfile ] [ -p ./policy.json ] [ IMAGE_ONE ] [ IMAGE_TWO ... ]

      -d Dockerfile path (optional)
      -p Anchore policy bundle path (optional)
 
EOF
}

cleanup() {
    ret="$?"
    set +e
    declare docker_id="${name:-$(docker ps -a | grep 'stateless-anchore-engine' | awk '{print $1}')}"
    if [[ ! -z "$docker_id" ]]; then
        for i in $docker_id; do
            printf '\n%s\n' "Cleaning up docker container: $docker_id"
            docker kill "$i" &> /dev/null
            docker rm "$i" &> /dev/null
            unset name
        done
    fi
    set -e
    exit "$ret"
}

trap 'cleanup' EXIT SIGTERM SIGINT

# Parse options
while getopts ':d:p:h' option; do
  case "$option" in
    h  ) display_usage >&2; exit;;
    d  ) d_flag=true; dockerfile="$OPTARG";;
    p  ) p_flag=true; policy_bundle="$OPTARG";;
    \? ) printf "\n\t%s\n\n" "  Invalid option: -${OPTARG}"; display_usage >&2; exit 1;;
    :  ) printf "\n\t%s\n\n%s\n\n" "  Option -${OPTARG} requires an argument."; display_usage >&2; exit 1;;
  esac
done

shift "$((OPTIND - 1))"

if [[ "${#@}" -eq 0 ]]; then
    printf '\n\t%s\n\n' "ERROR - $0 requires at least 1 image name as input."
    display_usage
    exit 1
elif [[ ! $(which docker) ]]; then
    printf '\n\t%s\n\n' 'ERROR - Docker is not installed or cannot be found in $PATH.'
    exit 1
elif [[ "$d_flag" ]] && [[ "${#@}" -gt 1 ]]; then
    printf '\n\t%s\n\n' 'ERROR - If specifying a Dockerfile, only 1 image can be scanned at a time.'
    display_usage
    exit 1
fi

stateless_anchore_image="${ANCHORE_CI_IMAGE:-docker.io/anchore/private_testing:stateless_ci}"
image_names=()
failed_images=()
scan_images=()

for i in "$@"; do
    if [[ "$i" =~ [a-zA-Z0-9/_.-]+:[a-zA-Z0-9_-]+ ]]; then
        if [[ ! "${image_names[@]}" =~ "$i" ]]; then
            image_names+=("$i")
        fi
    else
        printf '\n\t%s\n\n' "ERROR - not a valid docker image name: $i"
        display_usage
        exit 1
    fi
done

for i in "${image_names[@]}"; do
    docker inspect "$i" &> /dev/null || failed_images+=("$i")
    if [[ ! "${failed_images[@]}" =~ "$i" ]]; then
        scan_images+=("$i")
    fi
done

if [[ "${#failed_images[@]}" -gt 0 ]]; then
    printf '\n\t%s\n\n' "## Please pull, build and/or tag all images before attempting analysis again. ##"
    if [[ "${#failed_images[@]}" -ge "${#image_names[@]}" ]]; then
        printf '\t%s\n\n' "ERROR - no local docker images specified in script input: $0 ${image_names[*]}"
        display_usage
        exit 1
    fi
    for i in "${failed_images[@]}"; do
        printf '\t\t%s\n' "Could not find image locally - $i"
    done
    echo
fi

if [[ -z "$ANCHORE_CI_IMAGE" ]]; then
    docker pull "$stateless_anchore_image"
fi

for i in "${scan_images[@]}"; do
    echo "Preparing image for analysis: $i"
    name="${RANDOM:-TEMP}-stateless-anchore-engine"
    if [[ "$d_flag" ]] && [[ "$p_flag" ]]; then
        docker save "$i" | docker run -i --name "$name" "$stateless_anchore_image" -d"$(cat $dockerfile)" -p"$(cat $policy_bundle)" "$i"
    elif [[ "$d_flag" ]]; then
        docker save "$i" | docker run -i --name "$name" "$stateless_anchore_image" -d"$(cat $dockerfile)" "$i"
    elif [[ "$p_flag" ]]; then
        docker save "$i" | docker run -i --name "$name" "$stateless_anchore_image" -p"$(cat $policy_bundle)" "$i"
    else
        docker save "$i" | docker run -i --name "$name" "$stateless_anchore_image" "$i"
    fi
    docker cp "${name}:/anchore-engine/anchore-reports/" ./
done