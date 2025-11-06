#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check required environment variables
if [[ -z "$JIRA_URL" ]]; then
    echo -e "${RED}Error: JIRA_URL environment variable is not set${NC}"
    echo "Please set it using: export JIRA_URL=https://your-domain.atlassian.net"
    exit 1
fi

if [[ -z "$JIRA_PAT" ]]; then
    echo -e "${RED}Error: JIRA_PAT environment variable is not set${NC}"
    echo "Please set it using: export JIRA_PAT=your-personal-access-token"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo "Please install jq using: brew install jq (on macOS)"
    exit 1
fi

# Function to make API calls with retry logic
jira_api() {
    local method=$1
    local endpoint=$2
    local data=$3
    local max_retries=3
    local retry_count=0
    local wait_time=2
    
    while [[ $retry_count -lt $max_retries ]]; do
        local response
        local http_code
        local curl_error
        local temp_error_file=$(mktemp)
        
        if [[ -n "$data" ]]; then
            response=$(curl -k -s -w "\n%{http_code}" -X "$method" \
                -H "Authorization: Bearer ${JIRA_PAT}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -d "$data" \
                "${JIRA_URL}/rest/api/3/${endpoint}" 2>"$temp_error_file")
        else
            response=$(curl -k -s -w "\n%{http_code}" -X "$method" \
                -H "Authorization: Bearer ${JIRA_PAT}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                "${JIRA_URL}/rest/api/3/${endpoint}" 2>"$temp_error_file")
        fi
        
        # Capture curl errors
        curl_error=$(cat "$temp_error_file")
        rm -f "$temp_error_file"
        
        # Extract HTTP code and body
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
        
        # Check if request was successful
        if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
            echo "$body"
            return 0
        fi
        
        # Handle different error codes
        retry_count=$((retry_count + 1))
        
        if [[ "$http_code" == "401" ]]; then
            echo -e "${RED}Error: Authentication failed (HTTP 401)${NC}" >&2
            echo "Your JIRA_PAT may be invalid or expired." >&2
            echo "Response: $body" | jq '.' 2>/dev/null || echo "$body" >&2
            return 1
        elif [[ "$http_code" == "403" ]]; then
            echo -e "${RED}Error: Access forbidden (HTTP 403)${NC}" >&2
            echo "You may not have permission to perform this action." >&2
            echo "Response: $body" | jq '.' 2>/dev/null || echo "$body" >&2
            return 1
        elif [[ "$http_code" == "404" ]]; then
            echo -e "${RED}Error: Resource not found (HTTP 404)${NC}" >&2
            echo "The requested resource does not exist." >&2
            echo "Response: $body" | jq '.' 2>/dev/null || echo "$body" >&2
            return 1
        elif [[ "$http_code" =~ ^5[0-9]{2}$ ]]; then
            if [[ $retry_count -lt $max_retries ]]; then
                echo -e "${YELLOW}Warning: Server error (HTTP $http_code). Retrying in ${wait_time}s... (attempt $retry_count/$max_retries)${NC}" >&2
                sleep $wait_time
                wait_time=$((wait_time * 2))
                continue
            else
                echo -e "${RED}Error: Server error (HTTP $http_code) after $max_retries retries${NC}" >&2
                echo "Response: $body" | jq '.' 2>/dev/null || echo "$body" >&2
                return 1
            fi
        elif [[ "$http_code" == "000" ]] || [[ -z "$http_code" ]]; then
            if [[ $retry_count -lt $max_retries ]]; then
                echo -e "${YELLOW}Warning: Connection failed. Retrying in ${wait_time}s... (attempt $retry_count/$max_retries)${NC}" >&2
                if [[ -n "$curl_error" ]]; then
                    echo -e "${YELLOW}Curl error: $curl_error${NC}" >&2
                fi
                sleep $wait_time
                wait_time=$((wait_time * 2))
                continue
            else
                echo -e "${RED}Error: Could not connect to Jira after $max_retries retries${NC}" >&2
                echo "URL: ${JIRA_URL}/rest/api/3/${endpoint}" >&2
                if [[ -n "$curl_error" ]]; then
                    echo -e "${RED}Curl error: $curl_error${NC}" >&2
                fi
                echo "Check your JIRA_URL and network connection." >&2
                echo "Note: SSL certificate verification is disabled (using -k flag)" >&2
                return 1
            fi
        else
            echo -e "${RED}Error: Request failed (HTTP $http_code)${NC}" >&2
            echo "Response: $body" | jq '.' 2>/dev/null || echo "$body" >&2
            return 1
        fi
    done
    
    return 1
}

echo -e "${GREEN}=== Jira Epic Creator ===${NC}\n"

# Prompt for project name
read -p "Enter the Project name (e.g., 'My Project'): " project_name

if [[ -z "$project_name" ]]; then
    echo -e "${RED}Error: Project name cannot be empty${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Searching for project...${NC}"

# Search for projects
projects_response=$(jira_api "GET" "project/search")

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to retrieve projects from Jira${NC}"
    exit 1
fi

# Check if response is valid JSON
if ! echo "$projects_response" | jq empty 2>/dev/null; then
    echo -e "${RED}Error: Invalid response from Jira API${NC}"
    echo "Response: $projects_response"
    exit 1
fi

# Parse and find matching projects
project_key=$(echo "$projects_response" | jq -r --arg name "$project_name" \
    '.values[] | select(.name == $name) | .key' | head -n 1)

project_found_name=$(echo "$projects_response" | jq -r --arg name "$project_name" \
    '.values[] | select(.name == $name) | .name' | head -n 1)

if [[ -z "$project_key" ]]; then
    echo -e "${RED}Error: No project found with name '${project_name}'${NC}"
    echo -e "\n${YELLOW}Available projects:${NC}"
    echo "$projects_response" | jq -r '.values[] | "  - \(.name) (Key: \(.key))"' 2>/dev/null || echo "Could not parse projects"
    exit 1
fi

# Confirm with user
echo -e "\n${GREEN}Found project:${NC}"
echo "  Name: ${project_found_name}"
echo "  Key: ${project_key}"
echo ""
read -p "Is this the correct project? (y/n): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${YELLOW}Operation cancelled by user${NC}"
    exit 0
fi

# Prompt for Epic name
echo ""
read -p "Enter the Epic name: " epic_name

if [[ -z "$epic_name" ]]; then
    echo -e "${RED}Error: Epic name cannot be empty${NC}"
    exit 1
fi

# Get the Epic issue type ID
echo -e "\n${YELLOW}Looking up Epic issue type...${NC}"
issue_types_response=$(jira_api "GET" "issuetype")

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to retrieve issue types from Jira${NC}"
    exit 1
fi

epic_type_id=$(echo "$issue_types_response" | jq -r '.[] | select(.name == "Epic") | .id' | head -n 1)

if [[ -z "$epic_type_id" ]]; then
    echo -e "${RED}Error: Epic issue type not found in Jira${NC}"
    echo -e "${YELLOW}Available issue types:${NC}"
    echo "$issue_types_response" | jq -r '.[] | "  - \(.name) (ID: \(.id))"' 2>/dev/null
    exit 1
fi

# Create the Epic
echo -e "${YELLOW}Creating Epic...${NC}"

create_data=$(cat <<EOF
{
  "fields": {
    "project": {
      "key": "${project_key}"
    },
    "summary": "${epic_name}",
    "issuetype": {
      "id": "${epic_type_id}"
    }
  }
}
EOF
)

create_response=$(jira_api "POST" "issue" "$create_data")

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to create Epic${NC}"
    exit 1
fi

# Check if creation was successful
epic_key=$(echo "$create_response" | jq -r '.key // empty')

if [[ -z "$epic_key" ]]; then
    echo -e "${RED}Error: Failed to create Epic${NC}"
    echo "Response:"
    echo "$create_response" | jq '.' 2>/dev/null || echo "$create_response"
    exit 1
fi

epic_url="${JIRA_URL}/browse/${epic_key}"

echo -e "\n${GREEN}✓ Epic created successfully!${NC}"
echo "  Key: ${epic_key}"
echo "  URL: ${epic_url}"
echo ""

