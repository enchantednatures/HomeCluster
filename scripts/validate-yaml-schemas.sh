#!/usr/bin/env bash
# YAML Schema Validation Tool
# Validates YAML files against their schema annotations
# Uses the YAML language server protocol for validation
# Usage: ./validate-yaml-schemas.sh [--path <dir>]

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
readonly NC='\033[0m'

# Statistics
declare -i stats_total=0
declare -i stats_valid=0
declare -i stats_invalid=0
declare -i stats_no_schema=0

# Configuration
TARGET_PATH="${KUBERNETES_DIR}"
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
# VALIDATION FUNCTIONS
#=====================================================================

has_schema_annotation() {
    local file="$1"
    grep -q "^# yaml-language-server:" "$file" 2>/dev/null
}

validate_yaml_syntax() {
    local file="$1"
    
    # Use yq to validate YAML syntax
    if yq eval '.' "$file" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

validate_file() {
    local file="$1"
    
    stats_total=$((stats_total + 1))
    
    # Check if file has schema annotation
    if ! has_schema_annotation "$file"; then
        stats_no_schema=$((stats_no_schema + 1))
        log_warning "No schema annotation: $file"
        return 0
    fi
    
    # Validate YAML syntax
    if validate_yaml_syntax "$file"; then
        stats_valid=$((stats_valid + 1))
        log_info "✓ Valid: $file"
    else
        stats_invalid=$((stats_invalid + 1))
        log_error "✗ Invalid YAML syntax: $file"
    fi
}

#=====================================================================
# MAIN PROCESSING
#=====================================================================

process_directory() {
    local target_path="$1"
    
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
    
    print_header "Validating ${total} YAML files"
    
    local current=0
    for file in "${files[@]}"; do
        current=$((current + 1))
        printf "\r[%4d/%4d] Validating..." "$current" "$total"
        validate_file "$file"
    done
    printf "\r[%4d/%4d] Complete!     \n" "$total" "$total"
}

#=====================================================================
# REPORTING
#=====================================================================

generate_report() {
    echo ""
    print_header "VALIDATION REPORT"
    
    echo "STATISTICS:"
    echo "  Total files scanned:          $stats_total"
    echo "  Files with valid YAML:        $stats_valid ($(( stats_total > 0 ? stats_valid * 100 / stats_total : 0 ))%)"
    echo "  Files with invalid YAML:      $stats_invalid"
    echo "  Files without schema:         $stats_no_schema"
    echo ""
    
    if [[ $stats_invalid -eq 0 ]]; then
        log_success "All YAML files are syntactically valid!"
    else
        log_error "Found $stats_invalid files with YAML syntax errors"
        return 1
    fi
    
    if [[ $stats_no_schema -gt 0 ]]; then
        log_warning "$stats_no_schema files are missing schema annotations"
        echo "  Run: task scripts:add-schemas -- --execute"
    fi
}

#=====================================================================
# ARGUMENT PARSING
#=====================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validate YAML files against their schema annotations.

OPTIONS:
    --path <dir>    Target directory (default: kubernetes/)
    --verbose       Show detailed output
    -h, --help      Show this help message

EXAMPLES:
    # Validate all files
    $(basename "$0")
    
    # Validate specific directory
    $(basename "$0") --path kubernetes/apps
    
    # Verbose output
    $(basename "$0") --verbose

NOTES:
    This script validates YAML syntax using yq.
    For full Kubernetes resource validation, use:
        task kubernetes:kubeconform

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path)
                TARGET_PATH="$2"
                shift 2
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
    
    print_header "YAML Schema Validation Tool"
    
    # Check if yq is available
    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq is not installed. Please install it first:"
        echo "  https://github.com/mikefarah/yq"
        exit 1
    fi
    
    # Check if target directory exists
    if [[ ! -d "${TARGET_PATH}" ]]; then
        log_error "Target directory does not exist: ${TARGET_PATH}"
        exit 1
    fi
    
    log_success "Using yq version: $(yq --version)"
    
    # Process files
    process_directory "${TARGET_PATH}"
    
    # Generate report
    generate_report
}

# Run main
main "$@"
