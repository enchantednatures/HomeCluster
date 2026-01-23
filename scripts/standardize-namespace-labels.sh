#!/usr/bin/env bash
# Namespace Label Standardization Tool
# Standardizes namespace labels across the repository
# Usage: ./standardize-namespace-labels.sh [--dry-run|--execute] [--verbose]

set -o errexit
set -o pipefail

#=====================================================================
# CONFIGURATION
#=====================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Standard labels to add
readonly LABEL_PRUNE="kustomize.toolkit.fluxcd.io/prune"
readonly LABEL_ISTIO_DATAPLANE="istio.io/dataplane-mode"
readonly LABEL_POD_SECURITY="pod-security.kubernetes.io/enforce"

# Namespaces that should have Istio ambient mode
readonly ISTIO_ENABLED_NAMESPACES=(
    "immich"
    "atuin"
    "telepresence"
    "arangodb"
    "home-system"
    "default"
    "actions-runner-system"
    "redpanda"
    "kafka"
)

# Statistics
declare -i stats_total=0
declare -i stats_modified=0
declare -i stats_would_modify=0
declare -i stats_skipped=0

# Tracking
declare -A needs_prune_label=()
declare -A needs_istio_label=()
declare -A needs_pod_security=()
declare -A namespace_names=()

# Configuration
DRY_RUN=true
VERBOSE=false
ADD_POD_SECURITY=false

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

#=====================================================================
# ANALYSIS FUNCTIONS
#=====================================================================

is_istio_enabled_namespace() {
    local ns_name="$1"
    
    for istio_ns in "${ISTIO_ENABLED_NAMESPACES[@]}"; do
        if [[ "$ns_name" == "$istio_ns" ]]; then
            return 0
        fi
    done
    return 1
}

extract_namespace_name() {
    local file="$1"
    
    # Extract namespace name from metadata.name
    grep "^  name:" "$file" 2>/dev/null | head -1 | awk '{print $2}'
}

analyze_namespace() {
    local file="$1"
    
    # Check if it's actually a Namespace
    if ! grep -q "^kind: Namespace" "$file" 2>/dev/null; then
        return 0
    fi
    
    stats_total=$((stats_total + 1))
    
    local ns_name
    ns_name=$(extract_namespace_name "$file")
    namespace_names["$file"]="$ns_name"
    
    local needs_update=false
    
    # Check for prune label
    if ! grep -q "${LABEL_PRUNE}: disabled" "$file"; then
        needs_prune_label["$file"]="true"
        needs_update=true
        log_info "Missing prune label: $file ($ns_name)"
    fi
    
    # Check for Istio dataplane label
    if ! grep -q "${LABEL_ISTIO_DATAPLANE}:" "$file"; then
        needs_istio_label["$file"]="true"
        needs_update=true
        log_info "Missing Istio dataplane label: $file ($ns_name)"
    fi
    
    # Check for pod security label (optional)
    if [[ "${ADD_POD_SECURITY}" == "true" ]]; then
        if ! grep -q "${LABEL_POD_SECURITY}:" "$file"; then
            needs_pod_security["$file"]="true"
            needs_update=true
            log_info "Missing pod security label: $file ($ns_name)"
        fi
    fi
    
    if [[ "$needs_update" == "true" ]]; then
        stats_would_modify=$((stats_would_modify + 1))
    else
        stats_skipped=$((stats_skipped + 1))
    fi
}

#=====================================================================
# MODIFICATION FUNCTIONS
#=====================================================================

add_labels_to_namespace() {
    local file="$1"
    local dry_run="$2"
    local ns_name="${namespace_names[$file]}"
    
    if [[ "$dry_run" == "false" ]]; then
        local temp_file="${file}.tmp"
        local in_metadata=false
        local labels_section_exists=false
        local added_labels=false
        
        # Read file line by line
        while IFS= read -r line; do
            echo "$line"
            
            # Detect metadata section
            if [[ "$line" == "metadata:" ]]; then
                in_metadata=true
            elif [[ "$line" =~ ^[a-z] ]] && [[ "$in_metadata" == "true" ]]; then
                in_metadata=false
            fi
            
            # Detect labels section within metadata
            if [[ "$in_metadata" == "true" ]] && [[ "$line" == "  labels:" ]]; then
                labels_section_exists=true
            fi
            
            # Add labels after the metadata.name line if no labels section exists
            if [[ "$in_metadata" == "true" ]] && [[ "$line" =~ ^[[:space:]]+name: ]] && [[ "$labels_section_exists" == "false" ]] && [[ "$added_labels" == "false" ]]; then
                echo "  labels:"
                
                # Add prune label
                if [[ "${needs_prune_label[$file]}" == "true" ]]; then
                    echo "    ${LABEL_PRUNE}: disabled"
                fi
                
                # Add Istio label
                if [[ "${needs_istio_label[$file]}" == "true" ]]; then
                    if is_istio_enabled_namespace "$ns_name"; then
                        echo "    ${LABEL_ISTIO_DATAPLANE}: ambient"
                    else
                        echo "    ${LABEL_ISTIO_DATAPLANE}: disabled"
                    fi
                fi
                
                # Add pod security label
                if [[ "${needs_pod_security[$file]}" == "true" ]] && [[ "${ADD_POD_SECURITY}" == "true" ]]; then
                    echo "    ${LABEL_POD_SECURITY}: restricted"
                fi
                
                added_labels=true
                labels_section_exists=true
            fi
            
            # Add labels at the end of existing labels section
            if [[ "$labels_section_exists" == "true" ]] && [[ "$added_labels" == "false" ]] && [[ "$line" =~ ^[[:space:]]{0,2}[a-z] ]] && [[ ! "$line" =~ ^[[:space:]]+[a-z./] ]]; then
                # We've left the labels section, add our labels before this line
                if [[ "${needs_prune_label[$file]}" == "true" ]]; then
                    echo "    ${LABEL_PRUNE}: disabled" | cat - <(echo "$line")
                fi
                if [[ "${needs_istio_label[$file]}" == "true" ]]; then
                    if is_istio_enabled_namespace "$ns_name"; then
                        echo "    ${LABEL_ISTIO_DATAPLANE}: ambient"
                    else
                        echo "    ${LABEL_ISTIO_DATAPLANE}: disabled"
                    fi
                fi
                if [[ "${needs_pod_security[$file]}" == "true" ]] && [[ "${ADD_POD_SECURITY}" == "true" ]]; then
                    echo "    ${LABEL_POD_SECURITY}: restricted"
                fi
                added_labels=true
                continue  # Skip the original line since we already printed it
            fi
            
        done < "$file" > "$temp_file"
        
        # If labels section exists but we didn't add labels yet, append them
        if [[ "$labels_section_exists" == "true" ]] && [[ "$added_labels" == "false" ]]; then
            {
                cat "$temp_file"
                if [[ "${needs_prune_label[$file]}" == "true" ]]; then
                    echo "    ${LABEL_PRUNE}: disabled"
                fi
                if [[ "${needs_istio_label[$file]}" == "true" ]]; then
                    if is_istio_enabled_namespace "$ns_name"; then
                        echo "    ${LABEL_ISTIO_DATAPLANE}: ambient"
                    else
                        echo "    ${LABEL_ISTIO_DATAPLANE}: disabled"
                    fi
                fi
                if [[ "${needs_pod_security[$file]}" == "true" ]] && [[ "${ADD_POD_SECURITY}" == "true" ]]; then
                    echo "    ${LABEL_POD_SECURITY}: restricted"
                fi
            } > "${temp_file}.2"
            mv "${temp_file}.2" "$temp_file"
        fi
        
        mv "$temp_file" "$file"
        
        stats_modified=$((stats_modified + 1))
        log_success "Updated: $file ($ns_name)"
    else
        echo -e "${YELLOW}↻${NC} Would update: $file ($ns_name)"
        if [[ "${needs_prune_label[$file]}" == "true" ]]; then
            echo "    - Add ${LABEL_PRUNE}: disabled"
        fi
        if [[ "${needs_istio_label[$file]}" == "true" ]]; then
            if is_istio_enabled_namespace "$ns_name"; then
                echo "    - Add ${LABEL_ISTIO_DATAPLANE}: ambient"
            else
                echo "    - Add ${LABEL_ISTIO_DATAPLANE}: disabled"
            fi
        fi
        if [[ "${needs_pod_security[$file]}" == "true" ]] && [[ "${ADD_POD_SECURITY}" == "true" ]]; then
            echo "    - Add ${LABEL_POD_SECURITY}: restricted"
        fi
    fi
}

#=====================================================================
# MAIN PROCESSING
#=====================================================================

process_directory() {
    local target_path="$1"
    local dry_run="$2"
    
    # Find all namespace.yaml files
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$target_path" -type f -name "namespace.yaml" -print0)
    
    local total=${#files[@]}
    
    print_header "Analyzing ${total} Namespace files"
    
    # Phase 1: Analyze
    local current=0
    for file in "${files[@]}"; do
        current=$((current + 1))
        printf "\r[%4d/%4d] Analyzing..." "$current" "$total"
        analyze_namespace "$file"
    done
    printf "\r[%4d/%4d] Analysis complete!\n" "$total" "$total"
    
    # Phase 2: Standardize
    if [[ $stats_would_modify -gt 0 ]]; then
        print_header "Standardizing Namespaces"
        
        current=0
        for file in "${files[@]}"; do
            # Only process files that need updates
            if [[ "${needs_prune_label[$file]}" == "true" ]] || \
               [[ "${needs_istio_label[$file]}" == "true" ]] || \
               [[ "${needs_pod_security[$file]}" == "true" ]]; then
                current=$((current + 1))
                add_labels_to_namespace "$file" "$dry_run"
            fi
        done
    else
        log_success "All namespaces already follow the standard!"
    fi
}

#=====================================================================
# REPORTING
#=====================================================================

generate_report() {
    local mode="$1"
    local output_file="namespace-standardization-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "======================================================"
        echo "  Namespace Standardization Report"
        echo "  Generated: $(date)"
        echo "  Mode: $mode"
        echo "======================================================"
        echo ""
        echo "STATISTICS:"
        echo "  Total namespaces scanned:   $stats_total"
        echo "  Already standardized:       $stats_skipped"
        if [[ "$mode" == "DRY-RUN" ]]; then
            echo "  Would be modified:          $stats_would_modify"
        else
            echo "  Modified:                   $stats_modified"
        fi
        echo ""
        
        if [[ $stats_would_modify -gt 0 ]] || [[ $stats_modified -gt 0 ]]; then
            echo "LABELS ADDED:"
            local count_prune=0
            local count_istio=0
            local count_pod_security=0
            
            for file in "${!needs_prune_label[@]}"; do
                count_prune=$((count_prune + 1))
            done
            for file in "${!needs_istio_label[@]}"; do
                count_istio=$((count_istio + 1))
            done
            for file in "${!needs_pod_security[@]}"; do
                count_pod_security=$((count_pod_security + 1))
            done
            
            echo "  ${LABEL_PRUNE}: disabled          → $count_prune namespaces"
            echo "  ${LABEL_ISTIO_DATAPLANE}: ambient/disabled → $count_istio namespaces"
            if [[ "${ADD_POD_SECURITY}" == "true" ]]; then
                echo "  ${LABEL_POD_SECURITY}: restricted      → $count_pod_security namespaces"
            fi
            echo ""
        fi
        
        echo "ISTIO AMBIENT MODE NAMESPACES:"
        for ns in "${ISTIO_ENABLED_NAMESPACES[@]}"; do
            echo "  - $ns"
        done
        echo ""
        
        echo "======================================================"
        
        if [[ "$mode" == "DRY-RUN" ]]; then
            echo ""
            echo "Run with --execute to apply changes."
        else
            echo ""
            echo "Next steps:"
            echo "  1. Review changes: git diff kubernetes/"
            echo "  2. Validate: task kubernetes:kubeconform"
            echo "  3. Commit: git commit -m \"refactor: standardize namespace labels\""
        fi
    } | tee "$output_file"
    
    echo ""
    log_success "Report saved to: $output_file"
}

#=====================================================================
# ARGUMENT PARSING
#=====================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Standardize namespace labels across the repository.

Adds standard labels:
  - ${LABEL_PRUNE}: disabled
  - ${LABEL_ISTIO_DATAPLANE}: ambient (for app namespaces) or disabled
  - ${LABEL_POD_SECURITY}: restricted (optional)

OPTIONS:
    --dry-run           Preview changes without modifying files (default)
    --execute           Apply changes to files
    --pod-security      Also add pod-security.kubernetes.io/enforce label
    --verbose           Show detailed output
    -h, --help          Show this help message

EXAMPLES:
    # Preview what would change (default)
    $(basename "$0")
    
    # Apply changes
    $(basename "$0") --execute
    
    # Include pod security labels
    $(basename "$0") --execute --pod-security

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
            --pod-security)
                ADD_POD_SECURITY=true
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
# MAIN
#=====================================================================

main() {
    parse_arguments "$@"
    
    # Print header
    if [[ "${DRY_RUN}" == "true" ]]; then
        print_header "Namespace Standardization Tool - DRY RUN"
        echo "No changes will be made. Use --execute to apply changes."
    else
        print_header "Namespace Standardization Tool - EXECUTE MODE"
        log_warning "Files will be modified!"
    fi
    
    echo ""
    
    # Check git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not in a git repository"
        exit 1
    fi
    
    log_success "Git repository: OK"
    
    # Process files
    process_directory "${KUBERNETES_DIR}" "${DRY_RUN}"
    
    # Generate report
    echo ""
    local mode="EXECUTE"
    [[ "${DRY_RUN}" == "true" ]] && mode="DRY-RUN"
    generate_report "$mode"
}

# Run main
main "$@"
