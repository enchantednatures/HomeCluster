#!/usr/bin/env bash
# IP to Variable Extraction Tool
# Finds hardcoded IPs and converts them to Flux variables
# Usage: ./extract-ips-to-vars.sh [--dry-run|--execute] [--verbose]

set -o errexit
set -o pipefail

#=====================================================================
# CONFIGURATION
#=====================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly KUBERNETES_DIR="${REPO_ROOT}/kubernetes"
readonly CLUSTER_SETTINGS_FILE="${KUBERNETES_DIR}/flux/vars/cluster-settings.yaml"

# IP address pattern (IPv4 192.168.x.x private range)
readonly IP_PATTERN='192\.168\.[0-9]{1,3}\.[0-9]{1,3}'

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Exclude patterns (LoadBalancer IPs, etc.)
readonly EXCLUDE_PATTERNS=(
    "metallb.universe.tf/loadBalancerIPs"
    "io.cilium/lb-ipam-ips"
    "tailscale.com/hostname"
    "loadBalancerIP:"
)

# Statistics
declare -i stats_ips_found=0
declare -i stats_ips_excluded=0
declare -i stats_replacements=0
declare -i stats_variables_created=0

# IP tracking
declare -A ip_contexts=()
declare -A ip_occurrences=()
declare -A ip_files=()
declare -A ip_has_port=()
declare -A ip_port_value=()
declare -A existing_variables=()

# Configuration
DRY_RUN=true
VERBOSE=false

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
# IP DETECTION FUNCTIONS
#=====================================================================

should_exclude_line() {
    local line="$1"
    
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if echo "$line" | grep -q "$pattern"; then
            return 0  # Should exclude
        fi
    done
    
    return 1  # Should not exclude
}

detect_context_for_ip() {
    local file="$1"
    local ip="$2"
    local line_num="$3"
    
    # Get surrounding context (5 lines before/after)
    local context_start=$((line_num > 5 ? line_num - 5 : 1))
    local context_end=$((line_num + 5))
    local context
    context=$(sed -n "${context_start},${context_end}p" "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    # Also check filename
    local filename_context
    filename_context=$(basename "$file" | tr '[:upper:]' '[:lower:]')
    
    # Check for keywords
    if echo "$context $filename_context" | grep -qE "nfs|csi-driver-nfs"; then
        echo "NFS_SERVER"
    elif echo "$context $filename_context" | grep -qE "minio|s3"; then
        echo "MINIO_SERVER"
    elif echo "$context $filename_context" | grep -qE "proxmox|pve"; then
        echo "PROXMOX"
    elif echo "$context $filename_context" | grep -qE "prometheus|scrape|kube.*controller|kube.*scheduler"; then
        echo "PROMETHEUS_TARGET"
    elif echo "$context $filename_context" | grep -qE "grafana"; then
        echo "GRAFANA"
    elif echo "$context $filename_context" | grep -qE "kube-vip|kubernetes-api"; then
        echo "KUBERNETES_API"
    else
        echo "EXTERNAL_ENDPOINT"
    fi
}

scan_for_ips() {
    local file="$1"
    
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        
        # Skip excluded patterns
        if should_exclude_line "$line"; then
            continue
        fi
        
        # Find all IPs in the line
        local ips
        ips=$(echo "$line" | grep -oE "$IP_PATTERN" || true)
        
        for ip in $ips; do
            stats_ips_found=$((stats_ips_found + 1))
            
            # Detect context
            local context
            context=$(detect_context_for_ip "$file" "$ip" "$line_num")
            
            # Check if IP has a port
            if echo "$line" | grep -qE "${ip}:[0-9]+"; then
                local port
                port=$(echo "$line" | grep -oE "${ip}:([0-9]+)" | cut -d: -f2)
                ip_has_port["$ip"]="true"
                ip_port_value["$ip"]="$port"
            fi
            
            # Track IP
            ip_contexts["$ip"]="$context"
            ip_occurrences["$ip"]=$((${ip_occurrences["$ip"]:-0} + 1))
            
            # Track files
            if [[ -n "${ip_files["$ip"]}" ]]; then
                ip_files["$ip"]="${ip_files["$ip"]}|$file"
            else
                ip_files["$ip"]="$file"
            fi
        done
    done < "$file"
}

#=====================================================================
# VARIABLE GENERATION FUNCTIONS
#=====================================================================

generate_variable_name() {
    local ip="$1"
    local context="${ip_contexts[$ip]}"
    
    # Check if this IP already has a variable
    for var in "${!existing_variables[@]}"; do
        if [[ "${existing_variables[$var]}" == "$ip" ]]; then
            echo "$var"
            return 0
        fi
    done
    
    # Generate new variable name based on context
    case "$context" in
        "NFS_SERVER")
            echo "NFS_SERVER_IP" ;;
        "MINIO_SERVER")
            echo "MINIO_SERVER_IP" ;;
        "PROXMOX")
            echo "PROXMOX_HOST" ;;
        "PROMETHEUS_TARGET")
            echo "PROMETHEUS_TARGET_IP" ;;
        "GRAFANA")
            echo "GRAFANA_HOST" ;;
        "KUBERNETES_API")
            echo "KUBERNETES_API_IP" ;;
        *)
            echo "EXTERNAL_IP_${ip//./_}" ;;
    esac
}

parse_existing_variables() {
    if [[ ! -f "${CLUSTER_SETTINGS_FILE}" ]]; then
        log_warning "Cluster settings file not found: ${CLUSTER_SETTINGS_FILE}"
        return
    fi
    
    # Parse existing variables from cluster-settings.yaml
    while IFS= read -r line; do
        # Match lines like "  KUBE_VIP_ADDR: 192.168.1.201"
        if [[ "$line" =~ ^[[:space:]]+([A-Z_]+):[[:space:]]*([0-9.]+) ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local var_value="${BASH_REMATCH[2]}"
            existing_variables["$var_name"]="$var_value"
            log_info "Found existing variable: $var_name=$var_value"
        fi
    done < "${CLUSTER_SETTINGS_FILE}"
}

#=====================================================================
# FILE REPLACEMENT FUNCTIONS
#=====================================================================

replace_ips_in_file() {
    local file="$1"
    local dry_run="$2"
    
    local temp_file="${file}.tmp"
    local modifications=0
    
    while IFS= read -r line; do
        local new_line="$line"
        
        # Skip excluded patterns
        if should_exclude_line "$line"; then
            echo "$new_line"
            continue
        fi
        
        # Find all IPs in this line
        local ips
        ips=$(echo "$line" | grep -oE "$IP_PATTERN" || true)
        
        for ip in $ips; do
            local var_name
            var_name=$(generate_variable_name "$ip")
            
            # Handle different replacement patterns
            if [[ "${ip_has_port[$ip]}" == "true" ]]; then
                # IP with port: split into IP and PORT variables
                local port="${ip_port_value[$ip]}"
                local port_var="${var_name%_IP}_PORT"
                new_line=$(echo "$new_line" | sed "s|${ip}:${port}|\${${var_name}}:\${${port_var}}|g")
            else
                # IP without port
                new_line=$(echo "$new_line" | sed "s|${ip}|\${${var_name}}|g")
            fi
            
            if [[ "$new_line" != "$line" ]]; then
                modifications=$((modifications + 1))
            fi
        done
        
        echo "$new_line"
    done < "$file" > "$temp_file"
    
    # Apply changes if not dry-run
    if [[ "$dry_run" == "false" ]] && [[ $modifications -gt 0 ]]; then
        mv "$temp_file" "$file"
        stats_replacements=$((stats_replacements + modifications))
        log_success "Updated: $file ($modifications replacements)"
    else
        rm -f "$temp_file"
        if [[ $modifications -gt 0 ]]; then
            log_info "Would update: $file ($modifications replacements)"
        fi
    fi
}

#=====================================================================
# CLUSTER SETTINGS UPDATE
#=====================================================================

update_cluster_settings() {
    local dry_run="$1"
    
    if [[ ! -f "${CLUSTER_SETTINGS_FILE}" ]]; then
        log_error "Cluster settings file not found: ${CLUSTER_SETTINGS_FILE}"
        return 1
    fi
    
    # Build variables to add
    local new_vars_infra=""
    local new_vars_storage=""
    local new_vars_monitoring=""
    local added_count=0
    
    for ip in "${!ip_contexts[@]}"; do
        local var_name
        var_name=$(generate_variable_name "$ip")
        
        # Skip if variable already exists with same value
        if [[ -n "${existing_variables[$var_name]}" ]] && \
           [[ "${existing_variables[$var_name]}" == "$ip" ]]; then
            continue
        fi
        
        local context="${ip_contexts[$ip]}"
        
        # Categorize variable
        if [[ "$context" == *"PROXMOX"* || "$context" == *"KUBERNETES"* ]]; then
            new_vars_infra+="  ${var_name}: ${ip}\n"
        elif [[ "$context" == *"NFS"* || "$context" == *"MINIO"* ]]; then
            new_vars_storage+="  ${var_name}: ${ip}\n"
            # Add port variable if applicable
            if [[ "${ip_has_port[$ip]}" == "true" ]]; then
                local port_var="${var_name%_IP}_PORT"
                local port="${ip_port_value[$ip]}"
                new_vars_storage+="  ${port_var}: \"${port}\"\n"
                added_count=$((added_count + 1))
            fi
        elif [[ "$context" == *"PROMETHEUS"* || "$context" == *"GRAFANA"* ]]; then
            new_vars_monitoring+="  ${var_name}: ${ip}\n"
        fi
        
        added_count=$((added_count + 1))
    done
    
    if [[ $added_count -eq 0 ]]; then
        log_info "No new variables to add"
        return 0
    fi
    
    # Update cluster-settings.yaml
    if [[ "$dry_run" == "false" ]]; then
        local temp_file="${CLUSTER_SETTINGS_FILE}.tmp"
        
        # Append new variables to the end of the data section
        {
            cat "${CLUSTER_SETTINGS_FILE}"
            if [[ -n "$new_vars_infra" ]]; then
                echo ""
                echo "  # Infrastructure Endpoints"
                echo -e "$new_vars_infra"
            fi
            if [[ -n "$new_vars_storage" ]]; then
                echo "  # Storage Endpoints"
                echo -e "$new_vars_storage"
            fi
            if [[ -n "$new_vars_monitoring" ]]; then
                echo "  # Monitoring Endpoints"
                echo -e "$new_vars_monitoring"
            fi
        } > "$temp_file"
        
        mv "$temp_file" "${CLUSTER_SETTINGS_FILE}"
        log_success "Updated ${CLUSTER_SETTINGS_FILE} with ${added_count} new variables"
    else
        log_info "Would add ${added_count} new variables to ${CLUSTER_SETTINGS_FILE}"
    fi
    
    stats_variables_created=$added_count
}

#=====================================================================
# MAIN PROCESSING
#=====================================================================

process_directory() {
    local target_path="$1"
    local dry_run="$2"
    
    # Find all YAML files
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$target_path" -type f \( -name "*.yaml" -o -name "*.yml" \) \
             -not -path "*/.venv/*" \
             -not -path "*/.archive/*" \
             -not -path "*/.git/*" \
             -print0)
    
    local total=${#files[@]}
    
    print_header "Scanning ${total} YAML files for hardcoded IPs"
    
    # Phase 1: Scan for IPs
    local current=0
    for file in "${files[@]}"; do
        current=$((current + 1))
        printf "\r[%4d/%4d] Scanning..." "$current" "$total"
        scan_for_ips "$file"
    done
    printf "\r[%4d/%4d] Scan complete!\n" "$total" "$total"
    
    # Parse existing variables
    parse_existing_variables
    
    # Phase 2: Replace IPs
    if [[ ${#ip_contexts[@]} -gt 0 ]]; then
        print_header "Replacing IPs with variables"
        
        current=0
        for file in "${files[@]}"; do
            current=$((current + 1))
            printf "\r[%4d/%4d] Replacing..." "$current" "$total"
            replace_ips_in_file "$file" "$dry_run"
        done
        printf "\r[%4d/%4d] Replacement complete!\n" "$total" "$total"
        
        # Phase 3: Update cluster-settings.yaml
        update_cluster_settings "$dry_run"
    else
        log_info "No IPs found to process"
    fi
}

#=====================================================================
# REPORTING
#=====================================================================

generate_report() {
    local mode="$1"
    local output_file="ip-extraction-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "======================================================"
        echo "  IP to Variable Extraction Report"
        echo "  Generated: $(date)"
        echo "  Mode: $mode"
        echo "======================================================"
        echo ""
        echo "DISCOVERED IP ADDRESSES:"
        echo ""
        
        for ip in "${!ip_contexts[@]}"; do
            local var_name
            var_name=$(generate_variable_name "$ip")
            local context="${ip_contexts[$ip]}"
            local occurrences="${ip_occurrences[$ip]}"
            
            echo "IP: $ip ($var_name)"
            echo "  Context: $context"
            echo "  Occurrences: $occurrences"
            if [[ "${ip_has_port[$ip]}" == "true" ]]; then
                echo "  Has Port: ${ip_port_value[$ip]}"
            fi
            
            # Show unique files
            local file_list="${ip_files[$ip]}"
            local unique_files
            unique_files=$(echo "$file_list" | tr '|' '\n' | sort -u | head -5)
            echo "  Files:"
            while IFS= read -r file; do
                echo "    - $file"
            done <<< "$unique_files"
            
            local file_count
            file_count=$(echo "$file_list" | tr '|' '\n' | sort -u | wc -l)
            if [[ $file_count -gt 5 ]]; then
                echo "    - (and $((file_count - 5)) more)"
            fi
            echo ""
        done
        
        echo "======================================================"
        echo "SUMMARY"
        echo "======================================================"
        echo "Total IPs found: ${#ip_contexts[@]}"
        echo "Total occurrences: $stats_ips_found"
        if [[ "$mode" == "DRY-RUN" ]]; then
            echo "Total replacements that would be made: (calculated per file)"
        else
            echo "Total replacements made: $stats_replacements"
        fi
        echo "Variables created: $stats_variables_created"
        echo ""
        
        if [[ "$mode" == "DRY-RUN" ]]; then
            echo "Run with --execute to apply changes."
        else
            echo "Next steps:"
            echo "  1. Review changes: git diff kubernetes/"
            echo "  2. Test Flux substitution: task flux:reconcile"
            echo "  3. Validate manifests: task kubernetes:kubeconform"
            echo "  4. Commit: git commit -m \"refactor: extract hardcoded IPs to variables\""
        fi
        echo "======================================================"
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

Extract hardcoded IPs to cluster-wide variables.

OPTIONS:
    --dry-run       Preview changes without modifying files (default)
    --execute       Apply changes to files
    --verbose       Show detailed output
    -h, --help      Show this help message

EXAMPLES:
    # Preview what would change (default)
    $(basename "$0")
    
    # Apply changes
    $(basename "$0") --execute
    
    # Verbose output
    $(basename "$0") --execute --verbose

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
        print_header "IP to Variable Extraction Tool - DRY RUN"
        echo "No changes will be made. Use --execute to apply changes."
    else
        print_header "IP to Variable Extraction Tool - EXECUTE MODE"
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
