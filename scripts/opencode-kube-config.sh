#!/bin/bash

# This script automates the creation of a limited-access kubeconfig for a Kubernetes cluster.
# It performs the following steps:
# 1. Creates a Service Account.
# 2. Defines a ClusterRole with specific permissions (read all but secret values, delete pods, force Flux reconciliation).
# 3. Creates a ClusterRoleBinding to link the Service Account and ClusterRole.
# 4. Extracts necessary cluster information (API server URL, CA cert).
# 5. Generates a Service Account token (handling Kubernetes 1.24+).
# 6. Constructs and outputs the custom kubeconfig file.

set -euo pipefail # Exit on error, exit on unset variables, pipe errors

# --- Configuration ---
SERVICE_ACCOUNT_NAME="opencode"
SERVICE_ACCOUNT_NAMESPACE="default" # The namespace where the ServiceAccount will be created
KUBECONFIG_OUTPUT_FILE="${SERVICE_ACCOUNT_NAME}-kubeconfig"
CLUSTER_CONTEXT_NAME="talos"
USER_CONTEXT_NAME="opencode-user"
TOKEN_VALIDITY_HOURS="8760h" # 1 year validity for the token

echo "--- Starting Kubeconfig Automation Script ---"

echo "1. Extracting Cluster Information..."

# Get the current cluster's API server URL
CURRENT_CLUSTER_NAME=$(kubectl config view --minify --output jsonpath='{.clusters[0].name}')
API_SERVER=$(kubectl config view --minify --output jsonpath='{.clusters[0].cluster.server}')
if [ -z "$API_SERVER" ]; then
    echo "Error: Could not determine Kubernetes API server URL from current kubeconfig."
    exit 1
fi
echo "API Server: ${API_SERVER}"

# Get the CA certificate data from the current cluster context
CA_CERT_DATA=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="'$CURRENT_CLUSTER_NAME'")].cluster.certificate-authority-data}')
if [ -z "$CA_CERT_DATA" ]; then
    echo "Error: Could not retrieve CA certificate data from current kubeconfig."
    exit 1
fi
echo "CA Certificate Data extracted."

echo "2. Generating Service Account Token..."
SERVICE_ACCOUNT_TOKEN=""

# Check Kubernetes version to determine token retrieval method
K8S_MAJOR_VERSION=$(kubectl version --client -o json | jq -r '.clientVersion.major')
K8S_MINOR_VERSION=$(kubectl version --client -o json | jq -r '.clientVersion.minor' | sed 's/+//g') # Remove '+' from minor version, e.g., "24+"

if [[ "$K8S_MAJOR_VERSION" -ge 1 && "$K8S_MINOR_VERSION" -ge 24 ]]; then
    echo "Kubernetes version 1.24+ detected. Using 'kubectl create token' to get SA token."
    SERVICE_ACCOUNT_TOKEN=$(kubectl create token "${SERVICE_ACCOUNT_NAME}" -n "${SERVICE_ACCOUNT_NAMESPACE}" --duration="${TOKEN_VALIDITY_HOURS}")
    if [ -z "$SERVICE_ACCOUNT_TOKEN" ]; then
        echo "Error: Failed to create Service Account token using 'kubectl create token'."
        exit 1
    fi
else
    echo "Kubernetes version pre-1.24 detected. Attempting to get SA token from secret."
    SECRET_NAME=$(kubectl get sa "${SERVICE_ACCOUNT_NAME}" -n "${SERVICE_ACCOUNT_NAMESPACE}" -o jsonpath='{.secrets[0].name}' 2>/dev/null)
    if [ -z "$SECRET_NAME" ]; then
        echo "Error: No secret found for ServiceAccount '${SERVICE_ACCOUNT_NAME}'. This is common in K8s 1.24+ where auto-creation of SA secrets is deprecated."
        echo "If you are sure you are on a pre-1.24 cluster, you might need to manually create a secret for this ServiceAccount."
        exit 1
    fi
    echo "Found SA secret: ${SECRET_NAME}"
    SERVICE_ACCOUNT_TOKEN=$(kubectl get secret "${SECRET_NAME}" -n "${SERVICE_ACCOUNT_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)
    if [ -z "$SERVICE_ACCOUNT_TOKEN" ]; then
        echo "Error: Failed to decode token from secret."
        exit 1
    fi
fi
echo "Service Account Token generated."

echo "3. Generating Kubeconfig File: ${KUBECONFIG_OUTPUT_FILE}"
cat <<EOF >"${KUBECONFIG_OUTPUT_FILE}"
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${CA_CERT_DATA}
    server: ${API_SERVER}
  name: ${CLUSTER_CONTEXT_NAME}
contexts:
- context:
    cluster: ${CLUSTER_CONTEXT_NAME}
    user: ${USER_CONTEXT_NAME}
  name: ${USER_CONTEXT_NAME}@${CLUSTER_CONTEXT_NAME}
current-context: ${USER_CONTEXT_NAME}@${CLUSTER_CONTEXT_NAME}
kind: Config
preferences: {}
users:
- name: ${USER_CONTEXT_NAME}
  user:
    token: ${SERVICE_ACCOUNT_TOKEN}
EOF

echo "--- Kubeconfig file '${KUBECONFIG_OUTPUT_FILE}' created successfully. ---"
echo "To use it, run: export KUBECONFIG=./${KUBECONFIG_OUTPUT_FILE}"
echo "Then test with, e.g.: kubectl get pods -A"
echo "You can also test specific permissions, e.g.:"
echo "kubectl --kubeconfig=./${KUBECONFIG_OUTPUT_FILE} get pods -A"
echo "kubectl --kubeconfig=./${KUBECONFIG_OUTPUT_FILE} delete pod <pod-name> -n <namespace>"
echo "kubectl --kubeconfig=./${KUBECONFIG_OUTPUT_FILE} get secrets -A # Should list names, not values"
echo "kubectl --kubeconfig=./${KUBECONFIG_OUTPUT_FILE} get secret <secret-name> -n <namespace> # Should fail to show data"
echo "kubectl --kubeconfig=./${KUBECONFIG_OUTPUT_FILE} annotate kustomization <kustomization-name> reconcile.fluxcd.io/requestedAt=\"\$(date +%Y-%m-%dT%H:%M:%SZ)\" --overwrite -n <namespace>"
