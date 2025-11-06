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

echo -e "${GREEN}=== Jira Task Creator ===${NC}\n"

# Prompt for Epic name
read -p "Enter the Epic name to search for: " epic_name

if [[ -z "$epic_name" ]]; then
    echo -e "${RED}Error: Epic name cannot be empty${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Searching for Epic...${NC}"

# Search for the Epic using JQL
search_jql="type = Epic AND summary ~ \"${epic_name}\" ORDER BY created DESC"
search_response=$(jira_api "GET" "search?jql=$(echo "$search_jql" | jq -sRr @uri)&maxResults=10")

# Count results
result_count=$(echo "$search_response" | jq '.issues | length')

if [[ "$result_count" -eq 0 ]]; then
    echo -e "${RED}Error: No Epic found matching '${epic_name}'${NC}"
    exit 1
fi

if [[ "$result_count" -gt 1 ]]; then
    echo -e "${YELLOW}Found multiple Epics matching your search:${NC}\n"
    echo "$search_response" | jq -r '.issues[] | "[\(.key)] \(.fields.summary) - Project: \(.fields.project.name)"'
    echo ""
    read -p "Enter the Epic key you want to use (e.g., PROJ-123): " epic_key
    
    # Verify the entered key exists in results
    epic_key_found=$(echo "$search_response" | jq -r --arg key "$epic_key" \
        '.issues[] | select(.key == $key) | .key')
    
    if [[ -z "$epic_key_found" ]]; then
        echo -e "${RED}Error: Epic key '${epic_key}' not found in search results${NC}"
        exit 1
    fi
else
    epic_key=$(echo "$search_response" | jq -r '.issues[0].key')
fi

# Get Epic details for confirmation
epic_summary=$(echo "$search_response" | jq -r --arg key "$epic_key" \
    '.issues[] | select(.key == $key) | .fields.summary')
epic_project_key=$(echo "$search_response" | jq -r --arg key "$epic_key" \
    '.issues[] | select(.key == $key) | .fields.project.key')
epic_project_name=$(echo "$search_response" | jq -r --arg key "$epic_key" \
    '.issues[] | select(.key == $key) | .fields.project.name')

# Confirm with user
echo -e "\n${GREEN}Found Epic:${NC}"
echo "  Key: ${epic_key}"
echo "  Summary: ${epic_summary}"
echo "  Project: ${epic_project_name} (${epic_project_key})"
echo ""
read -p "Is this the correct Epic? (y/n): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${YELLOW}Operation cancelled by user${NC}"
    exit 0
fi

# Prompt for task title
echo ""
read -p "Enter the Task title: " task_title

if [[ -z "$task_title" ]]; then
    echo -e "${RED}Error: Task title cannot be empty${NC}"
    exit 1
fi

# Prompt for task description
echo ""
echo "Enter the Task description (press Ctrl+D when done):"
task_description=$(cat)

if [[ -z "$task_description" ]]; then
    echo -e "${YELLOW}Warning: Task description is empty${NC}"
fi

# Get the Task issue type ID
echo -e "\n${YELLOW}Looking up Task issue type...${NC}"
issue_types_response=$(jira_api "GET" "issuetype")
task_type_id=$(echo "$issue_types_response" | jq -r '.[] | select(.name == "Task") | .id' | head -n 1)

if [[ -z "$task_type_id" ]]; then
    echo -e "${RED}Error: Task issue type not found in Jira${NC}"
    exit 1
fi

# Create the Task
echo -e "${YELLOW}Creating Task...${NC}"

# Escape special characters in JSON strings
task_title_escaped=$(echo "$task_title" | jq -Rs .)
task_description_escaped=$(echo "$task_description" | jq -Rs .)

create_data=$(cat <<EOF
{
  "fields": {
    "project": {
      "key": "${epic_project_key}"
    },
    "summary": ${task_title_escaped},
    "description": {
      "type": "doc",
      "version": 1,
      "content": [
        {
          "type": "paragraph",
          "content": [
            {
              "type": "text",
              "text": ${task_description_escaped}
            }
          ]
        }
      ]
    },
    "issuetype": {
      "id": "${task_type_id}"
    },
    "parent": {
      "key": "${epic_key}"
    }
  }
}
EOF
)

create_response=$(jira_api "POST" "issue" "$create_data")

# Check if creation was successful
task_key=$(echo "$create_response" | jq -r '.key // empty')

if [[ -z "$task_key" ]]; then
    echo -e "${RED}Error: Failed to create Task${NC}"
    echo "Response:" 
    echo "$create_response" | jq '.'
    exit 1
fi

task_url="${JIRA_URL}/browse/${task_key}"

echo -e "\n${GREEN}✓ Task created successfully!${NC}"
echo "  Key: ${task_key}"
echo "  Title: ${task_title}"
echo "  Parent Epic: ${epic_key}"
echo "  URL: ${task_url}"
echo ""

