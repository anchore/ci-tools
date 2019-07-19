#!/usr/bin/env bash

set -exo pipefail

display_usage() {
cat << EOF

Anchore Engine Inline Analyzer --

  Script for performing analysis on local docker images, utilizing Anchore Engine analyzer subsystem.
  After image is analyzed, the resulting Anchore image archive is sent to a remote Anchore Engine installation
  using the -r <URL> option. This allows inline_analysis data to be persisted & utilized for reporting.

  Images should be built & tagged locally.

    Usage: ${0##*/} analyze -r <REMOTE_URL> -u <USER> -P <PASSWORD> [ OPTIONS ] <FULL_IMAGE_TAG>

      -r <TEXT>  [required] URL to remote Anchore Engine API endpoint (ex: -h 'https://anchore.example.com:8228/v1')
      -u <TEXT>  [required] Username for remote Anchore Engine auth (ex: -u 'admin')
      -P <TEXT>  [required] Password for remote Anchore Engine auth (ex: -P 'foobar')

      -a <TEXT>  [optional] Add annotations (ex: -a 'key=value,key=value')
      -d <PATH>  [optional] Specify image digest (ex: -d 'sha256:<64 hex characters>')
      -f <PATH>  [optional] Path to Dockerfile (ex: -f ./Dockerfile)
      -i <TEXT>  [optional] Specify image ID used within Anchore Engine (ex: -i '<64 hex characters>')
      -m <PATH>  [optional] Path to Docker image manifest (ex: -m ./manifest.json)
      -t <TEXT>  [optional] Specify timeout for image analysis in seconds. Defaults to 300s. (ex: -t 500)
      -g  [optional] Generate an image digest from docker save tarball

EOF
}

if [[ "$#" -lt 1 ]]; then
    printf '\n\t%s\n\n' "ERROR - must specify options when using ${0##*/}" >&2
    display_usage >&2
    exit 1
fi

# parse options
while getopts ':r:u:P:a:d:f:i:m:t:gh' option; do
    case "${option}" in
        r  ) r_flag=true; ANCHORE_URL="${OPTARG%%/v1}";;
        u  ) u_flag=true; ANCHORE_USER="$OPTARG";;
        P  ) P_flag=true; ANCHORE_PASS="$OPTARG";;
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
    echo "ERROR - only 1 image tag can be analyzed at a time" >&2
    display_usage >&2
    exit 1
else
    IMAGE_TAG="$1"
fi

# validate URL is functional anchore-engine api endpoint
if [[ ! "$r_flag" ]]; then
    echo "ERROR - must provide an anchore-engine endpoint" >&2
    display_usage >&2
    exit 1
elif ! curl --fail "${ANCHORE_URL%%/}/v1"; then
    echo "ERROR - invalid anchore-engine endpoint provided - $ANCHORE_URL" >&2
    display_usage >&2
    exit 1
# validate user & password are provided & correct
elif [[ ! "$u_flag" ]] || [[ ! "$P_flag" ]]; then
    echo "ERROR - must provide anchore-engine username & password" >&2
    display_usage >&2
    exit 1
elif ! curl --fail -u "${ANCHORE_USER}:${ANCHORE_PASS}" "${ANCHORE_URL%%/}/v1/status"; then
    echo "ERROR - invalid anchore-engine username/password provided" >&2
    display_usage >&2
    exit 1
elif [[ "$f_flag" ]] && [[ ! -f "$DOCKERFILE" ]]; then
    echo "ERROR - invalid path to dockerfile provided - $DOCKERFILE" >&2
    display_usage >&2
    exit 1
elif [[ "$m_flag" ]] && [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "ERROR - invalid path to image manifest file provided - $MANIFEST_FILE" >&2
    display_usage >&2
    exit 1
fi

# process image tarballs in /anchore-engine
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
ANALYSIS_FILE_NAME="/tmp/$(basename $IMAGE_FILE_NAME)"
ANALYZE_CMD=('anchore-manager analyzers exec')
ANALYZE_CMD+=('--tag "$IMAGE_TAG"') 
if [[ ! -z "$IMAGE_DIGEST_SHA" ]]; then
    ANALYZE_CMD+=('--digest "$IMAGE_DIGEST_SHA"') 
fi
if [[ "$m_flag" ]]; then
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

ANALYZE_CMD+=('"$IMAGE_FILE_NAME" "$ANALYSIS_FILE_NAME"')
eval "${ANALYZE_CMD[*]}"

# curl archive tarball to engine URL
if [[ -f "$ANALYSIS_FILE_NAME" ]]; then
    curl --fail -u "${ANCHORE_USER}:${ANCHORE_PASS}" -F "archive_file=@${ANALYSIS_FILE_NAME}" "${ANCHORE_URL%%/}/v1/import/images"
else
    printf '\n\t%s\n\n' "ERROR - analysis file invalid: $ANALYSIS_FILE_NAME. An error occured during analysis."
    exit 1
fi