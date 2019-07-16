#!/usr/bin/env bash

set -eo pipefail

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

error() {
    set +e
    printf '\n\n\t%s\n\n' "ERROR - $0 received SIGTERM or SIGINT" >&2
    # kill python process in wait loop
    (pkill -f python3 &> /dev/null)
    # kill skopeo process in wait loop
    (pkill -f skopeo &> /dev/null)
    exit 130
}

trap 'error' SIGINT

# Parse options
while getopts ':d:b:i:fhr' option; do
    case "${option}" in
        d  ) d_flag=true; DOCKERFILE="/anchore-engine/$(basename $OPTARG)";;
        b  ) b_flag=true; POLICY_BUNDLE="/anchore-engine/$(basename $OPTARG)";;
        i  ) i_flag=true; IMAGE_NAME="$OPTARG";;
        f  ) f_flag=true;;
        r  ) r_flag=true;;
        h  ) display_usage; exit;;
        \? ) printf "\n\t%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
        :  ) printf "\n\t%s\n\n%s\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
    esac
done

shift "$((OPTIND - 1))"

export TIMEOUT=${TIMEOUT:=300}

# Test options to ensure they're all valid. Error & display usage if not.
if [[ "$d_flag" ]] && [[ ! "$i_flag" ]]; then
    printf '\n\t%s\n\n' "ERROR - must specify an image when passing a Dockerfile." >&2
    display_usage >&2
    exit 1
elif [[ "$d_flag" ]] && [[ ! -f "$DOCKERFILE" ]]; then
    printf '\n\t%s\n\n' "ERROR - Can not find dockerfile at: $DOCKERFILE" >&2
    display_usage >&2
    exit 1
elif [[ "$b_flag" ]] && [[ ! -f "$POLICY_BUNDLE" ]]; then
    printf '\n\t%s\n\n' "ERROR - Can not find policy bundle file at: $POLICY_BUNDLE" >&2
    display_usage >&2
    exit 1
fi

if [[ "$i_flag" ]]; then
    if [[ "$IMAGE_NAME" =~ (.*/|)([a-zA-Z0-9_.-]+)[:]?([a-zA-Z0-9_.-]*) ]]; then
        FILE_NAME="/anchore-engine/${BASH_REMATCH[2]}+${BASH_REMATCH[3]:-latest}.tar"
        if [[ ! -f "$FILE_NAME" ]]; then
            cat <&0 > "$FILE_NAME"
            printf '%s\n' "Successfully prepared image archive -- $FILE_NAME"
        fi
    elif [[ -f "/anchore-engine/$(basename ${IMAGE_NAME})" ]]; then
        FILE_NAME="/anchore-engine/$(basename ${IMAGE_NAME})"
    else
        printf '\n\t%s\n\n' "ERROR - Could not find image file $IMAGE_NAME" >&2
        display_usage >&2
        exit 1
    fi
fi

main() {
    SCAN_FILES=()
    FINISHED_IMAGES=()

    printf '%s\n\n' "Searching for Docker archive files in /anchore-engine."
    if [[ "$FILE_NAME" ]]; then
        if [[ $(skopeo inspect "docker-archive:${FILE_NAME}") ]]; then 
            SCAN_FILES+=("$FILE_NAME")
            printf '\t%s\n' "Found Docker image archive:  $FILE_NAME"
        else 
            printf '\n\t%s\n\n' "ERROR - Invalid Docker image archive:  $FILE_NAME" >&2
            display_usage >&2
            exit 1
        fi
    else
        for i in $(find /anchore-engine -type f); do
            if [[ $(skopeo inspect "docker-archive:${i}") ]] && [[ ! "${SCAN_FILES[@]}" =~ "$i" ]]; then 
                SCAN_FILES+=("$i")
                printf '\t%s\n' "Found docker archive:  $i"
            else 
                printf '\t%s\n' "Ignoring invalid docker archive:  $i" >&2
            fi
        done
    fi
    echo

    if [[ "${#SCAN_FILES[@]}" -gt 0 ]]; then
        for file in "${SCAN_FILES[@]}"; do
            start_scan "$file"
        done
    else
        printf '\n\t%s\n\n' "ERROR - No valid docker archives provided." >&2
        display_usage >&2
        exit 1
    fi

    if [[ "$b_flag" ]]; then
        (anchore-cli --json policy add "$POLICY_BUNDLE" | jq '.policyId' | xargs anchore-cli policy activate) || \
            printf "\n%s\n" "Unable to activate policy bundle - $POLICY_BUNDLE -- using default policy bundle." >&2
    fi

    if [[ "${#FINISHED_IMAGES[@]}" -ge 1 ]]; then
        if [[ "$r_flag" ]]; then
            for image in "${FINISHED_IMAGES[@]}"; do
                anchore_ci_tools.py -r --image "$image"
            done
        fi
        echo
        for image in "${FINISHED_IMAGES[@]}"; do
            printf '\n\t%s\n' "Policy Evaluation - ${image##*/}"
            printf '%s\n\n' "-----------------------------------------------------------"
            (set +o pipefail; anchore-cli evaluate check "$image" --detail | tee /dev/null; set -o pipefail)
        done

        if [[ "$f_flag" ]]; then
            for image in "${FINISHED_IMAGES[@]}"; do
                anchore-cli evaluate check "$image"
            done
        fi
    fi
}

start_scan() {
    local file="$1"
    local image_repo=""
    local image_tag=""
    local anchore_image_name=""

    if [[ -z "$IMAGE_NAME" ]]; then
        if [[ "$file" =~ (.+)[+]([^+].+)[.]tar$ ]]; then
            image_repo=$(basename "${BASH_REMATCH[1]}")
            image_tag="${BASH_REMATCH[2]}"
        else
            image_repo=$(basename "${file%%.*}")
            image_tag="latest"
        fi
    elif [[ "$IMAGE_NAME" =~ (.*/|)([a-zA-Z0-9_.-]+)[:]?([a-zA-Z0-9_.-]*) ]]; then
        image_repo="${BASH_REMATCH[2]}"
        image_tag="${BASH_REMATCH[3]:-latest}"
    else
        printf '\n\t%s\n\n' "ERROR - Could not parse image file name $IMAGE_NAME" >&2
        display_usage >&2
        exit 1
    fi

    anchore_image_name="${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_repo}:${image_tag}"
    
    printf '%s\n\n' "Image archive loaded into Anchore Engine using tag -- ${anchore_image_name#*/}"
    anchore_analysis "$file" "$anchore_image_name"
}

anchore_analysis() {
    declare file="$1"
    declare anchore_image_name="$2"

    # pass to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    skopeo copy --dest-tls-verify=false "docker-archive:${file}" "docker://${anchore_image_name}" &
    declare wait_proc="$!"
    wait $wait_proc

    echo
    if [[ "$d_flag" ]] && [[ -f "$DOCKERFILE" ]]; then
        anchore-cli image add "$anchore_image_name" --dockerfile "$DOCKERFILE" > /dev/null
    else
        anchore-cli image add "$anchore_image_name" > /dev/null
    fi

    # pass to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    anchore_ci_tools.py --wait --timeout "$TIMEOUT" --image "$anchore_image_name" &
    declare wait_proc="$!"
    wait "$wait_proc"

    FINISHED_IMAGES+=("$anchore_image_name")
}

main "$@"