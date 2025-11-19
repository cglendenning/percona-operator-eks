# MySQL User_attributes Field and Password Sync Issue

## Problem Description

After restoring a Percona XtraDB Cluster using `PerconaXtraDBClusterRestore`, even though user passwords are reset to match the Kubernetes secret, the Percona Operator fails with:

```
manage sys users: is old password discarded: select User_attributes field: 
Access denied for user 'operator'@'x.x.x.x.percona-xtradb-cluster-operator.pxc-upgrade-testing'
```

## Root Cause

### MySQL 8.0 Dual Password Feature

MySQL 8.0+ introduced a **dual password** authentication feature that allows users to have both a current and a previous password active simultaneously. This is designed to facilitate password rotation without downtime.

#### How It Works:

1. **Primary Password**: Stored in `authentication_string` field
2. **Secondary Password**: Stored in `User_attributes` JSON field as `additional_password`

#### SQL Commands:

```sql
-- Set password and RETAIN the old one
ALTER USER 'operator'@'%' IDENTIFIED BY 'newpass' RETAIN CURRENT PASSWORD;

-- This stores:
-- - authentication_string: hash of 'newpass'
-- - User_attributes: {"additional_password": "hash_of_oldpass"}

-- Discard the old password
ALTER USER 'operator'@'%' DISCARD OLD PASSWORD;

-- This clears the User_attributes field
```

### Percona Operator Behavior

The Percona Operator **checks the `User_attributes` field** to verify that old passwords have been properly discarded. It does this by querying:

```sql
SELECT User_attributes FROM mysql.user WHERE User='operator' AND Host='%';
```

The operator wants to ensure no old passwords are retained, but:
1. The `operator` user doesn't have `SELECT` permission on `mysql.user` table
2. After a restore, `User_attributes` may contain old password hashes
3. When the operator tries to verify, it gets "Access denied" error

## Why This Happens After Restore

When you restore from backup:

1. **Backup contains**: Old database state with old passwords
2. **Current secret contains**: New passwords
3. **After restore**: Database has old password in `authentication_string` AND possibly in `User_attributes`
4. **Simple `ALTER USER`**: Only updates `authentication_string`, doesn't clear `User_attributes`
5. **Operator check**: Tries to verify `User_attributes` is clean, gets access denied

### Example Scenario:

```sql
-- Before backup (old password was 'oldpass'):
mysql.user:
  User: operator, authentication_string: hash('oldpass')
  User_attributes: NULL

-- Password changed to 'midpass' with RETAIN:
mysql.user:
  User: operator, authentication_string: hash('midpass')
  User_attributes: {"additional_password": "hash(oldpass)"}

-- BACKUP TAKEN HERE --

-- After backup, password changed again to 'newpass':
Kubernetes Secret: operator=newpass

-- RESTORE FROM BACKUP --
mysql.user:
  User: operator, authentication_string: hash('midpass')
  User_attributes: {"additional_password": "hash(oldpass)"}

-- You run: ALTER USER 'operator'@'%' IDENTIFIED BY 'newpass';
mysql.user:
  User: operator, authentication_string: hash('newpass')
  User_attributes: {"additional_password": "hash(oldpass)"}  # STILL THERE!

-- Operator tries to verify User_attributes is clean:
SELECT User_attributes FROM mysql.user WHERE User='operator';
ERROR: Access denied for user 'operator'@'...'
```

## Solution

### Use `DISCARD OLD PASSWORD`

The fix is to **explicitly discard old passwords** when updating:

```sql
ALTER USER 'operator'@'%' IDENTIFIED BY 'newpass' DISCARD OLD PASSWORD;
```

This command:
1. Updates the primary password in `authentication_string`
2. **Clears the `User_attributes` field** (removes `additional_password`)
3. Ensures no retained passwords exist

### Updated Script

The `sync-mysql-passwords.sh` script now uses:

```bash
mysql -uroot -p"$root_password" -e \
  "ALTER USER $user_host IDENTIFIED BY '$new_password' DISCARD OLD PASSWORD; 
   FLUSH PRIVILEGES;"
```

### Detection

The script also checks for retained passwords:

```sql
SELECT IF(User_attributes LIKE '%additional_password%', 'YES', 'NO') 
FROM mysql.user 
WHERE User='operator' AND Host='%';
```

This allows the script to report which users have old passwords that need to be discarded.

## Operator Version Differences

### Percona Operator v1.18.0+

Starting with version 1.18.0, the Percona Operator **automatically handles this** after restore:
- Updates user passwords from Kubernetes secrets
- Discards old passwords from `User_attributes`
- Creates missing users
- Grants necessary privileges

### Percona Operator v1.17.0 and Earlier

Requires **manual intervention** using the `sync-mysql-passwords.sh` script.

## Script Usage

### Dry-Run (See what needs fixing):

```bash
./sync-mysql-passwords.sh \
  -n percona \
  -s pxc-cluster-secrets \
  -c pxc-cluster \
  --dry-run
```

**Output Example:**
```
[INFO] Processing user: operator
[INFO]   Found: 'operator'@'%'
[WARN]     ⚠ User has retained old password in User_attributes (will be discarded)
[DRY-RUN]   Would update password for 'operator'@'%' AND discard old password
```

### Actual Fix:

```bash
./sync-mysql-passwords.sh \
  -n percona \
  -s pxc-cluster-secrets \
  -c pxc-cluster
```

The script will:
1. Prompt for each user before updating
2. Update password to match secret
3. Discard any old passwords from `User_attributes`
4. Report success/failure for each user

## Verification

After running the script, verify the fix:

```sql
-- Connect as root
mysql -uroot -p

-- Check User_attributes for operator user
SELECT User, Host, User_attributes 
FROM mysql.user 
WHERE User='operator';

-- Should show NULL or empty JSON, not {"additional_password": ...}
```

## References

- [MySQL 8.0 Dual Password Documentation](https://dev.mysql.com/doc/refman/8.0/en/password-management.html#dual-passwords)
- [Percona Operator Restore Documentation](https://docs.percona.com/percona-operator-for-mysql/pxc/backups-restore.html)
- MySQL `User_attributes` field: JSON column storing user metadata including secondary passwords

## Summary

The error `"is old password discarded: select User_attributes field: Access denied"` occurs because:

1. **MySQL 8.0 dual passwords** can leave old password hashes in `User_attributes`
2. **Percona Operator checks** this field to verify clean state
3. **Operator lacks permission** to read `mysql.user` table
4. **Solution**: Use `ALTER USER ... DISCARD OLD PASSWORD` to clean `User_attributes`

The updated `sync-mysql-passwords.sh` script handles this automatically.

