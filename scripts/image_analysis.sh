#!/usr/bin/env bash

set -eo pipefail

if [[ "${VERBOSE}" ]]; then
    set -x
fi

########################
### GLOBAL VARIABLES ###
########################

export TIMEOUT=${TIMEOUT:=300}
# defaults for variables set by script options
ANALYZE_CMD=()
ANCHORE_ANNOTATIONS=""
IMAGE_DIGEST_SHA=""
ANCHORE_IMAGE_ID=""
IMAGE_TAG=""
DOCKERFILE="/anchore-engine/Dockerfile"
MANIFEST_FILE="/anchore-engine/manifest.json"


display_usage() {
cat << EOF

Anchore Engine Inline Analyzer --

  Script for performing analysis on local docker images, utilizing Anchore Engine analyzer subsystem.
  After image is analyzed, the resulting Anchore image archive is sent to a remote Anchore Engine installation
  using the -r <URL> option. This allows inline_analysis data to be persisted & utilized for reporting.

  Images should be built & tagged locally.

    Usage: ${0##*/} [ OPTIONS ] <FULL_IMAGE_TAG>

      -u <TEXT>  [required] Anchore user account name associated with image analysis (ex: -u 'admin')
      -a <TEXT>  [optional] Add annotations (ex: -a 'key=value,key=value')
      -d <PATH>  [optional] Specify image digest (ex: -d 'sha256:<64 hex characters>')
      -f <PATH>  [optional] Path to Dockerfile (ex: -f ./Dockerfile)
      -i <TEXT>  [optional] Specify image ID used within Anchore Engine (ex: -i '<64 hex characters>')
      -m <PATH>  [optional] Path to Docker image manifest (ex: -m ./manifest.json)
      -t <TEXT>  [optional] Specify timeout for image analysis in seconds. Defaults to 300s. (ex: -t 500)
      -g  [optional] Generate an image digest from docker save tarball

EOF
}

main() {
    trap 'error' SIGINT
    get_and_validate_options "$@"

    local base_image_name=${IMAGE_TAG##*/}
    local image_file_path="/anchore-engine/${base_image_name}.tar"

    if [[ ! -f "${image_file_path}" ]]; then
        printf '\n\t%s\n\n' "ERROR - Could not find file: ${image_file_path}" >&2
        display_usage >&2
        exit 1
    fi

    # if filename has a : in it, replace it with _ to avoid skopeo errors
    if [[ "${base_image_name}" =~ [:] ]]; then
        local new_file_path="/anchore-engine/${base_image_name//:/_}.tar"
        mv "${image_file_path}" "${new_file_path}"
        image_file_path="${new_file_path}"
    fi

    # analyze image with anchore-engine
    ANALYZE_CMD=('anchore-manager analyzers exec')
    ANALYZE_CMD+=('--tag "${IMAGE_TAG}"')
    ANALYZE_CMD+=('--account-id "${ANCHORE_ACCOUNT}"')

    if [[ "${g_flag}" ]]; then
        IMAGE_DIGEST_SHA=$(skopeo inspect --raw "docker-archive:///${image_file_path}" | jq -r .config.digest)
    fi
    if [[ "${d_flag}" ]] || [[ "${g_flag}" ]]; then
        ANALYZE_CMD+=('--digest "${IMAGE_DIGEST_SHA}"') 
    fi
    if [[ "${m_flag}" ]]; then
        ANALYZE_CMD+=('--manifest "${MANIFEST_FILE}"')
    fi
    if [[ "${f_flag}" ]]; then
        ANALYZE_CMD+=('--dockerfile "${DOCKERFILE}"')
    fi
    if [[ "${i_flag}" ]]; then
        ANALYZE_CMD+=('--image-id "${ANCHORE_IMAGE_ID}"')
    fi
    if [[ "${a_flag}" ]]; then
        # transform all commas to spaces & cast to an array
        local annotation_array=(${ANCHORE_ANNOTATIONS//,/ })
        for i in "${annotation_array[@]}"; do
            ANALYZE_CMD+=("--annotation $i")
        done
    fi

    ANALYZE_CMD+=('"$image_file_path" /anchore-engine/image-analysis-archive.tgz > /dev/null')
    printf '\n%s\n' "Analyzing ${IMAGE_TAG}..."
    eval "${ANALYZE_CMD[*]}"
}

get_and_validate_options() {
    # parse options
    while getopts ':u:a:d:f:i:m:t:gh' option; do
        case "${option}" in
            a  ) a_flag=true; ANCHORE_ANNOTATIONS="${OPTARG}";;
            d  ) d_flag=true; IMAGE_DIGEST_SHA="${OPTARG}";;
            f  ) f_flag=true; DOCKERFILE="/anchore-engine/$(basename ${OPTARG})";;
            i  ) i_flag=true; ANCHORE_IMAGE_ID="${OPTARG}";;
            m  ) m_flag=true; MANIFEST_FILE="/anchore-engine/$(basename ${OPTARG})";;
            t  ) t_flag=true; TIMEOUT="${OPTARG}";;
            u  ) u_flag=true; ANCHORE_ACCOUNT="${OPTARG}";;
            g  ) g_flag=true;;
            h  ) display_usage; exit;;
            \? ) printf "\n\t%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
            :  ) printf "\n\t%s\n\n%s\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
        esac
    done
    shift "$((OPTIND - 1))"

    # Ensure only a single image tag is passed after options
    if [[ "${#@}" -gt 1 ]]; then
        printf '\n\t%s\n\n' "ERROR - only 1 image tag can be analyzed at a time" >&2
        display_usage >&2
        exit 1
    else
        IMAGE_TAG="$1"
    fi

    if [[ ! "${u_flag}" ]]; then
	printf '\n\t%s\n\n' "ERROR - must specify an anchore engine account name with -u" >&2
	display_usage >&2
	exit 1
    elif [[ "${f_flag}" ]] && [[ ! -f "${DOCKERFILE}" ]]; then
        printf '\n\t%s\n\n' "ERROR - invalid path to dockerfile provided - ${DOCKERFILE}" >&2
        display_usage >&2
        exit 1
    elif [[ "${m_flag}" ]] && [[ ! -f "${MANIFEST_FILE}" ]]; then
        printf '\n\t%s\n\n' "ERROR - invalid path to image manifest file provided - ${MANIFEST_FILE}" >&2
        display_usage >&2
        exit 1
    elif [[ "${g_flag}" ]] && ([[ "${m_flag}" ]] || [[ "${d_flag}" ]]); then
        printf '\n\t%s\n\n' "ERROR - cannot specify manifest file or digest when using the -g option" >&2
        display_usage >&2
        exit 1
    fi
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
