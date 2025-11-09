#!/usr/bin/env bash
#
# CloudWatch Logs Usage Analysis & Cost Projection Tool
# 
# Usage: chmod +x cw_status_projection.sh && ./cw_status_projection.sh
# Optional env: 
#   AWS_REGION (defaults to us-west-2)
#   WINDOW_DAYS (defaults to 7)
#   DETAILED (set to 1 for full log group list)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

: "${AWS_REGION:=${AWS_DEFAULT_REGION:-us-west-2}}"
: "${WINDOW_DAYS:=7}"
: "${DETAILED:=0}"

# CloudWatch Logs pricing (us-east-1, adjust for your region)
# https://aws.amazon.com/cloudwatch/pricing/
INGEST_PRICE_PER_GB=0.50      # Data ingestion
STORAGE_PRICE_PER_GB=0.03     # Data storage (per GB/month)
FREE_TIER_INGEST_GB=5.0       # Free tier ingestion
FREE_TIER_STORAGE_GB=5.0      # Free tier storage

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

log_header() {
    echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}$1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_section() {
    echo -e "\n${BOLD}${GREEN}▶ $1${NC}"
    echo -e "${GREEN}$([[ -n "${2:-}" ]] && echo "$2" || echo "")${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

log_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

# Check for required commands
check_requirements() {
    command -v aws >/dev/null 2>&1 || { log_error "Missing aws CLI."; exit 1; }
    command -v bc >/dev/null 2>&1 || { log_warn "Missing bc command. Install for better calculations."; }
}

# Date handling (macOS vs Linux)
get_date_cmd() {
    if command -v gdate >/dev/null 2>&1; then
        echo "gdate"
    else
        echo "date"
    fi
}

# ============================================================================
# Data Collection
# ============================================================================

collect_log_groups() {
    local tmp_file="$1"
    local datebin=$(get_date_cmd)
    
    # Calculate time window
    if "$datebin" -u -d "now" +%Y >/dev/null 2>&1; then
        START=$("$datebin" -u -d "${WINDOW_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
        END=$("$datebin" -u +%Y-%m-%dT%H:%M:%SZ)
    else
        START=$("$datebin" -u -v-"${WINDOW_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
        END=$("$datebin" -u +%Y-%m-%dT%H:%M:%SZ)
    fi
    
    export START END
    
    log_info "Collecting log groups from $AWS_REGION..."
    log_info "Time window: $START to $END (${WINDOW_DAYS} days)"
    
    # Paginate through all log groups
    local token=""
    local count=0
    
    while : ; do
        local cmd_args=(--region "$AWS_REGION")
        [[ -n "${token}" ]] && cmd_args+=(--next-token "$token")
        
        # Use AWS CLI query to extract fields reliably
        local result=$(aws logs describe-log-groups "${cmd_args[@]}" \
            --query 'logGroups[].[logGroupName,retentionInDays,storedBytes]' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$result" ]]; then
            # Convert AWS CLI tab-separated output to our format
            # Note: retentionInDays shows as "None" if not set
            echo "$result" | while read -r name ret sb; do
                [[ "$ret" == "None" ]] && ret="-"
                printf "%s\t%s\t%s\n" "$name" "$ret" "$sb"
            done >> "$tmp_file"
        fi
        
        # Check for next page token
        token=$(aws logs describe-log-groups "${cmd_args[@]}" \
            --query 'nextToken' --output text 2>/dev/null || echo "None")
        [[ "$token" == "None" || -z "$token" ]] && break
        
        count=$((count + 1))
    done
    
    local total=$(wc -l < "$tmp_file" | tr -d ' ')
    log_info "Found $total log groups"
}

# Get ingestion metrics for a log group (window period)
get_ingestion_metrics() {
    local log_group="$1"
    
    aws cloudwatch get-metric-statistics \
        --region "$AWS_REGION" \
        --namespace AWS/Logs \
        --metric-name IncomingBytes \
        --dimensions Name=LogGroupName,Value="$log_group" \
        --start-time "$START" --end-time "$END" \
        --period 3600 --statistics Sum \
        --query 'Datapoints[].Sum' --output text 2>/dev/null \
        | awk '{s+=$1} END{printf "%.0f", s+0}'
}

# Get 30-day historical daily metrics
get_historical_daily_metrics() {
    local datebin=$(get_date_cmd)
    local trends_file="$1"
    
    log_info "Collecting 30-day historical daily metrics..."
    
    # Calculate 30 days ago
    if "$datebin" -u -d "now" +%Y >/dev/null 2>&1; then
        HIST_START=$("$datebin" -u -d "30 days ago" +%Y-%m-%dT00:00:00Z)
    else
        HIST_START=$("$datebin" -u -v-30d +%Y-%m-%dT00:00:00Z)
    fi
    
    # Get daily totals across ALL log groups
    # Using 86400 second period (1 day) for daily granularity
    for day in $(seq 29 -1 0); do
        if "$datebin" -u -d "now" +%Y >/dev/null 2>&1; then
            day_start=$("$datebin" -u -d "$day days ago" +%Y-%m-%dT00:00:00Z)
            day_end=$("$datebin" -u -d "$day days ago" +%Y-%m-%dT23:59:59Z)
            day_label=$("$datebin" -u -d "$day days ago" +%Y-%m-%d)
        else
            day_start=$("$datebin" -u -v-"${day}"d +%Y-%m-%dT00:00:00Z)
            day_end=$("$datebin" -u -v-"${day}"d +%Y-%m-%dT23:59:59Z)
            day_label=$("$datebin" -u -v-"${day}"d +%Y-%m-%d)
        fi
        
        # Sum across all log groups for this day
        local daily_total=0
        
        # This would be slow to query each log group individually
        # Instead, we'll collect per-log-group daily data in analyze phase
        printf "%s\t%s\n" "$day_label" "$day_start" >> "$trends_file"
    done
    
    log_info "Historical data collection prepared"
}

# Get daily metrics for a specific log group over 30 days
get_log_group_daily_history() {
    local log_group="$1"
    local datebin=$(get_date_cmd)
    
    # Calculate 30 days ago
    if "$datebin" -u -d "now" +%Y >/dev/null 2>&1; then
        hist_start=$("$datebin" -u -d "30 days ago" +%Y-%m-%dT00:00:00Z)
        hist_end=$("$datebin" -u +%Y-%m-%dT23:59:59Z)
    else
        hist_start=$("$datebin" -u -v-30d +%Y-%m-%dT00:00:00Z)
        hist_end=$("$datebin" -u +%Y-%m-%dT23:59:59Z)
    fi
    
    # Get daily data (86400 seconds = 1 day)
    aws cloudwatch get-metric-statistics \
        --region "$AWS_REGION" \
        --namespace AWS/Logs \
        --metric-name IncomingBytes \
        --dimensions Name=LogGroupName,Value="$log_group" \
        --start-time "$hist_start" --end-time "$hist_end" \
        --period 86400 --statistics Sum \
        --query 'Datapoints[].[Timestamp,Sum]' --output text 2>/dev/null \
        | sort -k1
}

# Classify log group by service type
classify_log_group() {
    local lg="$1"
    
    case "$lg" in
        /aws/lambda/*) echo "LAMBDA" ;;
        /aws/apigateway/*|/aws/apigw/*) echo "APIGW" ;;
        /aws/eks/*) echo "EKS" ;;
        /aws/rds/*) echo "RDS" ;;
        /aws/ecs/*) echo "ECS" ;;
        /aws/batch/*) echo "BATCH" ;;
        /aws/codebuild/*) echo "CODEBUILD" ;;
        /aws/elasticbeanstalk/*) echo "BEANSTALK" ;;
        /aws/states/*) echo "STEPFUNC" ;;
        *vpc*|*flowlog*|*flow-log*) echo "VPC" ;;
        *) echo "OTHER" ;;
    esac
}

# ============================================================================
# Analysis Functions
# ============================================================================

analyze_log_groups() {
    local data_file="$1"
    local analysis_file="$2"
    
    log_info "Analyzing log group metrics..."
    
    local total=0
    local current=0
    total=$(wc -l < "$data_file" | tr -d ' ')
    
    while IFS=$'\t' read -r rawname retention storedbytes; do
        current=$((current + 1))
        
        # Progress indicator
        if (( current % 10 == 0 )) || (( current == total )); then
            printf "\r  Progress: %d/%d log groups analyzed..." "$current" "$total" >&2
        fi
        
        # Clean up name
        lg=$(printf "%s" "$rawname" | sed 's#\\/#/#g')
        
        # Calculate storage
        stored_gb=$(awk -v b="${storedbytes:-0}" 'BEGIN{printf "%.6f", b/1024/1024/1024}')
        
        # Get ingestion metrics
        win_bytes=$(get_ingestion_metrics "$lg")
        win_gb=$(awk -v b="$win_bytes" 'BEGIN{printf "%.6f", b/1024/1024/1024}')
        
        # Project 30-day usage
        proj_gb=$(awk -v b="$win_bytes" -v d="$WINDOW_DAYS" 'BEGIN{
            if (d<1) d=1;
            daily=b/d;
            proj=daily*30/1024/1024/1024;
            printf "%.6f", proj
        }')
        
        # Classify
        svc_type=$(classify_log_group "$lg")
        
        # Output: type, name, retention, stored_gb, win_gb, proj_gb
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$svc_type" "$lg" "${retention:--}" "$stored_gb" "$win_gb" "$proj_gb" >> "$analysis_file"
        
    done < "$data_file"
    
    echo "" >&2  # New line after progress
    log_info "Analysis complete"
}

# Collect 30-day aggregate daily metrics
collect_daily_trends() {
    local data_file="$1"
    local trends_file="$2"
    local datebin=$(get_date_cmd)
    
    log_info "Collecting 30-day historical trends..."
    
    # Calculate time range - get 30 days including today
    if "$datebin" -u -d "now" +%Y >/dev/null 2>&1; then
        # GNU date (Linux)
        hist_start=$("$datebin" -u -d "30 days ago" +%Y-%m-%dT00:00:00Z)
        hist_end=$("$datebin" -u +%Y-%m-%dT23:59:59Z)
    else
        # BSD date (macOS)
        hist_start=$("$datebin" -u -v-30d +%Y-%m-%dT00:00:00Z)
        hist_end=$("$datebin" -u +%Y-%m-%dT23:59:59Z)
    fi
    
    log_info "Querying from $hist_start to $hist_end"
    
    # Get all log groups
    local log_groups=$(awk -F'\t' '{print $1}' "$data_file")
    
    # Create temp file for raw daily data
    local raw_daily=$(mktemp)
    trap 'rm -f "${raw_daily:-}"' RETURN
    
    local lg_count=0
    local total_lgs=$(echo "$log_groups" | wc -l | tr -d ' ')
    
    # Collect daily data for each log group
    while read -r lg; do
        lg_count=$((lg_count + 1))
        printf "\r  Progress: %d/%d log groups processed..." "$lg_count" "$total_lgs" >&2
        
        # Get daily metrics for this log group
        aws cloudwatch get-metric-statistics \
            --region "$AWS_REGION" \
            --namespace AWS/Logs \
            --metric-name IncomingBytes \
            --dimensions Name=LogGroupName,Value="$lg" \
            --start-time "$hist_start" --end-time "$hist_end" \
            --period 86400 --statistics Sum \
            --query 'Datapoints[].[Timestamp,Sum]' --output text 2>/dev/null | \
        while read -r timestamp bytes; do
            if [[ -n "$timestamp" && -n "$bytes" ]]; then
                # Extract just the date part (YYYY-MM-DD)
                local date_only=$(echo "$timestamp" | cut -d'T' -f1)
                printf "%s\t%s\n" "$date_only" "$bytes"
            fi
        done >> "$raw_daily"
    done <<< "$log_groups"
    
    echo "" >&2
    
    # Aggregate by date using awk (works in all bash versions)
    local aggregated=$(mktemp)
    trap 'rm -f "${aggregated:-}"' RETURN
    
    if [[ -s "$raw_daily" ]]; then
        awk -F'\t' '
        {
            date = $1;
            bytes = $2;
            daily[date] += bytes;
        }
        END {
            for (date in daily) {
                gb = daily[date] / 1024 / 1024 / 1024;
                printf "%s\t%.6f\n", date, gb;
            }
        }
        ' "$raw_daily" | sort -k1 > "$aggregated"
    fi
    
    # Fill in missing days with 0.000 to show complete 30-day timeline
    for day in $(seq 29 -1 0); do
        if "$datebin" -u -d "now" +%Y >/dev/null 2>&1; then
            day_date=$("$datebin" -u -d "$day days ago" +%Y-%m-%d)
        else
            day_date=$("$datebin" -u -v-"${day}"d +%Y-%m-%d)
        fi
        
        # Check if this date exists in aggregated data
        if [[ -s "$aggregated" ]] && grep -q "^${day_date}" "$aggregated"; then
            grep "^${day_date}" "$aggregated"
        else
            printf "%s\t0.000000\n" "$day_date"
        fi
    done > "$trends_file"
    
    log_info "Historical trends collected (30 days)"
}

# ============================================================================
# Reporting Functions
# ============================================================================

print_executive_summary() {
    local analysis_file="$1"
    
    log_header "📊 CloudWatch Logs Analysis - Executive Summary"
    
    echo ""
    printf "%-25s: %s\n" "Region" "$AWS_REGION"
    printf "%-25s: %s days\n" "Analysis Window" "$WINDOW_DAYS"
    printf "%-25s: %s\n" "Period" "$START to $END"
    
    # Calculate totals
    local total_groups=$(wc -l < "$analysis_file" | tr -d ' ')
    local total_stored=$(awk -F'\t' '{sum+=$4} END{printf "%.3f", sum}' "$analysis_file")
    local total_ingested=$(awk -F'\t' '{sum+=$5} END{printf "%.3f", sum}' "$analysis_file")
    local total_proj=$(awk -F'\t' '{sum+=$6} END{printf "%.3f", sum}' "$analysis_file")
    
    # Cost calculations
    local storage_cost=$(awk -v s="$total_stored" -v p="$STORAGE_PRICE_PER_GB" -v f="$FREE_TIER_STORAGE_GB" \
        'BEGIN{billable=s-f; if(billable<0)billable=0; printf "%.2f", billable*p}')
    
    local ingest_cost=$(awk -v s="$total_proj" -v p="$INGEST_PRICE_PER_GB" -v f="$FREE_TIER_INGEST_GB" \
        'BEGIN{billable=s-f; if(billable<0)billable=0; printf "%.2f", billable*p}')
    
    local total_monthly_cost=$(awk -v a="$storage_cost" -v b="$ingest_cost" 'BEGIN{printf "%.2f", a+b}')
    local yearly_cost=$(awk -v m="$total_monthly_cost" 'BEGIN{printf "%.2f", m*12}')
    
    echo ""
    log_section "📈 Usage Metrics"
    printf "  %-35s: %6d\n" "Total Log Groups" "$total_groups"
    printf "  %-35s: %10.2f GB\n" "Currently Stored" "$total_stored"
    printf "  %-35s: %10.2f GB\n" "Ingested (${WINDOW_DAYS}d window)" "$total_ingested"
    printf "  %-35s: %10.2f GB\n" "Projected 30-day Ingestion" "$total_proj"
    
    echo ""
    log_section "💰 Cost Projections (Monthly)"
    printf "  %-35s: \$%9.2f\n" "Storage Cost" "$storage_cost"
    printf "  %-35s: \$%9.2f\n" "Ingestion Cost" "$ingest_cost"
    printf "  ${BOLD}%-35s: \$%9.2f${NC}\n" "Total Monthly Cost" "$total_monthly_cost"
    printf "  %-35s: \$%9.2f\n" "Projected Yearly Cost" "$yearly_cost"
    
    echo ""
    log_section "🎁 Free Tier Status"
    
    local ingest_over=$(awk -v p="$total_proj" -v f="$FREE_TIER_INGEST_GB" 'BEGIN{d=p-f; printf "%.2f", d}')
    local storage_over=$(awk -v s="$total_stored" -v f="$FREE_TIER_STORAGE_GB" 'BEGIN{d=s-f; printf "%.2f", d}')
    
    printf "  %-35s: %.1f GB\n" "Free Tier Ingestion" "$FREE_TIER_INGEST_GB"
    printf "  %-35s: %.1f GB\n" "Free Tier Storage" "$FREE_TIER_STORAGE_GB"
    
    if (( $(echo "$ingest_over > 0" | bc -l 2>/dev/null || echo 0) )); then
        printf "  ${RED}%-35s: %.2f GB (%.0f%% over)${NC}\n" "Ingestion Over Free Tier" "$ingest_over" \
            $(awk -v o="$ingest_over" -v f="$FREE_TIER_INGEST_GB" 'BEGIN{printf "%.0f", (o/f)*100}')
    else
        printf "  ${GREEN}%-35s: Within free tier${NC}\n" "Ingestion Status"
    fi
    
    if (( $(echo "$storage_over > 0" | bc -l 2>/dev/null || echo 0) )); then
        printf "  ${RED}%-35s: %.2f GB (%.0f%% over)${NC}\n" "Storage Over Free Tier" "$storage_over" \
            $(awk -v o="$storage_over" -v f="$FREE_TIER_STORAGE_GB" 'BEGIN{printf "%.0f", (o/f)*100}')
    else
        printf "  ${GREEN}%-35s: Within free tier${NC}\n" "Storage Status"
    fi
}

print_service_breakdown() {
    local analysis_file="$1"
    
    log_header "📦 Breakdown by Service Type"
    
    echo ""
    printf "%-12s  %8s  %12s  %12s  %12s  %10s\n" \
        "SERVICE" "COUNT" "STORED(GB)" "INGEST(GB)" "PROJ30(GB)" "COST/MONTH"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────"
    
    # Get unique service types
    local services=$(awk -F'\t' '{print $1}' "$analysis_file" | sort -u)
    
    local grand_stored=0 grand_ingest=0 grand_proj=0 grand_cost=0
    
    while read -r svc; do
        local count=$(awk -F'\t' -v s="$svc" '$1==s' "$analysis_file" | wc -l | tr -d ' ')
        local stored=$(awk -F'\t' -v s="$svc" '$1==s {sum+=$4} END{printf "%.3f", sum}' "$analysis_file")
        local ingest=$(awk -F'\t' -v s="$svc" '$1==s {sum+=$5} END{printf "%.3f", sum}' "$analysis_file")
        local proj=$(awk -F'\t' -v s="$svc" '$1==s {sum+=$6} END{printf "%.3f", sum}' "$analysis_file")
        
        # Calculate cost
        local svc_cost=$(awk -v st="$stored" -v ig="$proj" -v sp="$STORAGE_PRICE_PER_GB" -v ip="$INGEST_PRICE_PER_GB" \
            'BEGIN{printf "%.2f", (st*sp)+(ig*ip)}')
        
        printf "%-12s  %8d  %12.2f  %12.2f  %12.2f  $%9.2f\n" \
            "$svc" "$count" "$stored" "$ingest" "$proj" "$svc_cost"
        
        grand_stored=$(awk -v a="$grand_stored" -v b="$stored" 'BEGIN{printf "%.3f", a+b}')
        grand_ingest=$(awk -v a="$grand_ingest" -v b="$ingest" 'BEGIN{printf "%.3f", a+b}')
        grand_proj=$(awk -v a="$grand_proj" -v b="$proj" 'BEGIN{printf "%.3f", a+b}')
        grand_cost=$(awk -v a="$grand_cost" -v b="$svc_cost" 'BEGIN{printf "%.2f", a+b}')
        
    done <<< "$services"
    
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────"
    printf "${BOLD}%-12s  %8s  %12.2f  %12.2f  %12.2f  $%9.2f${NC}\n" \
        "TOTAL" "" "$grand_stored" "$grand_ingest" "$grand_proj" "$grand_cost"
}

print_top_consumers() {
    local analysis_file="$1"
    local n="${2:-10}"
    
    log_header "🔥 Top $n Log Groups by Projected Monthly Ingestion"
    
    echo ""
    printf "%-5s  %-50s  %12s  %10s\n" "RANK" "LOG GROUP" "PROJ30(GB)" "COST/MONTH"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────"
    
    # Sort by projected usage (column 6), descending
    sort -t$'\t' -k6 -rn "$analysis_file" | head -n "$n" | nl -w5 -s'  ' | \
    while read -r rank rest; do
        local svc_type=$(echo "$rest" | awk -F'\t' '{print $1}')
        local lg=$(echo "$rest" | awk -F'\t' '{print $2}')
        local proj=$(echo "$rest" | awk -F'\t' '{print $6}')
        
        # Truncate long names
        if [[ ${#lg} -gt 50 ]]; then
            lg="${lg:0:47}..."
        fi
        
        local cost=$(awk -v p="$proj" -v price="$INGEST_PRICE_PER_GB" 'BEGIN{printf "%.2f", p*price}')
        
        printf "%-5s  %-50s  %12.3f  $%9.2f\n" "$rank" "$lg" "$proj" "$cost"
    done
}

print_retention_analysis() {
    local analysis_file="$1"
    
    log_header "⏰ Retention Policy Analysis"
    
    echo ""
    printf "%-15s  %8s  %12s  %12s\n" "RETENTION" "COUNT" "STORED(GB)" "STORAGE_COST"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────"
    
    # Group by retention
    local retentions=$(awk -F'\t' '{print $3}' "$analysis_file" | sort | uniq)
    
    while read -r ret; do
        local count=$(awk -F'\t' -v r="$ret" '$3==r' "$analysis_file" | wc -l | tr -d ' ')
        local stored=$(awk -F'\t' -v r="$ret" '$3==r {sum+=$4} END{printf "%.3f", sum}' "$analysis_file")
        local cost=$(awk -v s="$stored" -v p="$STORAGE_PRICE_PER_GB" 'BEGIN{printf "%.2f", s*p}')
        
        local ret_display="${ret} days"
        [[ "$ret" == "-" ]] && ret_display="Never Expire"
        
        printf "%-15s  %8d  %12.2f  $%11.2f\n" "$ret_display" "$count" "$stored" "$cost"
    done <<< "$retentions"
    
    # Count groups with no retention
    local no_retention=$(awk -F'\t' '$3=="-"' "$analysis_file" | wc -l | tr -d ' ')
    
    if [[ $no_retention -gt 0 ]]; then
        echo ""
        log_warn "$no_retention log groups have no retention policy (never expire)"
        log_warn "Consider setting retention policies to reduce storage costs"
    fi
}

print_historical_trends() {
    local trends_file="$1"
    
    log_header "📈 30-Day Historical Usage Trend"
    
    # Check if we have data
    if [[ ! -s "$trends_file" ]]; then
        log_warn "No historical data available"
        return
    fi
    
    echo ""
    
    # Calculate statistics
    local total_days=$(wc -l < "$trends_file" | tr -d ' ')
    local max_gb=$(awk -F'\t' 'BEGIN{max=0} {if($2>max)max=$2} END{printf "%.3f", max}' "$trends_file")
    
    # For min, only consider non-zero days
    local min_gb=$(awk -F'\t' 'BEGIN{min=999999} {if($2<min && $2>0)min=$2} END{if(min==999999)min=0; printf "%.3f", min}' "$trends_file")
    
    # Average includes all days (even zeros)
    local avg_gb=$(awk -F'\t' '{sum+=$2; count++} END{if(count>0)printf "%.3f", sum/count; else print "0.000"}' "$trends_file")
    
    # Count days with actual data
    local active_days=$(awk -F'\t' '$2 > 0 {count++} END{print count+0}' "$trends_file")
    
    # Calculate weekly averages
    local week1_avg=$(tail -n 7 "$trends_file" | awk -F'\t' '{sum+=$2} END{printf "%.3f", sum/NR}')
    local week2_avg=$(tail -n 14 "$trends_file" | head -n 7 | awk -F'\t' '{sum+=$2} END{printf "%.3f", sum/NR}')
    local week3_avg=$(tail -n 21 "$trends_file" | head -n 7 | awk -F'\t' '{sum+=$2} END{printf "%.3f", sum/NR}')
    local week4_avg=$(tail -n 28 "$trends_file" | head -n 7 | awk -F'\t' '{sum+=$2} END{printf "%.3f", sum/NR}')
    
    # Determine trend
    local trend="STABLE"
    local trend_pct=0
    if command -v bc >/dev/null 2>&1; then
        trend_pct=$(echo "scale=1; (($week1_avg - $week4_avg) / $week4_avg) * 100" | bc 2>/dev/null || echo "0")
        if (( $(echo "$trend_pct > 10" | bc -l 2>/dev/null || echo 0) )); then
            trend="${RED}INCREASING ▲${NC}"
        elif (( $(echo "$trend_pct < -10" | bc -l 2>/dev/null || echo 0) )); then
            trend="${GREEN}DECREASING ▼${NC}"
        else
            trend="${YELLOW}STABLE ▬${NC}"
        fi
    fi
    
    log_section "📊 Summary Statistics"
    printf "  %-30s: %d days (%d with data)\n" "Data Points" "$total_days" "$active_days"
    printf "  %-30s: %.3f GB/day\n" "Average Daily Ingestion" "$avg_gb"
    printf "  %-30s: %.3f GB/day\n" "Peak Daily Ingestion" "$max_gb"
    printf "  %-30s: %.3f GB/day\n" "Minimum Daily Ingestion" "$min_gb"
    echo ""
    printf "  %-30s: %.3f GB/day (current week)\n" "Week 1 Average" "$week1_avg"
    printf "  %-30s: %.3f GB/day\n" "Week 2 Average" "$week2_avg"
    printf "  %-30s: %.3f GB/day\n" "Week 3 Average" "$week3_avg"
    printf "  %-30s: %.3f GB/day\n" "Week 4 Average" "$week4_avg"
    echo ""
    printf "  ${BOLD}%-30s: " "Trend"
    echo -e "$trend ($trend_pct%)"
    echo -e "${NC}"
    
    # Create ASCII chart
    log_section "📉 Daily Ingestion Chart (GB/day)"
    echo ""
    
    # Calculate scale for chart
    local chart_width=50
    local scale_factor=$(awk -v max="$max_gb" -v width="$chart_width" 'BEGIN{if(max>0)printf "%.6f", width/max; else print "1"}')
    
    # Print chart header
    printf "   %-12s  %8s  %s\n" "DATE" "GB/DAY" "CHART"
    printf "   %s\n" "────────────────────────────────────────────────────────────────────────────────"
    
    # Show ALL days in the data
    while IFS=$'\t' read -r date gb; do
        # Calculate bar length
        local bar_len=$(awk -v gb="$gb" -v scale="$scale_factor" 'BEGIN{printf "%.0f", gb*scale}')
        [[ $bar_len -lt 1 && $(awk -v gb="$gb" 'BEGIN{print (gb>0)}') -eq 1 ]] && bar_len=1
        
        # Create bar
        local bar=$(printf '█%.0s' $(seq 1 $bar_len 2>/dev/null))
        
        # Color code based on value
        local color="$NC"
        if (( $(awk -v gb="$gb" -v avg="$avg_gb" 'BEGIN{print (gb > avg*1.5)}') )); then
            color="$RED"
        elif (( $(awk -v gb="$gb" -v avg="$avg_gb" 'BEGIN{print (gb > avg*1.2)}') )); then
            color="$YELLOW"
        else
            color="$GREEN"
        fi
        
        printf "   %-12s  %8.3f  ${color}%s${NC}\n" "$date" "$gb" "$bar"
    done < "$trends_file"
    
    echo ""
    printf "   Scale: Max = %.3f GB/day  |  Legend: ${GREEN}█ Normal${NC}  ${YELLOW}█ Elevated${NC}  ${RED}█ High${NC}\n" "$max_gb"
    
    # Check for missing recent days
    local latest_date=$(tail -n 1 "$trends_file" | awk -F'\t' '{print $1}')
    local datebin=$(get_date_cmd)
    local today
    if "$datebin" -u -d "now" +%Y >/dev/null 2>&1; then
        today=$("$datebin" -u +%Y-%m-%d)
    else
        today=$("$datebin" -u +%Y-%m-%d)
    fi
    
    if [[ "$latest_date" != "$today" ]]; then
        echo ""
        log_info "Note: CloudWatch metrics may have 1-3 hour delay. Latest data: $latest_date (today: $today)"
    fi
    echo ""
    
    # Anomaly detection
    log_section "🔍 Anomaly Detection"
    
    local anomalies_found=0
    while IFS=$'\t' read -r date gb; do
        # Flag days that are 2x average or more
        if (( $(awk -v gb="$gb" -v avg="$avg_gb" 'BEGIN{print (gb > avg*2)}') )); then
            if [[ $anomalies_found -eq 0 ]]; then
                echo "  Days with unusually high ingestion (>2x average):"
            fi
            anomalies_found=$((anomalies_found + 1))
            local pct=$(awk -v gb="$gb" -v avg="$avg_gb" 'BEGIN{printf "%.0f", ((gb/avg)-1)*100}')
            printf "  ${RED}• %s: %.3f GB (+%s%% above average)${NC}\n" "$date" "$gb" "$pct"
        fi
    done < "$trends_file"
    
    if [[ $anomalies_found -eq 0 ]]; then
        echo -e "  ${GREEN}✓ No unusual spikes detected${NC}"
    else
        echo ""
        log_warn "Investigate these anomalies to identify causes (deployments, traffic spikes, etc.)"
    fi
}

print_optimization_recommendations() {
    local analysis_file="$1"
    
    log_header "💡 Optimization Recommendations"
    
    echo ""
    
    # Check for groups with no retention
    local no_retention=$(awk -F'\t' '$3=="-"' "$analysis_file" | wc -l | tr -d ' ')
    if [[ $no_retention -gt 0 ]]; then
        log_section "1. Set Retention Policies"
        echo "   $no_retention log groups have no retention policy (logs never expire)"
        echo "   Recommendation: Set appropriate retention (e.g., 7, 30, or 90 days)"
        
        local no_ret_storage=$(awk -F'\t' '$3=="-" {sum+=$4} END{printf "%.2f", sum}' "$analysis_file")
        local potential_savings=$(awk -v s="$no_ret_storage" -v p="$STORAGE_PRICE_PER_GB" \
            'BEGIN{printf "%.2f", s*p*0.7}')  # Assume 70% reduction with retention
        
        echo "   Potential monthly savings: \$$potential_savings (with 70% storage reduction)"
    fi
    
    # Check for high-volume low-value logs
    echo ""
    log_section "2. Review High-Volume Log Groups"
    echo "   Consider reducing log verbosity or sampling for:"
    
    sort -t$'\t' -k6 -rn "$analysis_file" | head -n 5 | \
    while IFS=$'\t' read -r svc_type lg retention stored win proj; do
        local lg_short="$lg"
        [[ ${#lg} -gt 60 ]] && lg_short="${lg:0:57}..."
        echo "   • $lg_short (${proj} GB/month projected)"
    done
    
    # Check for VPC Flow Logs
    local vpc_count=$(awk -F'\t' '$1=="VPC"' "$analysis_file" | wc -l | tr -d ' ')
    if [[ $vpc_count -gt 0 ]]; then
        echo ""
        log_section "3. VPC Flow Logs Optimization"
        echo "   Found $vpc_count VPC Flow Log groups"
        
        local vpc_proj=$(awk -F'\t' '$1=="VPC" {sum+=$6} END{printf "%.2f", sum}' "$analysis_file")
        echo "   Projected monthly ingestion: ${vpc_proj} GB"
        echo "   Consider:"
        echo "   • Enable flow logs only for specific subnets"
        echo "   • Use custom format with only required fields"
        echo "   • Set shorter retention periods"
        echo "   • Use S3 instead of CloudWatch for long-term storage"
    fi
    
    # General recommendations
    echo ""
    log_section "4. General Best Practices"
    echo "   • Use CloudWatch Logs Insights for analysis instead of exporting"
    echo "   • Archive old logs to S3 for long-term storage (cheaper)"
    echo "   • Use metric filters to extract KPIs instead of storing full logs"
    echo "   • Consider log sampling for high-volume, low-value logs"
    echo "   • Review lambda function log levels (DEBUG vs INFO vs ERROR)"
    echo "   • Use CloudWatch subscription filters to send logs to S3/Kinesis"
    
    # Cost comparison
    echo ""
    log_section "5. Cost Comparison"
    echo "   CloudWatch Logs: \$$INGEST_PRICE_PER_GB/GB ingestion + \$$STORAGE_PRICE_PER_GB/GB-month storage"
    echo "   S3 Standard:     ~\$0.023/GB-month storage (no ingestion cost)"
    echo "   S3 Glacier:      ~\$0.004/GB-month storage (for archives)"
    echo ""
    echo "   For logs older than 30 days, S3 is typically more cost-effective"
}

print_detailed_log_groups() {
    local analysis_file="$1"
    
    log_header "📋 Detailed Log Group Listing"
    
    echo ""
    printf "%-10s  %-55s  %6s  %10s  %10s  %10s\n" \
        "TYPE" "LOG GROUP" "RET(d)" "STORED(GB)" "INGEST(GB)" "PROJ30(GB)"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    # Sort by projected usage
    sort -t$'\t' -k6 -rn "$analysis_file" | \
    while IFS=$'\t' read -r svc_type lg retention stored win proj; do
        # Truncate long names
        local lg_short="$lg"
        if [[ ${#lg} -gt 55 ]]; then
            lg_short="${lg:0:52}..."
        fi
        
        printf "%-10s  %-55s  %6s  %10.3f  %10.3f  %10.3f\n" \
            "$svc_type" "$lg_short" "$retention" "$stored" "$win" "$proj"
    done
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    check_requirements
    
    # Create temp files
    lg_tmp=$(mktemp)
    analysis_tmp=$(mktemp)
    trends_tmp=$(mktemp)
    trap 'rm -f "${lg_tmp:-}" "${analysis_tmp:-}" "${trends_tmp:-}"' EXIT
    
    # Collect data
    collect_log_groups "$lg_tmp"
    
    # Analyze
    analyze_log_groups "$lg_tmp" "$analysis_tmp"
    
    # Collect 30-day historical trends
    collect_daily_trends "$lg_tmp" "$trends_tmp"
    
    # Generate reports
    print_executive_summary "$analysis_tmp"
    print_historical_trends "$trends_tmp"
    print_service_breakdown "$analysis_tmp"
    print_top_consumers "$analysis_tmp" 10
    print_retention_analysis "$analysis_tmp"
    print_optimization_recommendations "$analysis_tmp"
    
    # Detailed listing (optional)
    if [[ "${DETAILED}" == "1" ]]; then
        print_detailed_log_groups "$analysis_tmp"
    else
        echo ""
        log_info "Run with DETAILED=1 for full log group listing"
    fi
    
    echo ""
    log_header "📄 Analysis Complete"
    echo ""
}

main "$@"

