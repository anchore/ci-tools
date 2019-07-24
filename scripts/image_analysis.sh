#!/usr/bin/env bash

set -eo pipefail

display_usage() {
cat << EOF

Anchore Engine Inline Analyzer --

  Script for performing analysis on local docker images, utilizing Anchore Engine analyzer subsystem.
  After image is analyzed, the resulting Anchore image archive is sent to a remote Anchore Engine installation
  using the -r <URL> option. This allows inline_analysis data to be persisted & utilized for reporting.

  Images should be built & tagged locally.

    Usage: ${0##*/} [ OPTIONS ] <FULL_IMAGE_TAG>

      -a <TEXT>  [optional] Add annotations (ex: -a 'key=value,key=value')
      -d <PATH>  [optional] Specify image digest (ex: -d 'sha256:<64 hex characters>')
      -f <PATH>  [optional] Path to Dockerfile (ex: -f ./Dockerfile)
      -i <TEXT>  [optional] Specify image ID used within Anchore Engine (ex: -i '<64 hex characters>')
      -m <PATH>  [optional] Path to Docker image manifest (ex: -m ./manifest.json)
      -t <TEXT>  [optional] Specify timeout for image analysis in seconds. Defaults to 300s. (ex: -t 500)
      -g  [optional] Generate an image digest from docker save tarball

EOF
}

get_and_validate_options() {
    # parse options
    while getopts ':a:d:f:i:m:t:gh' option; do
        case "${option}" in
            a  ) a_flag=true; ANCHORE_ANNOTATIONS="$OPTARG";;
            d  ) d_flag=true; IMAGE_DIGEST_SHA="$OPTARG";;
            f  ) f_flag=true; DOCKERFILE="/anchore-engine/$(basename $OPTARG)";;
            i  ) i_flag=true; ANCHORE_IMAGE_ID="$OPTARG";;
            m  ) m_flag=true; MANIFEST_FILE="/anchore-engine/$(basename $OPTARG)";;
            t  ) t_flag=true; TIMEOUT="$OPTARG";;
            g  ) g_flag=true;;
            h  ) display_usage; exit;;
            \? ) printf "\n\t%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
            :  ) printf "\n\t%s\n\n%s\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
        esac
    done
    shift "$((OPTIND - 1))"

    export TIMEOUT=${TIMEOUT:=300}

    # Ensure only a single image tag is passed after options
    if [[ "${#@}" -gt 1 ]]; then
        printf '\n\t%s\n\n' "ERROR - only 1 image tag can be analyzed at a time" >&2
        display_usage >&2
        exit 1
    else
        IMAGE_TAG="$1"
    fi

    if [[ "$f_flag" ]] && [[ ! -f "$DOCKERFILE" ]]; then
        printf '\n\t%s\n\n' "ERROR - invalid path to dockerfile provided - $DOCKERFILE" >&2
        display_usage >&2
        exit 1
    elif [[ "$m_flag" ]] && [[ ! -f "$MANIFEST_FILE" ]]; then
        printf '\n\t%s\n\n' "ERROR - invalid path to image manifest file provided - $MANIFEST_FILE" >&2
        display_usage >&2
        exit 1
    elif [[ "$p_flag" ]] && ([[ "$m_flag" ]] || [[ "$d_flag" ]]); then
        printf '\n\t%s\n\n' "ERROR - cannot specify manifest file or digest when pulling image from registry" >&2
        display_usage >&2
        exit 1
    fi
}

main() {
    get_and_validate_options "$@"

    if [[ "$IMAGE_TAG" =~ (.*/|)([a-zA-Z0-9_.-]+)[:]?([a-zA-Z0-9_.-]*) ]]; then
        IMAGE_FILE_NAME="/anchore-engine/${BASH_REMATCH[2]}+${BASH_REMATCH[3]:-latest}.tar"
        if [[ ! -f "$IMAGE_FILE_NAME" ]]; then
            cat <&0 > "$IMAGE_FILE_NAME"
            printf '%s\n' "Successfully prepared image archive -- $IMAGE_FILE_NAME"
        fi
    elif [[ -f "/anchore-engine/$(basename ${IMAGE_TAG})" ]]; then
        IMAGE_FILE_NAME="/anchore-engine/$(basename ${IMAGE_TAG})"
    else
        printf '\n\t%s\n\n' "ERROR - Could not find file for $IMAGE_TAG" >&2
        display_usage >&2
        exit 1
    fi

    if [[ "$g_flag" ]]; then
        IMAGE_DIGEST_SHA=$(skopeo inspect --raw "docker-archive:///${IMAGE_FILE_NAME}" | jq -r .config.digest)
    fi

    # analyze image with anchore-engine
    ANALYZE_CMD=('anchore-manager analyzers exec')
    ANALYZE_CMD+=('--tag "$IMAGE_TAG"') 
    if [[ ! -z "$IMAGE_DIGEST_SHA" ]]; then
        ANALYZE_CMD+=('--digest "$IMAGE_DIGEST_SHA"') 
    fi
    if [[ ! -z "$MANIFEST_FILE" ]]; then
        ANALYZE_CMD+=('--manifest "$MANIFEST_FILE"')
    fi
    if [[ "$f_flag" ]]; then
        ANALYZE_CMD+=('--dockerfile "$DOCKERFILE"')
    fi
    if [[ "$i_flag" ]]; then
        ANALYZE_CMD+=('--image-id "$ANCHORE_IMAGE_ID"')
    fi
    if [[ "$a_flag" ]]; then
        # transform all commas to spaces & cast to an array
        local annotationArray=(${ANCHORE_ANNOTATIONS//,/ })
        for i in "${annotationArray[@]}"; do
            ANALYZE_CMD+=("--annotation $i")
        done
    fi

    ANALYZE_CMD+=('"$IMAGE_FILE_NAME" /anchore-engine/image-analysis-archive.tgz > /dev/null')
    printf '\n%s' "Analyzing ${IMAGE_TAG}..."
    eval "${ANALYZE_CMD[*]}"
}

main "$@"