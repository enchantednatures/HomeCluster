#!/bin/bash
set -euo pipefail

tailnet="enchantednatures.github"
# Replace with a path to your Tailscale API key.
if [[ ! -f ~/keys/tskey ]]; then
    echo "Error: API key file ~/keys/tskey not found"
    exit 1
fi

apikey=$(cat ~/keys/tskey)
tag="tag:k8s"

# Use portable date command that works on both BSD and GNU
if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    oldenough=$(date -u -d '1 week ago' +"%Y-%m-%dT%H:%M:%SZ")
else
    # BSD date (macOS)
    oldenough=$(date -v-1w -u +"%Y-%m-%dT%H:%M:%SZ")
fi

echo "Fetching devices from Tailscale API..."
response=$(curl -s -w "\n%{http_code}" "https://api.tailscale.com/api/v2/tailnet/$tailnet/devices" -u "$apikey:")
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [[ "$http_code" != "200" ]]; then
    echo "Error: API request failed with HTTP $http_code"
    echo "Response: $body"
    exit 1
fi

if [[ $(echo "$body" | jq -r '.devices') == "null" ]]; then
    echo "Error: No devices found in API response"
    echo "Response: $body"
    exit 1
fi

echo "Searching for devices with tag: $tag"
echo "$body" | jq -r '.devices[] | "\(.id)\t\(.name)\t\((.tags // []) | join(","))"' | while IFS=$'\t' read -r id name tags; do
    # check if the tag is in the list of tags
    if [[ "$tags" =~ $tag ]]; then
        echo "Deleting device: $name (ID: $id) - has tag $tag"
        curl -s -X DELETE "https://api.tailscale.com/api/v2/device/$id" -u "$apikey:"
    else
        echo "Keeping device: $name (ID: $id) - does not have tag $tag"
    fi
done
