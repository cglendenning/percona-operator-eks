#!/bin/bash
# Sensitive Data Scrubber - Redacts sensitive information from files
# Works on WSL and Linux systems
# 
# Usage:
#   ./scrubber.sh redact <directory> [--dry-run]     - Redact sensitive data
#   ./scrubber.sh unredact <directory> [--dry-run]   - Restore original data
#
# Features:
# - Redacts IP addresses, hostnames, passwords, secrets, etc.
# - User-defined product keywords
# - Case-insensitive matching
# - Reversible with redacted.json mapping file
# - Creates backups before modification

# Use set -euo pipefail globally, but disable in specific functions that need to handle errors
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDACTED_JSON="redacted.json"
KEYWORDS_JSON="keywords.json"
BACKUP_DIR=".scrubber_backup"
DRY_RUN=false
DEBUG=false

# Global variables (declared here to avoid scoping issues)
declare -a PRODUCT_KEYWORDS=()

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_dry_run() {
    echo -e "${YELLOW}[DRY-RUN]${NC} $1"
}

log_header() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Show usage
usage() {
    cat << EOF
Usage: $0 <command> <directory> [options]

Commands:
  redact <directory>     Redact sensitive information from all files
  unredact <directory>   Restore original data using redacted.json

Options:
  --dry-run              Preview what would be changed without modifying files
  --debug                Enable verbose debug output for troubleshooting

Examples:
  $0 redact /path/to/project
  $0 redact /path/to/project --dry-run
  $0 redact /path/to/project --dry-run --debug
  $0 unredact /path/to/project
  $0 unredact /path/to/project --dry-run

The script will:
  1. Prompt for product-specific keywords to redact
  2. Scan all files for sensitive data patterns
  3. Replace sensitive data with [REDACTED_ID_XXX] markers
  4. Store mappings in redacted.json for restoration
  5. Create backups in .scrubber_backup directory

Dry-run mode:
  - Shows exactly what would be redacted/unredacted
  - Does not modify any files
  - Does not create backups or redacted.json
  - Useful for previewing impact before making changes

Debug mode:
  - Shows detailed processing information for each file
  - Useful for troubleshooting issues
  - Can be combined with --dry-run

EOF
    exit 1
}

# Check prerequisites
check_prerequisites() {
    local missing=()

    # jq is required for JSON operations
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    # sed is required for string manipulation
    if ! command -v sed &> /dev/null; then
        missing+=("sed")
    fi

    # grep is required for pattern matching
    if ! command -v grep &> /dev/null; then
        missing+=("grep")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install with: sudo apt-get install ${missing[*]}"
        exit 1
    fi

    # Optional tools warnings
    local optional_missing=()
    if ! command -v file &> /dev/null; then
        optional_missing+=("file (for better binary detection)")
    fi
    if ! command -v mktemp &> /dev/null; then
        optional_missing+=("mktemp (for safer temp files)")
    fi
    if ! command -v timeout &> /dev/null; then
        optional_missing+=("timeout (for preventing hangs)")
    fi

    if [ ${#optional_missing[@]} -gt 0 ]; then
        log_warn "Optional tools not found: ${optional_missing[*]}"
        log_warn "Script will work with reduced functionality"
    fi
}

# Escape string for use in sed
escape_for_sed() {
    echo "$1" | sed -e 's/[\/&]/\\&/g' -e 's/\$/\\$/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

# Escape string for use in grep
escape_for_grep() {
    echo "$1" | sed 's/[.*^$[\]\\]/\\&/g'
}

# Generate unique redaction ID
generate_redaction_id() {
    # Use nanoseconds and random for better uniqueness
    local timestamp=$(date +%s%N 2>/dev/null || date +%s)
    local random_part=$(od -An -tx8 -N8 /dev/urandom 2>/dev/null | tr -d ' ' || echo "${RANDOM}${RANDOM}")
    echo "REDACTED_ID_${timestamp}_${random_part}"
}

# Initialize redaction map
init_redaction_map() {
    local target_dir="$1"
    local json_file="${target_dir}/${REDACTED_JSON}"
    
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would initialize redaction map: $json_file"
        return
    fi
    
    if [ -f "$json_file" ]; then
        log_warn "Redaction map already exists: $json_file"
        echo -n "Overwrite existing map? (yes/no): "
        read confirm
        if [ "$confirm" != "yes" ]; then
            log_error "Aborted by user"
            exit 1
        fi
    fi
    
    # Initialize JSON structure
    cat > "$json_file" << 'EOF'
{
  "metadata": {
    "created": "",
    "version": "1.0",
    "total_redactions": 0
  },
  "redactions": {}
}
EOF
    
    # Set created timestamp
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".metadata.created = \"$timestamp\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
    
    log_success "Initialized redaction map: $json_file"
}

# Add redaction to map
add_to_redaction_map() {
    local json_file="$1"
    local redaction_id="$2"
    local original_value="$3"
    local pattern_type="$4"
    
    if [ "$DRY_RUN" = true ]; then
        return
    fi
    
    # Escape special characters for JSON
    local escaped_value=$(echo "$original_value" | jq -Rs .)
    
    # Add to redactions object
    jq ".redactions[\"$redaction_id\"] = {
        \"original\": $escaped_value,
        \"type\": \"$pattern_type\"
    } | .metadata.total_redactions += 1" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
}

# Load keywords from JSON file
load_keywords_from_json() {
    local keywords_file="$1"

    if [ ! -f "$keywords_file" ]; then
        return 1
    fi

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_error "jq is required to load keywords from JSON file"
        return 1
    fi

    # Read keywords array from JSON
    local keywords_json=""
    keywords_json=$(jq -r '.keywords[]' "$keywords_file" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")

    if [ -z "$keywords_json" ]; then
        return 1
    fi

    # Convert to array
    IFS=',' read -ra PRODUCT_KEYWORDS <<< "$keywords_json"

    # Trim whitespace from each keyword
    for i in "${!PRODUCT_KEYWORDS[@]}"; do
        PRODUCT_KEYWORDS[$i]=$(echo "${PRODUCT_KEYWORDS[$i]}" | xargs)
    done

    return 0
}

# Save keywords to JSON file
save_keywords_to_json() {
    local keywords_file="$1"
    shift
    local keywords=("$@")

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_error "Cannot save keywords: jq is required"
        return 1
    fi

    # Create JSON array
    local json_keywords=""
    json_keywords=$(printf '%s\n' "${keywords[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

    # Create JSON structure
    cat > "$keywords_file" << EOF
{
  "keywords": $json_keywords,
  "updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# Get product keywords from user
get_product_keywords() {
    local target_dir="$1"
    local keywords_file="${target_dir}/${KEYWORDS_JSON}"
    
    log_header "Product Keywords Configuration"
    
    # Check if keywords.json exists
    if [ -f "$keywords_file" ]; then
        log_info "Found existing keywords file: $keywords_file"
        
        if load_keywords_from_json "$keywords_file"; then
            echo ""
            log_success "Loaded ${#PRODUCT_KEYWORDS[@]} keywords from file:"
            for keyword in "${PRODUCT_KEYWORDS[@]}"; do
                echo "  - $keyword"
            done
            echo ""
            
            echo -n "Add additional keywords? (yes/no) [no]: "
            read add_more
            
            if [ "$add_more" = "yes" ]; then
                echo ""
                echo "Enter additional keywords to add (comma-separated):"
                echo -n "Additional keywords: "
                read keywords_input
                
                if [ -n "$keywords_input" ]; then
                    # Convert comma-separated to array
                    IFS=',' read -ra NEW_KEYWORDS <<< "$keywords_input"

                    # Validate and add to existing keywords
                    local added_count=0
                    for keyword in "${NEW_KEYWORDS[@]}"; do
                        keyword=$(echo "$keyword" | xargs)
                        if [ -n "$keyword" ]; then
                            # Validate keyword (no dangerous characters)
                            if [[ "$keyword" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                                # Check if keyword already exists
                                if [[ ! " ${PRODUCT_KEYWORDS[*]} " =~ " $keyword " ]]; then
                                    PRODUCT_KEYWORDS+=("$keyword")
                                    ((added_count++))
                                else
                                    log_warn "Keyword already exists: '$keyword'"
                                fi
                            else
                                log_warn "Skipping invalid keyword (only alphanumeric, underscore, hyphen allowed): '$keyword'"
                            fi
                        fi
                    done

                    if [ $added_count -gt 0 ]; then
                        # Save updated keywords
                        save_keywords_to_json "$keywords_file" "${PRODUCT_KEYWORDS[@]}"
                        log_success "Added $added_count new keywords (total: ${#PRODUCT_KEYWORDS[@]})"
                        log_success "Updated $keywords_file"
                    else
                        log_info "No new valid keywords added"
                    fi
                fi
            fi
        else
            log_warn "Failed to load keywords from file, starting fresh"
            PRODUCT_KEYWORDS=()
        fi
    else
        log_info "No keywords file found at: $keywords_file"
        echo ""
        echo "Enter product-specific keywords to redact (comma-separated)."
        echo "Example: CompanyName,ProjectX,SecretProduct,InternalCodename"
        echo ""
        echo -n "Keywords: "
        read keywords_input
        
        if [ -z "$keywords_input" ]; then
            log_warn "No keywords provided, skipping product keyword redaction"
            echo ""
            return
        fi
        
        # Convert comma-separated to array
        IFS=',' read -ra PRODUCT_KEYWORDS <<< "$keywords_input"

        # Validate and trim whitespace from each keyword
        local validated_keywords=()
        for keyword in "${PRODUCT_KEYWORDS[@]}"; do
            keyword=$(echo "$keyword" | xargs)
            if [ -n "$keyword" ]; then
                # Validate keyword (no dangerous characters)
                if [[ "$keyword" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    validated_keywords+=("$keyword")
                else
                    log_warn "Skipping invalid keyword (only alphanumeric, underscore, hyphen allowed): '$keyword'"
                fi
            fi
        done

        PRODUCT_KEYWORDS=("${validated_keywords[@]}")

        if [ ${#PRODUCT_KEYWORDS[@]} -eq 0 ]; then
            log_error "No valid keywords provided"
            return
        fi
        
        # Save keywords to file
        save_keywords_to_json "$keywords_file" "${PRODUCT_KEYWORDS[@]}"
        log_success "Saved keywords to $keywords_file"
    fi
    
    if [ ${#PRODUCT_KEYWORDS[@]} -gt 0 ]; then
        log_success "Will redact ${#PRODUCT_KEYWORDS[@]} product keywords"
    fi
    echo ""
}

# Define sensitive data patterns
declare -A PATTERNS=(
    # IP addresses (IPv4) - exclude private ranges that might be legitimate
    ["ipv4"]='([0-9]{1,3}\.){3}[0-9]{1,3}'
    
    # Email addresses
    ["email"]='[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
    
    # AWS Access Keys
    ["aws_access_key"]='AKIA[0-9A-Z]{16}'
    
    # AWS Secret Keys (pattern)
    ["aws_secret"]='aws_secret_access_key[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+=]{40}'
    
    # Generic API Keys
    ["api_key"]='api[_-]?key[[:space:]]*[:=][[:space:]]*["\047]?[A-Za-z0-9_\-]{20,}["\047]?'
    
    # Passwords in configs (avoid common false positives)
    ["password"]='(password|passwd|pwd)[[:space:]]*[:=][[:space:]]*["\047]?[^"\047[:space:]]{6,}["\047]?'
    
    # JWT tokens (simplified)
    ["jwt"]='eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*'
    
    # Private keys
    ["private_key"]='-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----'
    
    # Kubernetes secrets (base64 encoded values in YAML)
    ["k8s_secret"]='(data|stringData):[[:space:]]*\n[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]+[A-Za-z0-9+/=]{20,}'
    
    # Database connection strings
    ["db_connection"]='(mysql|postgresql|mongodb|redis)://[^[:space:]"'\'']*'
    
    # URLs with credentials
    ["url_with_creds"]='https?://[^:]+:[^@]+@[^[:space:]"'\'']*'
    
    # Common hostname patterns (only suspicious ones)
    ["hostname"]='[a-z0-9-]+\.(internal|local|corp|lan|private|company\.local|dev\.local)'
)

# Create backup of original file
backup_file() {
    local file="$1"
    local target_dir="$2"
    local backup_dir="${target_dir}/${BACKUP_DIR}"
    
    if [ "$DRY_RUN" = true ]; then
        return
    fi
    
    # Get relative path from target_dir
    local rel_path="${file#$target_dir/}"
    local backup_file="${backup_dir}/${rel_path}"
    local backup_file_dir=$(dirname "$backup_file")
    
    # Create backup directory structure
    mkdir -p "$backup_file_dir"
    
    # Copy original file
    cp "$file" "$backup_file"
}

# Check if file should be processed
should_process_file() {
    local file="$1"
    
    # Disable exit on error for this function
    set +e
    
    # Skip if in backup directory
    if [[ "$file" == *"${BACKUP_DIR}"* ]]; then
        set -e
        return 1
    fi
    
    # Skip redacted.json itself
    if [[ "$file" == *"${REDACTED_JSON}" ]]; then
        set -e
        return 1
    fi
    
    # Skip keywords.json itself
    if [[ "$file" == *"${KEYWORDS_JSON}" ]]; then
        set -e
        return 1
    fi
    
    # Skip .git directory
    if [[ "$file" == *"/.git/"* ]]; then
        set -e
        return 1
    fi
    
    # Skip node_modules
    if [[ "$file" == *"/node_modules/"* ]]; then
        set -e
        return 1
    fi
    
    # Skip binary files (but be more lenient - only skip obvious binaries)
    if command -v file &> /dev/null; then
        local file_type=""
        file_type=$(file "$file" 2>/dev/null || echo "")
        if [ -n "$file_type" ]; then
            # Only skip truly binary files, not text files
            if echo "$file_type" | grep -qE 'executable.*binary|compiled|ELF|PE32|Mach-O|Java class|image data|audio|video|ISO|tar archive|gzip|bzip2|zip archive|RPM|deb package|PDF document|Microsoft.*document|SQLite|database' 2>/dev/null; then
                return 1
            fi
        fi
    else
        # Fallback: check file extension for common binary types
        local filename="${file##*/}"
        local extension="${filename##*.}"
        case "${extension,,}" in
            exe|dll|so|dylib|bin|deb|rpm|msi|dmg|pkg|app|jar|war|ear|pdf|doc|docx|xls|xlsx|ppt|pptx|zip|tar|gz|bz2|tgz|tbz2|7z|rar|iso|img|sqlite|db)
                return 1
                ;;
        esac
    fi
    
    # Skip very large files (> 10MB)
    local size=0
    if command -v stat &> /dev/null; then
        # Try macOS format first
        size=$(stat -f%z "$file" 2>/dev/null || echo "")
        if [ -z "$size" ]; then
            # Try Linux format
            size=$(stat -c%s "$file" 2>/dev/null || echo "0")
        fi
    else
        # Fallback: use wc -c (slower but more portable)
        size=$(wc -c < "$file" 2>/dev/null || echo "0")
    fi

    # Ensure size is numeric
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        size=0
    fi

    if [ "$size" -gt 10485760 ]; then
        log_warn "Skipping large file (>10MB): $file"
        return 1
    fi
    
    # Re-enable exit on error
    set -e
    return 0
}

# Redact file content
redact_file() {
    local file="$1"
    local json_file="$2"
    local redaction_count=0
    
    # Disable exit on error for this function
    set +e
    
    # In dry-run mode, work with original file directly
    if [ "$DRY_RUN" = true ]; then
        local temp_file="$file"
    else
        # Create temporary file for modifications (safer than hardcoded name)
        local temp_file=""
        if command -v mktemp &> /dev/null; then
            temp_file=$(mktemp "${file}.scrubber.XXXXXX")
        else
            # Fallback: use timestamp-based name
            temp_file="${file}.scrubber.${timestamp:-$$}.tmp"
        fi
        cp "$file" "$temp_file"

        # Ensure cleanup on exit
        trap "rm -f '$temp_file'" EXIT
    fi
    
    # Redact product keywords (case-insensitive, matches anywhere including adjacent to other chars)
    if [ ${#PRODUCT_KEYWORDS[@]} -gt 0 ]; then
        for keyword in "${PRODUCT_KEYWORDS[@]}"; do
            if [ -z "$keyword" ]; then
                continue
            fi

            # Check if keyword exists in file (case-insensitive, simple substring match)
            # Use grep -i without word boundaries to match keyword anywhere
            if grep -qi "$keyword" "$temp_file" 2>/dev/null; then
                # Find all case variations of the keyword in the file
                # Use grep -io to extract the keyword as it appears (preserving case)
                local matches=$(grep -io "$keyword" "$temp_file" 2>/dev/null | sort -u || true)

                if [ -n "$matches" ]; then
                    while IFS= read -r match; do
                        if [ -n "$match" ]; then
                            local redaction_id=$(generate_redaction_id)

                            if [ "$DRY_RUN" = true ]; then
                                # Count occurrences for dry-run display
                                local occurrences=$(grep -o "$match" "$temp_file" 2>/dev/null | wc -l | xargs || echo "0")
                                # Ensure it's numeric
                                if ! [[ "$occurrences" =~ ^[0-9]+$ ]]; then
                                    occurrences=1
                                fi
                                log_dry_run "  Would redact (product_keyword): '$match' ($occurrences occurrence(s)) -> [${redaction_id}]"
                            else
                                add_to_redaction_map "$json_file" "${redaction_id}" "$match" "product_keyword"

                                # Perform replacement (case-sensitive for exact match)
                                local escaped_match=$(escape_for_sed "$match")
                                sed -i "s/${escaped_match}/[${redaction_id}]/g" "$temp_file" 2>/dev/null || \
                                    sed -i "" "s/${escaped_match}/[${redaction_id}]/g" "$temp_file"
                            fi

                            ((redaction_count++))
                        fi
                    done <<< "$matches"
                fi
            fi
        done
    fi

    # Redact standard patterns (ALWAYS processed, regardless of keywords)
    for pattern_name in "${!PATTERNS[@]}"; do
        local pattern="${PATTERNS[$pattern_name]}"

        # Check if pattern exists in file
        # Use || true to prevent grep from causing script exit on no match
        if grep -qE "$pattern" "$temp_file" 2>/dev/null; then
            # Extract all matches
            local matches=$(grep -oE "$pattern" "$temp_file" 2>/dev/null | sort -u || true)
            
            while IFS= read -r match; do
                if [ -n "$match" ]; then
                    local redaction_id=$(generate_redaction_id)
                    
                    if [ "$DRY_RUN" = true ]; then
                        # Truncate long matches for display
                        local display_match="$match"
                        if [ ${#display_match} -gt 60 ]; then
                            display_match="${display_match:0:57}..."
                        fi
                        log_dry_run "  Would redact ($pattern_name): '$display_match' -> [$redaction_id]"
                    else
                        add_to_redaction_map "$json_file" "$redaction_id" "$match" "$pattern_name"
                        
                        # Perform replacement
                        local escaped_match=$(escape_for_sed "$match")
                        sed -i "s/${escaped_match}/[${redaction_id}]/g" "$temp_file" 2>/dev/null || \
                            sed -i "" "s/${escaped_match}/[${redaction_id}]/g" "$temp_file"
                    fi
                    
                    ((redaction_count++))
                fi
            done <<< "$matches"
        fi
    done
    
    # If redactions were made, replace original file (unless dry-run)
    if [ $redaction_count -gt 0 ]; then
        if [ "$DRY_RUN" = false ]; then
            mv "$temp_file" "$file"
        fi
        echo "$redaction_count"
    else
        if [ "$DRY_RUN" = false ]; then
            rm "$temp_file"
        fi
        echo "0"
    fi
    
    # Re-enable exit on error
    set -e
}

# Redact directory
redact_directory() {
    local target_dir="$1"
    
    if [ ! -d "$target_dir" ]; then
        log_error "Directory not found: $target_dir"
        exit 1
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_header "Sensitive Data Redaction (DRY-RUN MODE)"
        log_warn "DRY-RUN MODE: No files will be modified"
    else
        log_header "Sensitive Data Redaction"
    fi
    log_info "Target directory: $target_dir"
    
    # Get product keywords
    get_product_keywords "$target_dir"
    
    # Initialize redaction map
    local json_file="${target_dir}/${REDACTED_JSON}"
    init_redaction_map "$target_dir"
    
    # Create backup directory (skip in dry-run)
    if [ "$DRY_RUN" = false ]; then
        local backup_dir="${target_dir}/${BACKUP_DIR}"
        mkdir -p "$backup_dir"
        log_success "Created backup directory: $backup_dir"
        echo ""
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_header "Scanning Files (Preview Only)"
    else
        log_header "Scanning and Redacting Files"
    fi
    
    # Count total files first
    local file_count=$(find "$target_dir" -type f 2>/dev/null | wc -l | xargs)
    log_info "Found $file_count files in directory"
    
    if [ "$file_count" -eq 0 ]; then
        log_error "No files found in directory!"
        exit 1
    fi
    
    echo ""
    
    local total_files=0
    local processed_files=0
    local total_redactions=0
    
    # Find all files
    log_info "Starting file scan..."

    if [ "$DRY_RUN" = true ]; then
        log_info "NOTE: Showing all files being checked..."
    fi

    echo ""

    # Get all files into an array (simpler and more reliable)
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(if command -v timeout &> /dev/null; then timeout 300 find "$target_dir" -type f -print0 2>/dev/null; else find "$target_dir" -type f -print0 2>/dev/null; fi)

    local total_found=${#files[@]}
    if [ "$DEBUG" = true ]; then
        log_info "DEBUG: Array contains $total_found files"
    fi

    # Process each file
    for file in "${files[@]}"; do
        ((total_files++))

        if [ "$DEBUG" = true ]; then
            log_info "DEBUG: File #$total_files: ${file#$target_dir/}"
        fi

        # Debug output to see we're actually processing
        if [ "$DRY_RUN" = true ] && [ $((total_files % 5)) -eq 0 ]; then
            echo -n "."  # Progress indicator every 5 files
        fi

        local should_process=0
        if should_process_file "$file"; then
            should_process=1
        fi

        if [ $should_process -eq 0 ]; then
            if [ "$DRY_RUN" = true ] || [ "$DEBUG" = true ]; then
                log_info "Skipping: ${file#$target_dir/} (binary, backup, or excluded)"
            fi
            continue
        fi

        log_info "Processing: ${file#$target_dir/}"

        # Backup original
        backup_file "$file" "$target_dir"

        # Redact file
        local count=$(redact_file "$file" "$json_file")

        if [ "$count" -gt 0 ]; then
            if [ "$DRY_RUN" = true ]; then
                log_success "  Found $count items to redact"
            else
                log_success "  Redacted $count items"
            fi
            ((processed_files++))
            ((total_redactions += count))
        else
            if [ "$DRY_RUN" = true ]; then
                log_info "  No sensitive data found"
            fi
        fi
    done
    
    echo ""  # Newline after progress dots
    
    if [ "$DRY_RUN" = true ]; then
        log_header "Dry-Run Summary"
        log_success "Total files scanned: $total_files"
        log_success "Files that would be modified: $processed_files"
        log_success "Total items that would be redacted: $total_redactions"
        echo ""
        log_info "No files were actually modified (dry-run mode)"
        log_info "Run without --dry-run to perform actual redaction"
    else
        log_header "Redaction Complete"
        log_success "Total files scanned: $total_files"
        log_success "Files modified: $processed_files"
        log_success "Total redactions: $total_redactions"
        echo ""
        log_info "Redaction map saved to: $json_file"
        log_info "Original files backed up to: ${target_dir}/${BACKUP_DIR}"
        echo ""
        log_warn "IMPORTANT: Keep redacted.json secure - it contains all original sensitive data!"
    fi
}

# Unredact file content
unredact_file() {
    local file="$1"
    local redactions="$2"
    local unredaction_count=0
    
    # Disable exit on error for this function
    set +e
    
    # In dry-run mode, work with original file directly
    if [ "$DRY_RUN" = true ]; then
        local temp_file="$file"
    else
        # Create temporary file for modifications
        local temp_file="${file}.unscrubber.tmp"
        cp "$file" "$temp_file"
    fi
    
    # Iterate through all redaction IDs in the file
    # Only match our specific format: [REDACTED_ID_timestamp_random...]
    local redaction_ids=$(grep -oE '\[REDACTED_ID_[0-9]{10}_[0-9]+[^]]*\]' "$temp_file" 2>/dev/null | sort -u || true)
    
    while IFS= read -r redacted_marker; do
        if [ -z "$redacted_marker" ]; then
            continue
        fi
        
        # Extract ID from marker (remove brackets)
        local redaction_id="${redacted_marker:1:-1}"
        
        # Get original value from JSON
        local original_value=$(echo "$redactions" | jq -r ".\"$redaction_id\".original // empty")
        
        if [ -n "$original_value" ]; then
            if [ "$DRY_RUN" = true ]; then
                # Truncate long values for display
                local display_value="$original_value"
                if [ ${#display_value} -gt 60 ]; then
                    display_value="${display_value:0:57}..."
                fi
                log_dry_run "  Would restore: '$redacted_marker' -> '$display_value'"
            else
                # Perform replacement
                local escaped_marker=$(escape_for_sed "$redacted_marker")
                local escaped_original=$(escape_for_sed "$original_value")
                
                    sed -i "s/${escaped_marker}/${escaped_original}/g" "$temp_file" 2>/dev/null || \
                        sed -i "" "s/${escaped_marker}/${escaped_original}/g" "$temp_file"
            fi
            
            ((unredaction_count++))
        else
            log_warn "  No mapping found for: $redaction_id"
        fi
    done <<< "$redaction_ids"
    
    # If unredactions were made, replace file (unless dry-run)
    if [ $unredaction_count -gt 0 ]; then
        if [ "$DRY_RUN" = false ]; then
            mv "$temp_file" "$file"
        fi
        echo "$unredaction_count"
    else
        if [ "$DRY_RUN" = false ]; then
            rm "$temp_file"
        fi
        echo "0"
    fi
    
    # Re-enable exit on error
    set -e
}

# Unredact directory
unredact_directory() {
    local target_dir="$1"
    
    if [ ! -d "$target_dir" ]; then
        log_error "Directory not found: $target_dir"
        exit 1
    fi
    
    local json_file="${target_dir}/${REDACTED_JSON}"
    
    if [ ! -f "$json_file" ]; then
        log_error "Redaction map not found: $json_file"
        log_error "Cannot unredact without the mapping file"
        exit 1
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_header "Restoring Original Data (DRY-RUN MODE)"
        log_warn "DRY-RUN MODE: No files will be modified"
    else
        log_header "Restoring Original Data"
    fi
    log_info "Target directory: $target_dir"
    log_info "Using redaction map: $json_file"
    echo ""
    
    # Load redactions from JSON
    local redactions=$(jq -r '.redactions' "$json_file")
    local total_mappings=$(jq -r '.metadata.total_redactions' "$json_file")
    
    log_info "Loaded $total_mappings redaction mappings"
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        log_header "Processing Files (Preview Only)"
    else
        log_header "Restoring Files"
    fi
    
    # Count total files first
    local file_count=$(find "$target_dir" -type f 2>/dev/null | wc -l | xargs)
    log_info "Found $file_count files in directory"
    echo ""
    
    local total_files=0
    local processed_files=0
    local total_unredactions=0
    
    # Find all files with redaction markers
    while IFS= read -r -d '' file; do
        if ! should_process_file "$file"; then
            if [ "$DRY_RUN" = true ]; then
                if grep -q '\[REDACTED_ID_' "$file" 2>/dev/null; then
                    log_info "Skipping: ${file#$target_dir/} (binary, backup, or excluded)"
                fi
            fi
            continue
        fi
        
        # Check if file contains redaction markers
        if grep -q '\[REDACTED_ID_' "$file" 2>/dev/null; then
            ((total_files++))
            
            log_info "Processing: ${file#$target_dir/}"
            
            # Unredact file
            local count=$(unredact_file "$file" "$redactions")
            
            if [ "$count" -gt 0 ]; then
                if [ "$DRY_RUN" = true ]; then
                    log_success "  Found $count items to restore"
                else
                    log_success "  Restored $count items"
                fi
                ((processed_files++))
                ((total_unredactions += count))
            else
                if [ "$DRY_RUN" = true ]; then
                    log_info "  No redaction markers found"
                fi
            fi
        fi
        
    done < <(if command -v timeout &> /dev/null; then timeout 300 find "$target_dir" -type f -print0 2>/dev/null; else find "$target_dir" -type f -print0 2>/dev/null; fi)
    
    if [ "$DRY_RUN" = true ]; then
        log_header "Dry-Run Summary"
        log_success "Total files that would be processed: $processed_files"
        log_success "Total items that would be restored: $total_unredactions"
        echo ""
        log_info "No files were actually modified (dry-run mode)"
        log_info "Run without --dry-run to perform actual restoration"
    else
        log_header "Restoration Complete"
        log_success "Total files processed: $processed_files"
        log_success "Total items restored: $total_unredactions"
        echo ""
        log_info "Original files have been restored"
        log_warn "The .scrubber_backup directory still contains backups if needed"
    fi
}

# Main function
main() {
    if [ $# -lt 2 ]; then
        usage
    fi
    
    local command="$1"
    local target_dir="$2"
    
    # Parse optional flags
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Validate and convert to absolute path
    if [ ! -d "$target_dir" ]; then
        log_error "Directory does not exist: $target_dir"
        exit 1
    fi

    if [ ! -r "$target_dir" ]; then
        log_error "Directory is not readable: $target_dir"
        exit 1
    fi

    target_dir=$(cd "$target_dir" && pwd)

    check_prerequisites
    
    case "$command" in
        redact)
            redact_directory "$target_dir"
            ;;
        unredact)
            unredact_directory "$target_dir"
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            ;;
    esac
}

# Run main function
main "$@"

