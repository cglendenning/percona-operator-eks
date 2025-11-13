#!/usr/bin/env python3
"""
DB Concierge Operator - Manages AppDatabase custom resources
This operator creates MySQL databases, users, grants, and Kubernetes secrets
"""
import kopf
import logging
from handlers.appdatabase_handler import (
    on_create,
    on_update,
    on_delete,
    on_startup,
)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Register handlers
@kopf.on.startup()
def startup_fn(settings: kopf.OperatorSettings, **kwargs):
    """Configure operator settings on startup"""
    on_startup(settings, **kwargs)

@kopf.on.create('db.stillwaters.io', 'v1', 'appdatabases')
def create_fn(spec, status, meta, name, namespace, logger, **kwargs):
    """Handle AppDatabase creation"""
    return on_create(spec, status, meta, name, namespace, logger, **kwargs)

@kopf.on.update('db.stillwaters.io', 'v1', 'appdatabases')
def update_fn(spec, status, meta, name, namespace, logger, **kwargs):
    """Handle AppDatabase updates"""
    return on_update(spec, status, meta, name, namespace, logger, **kwargs)

@kopf.on.delete('db.stillwaters.io', 'v1', 'appdatabases')
def delete_fn(spec, status, meta, name, namespace, logger, **kwargs):
    """Handle AppDatabase deletion"""
    return on_delete(spec, status, meta, name, namespace, logger, **kwargs)

if __name__ == '__main__':
    logger.info("Starting DB Concierge Operator")

