#!/usr/bin/env bash
# HelmRelease Standardization Tool
# Standardizes HelmRelease specifications across the repository
# Usage: ./standardize-helmreleases.sh [--dry-run|--execute] [--verbose]

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

# Statistics
declare -i stats_total=0
declare -i stats_modified=0
declare -i stats_would_modify=0
declare -i stats_skipped=0
declare -i stats_errors=0

# Tracking what needs to be added
declare -A needs_max_history=()
declare -A needs_uninstall=()
declare -A needs_install_strategy=()
declare -A needs_upgrade_strategy=()

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
# ANALYSIS FUNCTIONS
#=====================================================================

analyze_helmrelease() {
    local file="$1"
    
    # Check if it's actually a HelmRelease
    if ! grep -q "^kind: HelmRelease" "$file" 2>/dev/null; then
        return 0
    fi
    
    stats_total=$((stats_total + 1))
    
    local needs_update=false
    
    # Check for maxHistory
    if ! grep -q "^  maxHistory:" "$file"; then
        needs_max_history["$file"]="true"
        needs_update=true
        log_info "Missing maxHistory: $file"
    fi
    
    # Check for uninstall.keepHistory
    if ! grep -q "keepHistory:" "$file"; then
        needs_uninstall["$file"]="true"
        needs_update=true
        log_info "Missing uninstall.keepHistory: $file"
    fi
    
    # Check for install remediation strategy
    if grep -q "^  install:" "$file"; then
        if ! grep -A5 "^  install:" "$file" | grep -q "strategy:"; then
            needs_install_strategy["$file"]="true"
            needs_update=true
            log_info "Missing install.remediation.strategy: $file"
        fi
    fi
    
    # Check for upgrade remediation strategy
    if grep -q "^  upgrade:" "$file"; then
        if ! grep -A5 "^  upgrade:" "$file" | grep -q "strategy:"; then
            needs_upgrade_strategy["$file"]="true"
            needs_update=true
            log_info "Missing upgrade.remediation.strategy: $file"
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

add_max_history() {
    local file="$1"
    
    # Add maxHistory: 2 after the spec: line
    sed -i '/^spec:$/a\  maxHistory: 2' "$file"
}

add_uninstall_keep_history() {
    local file="$1"
    
    # Check if uninstall section exists
    if grep -q "^  uninstall:" "$file"; then
        # Add keepHistory under existing uninstall
        sed -i '/^  uninstall:$/a\    keepHistory: false' "$file"
    else
        # Add entire uninstall section before values or at end of spec
        if grep -q "^  values:" "$file"; then
            sed -i '/^  values:$/i\  uninstall:\n    keepHistory: false' "$file"
        else
            # Add at end of spec section (before the closing of the file)
            # This is tricky - we'll add it after the last indented spec item
            local last_line=$(grep -n "^  [a-z]" "$file" | tail -1 | cut -d: -f1)
            if [[ -n "$last_line" ]]; then
                sed -i "${last_line}a\\  uninstall:\\n    keepHistory: false" "$file"
            fi
        fi
    fi
}

add_remediation_strategy() {
    local file="$1"
    local section="$2"  # "install" or "upgrade"
    
    # Find the remediation section within install/upgrade
    if grep -A10 "^  ${section}:" "$file" | grep -q "remediation:"; then
        # Remediation exists, add strategy after it
        # Use awk to add strategy: rollback after the remediation: line in the correct section
        awk -v section="$section" '
        /^  install:/ { in_install=1; in_upgrade=0 }
        /^  upgrade:/ { in_upgrade=1; in_install=0 }
        /^  [a-z]/ && !/^  (install|upgrade):/ { in_install=0; in_upgrade=0 }
        {
            print
            if ((section == "install" && in_install) || (section == "upgrade" && in_upgrade)) {
                if (/^      remediation:$/ && !strategy_added) {
                    print "        strategy: rollback"
                    strategy_added=1
                }
            }
        }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi
}

standardize_file() {
    local file="$1"
    local dry_run="$2"
    
    if [[ "$dry_run" == "false" ]]; then
        # Add maxHistory if needed
        if [[ "${needs_max_history[$file]}" == "true" ]]; then
            add_max_history "$file"
            log_info "  ✓ Added maxHistory: 2"
        fi
        
        # Add uninstall.keepHistory if needed
        if [[ "${needs_uninstall[$file]}" == "true" ]]; then
            add_uninstall_keep_history "$file"
            log_info "  ✓ Added uninstall.keepHistory: false"
        fi
        
        # Add install strategy if needed
        if [[ "${needs_install_strategy[$file]}" == "true" ]]; then
            add_remediation_strategy "$file" "install"
            log_info "  ✓ Added install.remediation.strategy: rollback"
        fi
        
        # Add upgrade strategy if needed
        if [[ "${needs_upgrade_strategy[$file]}" == "true" ]]; then
            add_remediation_strategy "$file" "upgrade"
            log_info "  ✓ Added upgrade.remediation.strategy: rollback"
        fi
        
        stats_modified=$((stats_modified + 1))
        log_success "Updated: $file"
    else
        echo -e "${YELLOW}↻${NC} Would update: $file"
        if [[ "${needs_max_history[$file]}" == "true" ]]; then
            echo "    - Add maxHistory: 2"
        fi
        if [[ "${needs_uninstall[$file]}" == "true" ]]; then
            echo "    - Add uninstall.keepHistory: false"
        fi
        if [[ "${needs_install_strategy[$file]}" == "true" ]]; then
            echo "    - Add install.remediation.strategy: rollback"
        fi
        if [[ "${needs_upgrade_strategy[$file]}" == "true" ]]; then
            echo "    - Add upgrade.remediation.strategy: rollback"
        fi
    fi
}

#=====================================================================
# MAIN PROCESSING
#=====================================================================

process_directory() {
    local target_path="$1"
    local dry_run="$2"
    
    # Find all HelmRelease files
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$target_path" -type f -name "helmrelease.yaml" -print0)
    
    local total=${#files[@]}
    
    print_header "Analyzing ${total} HelmRelease files"
    
    # Phase 1: Analyze
    local current=0
    for file in "${files[@]}"; do
        current=$((current + 1))
        printf "\r[%4d/%4d] Analyzing..." "$current" "$total"
        analyze_helmrelease "$file"
    done
    printf "\r[%4d/%4d] Analysis complete!\n" "$total" "$total"
    
    # Phase 2: Standardize
    if [[ $stats_would_modify -gt 0 ]]; then
        print_header "Standardizing HelmReleases"
        
        current=0
        for file in "${files[@]}"; do
            # Only process files that need updates
            if [[ "${needs_max_history[$file]}" == "true" ]] || \
               [[ "${needs_uninstall[$file]}" == "true" ]] || \
               [[ "${needs_install_strategy[$file]}" == "true" ]] || \
               [[ "${needs_upgrade_strategy[$file]}" == "true" ]]; then
                current=$((current + 1))
                standardize_file "$file" "$dry_run"
            fi
        done
    else
        log_success "All HelmReleases already follow the standard!"
    fi
}

#=====================================================================
# REPORTING
#=====================================================================

generate_report() {
    local mode="$1"
    local output_file="helmrelease-standardization-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "======================================================"
        echo "  HelmRelease Standardization Report"
        echo "  Generated: $(date)"
        echo "  Mode: $mode"
        echo "======================================================"
        echo ""
        echo "STATISTICS:"
        echo "  Total HelmReleases scanned: $stats_total"
        echo "  Already standardized:       $stats_skipped"
        if [[ "$mode" == "DRY-RUN" ]]; then
            echo "  Would be modified:          $stats_would_modify"
        else
            echo "  Modified:                   $stats_modified"
        fi
        echo "  Errors:                     $stats_errors"
        echo ""
        
        if [[ $stats_would_modify -gt 0 ]] || [[ $stats_modified -gt 0 ]]; then
            echo "CHANGES MADE/PLANNED:"
            local count_max_history=0
            local count_uninstall=0
            local count_install_strategy=0
            local count_upgrade_strategy=0
            
            for file in "${!needs_max_history[@]}"; do
                count_max_history=$((count_max_history + 1))
            done
            for file in "${!needs_uninstall[@]}"; do
                count_uninstall=$((count_uninstall + 1))
            done
            for file in "${!needs_install_strategy[@]}"; do
                count_install_strategy=$((count_install_strategy + 1))
            done
            for file in "${!needs_upgrade_strategy[@]}"; do
                count_upgrade_strategy=$((count_upgrade_strategy + 1))
            done
            
            echo "  Added maxHistory: 2                    → $count_max_history files"
            echo "  Added uninstall.keepHistory: false     → $count_uninstall files"
            echo "  Added install.remediation.strategy     → $count_install_strategy files"
            echo "  Added upgrade.remediation.strategy     → $count_upgrade_strategy files"
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
            echo "  2. Validate: task kubernetes:kubeconform"
            echo "  3. Commit: git commit -m \"refactor: standardize HelmRelease specifications\""
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

Standardize HelmRelease specifications across the repository.

Adds missing standard fields:
  - maxHistory: 2
  - uninstall.keepHistory: false
  - install.remediation.strategy: rollback
  - upgrade.remediation.strategy: rollback

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
        print_header "HelmRelease Standardization Tool - DRY RUN"
        echo "No changes will be made. Use --execute to apply changes."
    else
        print_header "HelmRelease Standardization Tool - EXECUTE MODE"
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
