#!/usr/bin/env bash

set -eo pipefail

if [[ "${VERBOSE}" ]]; then
    set -x
fi

########################
### GLOBAL VARIABLES ###
########################

export TIMEOUT=${TIMEOUT:=300}
SCAN_FILES=()
FINISHED_IMAGES=()
# defaults for variables set by script options
FILE_NAME=""
IMAGE_NAME=""
POLICY_BUNDLE="/anchore-engine/policy_bundle.json"
DOCKERFILE="/anchore-engine/Dockerfile"


display_usage() {
cat << EOF

Anchore Engine Inline Scan --

  Docker entrypoint for performing vulnerability analysis on local docker images.

  Starts Anchore Engine, Postgresql 9.6, and Docker Registry. 
  Finds docker image archives copied or mounted to /anchore-engine in the form of image+tag.tar.
  Also supports taking stdin from the docker save command (use -i option to specify image name).


  Usage: ${0##*/} [ -f ] [ -r ] [ -d Dockerfile ] [ -b policy.json ] [ -i IMAGE_ONE ]

      -d  [optional] Dockerfile name - must be mounted/copied to /anchore-engine.
      -i  [optional] Image name or file name location (use image name if piping in docker save stdout).
      -b  [optional] Anchore policy bundle name - must be mounted/copied to /anchore-engine.
      -f  [optional] Exit script upon failed Anchore policy evaluation.
      -r  [optional] Generate analysis reports.

EOF
}

main() {
    trap 'error' SIGINT
    get_and_validate_options "$@"

    if [[ "${FILE_NAME}" ]]; then
        if [[ $(skopeo inspect "docker-archive:${FILE_NAME}") ]]; then 
            SCAN_FILES+=("$FILE_NAME")
        else 
            printf '\n\t%s\n\n' "ERROR - Invalid Docker image archive:  ${FILE_NAME}" >&2
            display_usage >&2
            exit 1
        fi
    else
        printf '%s\n\n' "Searching for Docker archive files in /anchore-engine."
        for i in $(find /anchore-engine -type f); do
            local file_name="$i"
            if [[ "${file_name}" =~ [:] ]]; then
                local new_file_name="${file_name//:/_}"
                mv "${file_name}" "${new_file_name}"
                file_name="${new_file_name}"
            fi
            if [[ $(skopeo inspect "docker-archive:${file_name}") ]] && [[ ! "${SCAN_FILES[@]}" =~ "${file_name}" ]]; then 
                SCAN_FILES+=("$file_name")
                printf '\t%s\n' "Found docker image archive:  ${file_name}"
            else 
                printf '\t%s\n' "Ignoring invalid docker archive:  ${file_name}" >&2
            fi
        done
    fi
    echo

    if [[ "${#SCAN_FILES[@]}" -gt 0 ]]; then
        for file in "${SCAN_FILES[@]}"; do
            prepare_image "${file}"
        done
    else
        printf '\n\t%s\n\n' "ERROR - No valid docker archives provided." >&2
        display_usage >&2
        exit 1
    fi

    if [[ "${b_flag}" ]]; then
        (anchore-cli --json policy add "${POLICY_BUNDLE}" | jq '.policyId' | xargs anchore-cli policy activate) || \
            printf "\n%s\n" "Unable to activate policy bundle - ${POLICY_BUNDLE} -- using default policy bundle." >&2
    fi

    if [[ "${#FINISHED_IMAGES[@]}" -ge 1 ]]; then
        if [[ "${r_flag}" ]]; then
            for image in "${FINISHED_IMAGES[@]}"; do
                anchore_ci_tools.py -r --image "${image}"
            done
        fi
        echo
        for image in "${FINISHED_IMAGES[@]}"; do
            printf '\t%s\n' "Policy Evaluation - ${image##*/}"
            printf '%s\n\n' "-----------------------------------------------------------"
            (set +o pipefail; anchore-cli evaluate check "${image}" --detail | tee /dev/null; set -o pipefail)
        done

        if [[ "${f_flag}" ]]; then
            for image in "${FINISHED_IMAGES[@]}"; do
                anchore-cli evaluate check "${image}"
            done
        fi
    fi
}

get_and_validate_options() {
    # Parse options
    while getopts ':d:b:i:fhr' option; do
        case "${option}" in
            d  ) d_flag=true; DOCKERFILE="/anchore-engine/$(basename $OPTARG)";;
            b  ) b_flag=true; POLICY_BUNDLE="/anchore-engine/$(basename $OPTARG)";;
            i  ) i_flag=true; IMAGE_NAME="${OPTARG}";;
            f  ) f_flag=true;;
            r  ) r_flag=true;;
            h  ) display_usage; exit;;
            \? ) printf "\n\t%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
            :  ) printf "\n\t%s\n\n%s\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
        esac
    done

    shift "$((OPTIND - 1))"

    # Test options to ensure they're all valid. Error & display usage if not.
    if [[ "${d_flag}" ]] && [[ ! "${i_flag}" ]]; then
        printf '\n\t%s\n\n' "ERROR - must specify an image when passing a Dockerfile." >&2
        display_usage >&2
        exit 1
    elif [[ "${d_flag}" ]] && [[ ! -f "${DOCKERFILE}" ]]; then
        printf '\n\t%s\n\n' "ERROR - Can not find dockerfile at: ${DOCKERFILE}" >&2
        display_usage >&2
        exit 1
    elif [[ "${b_flag}" ]] && [[ ! -f "${POLICY_BUNDLE}" ]]; then
        printf '\n\t%s\n\n' "ERROR - Can not find policy bundle file at: ${POLICY_BUNDLE}" >&2
        display_usage >&2
        exit 1
    fi

    if [[ "${i_flag}" ]]; then
        if [[ -f "/anchore-engine/${IMAGE_NAME##*/}" ]] && [[ "${IMAGE_NAME}" =~ [.]tar? ]]; then
            FILE_NAME="/anchore-engine/${IMAGE_NAME##*/}"
        elif [[ "${IMAGE_NAME}" =~ (.*/|)([a-zA-Z0-9_.-]+)[:]([a-zA-Z0-9_.-]*) ]]; then
            FILE_NAME="/anchore-engine/${IMAGE_NAME##*/}.tar"
            if [[ ! -f "${FILE_NAME}" ]]; then
                cat <&0 > "${FILE_NAME}"
            fi
            # Transform file name for skopeo functionality, replace : with _
            if [[ "${FILE_NAME}" =~ [:] ]]; then
                local new_file_name="${FILE_NAME//:/_}"
                mv "${FILE_NAME}" "${new_file_name}"
                FILE_NAME="${new_file_name}"
            fi
        else
            printf '\n\t%s\n\n' "ERROR - Could not find image file ${IMAGE_NAME}" >&2
            display_usage >&2
            exit 1
        fi
    fi
}

prepare_image() {
    local file="$1"

    if [[ -z "${IMAGE_NAME##*/}" ]]; then
        if [[ "${file}" =~ ([a-zA-Z0-9_.-]+)([:]|[_])([a-zA-Z0-9_.-]*)[.]tar$ ]]; then
            local image_repo="${BASH_REMATCH[1]}"
            local image_tag="${BASH_REMATCH[3]}"
        else
            local image_repo=$(basename "${file%%.*}")
            local image_tag="latest"
        fi
    elif [[ "${IMAGE_NAME##*/}" =~ (.*/|)([a-zA-Z0-9_.-]+)[:]([a-zA-Z0-9_.-]*) ]]; then
        local image_repo="${BASH_REMATCH[2]}"
        local image_tag="${BASH_REMATCH[3]:-latest}"
    elif [[ "${IMAGE_NAME##*/}" =~ ([a-zA-Z0-9_.-]*) ]]; then
        local image_repo="${BASH_REMATCH[1]}"
        local image_tag='latest'
    else
        printf '\n\t%s\n\n' "ERROR - Could not parse image file name ${IMAGE_NAME}" >&2
        display_usage >&2
        exit 1
    fi

    local anchore_image_name="${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_repo}:${image_tag}"    
    printf '%s\n\n' "Preparing ${IMAGE_NAME} for analysis"
    # pass to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    skopeo copy --dest-tls-verify=false "docker-archive:${file}" "docker://${anchore_image_name}" &
    wait_proc="$!"
    wait "${wait_proc}"
    printf '\n%s\n' "Image archive loaded into Anchore Engine using tag -- ${anchore_image_name#*/}"

    start_scan "${file}" "${anchore_image_name}"
}

start_scan() {
    local file="$1"
    local anchore_image_name="$2"
    local wait_proc=""

    if [[ "${d_flag}" ]] && [[ -f "${DOCKERFILE}" ]]; then
        anchore-cli image add "${anchore_image_name}" --dockerfile "${DOCKERFILE}" > /dev/null
    else
        anchore-cli image add "${anchore_image_name}" > /dev/null
    fi

    # pass to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    anchore_ci_tools.py --wait --timeout "${TIMEOUT}" --image "${anchore_image_name}" &
    wait_proc="$!"
    wait "${wait_proc}"

    FINISHED_IMAGES+=("${anchore_image_name}")
}

error() {
    set +e
    printf '\n\n\t%s\n\n' "ERROR - $0 received SIGTERM or SIGINT" >&2
    # kill python process in wait loop
    (pkill -f python3 &> /dev/null)
    # kill skopeo process in wait loop
    (pkill -f skopeo &> /dev/null)
    exit 130
}

main "$@"