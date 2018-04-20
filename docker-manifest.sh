#!/bin/bash
set -e

RED='\033[0;31m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

REPO_REGISTRY="https://registry-1.docker.io/v2"
REPO_AUTH="https://auth.docker.io"


LIST_TEMPLATE="{
   \"schemaVersion\": 2,
   \"mediaType\": \"application/vnd.docker.distribution.manifest.list.v2+json\",
   \"manifests\": [
      IMAGES
   ]
}"

IMAGE_TEMPLATE="      {
         \"mediaType\": \"application/vnd.docker.distribution.manifest.v2+json\",
         \"size\": IMAGE_SIZE,
         \"digest\": \"IMAGE_DIGEST\",
         \"platform\": {
            \"architecture\": \"ARCHITECTURE\",
            \"os\": \"OS\"
         }
      }"

# arrays to store temporary values
declare -A TOKENS
declare -A CROSS_TOKENS
declare -A OPTIONS
declare -A MANIFESTS

CURL_OPT="-s -L"
V2SCHEMA2_MANIFEST_LIST="application/vnd.docker.distribution.manifest.list.v2+json"
V2SCHEMA2_MANIFEST="application/vnd.docker.distribution.manifest.v2+json"
V2SCHEMA2_CONTAINER_CFG="application/vnd.docker.container.image.v1+json"
OUTPUT_DIR="output"

make_request()
{
    curl -s -L -w "HTTPSTATUS:%{http_code}" $@
}

get_request_status()
{
    # response code of make_request
    echo $1 | tail -1 | sed -e 's/.*HTTPSTATUS://'
}

get_request_body()
{
    # response body of make_request
    echo $1 | sed -e 's/HTTPSTATUS\:.*//g'
}

get_token()
{
  local repo="$1"
  # request for it now
  curl ${CURL_OPT} \
    "${REPO_AUTH}/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | jq -r '.token'
}

get_manifests_list()
{
    local repo=$(echo "$1" | cut -d ':' -f 1)
    local tag=$(echo "$1" | cut -d ':' -f 2)
    local token=$2

    # load manifest.list
    curl ${CURL_OPT} \
    --header "Authorization: Bearer ${token}" \
    --header "Accept: ${V2SCHEMA2_MANIFEST_LIST}" \
    "${REPO_REGISTRY}/${repo}/manifests/$tag"
}

get_manifest()
{
    local repo=$(echo "$1" | cut -d ':' -f 1)
    local tag=$(echo "$1" | cut -d ':' -f 2)
    local token=$2
    local flag=$3

    # load manifest
    curl $flag ${CURL_OPT} \
    --header "Authorization: Bearer ${token}" \
    --header "Accept: ${V2SCHEMA2_MANIFEST}" \
    "${REPO_REGISTRY}/${repo}/manifests/${tag}"
}

get_image()
{
    local repo=$(echo "$1" | cut -d ':' -f 1)
    local token=$2
    local digest=$3

    # load image info
    curl ${CURL_OPT} \
    --header "Authorization: Bearer $token" \
    --header "Accept: ${V2SCHEMA2_CONTAINER_CFG}" \
    "${REPO_REGISTRY}/${repo}/blobs/$digest"
}

REPOSITORY=$1
manifest_digests=""
image_digests=""

process_option()
{
    opt=$(echo $1 | sed -e 's/^-*//')
    echo "opt: $opt"
    case "$opt" in
        # save value
        os|arch|os-features|variant)
            OPTIONS["$opt"]="$2"
        ;;
        # default is to mark the option selected-"Y"
        *)
            OPTIONS["$opt"]="Y"
        ;;
    esac
}

show_create_help()
{
    echo -e "Usage:  $0 create [OPTIONS] MANFEST_LIST MANIFEST [MANIFEST...]\n"
    echo -e "Create a local manifest list for annotating and pushing to a registry\n"
    echo "Options:"
    echo "  -a, --amend   Amend an existing manifest list"
    echo "  --insecure    allow communication with an insecure registry"
    echo "  --help        Print usage"
}

show_annotate_help()
{
    echo -e "Usage:  $0 annotate MANIFEST_LIST MANIFEST [OPTIONS]\n"
    echo -e "Add additional information to a local image manifest\n"
    echo "Options:"
    echo "  --arch string               Set architecture"
    echo "  --os string                 Set operating system"
    echo "  --os-features stringSlice   Set operating system feature"
    echo "  --variant string            Set architecture variant"
    echo "  --help                      Print usage"
}

show_inspect_help()
{
    echo -e "Usage:  $0 inspect [OPTIONS] [MANIFEST_LIST] MANIFEST\n"
    echo -e "Display an image manifest, or manifest list\n"
    echo "Options:"
    echo "  -v, --verbose    Output additional info including layers and platform"
    echo "  --insecure       allow communication with an insecure registry"
    echo "  --help           Print usage"
}

show_push_help()
{
    echo -e "Usage:  $0 push [OPTIONS] MANIFEST_LIST\n"
    echo -e "Push a manifest list to a repository"
    echo "Options:"
    echo "  --insecure    allow push to an insecure registry"
    echo "  -p, --purge   Remove the local manifest list after push"
    echo "  --help        Print usage"
}

showhelp()
{
    echo "A script to manage docker manifests"
    echo ""
    echo "Usage: $0 COMMAND"
    echo "Commands:"
    echo -e "  create\tCreate a local manifest list for annotating and pushing to a registry"
    echo -e "  annotate\tAdd additional information to a local image manifest"
    echo -e "  inspect\tDisplay an image manifest, or manifest list"
    echo -e "  push   \tPush a manifest list to a repository"
    echo ""
    echo "Run '$0 COMMAND --help' for more information on a command."
}

process_create()
{
    # input validate
    if [ "--help" == "$1" ] || [ $# -lt 2 ]; then
        show_create_help
        exit 1
    fi

    # process arguments
    local i=0
    while (( "$#" )); do
        case "$1" in
            -*|--*)
                opt=$(echo $1 | sed -e 's/^-*//')
                OPTIONS["$opt"]="Y"
            ;;
            *)
                MANIFESTS[$i]=$1
                let i=i+1
            ;;
        esac
        shift
    done

    if [ "Y" == "${OPTIONS[insecure]}" ]; then
        # add -k option to curl
        CURL_OPT="${CURL_OPT} -k"
    fi
    # "amend" option is omitted as we'll write manifests file anyway

    should_fail="NO"

    # extract manifests list fields
    list_repo=$(echo ${MANIFESTS[0]} | cut -d ':' -f 1)
    list_tag=$(echo ${MANIFESTS[0]} | cut -d ':' -f 2)
    list_name="$(echo $list_repo | sed -e 's|/|\#|')#$list_tag"

    # process specified images one by one
    images_list=""
    # MANIFESTS[0] is always the "manifests list"
    for ((i=1; i <${#MANIFESTS[@]}; i++)); do

        this_image=${MANIFESTS[$i]}
        repo=$(echo "$this_image" | cut -d ':' -f 1)
        tag=$(echo "$this_image" | cut -d ':' -f 2)

        # check read token for $repo
        token=${TOKENS[${repo}]}
        if [ -z "$token" ]; then
            # request and cache read token
            token=$(get_token $repo)
            TOKENS[${repo}]=$token
        fi

        # check if specified item is a manifests list.
        # manifests-list cannot be added
        api_resp=$(get_manifests_list $this_image $token)
        list_count=$(echo "$api_resp" | jq '.manifests | length')

        if [ $list_count -eq 0 ]; then
            # this is a image manifest, now read its info
            printf "Reading [${CYAN}${MANIFESTS[$i]}${NC}] ...."
            # read header to find length and digest
            get_manifest $this_image $token "-I -D /tmp/$$.txt" > /dev/null
            header=$(cat /tmp/$$.txt)
            content_length=$(echo "$header" | grep 'Content-Length' | tr -d ' \n\r' | cut -d ':' -f 2)
            digest=$(echo "$header" | grep 'Docker-Content-Digest' | tr -d '\n\r' | cut -d ' ' -f 2)
            rm /tmp/$$.txt
            #echo "digest: $digest"

            if [ ! -z $digest ]; then
                printf " ${GREEN}Success${NC}\n"
                # specified image is found, now load its manifest info to read blob digest
                # so we can detect arch/os/features
                api_resp=$(get_manifest $this_image $token)
                blob_digest=$(echo $api_resp | jq -r '.config.digest')
                #echo "blob digest: $blob_digest"

                # check if $this_image repo is same as $list_repo
                # if not, we need to
                # 1. mount blob layers to make it visible to $list_repo
                # 2. push reference manifest to $list_repo
                # check: https://docs.docker.com/registry/spec/api/ Cross Repository Blob Mount
                if [ "$repo" != "$list_repo" ]; then
                    # do mount
                    # 1. get authorization to pull/push, $list_repo:pull and push, $target_repo: pull
                    cross_token=${CROSS_TOKENS[${repo}]}
                    if [ -z "$cross_token" ]; then
                        # prompt for authorization
                        read -p "Please input account@hub.docker.io: " username
                        read -sp "Please input password: " password

                        # request for access_token
                        printf "\nAuthorizing ......."
                        response=$(make_request -u $username:$password "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${list_repo}:pull,push&scope=repository:${repo}:pull")
                        code=$(get_request_status "$response")
                        body=$(get_request_body "$response")
                        if [ 200 -eq $code ]; then
                            cross_token=$(echo $body | jq -r .token)
                            CROSS_TOKENS[${repo}]=$cross_token
                            printf " ${GREEN}Success${NC}\n"
                        else
                            printf " ${RED}Failed${NC}\n"
                            printf "Reason:  ${CYAN}$body${NC}\n"
                            exit 1
                        fi
                    fi

                    # 2. read this_image manifest to create layers list
                    # these layers shall be mounted to $list_repo
                    layers_cnt=$(echo "$api_resp" | jq '.layers | length')
                    let layers_cnt=layers_cnt-1
                    for layer_i in $(seq 0 $layers_cnt); do
                        layer_digest=$(echo "$api_resp" | jq -r ".layers[$layer_i].digest")
                        printf "Mounting layer [$layer_digest] ..."
                        response=$(curl -s -L -w "HTTPSTATUS:%{http_code}" -X POST -H "Authorization: Bearer ${cross_token}" -H "Content-Length: 0" "$REPO_REGISTRY/$list_repo/blobs/uploads/?mount=$layer_digest&from=$repo")
                        code=$(get_request_status "$response")
                        body=$(get_request_body "$response")
                        if [ 201 -ne $code ]; then
                            printf " ${RED}Failed${NC}\n"
                            printf "Reason:  ${CYAN}$body${NC}\n"
                            exit 1
                        else
                            printf " ${GREEN}SUCCESS${NC}\n"
                        fi
                    done
                    # 3. upload config content
                    printf "Mounting blob  [${repo}:${tag}] ......"
                    # load blob info by digest
                    response=$(curl -s -L -w "HTTPSTATUS:%{http_code}" -X POST -H "Authorization: Bearer ${cross_token}" -H "Content-Length: 0" "$REPO_REGISTRY/$list_repo/blobs/uploads/?mount=$blob_digest&from=$repo")
                    code=$(get_request_status "$response")
                    body=$(get_request_body "$response")
                    if [ 201 -ne $code ]; then
                        printf " ${RED}Failed${NC}\n"
                        printf "Reason:  ${CYAN}$body${NC}\n"
                        exit 1
                    else
                        printf " ${GREEN}SUCCESS${NC}\n"
                    fi
                    # 4. upload reference manifest
                    printf "Pushing reference manifest: [${repo}:${tag}] ......"
                    response=$(curl -s -L -w "HTTPSTATUS:%{http_code}" -X PUT "$REPO_REGISTRY/${list_repo}/manifests/${digest}" -H "Authorization: Bearer ${cross_token}" -H "Content-Type: application/vnd.docker.distribution.manifest.list.v2+json" --data-binary "$api_resp")
                    code=$(get_request_status "$response")
                    body=$(get_request_body "$response")
                    if [ 201 -ne $code ]; then
                        printf " ${RED}Failed${NC}\n"
                        printf "Reason:  ${CYAN}$body${NC}\n"
                        exit 1
                    else
                        printf " ${GREEN}SUCCESS${NC}\n"
                    fi
                fi

                # load blob info by digest
                api_resp=$(get_image $this_image $token $blob_digest)
                # get os/architecture/features... info specified in
                # https://docs.docker.com/registry/spec/manifest-v2-2/
                os=$(echo $api_resp | jq -r '.os')
                architecture=$(echo $api_resp | jq -r '.architecture')
                # now add it to list
                images_list="$images_list ${content_length},$digest,$os,$architecture"
            else
                printf " ${RED}FAILED${NC}\n"
                printf "[${RED}ERROR${NC}] ${CYAN}$repo:$tag${NC} is not found!\n"
                should_fail="YES"
            fi
        else
            # it is a manifest list
            printf "[${RED}ERROR${YELLOW}] ${CYAN}$repo:$tag${NC} is not an image.\n"
            should_fail="YES"
        fi
    done

    if [ "YES" == $should_fail ]; then
        exit 1
    fi

    [ ! -d ${OUTPUT_DIR} ] && mkdir -p ${OUTPUT_DIR}
    # now build manifest list file
    manifests_list=$LIST_TEMPLATE
    > ${OUTPUT_DIR}/$$-images.json
    for image in $images_list; do
        image_length=$(echo $image | cut -d ',' -f 1)
        image_digest=$(echo $image | cut -d ',' -f 2)
        image_os=$(echo $image | cut -d ',' -f 3)
        image_architecture=$(echo $image | cut -d ',' -f 4)
        # these fields are must options
        entry=$(echo -n "$IMAGE_TEMPLATE" | sed -e "s/IMAGE_SIZE/$image_length/" | sed -e "s/IMAGE_DIGEST/$image_digest/")
        entry=$(echo -n "$entry" | sed -e "s/ARCHITECTURE/$image_architecture/" | sed -e "s/OS/$image_os/")
        entry="$entry,"

        echo -e "$entry" >> ${OUTPUT_DIR}/$$-images.json
    done
    sed -i '$s/,$//' ${OUTPUT_DIR}/$$-images.json

    manifests_list=$(echo -n "$manifests_list" | sed -e "/IMAGES/r ${OUTPUT_DIR}/$$-images.json" | sed -e '/IMAGE/d')
    echo -n "$manifests_list" > ${OUTPUT_DIR}/${list_name}#manifest.json
    mv ${OUTPUT_DIR}/$$-images.json ${OUTPUT_DIR}/${list_name}#images.json
}

process_annotate()
{
    if [ "--help" == "$1" ] || [ $# -lt 4 ]; then
        show_annotate_help
        exit 1
    fi

    # so far support these fields: os, arch, variant, os-features
    # process arguments
    local i=0
    while (( "$#" )); do
        case "$1" in
            -*|--*)
                opt=$(echo $1 | sed -e 's/^-*//')
                case "$opt" in
                    # save value
                    os|variant)
                        OPTIONS["$opt"]="$2"
                        shift
                    ;;
                    arch)
                        OPTIONS["architecture"]="$2"
                        shift
                    ;;
                    os-features)
                        # string slice
                        value=$(echo "$2" | sed -e 's/\,/\"\,\"/g')
                        OPTIONS["os.features"]="[\"$value\"]"
                        shift
                    ;;

                    # default is to mark the option selected-"Y"
                    *)
                        OPTIONS["$opt"]="Y"
                    ;;
                esac
                ;;
            *)
                MANIFESTS[$i]=$1
                let i=i+1
                ;;
        esac
        shift
    done

    should_fail="NO"

    # get manifests list content
    # 1. from local cache
    # 2. from remote registry
    list_repo=$(echo ${MANIFESTS[0]} | cut -d ':' -f 1)
    list_tag=$(echo ${MANIFESTS[0]} | cut -d ':' -f 2)
    list_name="$(echo $list_repo | sed -e 's|/|\#|')#$list_tag"
    if [ -f ${OUTPUT_DIR}/${list_name}#manifest.json ]; then
        list_content=$(cat ${OUTPUT_DIR}/${list_name}#manifest.json)
    else
        printf "Cannot find ${CYAN}[${MANIFESTS[0]}]${NC} in cache.\n"
        read -p "Download to proceed? (Y/N) : " choice
        [ "N" == "$choice" ] && exit 1

        # load manifests-list access token
        target=${MANIFESTS[0]}
        printf "Reading: [${CYAN}$target${NC}]\n"
        repo=$(echo "$target" | cut -d ':' -f 1)
        token=${TOKENS[${repo}]}
        if [ -z "$token" ]; then
            printf "\tRequesting access token ..."
            token=$(get_token $repo)
            TOKENS[${repo}]=$token
            printf " ${GREEN}Done${NC}\n"
        fi
        # read from registry
        printf "\tLoading manifests list ..."
        list_content=$(get_manifests_list $target $token)
        printf " ${GREEN}Done${NC}\n"
    fi
    list_count=$(echo "$list_content" | jq '.manifests | length')


    if [ $list_count -gt 0 ]; then
        # get listed images manifest
        for ((i=1; i <${#MANIFESTS[@]}; i++)); do
            target=${MANIFESTS[$i]}

            # read digest associates with given target
            # search target manifest-digest in list
            # append/modify fields if target exists

            # get token for this repo
            repo=$(echo "$target" | cut -d ':' -f 1)
            token=${TOKENS[${repo}]}
            if [ -z "$token" ]; then
                token=$(get_token $repo)
                TOKENS[${repo}]=$token
            fi

            # check if specified item is a manifest list.
            api_resp=$(get_manifests_list $target $token)
            list_count=$(echo "$api_resp" | jq '.manifests | length')
            if [ $list_count -gt 0 ]; then
                printf "[${RED}ERROR${NC}] [${CYAN}$target${NC}] is not an image\n"
                exit 1
            fi

            # get digest of target manifest
            get_manifest $target $token "-I -D /tmp/$$.txt" > /dev/null
            header=$(cat /tmp/$$.txt)
            content_length=$(echo "$header" | grep 'Content-Length' | tr -d ' \n\r' | cut -d ':' -f 2)
            digest=$(echo "$header" | grep 'Docker-Content-Digest' | tr -d '\n\r' | cut -d ' ' -f 2)
            rm /tmp/$$.txt

            # search this digest in $list_content
            found=$(echo $list_content | grep "$digest" | wc -l)
            if [ 0 -eq $found ]; then
                echo "[ERROR] Specified [$target] is not in ${MANIFESTS[0]}"
                exit 1
            else
                # add fields
                export MS_DIGEST=$digest
                for this_field in architecture variant os "os.features"; do
                    if [ ! -z ${OPTIONS[${this_field}]} ]; then
                        export FIELD=${this_field}
                        export VALUE="${OPTIONS[${this_field}]}"
                        if [ "$FIELD" == "os.features" ]; then
                        list_content=$(echo -E "$list_content" | jq '(.manifests[] | select(.digest == "'$MS_DIGEST'").platform."'$FIELD'") = '$VALUE'')
                        else
                        list_content=$(echo -E "$list_content" | jq '(.manifests[] | select(.digest == "'$MS_DIGEST'").platform."'$FIELD'") = "'$VALUE'"')
                        fi
                        unset FIELD
                        unset VALUE
                    fi
                done
                unset MS_DIGEST
            fi
        done
        # save to cache
        echo "$list_content" | jq . -M > ${OUTPUT_DIR}/${list_name}#manifest.json
    else
        printf "[${RED}ERROR${NC}] [${CYAN}$target${NC}] is not a manifest list\n"
        should_fail="YES"
    fi

}

process_inspect()
{
    if [ "--help" == "$1" ] || [ $# -lt 1 ]; then
        show_inspect_help
        exit 1
    fi

    # process arguments
    local i=0
    while (( "$#" )); do
        case "$1" in
            -*|--*)
                opt=$(echo $1 | sed -e 's/^-*//')
                OPTIONS["$opt"]="Y"
            ;;
            *)
                MANIFESTS[$i]=$1
                let i=i+1
            ;;
        esac
        shift
    done

    if [ "Y" == "${OPTIONS[insecure]}" ]; then
        # add -k option to curl
        CURL_OPT="${CURL_OPT} -k"
    fi

    # check token
    target=${MANIFESTS[0]}
    repo=$(echo "$target" | cut -d ':' -f 1)
    token=${TOKENS[${repo}]}
    if [ -z "$token" ]; then
    token=$(get_token $repo)
    TOKENS[${repo}]=$token
    fi

    # get manifests list
    api_resp=$(get_manifests_list $target $token)
    list_count=$(echo -E "$api_resp" | jq '.manifests | length')

    if [ $list_count -eq 0 ]; then
    # get image manifest
    api_resp=$(get_manifest $target $token)
    fi
    echo $api_resp | jq
}

process_push()
{
    echo $#
    if [ "--help" == "$1" ] || [ $# -lt 1 ]; then
        show_push_help
        exit 1
    fi

    # check options
    local i=0
    while (( "$#" )); do
        case "$1" in
            -*|--*)
                opt=$(echo $1 | sed -e 's/^-*//')
                OPTIONS["$opt"]="Y"
            ;;
            *)
                MANIFESTS[$i]=$1
                let i=i+1
            ;;
        esac
        shift
    done

    if [ "Y" == "${OPTIONS[insecure]}" ]; then
        # add -k option to curl
        CURL_OPT="${CURL_OPT} -k"
    fi

    # check if manifests-list has been created or not
    repo=$(echo "${MANIFESTS[0]}" | cut -d ':' -f 1)
    tag=$(echo "${MANIFESTS[0]}" | cut -d ':' -f 2)
    manifests_file="${OUTPUT_DIR}/$(echo $repo | sed -e 's|/|\#|')#$tag#manifest.json"
    if [ ! -f ${manifests_file} ]; then
        printf "${RED}[ERROR]${NC} Couldn't find specified manifest ${CYAN}[$repo:$tag]${NC}\n"
        exit 1
    fi

    # prompt for authorization
    read -p "Please input account@hub.docker.io: " username
    read -sp "Please input password: " password

    # request for access_token
    printf "\nAuthorizing ......."
    response=$(make_request -u $username:$password "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull,push")
    code=$(get_request_status "$response")
    body=$(get_request_body "$response")
    #ret=$(curl -s -u $username:$password "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull,push")
    if [ 200 -eq $code ]; then
        access_token=$(echo $body | jq -r .token)
        printf " ${GREEN}Success${NC}\n"
    else
        printf " ${RED}Failed${NC}\n"
        printf "Reason:  ${CYAN}$body${NC}\n"
        exit 1
    fi

    # put manifests file
    printf "Uploading   ......."
    response=$(curl -s -L -w "HTTPSTATUS:%{http_code}" -X PUT "$REPO_REGISTRY/${repo}/manifests/${tag}" -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/vnd.docker.distribution.manifest.list.v2+json" --data-binary @${manifests_file})
    code=$(get_request_status "$response")
    body=$(get_request_body "$response")
    if [ 201 -eq $code ]; then
        printf " ${GREEN}Success${NC}\n"
    else
        printf " ${RED}Failed${NC}\n"
        printf "Reason:  ${CYAN}$body${NC}\n"
    fi

    # should manifests-list be purged?
    if [ "Y" == "${OPTIONS[purge]}" ]; then
        printf "Delete manifest json file\n"
    fi
}

if [ $# -lt 1 ]; then
showhelp
exit 1
fi

cmd=$1
shift
case $cmd in
    create)
        process_create $@
        ;;
    annotate)
        process_annotate $@
        ;;
    inspect)
        process_inspect $@
        ;;
    push)
        process_push $@
        ;;
    *)
        showhelp
        ;;
esac
