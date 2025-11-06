# Jira CLI Tools

Command-line tools for creating Jira Epics and Tasks.

## Prerequisites

1. **jq** - JSON processor
   ```bash
   brew install jq  # macOS
   ```

2. **Jira API Token** - Generate from your Jira account:
   - Go to https://id.atlassian.com/manage-profile/security/api-tokens
   - Click "Create API token"
   - Save the token securely

## Setup

Set the following environment variables:

```bash
export JIRA_URL=https://your-domain.atlassian.net
export JIRA_EMAIL=your-email@example.com
export JIRA_API_TOKEN=your-api-token-here
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

## Troubleshooting

### Authentication Errors

If you get 401 Unauthorized errors:
- Verify your `JIRA_EMAIL` is correct
- Verify your `JIRA_API_TOKEN` is valid
- Make sure you're using an API token, not your password

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

### Missing jq

If you see "jq: command not found":
```bash
brew install jq  # macOS
apt-get install jq  # Ubuntu/Debian
yum install jq  # CentOS/RHEL
```

## API Reference

These scripts use the Jira REST API v3:
- [Jira Cloud REST API Documentation](https://developer.atlassian.com/cloud/jira/platform/rest/v3/)
- [Authentication](https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/)

