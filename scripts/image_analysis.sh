#!/usr/bin/env bash

set -exo pipefail

display_usage() {
cat << EOF

Anchore Engine Inline Analyzer --

  Wrapper script for performing analysis on local docker images, utilizing Anchore Engine analyzer subsystem.
  After image is analyzed, the resulting Anchore image archive is sent to a remote Anchore Engine installation
  using the -u <URL> option.

  Images should be built & tagged locally.

    Usage: ${0##*/} analyze -h <URL> -u <USER> -p <PASSWORD> [ OPTIONS ] <FULL_IMAGE_TAG>

      -h <TEXT> [required] URL to remote Anchore Engine API endpoint host (ex: -h 'https://anchore.example.com:8228/v1')
      -u <TEXT> [required] Username for remote Anchore Engine auth (ex: -u 'admin')
      -p <TEXT> [required] Password for remote Anchore Engine auth (ex: -p 'foobar')

      -a <TEXT> [optional] Add annotations (ex: -a 'key=value,key=value')
      -s <PATH> [optional] Specify image digest (ex: -d 'sha256:<64 hex characters>')
      -d <PATH> [optional] Path to Dockerfile (ex: -f ./Dockerfile)
      -i <TEXT> [optional] Specify image ID within Anchore Engine (ex: -i '<64 hex characters>')
      -f <PATH> [optional] Path to Docker image manifest file (ex: -m ./manifest.json)
EOF
}

# parse options
while getopts ':h:u:p:a:s:d:i:f' option; do
    case "${option}" in
        h  ) h_flag=true; ANCHORE_URL="${OPTARG%%/v1}";;
        u  ) u_flag=true; ANCHORE_USER="$OPTARG";;
        p  ) p_flag=true; ANCHORE_PASS="$OPTARG";;
        a  ) a_flag=true; ANCHORE_ANNOTATIONS="$OPTARG";;
        s  ) s_flag=true; IMAGE_DIGEST_SHA="$OPTARG";;
        d  ) d_flag=true; DOCKERFILE="/anchore-engine/$(basename $OPTARG)";;
        i  ) i_flag=true; IMAGE_ID="$OPTARG";;
        f  ) f_flag=true; MANIFEST_FILE="$OPTARG";;
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
if [[ ! "$h_flag" ]]; then
    echo "ERROR - must provide an anchore-engine endpoint" >&2
    display_usage >&2
    exit 1
elif ! curl --fail "${ANCHORE_URL%%/}/v1"; then
    echo "ERROR - invalid anchore-engine endpoint provided - $ANCHORE_URL" >&2
    display_usage >&2
    exit 1
fi

# validate user & password are provided & correct
if [[ ! "$u_flag" ]] || [[ ! "$p_flag" ]]; then
    echo "ERROR - must provide anchore-engine username & password" >&2
    display_usage >&2
    exit 1
elif ! curl --fail -u "${ANCHORE_USER}:${ANCHORE_PASS}" "${ANCHORE_URL%%/}/v1/status"; then
    echo "ERROR - invalid anchore-engine username/password provided" >&2
    display_usage >&2
    exit 1
fi

# validate path to dockerfile
if [[ "$d_flag" ]] && [[ ! -f "$DOCKERFILE" ]]; then
    echo "ERROR - invalid path to dockerfile provided - $DOCKERFILE" >&2
    display_usage >&2
    exit 1
fi

# validate path to image manifest
if [[ "$m_flag" ]] && [[ ! -f "$MANIFEST_FILE" ]]; then
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

if [[ ! "$m_flag" ]] && [[ ! "$s_flag" ]]; then
    IMAGE_DIGEST_SHA=$(skopeo inspect --raw "docker-archive:///${IMAGE_FILE_NAME}" | jq -r .config.digest)
fi

# analyze image with anchore-engine
ANALYSIS_FILE_NAME="/tmp/$(basename $IMAGE_FILE_NAME)"
ANALYZE_CMD=('anchore-manager analyzers exec')
ANALYZE_CMD+=('--tag "$IMAGE_TAG"') 
if [[ ! -z "$IMAGE_DIGEST_SHA" ]]; then
    ANALYZE_CMD+=('--digest "$IMAGE_DIGEST_SHA"') 
fi

ANALYZE_CMD+=('"$IMAGE_FILE_NAME" "$ANALYSIS_FILE_NAME"')
eval "${ANALYZE_CMD[*]}"

# curl archive tarball to engine URL
curl --fail -u "${ANCHORE_USER}:${ANCHORE_PASS}" -F "archive_file=@${ANALYSIS_FILE_NAME}" "$ANCHORE_URL"