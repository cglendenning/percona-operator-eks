#!/usr/bin/env python3
"""
Handler for AppDatabase custom resource
Manages MySQL database lifecycle and Kubernetes secrets
"""
import os
import secrets
import string
from datetime import datetime
from typing import Dict, Any
import pymysql
from kubernetes import client, config
import kopf

def on_startup(settings: kopf.OperatorSettings, **kwargs):
    """Configure operator settings"""
    settings.persistence.finalizer = 'appdatabase.db.stillwaters.io/finalizer'
    settings.watching.server_timeout = 600
    
    # Load kubernetes config
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()

def generate_password(length: int = 24) -> str:
    """Generate a secure random password"""
    alphabet = string.ascii_letters + string.digits + '!@#$%^&*'
    # Ensure at least one of each type
    password = [
        secrets.choice(string.ascii_lowercase),
        secrets.choice(string.ascii_uppercase),
        secrets.choice(string.digits),
        secrets.choice('!@#$%^&*')
    ]
    # Fill the rest randomly
    password += [secrets.choice(alphabet) for _ in range(length - 4)]
    # Shuffle
    secrets.SystemRandom().shuffle(password)
    return ''.join(password)

def get_mysql_connection(cluster_ref: str, namespace: str):
    """
    Get MySQL connection using admin credentials from operator secret
    """
    # Get admin credentials from environment or secret
    mysql_host = os.environ.get('MYSQL_ADMIN_HOST', cluster_ref)
    mysql_port = int(os.environ.get('MYSQL_ADMIN_PORT', '3306'))
    mysql_user = os.environ.get('MYSQL_ADMIN_USER', 'root')
    mysql_password = os.environ.get('MYSQL_ADMIN_PASSWORD', '')
    
    # If running in cluster, may need to append namespace to service name
    if '.' not in mysql_host and namespace:
        mysql_host = f"{mysql_host}.{namespace}.svc.cluster.local"
    
    connection = pymysql.connect(
        host=mysql_host,
        port=mysql_port,
        user=mysql_user,
        password=mysql_password,
        charset='utf8mb4',
        cursorclass=pymysql.cursors.DictCursor
    )
    return connection

def create_database(conn, db_name: str, charset: str, collation: str, logger) -> bool:
    """Create MySQL database if it doesn't exist"""
    try:
        with conn.cursor() as cursor:
            # Check if database exists
            cursor.execute("SHOW DATABASES LIKE %s", (db_name,))
            if cursor.fetchone():
                logger.info(f"Database {db_name} already exists")
                return True
            
            # Create database
            sql = f"CREATE DATABASE `{db_name}` CHARACTER SET {charset} COLLATE {collation}"
            cursor.execute(sql)
            conn.commit()
            logger.info(f"Created database: {db_name}")
            return True
    except Exception as e:
        logger.error(f"Failed to create database {db_name}: {e}")
        raise

def create_user_and_grant(conn, user_name: str, password: str, db_name: str, logger) -> bool:
    """Create MySQL user and grant privileges"""
    try:
        with conn.cursor() as cursor:
            # Check if user exists
            cursor.execute("SELECT User FROM mysql.user WHERE User = %s", (user_name,))
            user_exists = cursor.fetchone() is not None
            
            if user_exists:
                # Update password for existing user
                logger.info(f"User {user_name} exists, updating password")
                cursor.execute(f"ALTER USER %s@'%%' IDENTIFIED BY %s", (user_name, password))
            else:
                # Create new user
                logger.info(f"Creating user: {user_name}")
                cursor.execute(f"CREATE USER %s@'%%' IDENTIFIED BY %s", (user_name, password))
            
            # Grant privileges on the specific database
            logger.info(f"Granting privileges on {db_name} to {user_name}")
            cursor.execute(f"GRANT ALL PRIVILEGES ON `{db_name}`.* TO %s@'%%'", (user_name,))
            cursor.execute("FLUSH PRIVILEGES")
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"Failed to create user {user_name}: {e}")
        raise

def create_k8s_secret(
    secret_name: str,
    namespace: str,
    db_name: str,
    user_name: str,
    password: str,
    host: str,
    port: str,
    logger
) -> bool:
    """Create Kubernetes secret with database credentials"""
    try:
        v1 = client.CoreV1Api()
        
        # Prepare secret data
        secret_data = {
            'username': user_name,
            'password': password,
            'database': db_name,
            'host': host,
            'port': port,
            'connection-string': f"mysql://{user_name}:{password}@{host}:{port}/{db_name}"
        }
        
        secret = client.V1Secret(
            metadata=client.V1ObjectMeta(
                name=secret_name,
                namespace=namespace,
                labels={
                    'app.kubernetes.io/managed-by': 'db-concierge-operator',
                    'db.stillwaters.io/database': db_name
                }
            ),
            string_data=secret_data,
            type='Opaque'
        )
        
        # Try to create or update secret
        try:
            v1.create_namespaced_secret(namespace=namespace, body=secret)
            logger.info(f"Created secret {secret_name} in namespace {namespace}")
        except client.exceptions.ApiException as e:
            if e.status == 409:  # Already exists
                v1.replace_namespaced_secret(name=secret_name, namespace=namespace, body=secret)
                logger.info(f"Updated secret {secret_name} in namespace {namespace}")
            else:
                raise
        
        return True
    except Exception as e:
        logger.error(f"Failed to create secret {secret_name}: {e}")
        raise

def on_create(spec: Dict[str, Any], status: Dict[str, Any], meta: Dict[str, Any], 
              name: str, namespace: str, logger, **kwargs) -> Dict[str, Any]:
    """Handle creation of AppDatabase resource"""
    logger.info(f"Creating AppDatabase: {name} in namespace {namespace}")
    
    try:
        # Extract spec fields
        cluster_ref = spec['clusterRef']
        db_name = spec['dbName']
        app_namespace = spec['appNamespace']
        secret_name = spec.get('secretName', f"{db_name}-mysql-creds")
        charset = spec.get('charset', 'utf8mb4')
        collation = spec.get('collation', 'utf8mb4_unicode_ci')
        user_name = spec.get('userName', f"{db_name}_app")
        
        # Generate password
        password = generate_password()
        
        # Connect to MySQL
        logger.info(f"Connecting to MySQL cluster: {cluster_ref}")
        conn = get_mysql_connection(cluster_ref, namespace)
        
        try:
            # Create database
            logger.info(f"Creating database: {db_name}")
            create_database(conn, db_name, charset, collation, logger)
            
            # Create user and grant privileges
            logger.info(f"Creating user and granting privileges: {user_name}")
            create_user_and_grant(conn, user_name, password, db_name, logger)
            
        finally:
            conn.close()
        
        # Create Kubernetes secret in app namespace
        logger.info(f"Creating secret in namespace: {app_namespace}")
        create_k8s_secret(
            secret_name=secret_name,
            namespace=app_namespace,
            db_name=db_name,
            user_name=user_name,
            password=password,
            host=cluster_ref,
            port='3306',
            logger=logger
        )
        
        # Return status update
        return {
            'phase': 'Ready',
            'message': f'Database {db_name} and user {user_name} created successfully',
            'userName': user_name,
            'secretName': secret_name,
            'connectionString': f'mysql://{user_name}:***@{cluster_ref}:3306/{db_name}',
            'lastReconcileTime': datetime.utcnow().isoformat() + 'Z'
        }
        
    except Exception as e:
        logger.error(f"Failed to create AppDatabase {name}: {e}")
        return {
            'phase': 'Failed',
            'message': f'Error: {str(e)}',
            'lastReconcileTime': datetime.utcnow().isoformat() + 'Z'
        }

def on_update(spec: Dict[str, Any], status: Dict[str, Any], meta: Dict[str, Any],
              name: str, namespace: str, logger, **kwargs) -> Dict[str, Any]:
    """Handle updates to AppDatabase resource"""
    logger.info(f"Updating AppDatabase: {name}")
    
    # For now, treat updates similar to creates (idempotent)
    # In production, you might want more sophisticated update logic
    return on_create(spec, status, meta, name, namespace, logger, **kwargs)

def on_delete(spec: Dict[str, Any], status: Dict[str, Any], meta: Dict[str, Any],
              name: str, namespace: str, logger, **kwargs):
    """Handle deletion of AppDatabase resource"""
    logger.info(f"Deleting AppDatabase: {name}")
    
    deletion_policy = spec.get('deletionPolicy', 'Retain')
    
    if deletion_policy == 'Delete':
        try:
            db_name = spec['dbName']
            cluster_ref = spec['clusterRef']
            user_name = spec.get('userName', f"{db_name}_app")
            
            logger.warning(f"DeletionPolicy is Delete - removing database {db_name}")
            
            # Connect to MySQL
            conn = get_mysql_connection(cluster_ref, namespace)
            
            try:
                with conn.cursor() as cursor:
                    # Drop user
                    logger.info(f"Dropping user: {user_name}")
                    cursor.execute(f"DROP USER IF EXISTS '{user_name}'@'%'")
                    
                    # Drop database
                    logger.info(f"Dropping database: {db_name}")
                    cursor.execute(f"DROP DATABASE IF EXISTS `{db_name}`")
                    
                    conn.commit()
                    logger.info(f"Deleted database {db_name} and user {user_name}")
            finally:
                conn.close()
                
        except Exception as e:
            logger.error(f"Failed to delete database resources: {e}")
            raise
    else:
        logger.info(f"DeletionPolicy is Retain - keeping database {spec['dbName']}")
    
    # Note: We don't delete the k8s secret - let the app namespace owner decide
    logger.info(f"AppDatabase {name} deletion complete")

