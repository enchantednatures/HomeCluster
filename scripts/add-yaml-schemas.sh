#!/usr/bin/env bash
# YAML Schema Annotation Tool
# Automatically adds or updates yaml-language-server schema annotations
# Usage: ./add-yaml-schemas.sh [--dry-run|--execute] [--path <dir>] [--force] [--verbose]

set -o errexit
set -o pipefail

#=====================================================================
# CONFIGURATION
#=====================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly KUBERNETES_DIR="${REPO_ROOT}/kubernetes"
readonly SCHEMA_BASE="https://kubernetes-schemas.pages.dev"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Directories to exclude from processing
readonly EXCLUDE_DIRS=(
    ".venv"
    ".archive"
    ".git"
    ".task"
    ".tasks"
    "node_modules"
    ".opencode"
)

# Statistics counters
declare -i stats_total=0
declare -i stats_modified=0
declare -i stats_would_modify=0
declare -i stats_skipped=0
declare -i stats_unknown=0
declare -i stats_errors=0

# Resource type counters
declare -A type_counts=()

# Configuration flags
DRY_RUN=true
FORCE=false
VERBOSE=false
TARGET_PATH="${KUBERNETES_DIR}"

#=====================================================================
# UTILITY FUNCTIONS
#=====================================================================

print_header() {
    echo ""
    echo "======================================================"
    echo "  $1"
    echo "======================================================"
    echo ""
}

log_info() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo -e "${BLUE}ℹ${NC} $1"
    fi
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

log_action() {
    local action="$1"
    local file="$2"
    local resource_type="$3"
    
    case "$action" in
        "ADD")
            echo -e "${GREEN}+${NC} ${file} (${CYAN}${resource_type}${NC})" ;;
        "UPDATE")
            echo -e "${YELLOW}↻${NC} ${file} (${CYAN}${resource_type}${NC})" ;;
        "SKIP")
            if [[ "${VERBOSE}" == "true" ]]; then
                echo -e "${BLUE}−${NC} ${file} (${CYAN}${resource_type}${NC})" 
            fi ;;
    esac
}

#=====================================================================
# SCHEMA MAPPING FUNCTIONS
#=====================================================================

get_schema_url() {
    local resource_type="$1"
    
    case "$resource_type" in
        # Flux CD Resources
        "HelmRelease")
            echo "${SCHEMA_BASE}/helm.toolkit.fluxcd.io/helmrelease_v2.json" ;;
        "Kustomization")
            echo "${SCHEMA_BASE}/kustomize.toolkit.fluxcd.io/kustomization_v1.json" ;;
        "GitRepository")
            echo "${SCHEMA_BASE}/source.toolkit.fluxcd.io/gitrepository_v1.json" ;;
        "HelmRepository")
            echo "${SCHEMA_BASE}/source.toolkit.fluxcd.io/helmrepository_v1.json" ;;
        "OCIRepository")
            echo "${SCHEMA_BASE}/source.toolkit.fluxcd.io/ocirepository_v1beta2.json" ;;
        "ImageRepository")
            echo "${SCHEMA_BASE}/image.toolkit.fluxcd.io/imagerepository_v1beta2.json" ;;
        "ImagePolicy")
            echo "${SCHEMA_BASE}/image.toolkit.fluxcd.io/imagepolicy_v1beta2.json" ;;
        "ImageUpdateAutomation")
            echo "${SCHEMA_BASE}/image.toolkit.fluxcd.io/imageupdateautomation_v1beta2.json" ;;
        
        # Istio Resources - Networking
        "VirtualService")
            echo "${SCHEMA_BASE}/networking.istio.io/virtualservice_v1.json" ;;
        "Gateway")
            echo "${SCHEMA_BASE}/networking.istio.io/gateway_v1.json" ;;
        "DestinationRule")
            echo "${SCHEMA_BASE}/networking.istio.io/destinationrule_v1.json" ;;
        "ServiceEntry")
            echo "${SCHEMA_BASE}/networking.istio.io/serviceentry_v1.json" ;;
        "Sidecar")
            echo "${SCHEMA_BASE}/networking.istio.io/sidecar_v1.json" ;;
        "WorkloadEntry")
            echo "${SCHEMA_BASE}/networking.istio.io/workloadentry_v1.json" ;;
        "WorkloadGroup")
            echo "${SCHEMA_BASE}/networking.istio.io/workloadgroup_v1.json" ;;
        
        # Istio Resources - Security
        "AuthorizationPolicy")
            echo "${SCHEMA_BASE}/security.istio.io/authorizationpolicy_v1.json" ;;
        "PeerAuthentication")
            echo "${SCHEMA_BASE}/security.istio.io/peerauthentication_v1.json" ;;
        "RequestAuthentication")
            echo "${SCHEMA_BASE}/security.istio.io/requestauthentication_v1.json" ;;
        
        # Istio Resources - Telemetry
        "Telemetry")
            echo "${SCHEMA_BASE}/telemetry.istio.io/telemetry_v1.json" ;;
        
        # Core Kubernetes Resources (v1)
        "Namespace")
            echo "${SCHEMA_BASE}/v1/namespace.json" ;;
        "ConfigMap")
            echo "${SCHEMA_BASE}/v1/configmap.json" ;;
        "Secret")
            echo "${SCHEMA_BASE}/v1/secret.json" ;;
        "Service")
            echo "${SCHEMA_BASE}/v1/service.json" ;;
        "PersistentVolumeClaim")
            echo "${SCHEMA_BASE}/v1/persistentvolumeclaim.json" ;;
        "PersistentVolume")
            echo "${SCHEMA_BASE}/v1/persistentvolume.json" ;;
        "ServiceAccount")
            echo "${SCHEMA_BASE}/v1/serviceaccount.json" ;;
        "Pod")
            echo "${SCHEMA_BASE}/v1/pod.json" ;;
        "Endpoints")
            echo "${SCHEMA_BASE}/v1/endpoints.json" ;;
        "LimitRange")
            echo "${SCHEMA_BASE}/v1/limitrange.json" ;;
        "ResourceQuota")
            echo "${SCHEMA_BASE}/v1/resourcequota.json" ;;
        
        # Apps Resources (apps/v1)
        "Deployment")
            echo "${SCHEMA_BASE}/apps/v1/deployment.json" ;;
        "StatefulSet")
            echo "${SCHEMA_BASE}/apps/v1/statefulset.json" ;;
        "DaemonSet")
            echo "${SCHEMA_BASE}/apps/v1/daemonset.json" ;;
        "ReplicaSet")
            echo "${SCHEMA_BASE}/apps/v1/replicaset.json" ;;
        
        # Batch Resources (batch/v1)
        "Job")
            echo "${SCHEMA_BASE}/batch/v1/job.json" ;;
        "CronJob")
            echo "${SCHEMA_BASE}/batch/v1/cronjob.json" ;;
        
        # Networking Resources (networking.k8s.io/v1)
        "Ingress")
            echo "${SCHEMA_BASE}/networking.k8s.io/v1/ingress.json" ;;
        "NetworkPolicy")
            echo "${SCHEMA_BASE}/networking.k8s.io/v1/networkpolicy.json" ;;
        "IngressClass")
            echo "${SCHEMA_BASE}/networking.k8s.io/v1/ingressclass.json" ;;
        
        # Storage Resources (storage.k8s.io/v1)
        "StorageClass")
            echo "${SCHEMA_BASE}/storage.k8s.io/v1/storageclass.json" ;;
        "VolumeAttachment")
            echo "${SCHEMA_BASE}/storage.k8s.io/v1/volumeattachment.json" ;;
        "CSIDriver")
            echo "${SCHEMA_BASE}/storage.k8s.io/v1/csidriver.json" ;;
        "CSINode")
            echo "${SCHEMA_BASE}/storage.k8s.io/v1/csinode.json" ;;
        
        # RBAC Resources (rbac.authorization.k8s.io/v1)
        "Role")
            echo "${SCHEMA_BASE}/rbac.authorization.k8s.io/v1/role.json" ;;
        "RoleBinding")
            echo "${SCHEMA_BASE}/rbac.authorization.k8s.io/v1/rolebinding.json" ;;
        "ClusterRole")
            echo "${SCHEMA_BASE}/rbac.authorization.k8s.io/v1/clusterrole.json" ;;
        "ClusterRoleBinding")
            echo "${SCHEMA_BASE}/rbac.authorization.k8s.io/v1/clusterrolebinding.json" ;;
        
        # Policy Resources
        "PodDisruptionBudget")
            echo "${SCHEMA_BASE}/policy/v1/poddisruptionbudget.json" ;;
        "PodSecurityPolicy")
            echo "${SCHEMA_BASE}/policy/v1beta1/podsecuritypolicy.json" ;;
        
        # Custom Resource Definitions
        "CustomResourceDefinition")
            echo "${SCHEMA_BASE}/apiextensions.k8s.io/v1/customresourcedefinition.json" ;;
        
        # CloudNative-PG
        "Cluster")
            echo "${SCHEMA_BASE}/postgresql.cnpg.io/cluster_v1.json" ;;
        "Backup")
            echo "${SCHEMA_BASE}/postgresql.cnpg.io/backup_v1.json" ;;
        "ScheduledBackup")
            echo "${SCHEMA_BASE}/postgresql.cnpg.io/scheduledbackup_v1.json" ;;
        "Pooler")
            echo "${SCHEMA_BASE}/postgresql.cnpg.io/pooler_v1.json" ;;
        
        # DragonflyDB
        "Dragonfly")
            echo "${SCHEMA_BASE}/dragonflydb.io/dragonfly_v1alpha1.json" ;;
        
        # Cert-Manager
        "Certificate")
            echo "${SCHEMA_BASE}/cert-manager.io/v1/certificate.json" ;;
        "ClusterIssuer")
            echo "${SCHEMA_BASE}/cert-manager.io/v1/clusterissuer.json" ;;
        "Issuer")
            echo "${SCHEMA_BASE}/cert-manager.io/v1/issuer.json" ;;
        "CertificateRequest")
            echo "${SCHEMA_BASE}/cert-manager.io/v1/certificaterequest.json" ;;
        
        # Prometheus Operator
        "ServiceMonitor")
            echo "${SCHEMA_BASE}/monitoring.coreos.com/v1/servicemonitor.json" ;;
        "PrometheusRule")
            echo "${SCHEMA_BASE}/monitoring.coreos.com/v1/prometheusrule.json" ;;
        "Prometheus")
            echo "${SCHEMA_BASE}/monitoring.coreos.com/v1/prometheus.json" ;;
        "Alertmanager")
            echo "${SCHEMA_BASE}/monitoring.coreos.com/v1/alertmanager.json" ;;
        "PodMonitor")
            echo "${SCHEMA_BASE}/monitoring.coreos.com/v1/podmonitor.json" ;;
        "Probe")
            echo "${SCHEMA_BASE}/monitoring.coreos.com/v1/probe.json" ;;
        
        # Kyverno
        "ClusterPolicy")
            echo "${SCHEMA_BASE}/kyverno.io/v1/clusterpolicy.json" ;;
        "Policy")
            echo "${SCHEMA_BASE}/kyverno.io/v1/policy.json" ;;
        
        # Rook-Ceph
        "CephCluster")
            echo "${SCHEMA_BASE}/ceph.rook.io/v1/cephcluster.json" ;;
        "CephBlockPool")
            echo "${SCHEMA_BASE}/ceph.rook.io/v1/cephblockpool.json" ;;
        "CephObjectStore")
            echo "${SCHEMA_BASE}/ceph.rook.io/v1/cephobjectstore.json" ;;
        "CephFilesystem")
            echo "${SCHEMA_BASE}/ceph.rook.io/v1/cephfilesystem.json" ;;
        
        # Native Kustomization
        "NativeKustomization")
            echo "${SCHEMA_BASE}/kustomize.config.k8s.io/kustomization_v1beta1.json" ;;
        
        # Unknown/Generic - use generic Kubernetes schema
        *)
            echo "https://kubernetesjsonschema.dev/master-standalone-strict/_definitions.json" ;;
    esac
}

#=====================================================================
# RESOURCE DETECTION FUNCTIONS
#=====================================================================

detect_resource_type() {
    local file="$1"
    
    # Special case: detect kustomization.yaml by filename
    local basename
    basename="$(basename "$file")"
    if [[ "$basename" == "kustomization.yaml" ]] || [[ "$basename" == "kustomization.yml" ]]; then
        # Check if it's a Flux Kustomization or native
        if grep -q "^apiVersion: kustomize.toolkit.fluxcd.io" "$file" 2>/dev/null; then
            echo "Kustomization"
            return 0
        elif grep -q "^apiVersion: kustomize.config.k8s.io" "$file" 2>/dev/null; then
            echo "NativeKustomization"
            return 0
        elif grep -q "^kind: Kustomization" "$file" 2>/dev/null; then
            # Has kind but no apiVersion - likely native
            echo "NativeKustomization"
            return 0
        else
            # Native kustomization without explicit kind/apiVersion
            echo "NativeKustomization"
            return 0
        fi
    fi
    
    # Extract all 'kind:' values from the file
    local kinds=()
    while IFS= read -r kind; do
        kinds+=("$kind")
    done < <(grep "^kind:" "$file" 2>/dev/null | awk '{print $2}' | sort -u)
    
    # No kinds found
    if [[ ${#kinds[@]} -eq 0 ]]; then
        echo "UNKNOWN"
        return 0
    fi
    
    # Single kind - return it
    if [[ ${#kinds[@]} -eq 1 ]]; then
        echo "${kinds[0]}"
        return 0
    fi
    
    # Multiple kinds - check if all the same
    local first="${kinds[0]}"
    local all_same=true
    for kind in "${kinds[@]}"; do
        if [[ "$kind" != "$first" ]]; then
            all_same=false
            break
        fi
    done
    
    if [[ "$all_same" == "true" ]]; then
        echo "$first"
    else
        # Mixed types - return as comma-separated
        echo "MIXED:${kinds[*]}"
    fi
}

#=====================================================================
# FILE PROCESSING FUNCTIONS
#=====================================================================

has_schema_annotation() {
    local file="$1"
    grep -q "^# yaml-language-server:" "$file" 2>/dev/null
}

get_existing_schema() {
    local file="$1"
    grep -m1 "^# yaml-language-server:" "$file" 2>/dev/null || echo ""
}

is_schema_correct() {
    local file="$1"
    local expected_url="$2"
    local existing
    existing="$(get_existing_schema "$file")"
    
    [[ "$existing" =~ "$expected_url" ]]
}

add_or_update_schema() {
    local file="$1"
    local schema_url="$2"
    local has_existing="$3"
    
    local schema_line="# yaml-language-server: \$schema=${schema_url}"
    local temp_file="${file}.tmp"
    
    if [[ "$has_existing" == "false" ]]; then
        # Add new schema at the top
        {
            echo "$schema_line"
            cat "$file"
        } > "$temp_file"
    else
        # Replace existing schema
        sed "s|^# yaml-language-server:.*|$schema_line|" "$file" > "$temp_file"
    fi
    
    # Move temp file to original
    mv "$temp_file" "$file"
}

process_file() {
    local file="$1"
    local dry_run="$2"
    
    stats_total=$((stats_total + 1))
    
    # Detect resource type
    local resource_type
    resource_type="$(detect_resource_type "$file")"
    
    # Handle unknown resources
    if [[ "$resource_type" == "UNKNOWN" ]]; then
        log_warning "Unknown resource type: ${file}"
        stats_unknown=$((stats_unknown + 1))
        return 0
    fi
    
    # Handle mixed resource types
    if [[ "$resource_type" == MIXED:* ]]; then
        log_warning "Mixed resource types in file: ${file} (${resource_type#MIXED:})"
        log_info "  → Using generic Kubernetes schema"
        resource_type="UNKNOWN"  # Will use generic schema
    fi
    
    # Track resource type count
    type_counts["$resource_type"]=$((${type_counts["$resource_type"]:-0} + 1))
    
    # Get appropriate schema URL
    local schema_url
    schema_url="$(get_schema_url "$resource_type")"
    
    # Check existing schema
    local has_existing=false
    if has_schema_annotation "$file"; then
        has_existing=true
        
        # Check if it's correct
        if is_schema_correct "$file" "$schema_url"; then
            log_action "SKIP" "$file" "$resource_type"
            stats_skipped=$((stats_skipped + 1))
            return 0
        else
            # Schema exists but wrong URL - needs update
            if [[ "$dry_run" == "false" ]]; then
                add_or_update_schema "$file" "$schema_url" "true"
                log_action "UPDATE" "$file" "$resource_type"
                stats_modified=$((stats_modified + 1))
            else
                log_action "UPDATE" "$file" "$resource_type"
                if [[ "${VERBOSE}" == "true" ]]; then
                    local existing
                    existing="$(get_existing_schema "$file")"
                    log_info "  Old: ${existing#*\$schema=}"
                    log_info "  New: $schema_url"
                fi
                stats_would_modify=$((stats_would_modify + 1))
            fi
        fi
    else
        # No schema - needs to be added
        if [[ "$dry_run" == "false" ]]; then
            add_or_update_schema "$file" "$schema_url" "false"
            log_action "ADD" "$file" "$resource_type"
            stats_modified=$((stats_modified + 1))
        else
            log_action "ADD" "$file" "$resource_type"
            if [[ "${VERBOSE}" == "true" ]]; then
                log_info "  → Would add: $schema_url"
            fi
            stats_would_modify=$((stats_would_modify + 1))
        fi
    fi
}

#=====================================================================
# MAIN PROCESSING FUNCTIONS
#=====================================================================

build_find_command() {
    local target_path="$1"
    
    # Build find command with exclusions
    local find_cmd="find \"$target_path\" -type f \\( -name '*.yaml' -o -name '*.yml' \\)"
    
    for exclude_dir in "${EXCLUDE_DIRS[@]}"; do
        find_cmd+=" -not -path '*/${exclude_dir}/*'"
    done
    
    find_cmd+=" -print0"
    
    echo "$find_cmd"
}

process_directory() {
    local target_path="$1"
    local dry_run="$2"
    
    # Find all YAML files
    local files=()
    local find_cmd
    find_cmd="$(build_find_command "$target_path")"
    
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(eval "$find_cmd")
    
    local total=${#files[@]}
    
    if [[ $total -eq 0 ]]; then
        log_error "No YAML files found in ${target_path}"
        exit 1
    fi
    
    print_header "Processing ${total} YAML files in ${target_path}"
    
    local current=0
    for file in "${files[@]}"; do
        current=$((current + 1))
        
        # Show progress
        if [[ "${VERBOSE}" == "false" ]]; then
            printf "\r[%4d/%4d] Processing..." "$current" "$total"
        else
            echo ""
            log_info "[${current}/${total}] Processing: ${file}"
        fi
        
        # Process the file
        process_file "$file" "$dry_run"
    done
    
    if [[ "${VERBOSE}" == "false" ]]; then
        printf "\r[%4d/%4d] Complete!     \n" "$total" "$total"
    fi
}

#=====================================================================
# REPORTING FUNCTIONS
#=====================================================================

generate_report() {
    local mode="$1"
    local output_file="schema-annotation-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "======================================================"
        echo "  YAML Schema Annotation Report"
        echo "  Generated: $(date)"
        echo "  Mode: $mode"
        echo "======================================================"
        echo ""
        echo "STATISTICS:"
        echo "  Total files scanned:          $stats_total"
        echo "  Files with correct schemas:   $stats_skipped ($(( stats_total > 0 ? stats_skipped * 100 / stats_total : 0 ))%)"
        if [[ "$mode" == "DRY-RUN" ]]; then
            echo "  Files that would be modified: $stats_would_modify"
        else
            echo "  Files modified:               $stats_modified"
        fi
        echo "  Unknown resource types:       $stats_unknown"
        echo "  Errors:                       $stats_errors"
        echo ""
        
        if [[ ${#type_counts[@]} -gt 0 ]]; then
            echo "RESOURCE TYPE BREAKDOWN:"
            for type in "${!type_counts[@]}"; do
                printf "  %-35s %5d\n" "$type:" "${type_counts[$type]}"
            done | sort -k2 -rn
            echo ""
        fi
        
        echo "======================================================"
        
        if [[ "$mode" == "DRY-RUN" ]]; then
            echo ""
            echo "Run with --execute to apply changes."
        else
            echo ""
            echo "Next steps:"
            echo "  1. Review changes: git diff kubernetes/"
            echo "  2. Validate manifests: task kubernetes:kubeconform"
            echo "  3. Commit changes: git commit -m \"feat: add YAML schema annotations\""
        fi
    } | tee "$output_file"
    
    echo ""
    log_success "Report saved to: $output_file"
}

#=====================================================================
# PRE-FLIGHT CHECKS
#=====================================================================

check_prerequisites() {
    # Check if we're in a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not in a git repository"
        exit 1
    fi
    
    # Check if target directory exists
    if [[ ! -d "${TARGET_PATH}" ]]; then
        log_error "Target directory does not exist: ${TARGET_PATH}"
        exit 1
    fi
    
    # Warn if working tree is dirty (only if not force mode and executing)
    if [[ "${FORCE}" != "true" ]] && [[ "${DRY_RUN}" == "false" ]] && ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log_warning "Git working tree has uncommitted changes"
        log_warning "Changes made by this script will be mixed with existing modifications"
        log_warning "Consider committing or stashing first, or run with --force"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    log_success "Git repository: OK"
}

#=====================================================================
# USAGE AND ARGUMENT PARSING
#=====================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Add or update YAML schema annotations to Kubernetes manifests.

OPTIONS:
    --dry-run       Preview changes without modifying files (default)
    --execute       Apply changes to files
    --path <dir>    Target directory (default: kubernetes/)
    --force         Skip git clean check and confirmation prompts
    --verbose       Show detailed output
    -h, --help      Show this help message

EXAMPLES:
    # Preview what would change (default)
    $(basename "$0")
    
    # Preview specific directory
    $(basename "$0") --path kubernetes/apps
    
    # Apply changes to all files
    $(basename "$0") --execute
    
    # Apply changes with verbose output
    $(basename "$0") --execute --verbose
    
    # Force execution ignoring git status
    $(basename "$0") --execute --force

For more information, see docs/scripts/add-yaml-schemas.md
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --execute)
                DRY_RUN=false
                shift
                ;;
            --path)
                TARGET_PATH="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

#=====================================================================
# MAIN FUNCTION
#=====================================================================

main() {
    parse_arguments "$@"
    
    # Print header
    if [[ "${DRY_RUN}" == "true" ]]; then
        print_header "YAML Schema Annotation Tool - DRY RUN MODE"
        echo "No changes will be made. Use --execute to apply changes."
    else
        print_header "YAML Schema Annotation Tool - EXECUTE MODE"
        log_warning "Files will be modified!"
    fi
    
    echo ""
    
    # Pre-flight checks
    check_prerequisites
    
    # Process files
    local mode="EXECUTE"
    [[ "${DRY_RUN}" == "true" ]] && mode="DRY-RUN"
    
    process_directory "${TARGET_PATH}" "${DRY_RUN}"
    
    # Generate report
    echo ""
    generate_report "$mode"
}

# Run main function
main "$@"
