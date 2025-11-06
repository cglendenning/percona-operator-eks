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

if [[ -z "$JIRA_EMAIL" ]]; then
    echo -e "${RED}Error: JIRA_EMAIL environment variable is not set${NC}"
    echo "Please set it using: export JIRA_EMAIL=your-email@example.com"
    exit 1
fi

if [[ -z "$JIRA_API_TOKEN" ]]; then
    echo -e "${RED}Error: JIRA_API_TOKEN environment variable is not set${NC}"
    echo "Please set it using: export JIRA_API_TOKEN=your-api-token"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo "Please install jq using: brew install jq (on macOS)"
    exit 1
fi

# Base64 encode credentials for basic auth
AUTH=$(echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64)

# Function to make API calls
jira_api() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    if [[ -n "$data" ]]; then
        curl -s -X "$method" \
            -H "Authorization: Basic ${AUTH}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$data" \
            "${JIRA_URL}/rest/api/3/${endpoint}"
    else
        curl -s -X "$method" \
            -H "Authorization: Basic ${AUTH}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            "${JIRA_URL}/rest/api/3/${endpoint}"
    fi
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

# Parse and find matching projects
project_key=$(echo "$projects_response" | jq -r --arg name "$project_name" \
    '.values[] | select(.name == $name) | .key' | head -n 1)

project_found_name=$(echo "$projects_response" | jq -r --arg name "$project_name" \
    '.values[] | select(.name == $name) | .name' | head -n 1)

if [[ -z "$project_key" ]]; then
    echo -e "${RED}Error: No project found with name '${project_name}'${NC}"
    echo -e "\n${YELLOW}Available projects:${NC}"
    echo "$projects_response" | jq -r '.values[] | "  - \(.name) (Key: \(.key))"'
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
epic_type_id=$(echo "$issue_types_response" | jq -r '.[] | select(.name == "Epic") | .id' | head -n 1)

if [[ -z "$epic_type_id" ]]; then
    echo -e "${RED}Error: Epic issue type not found in Jira${NC}"
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

# Check if creation was successful
epic_key=$(echo "$create_response" | jq -r '.key // empty')

if [[ -z "$epic_key" ]]; then
    echo -e "${RED}Error: Failed to create Epic${NC}"
    echo "Response: $create_response" | jq '.'
    exit 1
fi

epic_url="${JIRA_URL}/browse/${epic_key}"

echo -e "\n${GREEN}✓ Epic created successfully!${NC}"
echo "  Key: ${epic_key}"
echo "  URL: ${epic_url}"
echo ""

