#!/bin/bash

tailnet="enchantednatures.github"
# Replace with a path to your Tailscale API key.
apikey=$(cat ~/keys/tskey)
oldenough=$(date -v-1w -u +"%Y-%m-%dT%H:%M:%SZ")

curl -s "https://api.tailscale.com/api/v2/tailnet/$tailnet/devices" -u "$apikey:" | jq -r '.devices[] |  "\(.lastSeen) \(.id) \(.name)"' |
    while read seen id; do
        if [[ $seen < $oldenough ]]; then
            curl -s -X DELETE "https://api.tailscale.com/api/v2/device/$id" -u "$apikey:"
        else
            echo $id " was last seen " $seen " keeping it"
        fi
    done
