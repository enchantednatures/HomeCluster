#!/bin/bash

tailnet="enchantednatures.github"
# Replace with a path to your Tailscale API key.
apikey=$(cat ~/keys/tskey)
tag="k8s"

curl -s "https://api.tailscale.com/api/v2/tailnet/$tailnet/devices" -u "$apikey:" | jq -r '.devices[] |  "\(.id) \(.name) \(.tags)"' |
    while read id name tags; do
        # check if the tag is in the list of tags
        if [[ $tags =~ $tag ]]; then
            echo $name $id " includes " $tag " in its tags - getting rid of it"
            curl -s -X DELETE "https://api.tailscale.com/api/v2/device/$id" -u "$apikey:"
        else
            echo $name" does not have the tag, keeping it"
        fi
    done
