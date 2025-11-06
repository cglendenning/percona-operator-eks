# Jira CLI Tools

Command-line tools for creating Jira Epics and Tasks.

## Prerequisites

1. **jq** - JSON processor
   ```bash
   brew install jq  # macOS
   ```

2. **Jira Personal Access Token (PAT)** - Generate from your Jira account:
   - Go to https://id.atlassian.com/manage-profile/security/api-tokens
   - Click "Create API token" 
   - Or for PAT: Go to your Jira instance → Profile → Personal Access Tokens
   - Save the token securely

## Setup

Set the following environment variables:

```bash
export JIRA_URL=https://your-domain.atlassian.net
export JIRA_PAT=your-personal-access-token-here
```

> **Tip:** Add these to your `~/.bashrc`, `~/.zshrc`, or `~/.bash_profile` to make them persistent.

## Usage

### Creating an Epic

```bash
./utils/jira/create_epic.sh
```

The script will:
1. Prompt for the Project name (must match exact display name)
2. Search for and display the matching project
3. Ask for confirmation
4. Prompt for the Epic name
5. Create the Epic and display the URL

**Example:**
```
$ ./utils/jira/create_epic.sh
=== Jira Epic Creator ===

Enter the Project name (e.g., 'My Project'): Percona Operator

Searching for project...

Found project:
  Name: Percona Operator
  Key: PO

Is this the correct project? (y/n): y

Enter the Epic name: Database Resiliency Testing

Creating Epic...

✓ Epic created successfully!
  Key: PO-123
  URL: https://your-domain.atlassian.net/browse/PO-123
```

### Creating a Task

```bash
./utils/jira/create_task.sh
```

The script will:
1. Prompt for the Epic name to search
2. Display matching Epic(s)
3. Ask for confirmation of the correct Epic
4. Prompt for the Task title
5. Prompt for the Task description (multi-line, press Ctrl+D when done)
6. Create the Task linked to the Epic and display the URL

**Example:**
```
$ ./utils/jira/create_task.sh
=== Jira Task Creator ===

Enter the Epic name to search for: Database Resiliency

Searching for Epic...

Found Epic:
  Key: PO-123
  Summary: Database Resiliency Testing
  Project: Percona Operator (PO)

Is this the correct Epic? (y/n): y

Enter the Task title: Test pod recovery after deletion

Enter the Task description (press Ctrl+D when done):
Verify that MySQL pods can recover automatically after deletion:
- Delete a pod manually
- Monitor recovery time
- Verify data consistency
^D

Creating Task...

✓ Task created successfully!
  Key: PO-124
  Title: Test pod recovery after deletion
  Parent Epic: PO-123
  URL: https://your-domain.atlassian.net/browse/PO-124
```

## Features

- **Robust Error Handling**: Clear error messages with HTTP status codes
- **Automatic Retries**: Up to 3 retries for server errors and connection failures with exponential backoff
- **Detailed Feedback**: Shows exactly what went wrong if API calls fail
- **Interactive Prompts**: User-friendly prompts with confirmation steps
- **Colored Output**: Easy-to-read terminal output with status indicators

## Troubleshooting

### Authentication Errors

If you get 401 Unauthorized errors:
- Verify your `JIRA_PAT` is valid and not expired
- Make sure you're using a Personal Access Token
- Regenerate your PAT if necessary
- Check that your token has the required permissions

### Project Not Found

If the script can't find your project:
- Check the exact project name in Jira (case-sensitive)
- Verify you have access to the project
- The script will list available projects if none match

### Epic Not Found

If the script can't find your epic:
- Check the Epic name spelling
- Verify the Epic exists in Jira
- Try searching with partial name (e.g., "Resiliency" instead of full name)

### Connection Errors

If you get connection errors:
- Verify your `JIRA_URL` is correct (e.g., `https://your-domain.atlassian.net`)
- Check your network connection
- Ensure you can access Jira from your browser
- The script will automatically retry failed connections up to 3 times

### Missing jq

If you see "jq: command not found":
```bash
brew install jq  # macOS
apt-get install jq  # Ubuntu/Debian
yum install jq  # CentOS/RHEL
```

### Debugging

Both scripts provide detailed error messages including:
- HTTP status codes (401, 403, 404, 500, etc.)
- Full error responses from Jira API
- Retry attempts for transient failures
- Available options when resources aren't found

## API Reference

These scripts use the Jira REST API v3:
- [Jira Cloud REST API Documentation](https://developer.atlassian.com/cloud/jira/platform/rest/v3/)
- [Authentication](https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/)

