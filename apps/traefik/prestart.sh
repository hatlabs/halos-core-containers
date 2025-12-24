#!/bin/bash
# Prestart script for traefik-container
# Creates acme.json and sets up dynamic middleware directory
set -e

# Derive package name from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ETC_DIR}/env" ] && . "${ETC_DIR}/env"
set +a

# Create data directory
mkdir -p "${CONTAINER_DATA_ROOT}"

# Create acme.json with proper permissions if it doesn't exist
# Traefik requires this file to have 600 permissions
ACME_FILE="${CONTAINER_DATA_ROOT}/acme.json"
if [ ! -f "${ACME_FILE}" ]; then
    touch "${ACME_FILE}"
    chmod 600 "${ACME_FILE}"
fi

# ============================================
# Dynamic Configuration Directory
# ============================================
# This directory allows per-app middleware configurations
# Apps can drop their own middleware files here
DYNAMIC_DIR="/etc/halos/traefik-dynamic.d"
mkdir -p "${DYNAMIC_DIR}"

# Install default Authelia ForwardAuth middleware if not present
# This is the standard middleware for apps using forward_auth
AUTHELIA_MIDDLEWARE="${DYNAMIC_DIR}/authelia.yml"
AUTHELIA_MIDDLEWARE_SRC="${SCRIPT_DIR}/dynamic/authelia.yml"

if [ ! -f "${AUTHELIA_MIDDLEWARE}" ]; then
    if [ -f "${AUTHELIA_MIDDLEWARE_SRC}" ]; then
        echo "Installing default Authelia ForwardAuth middleware..."
        cp "${AUTHELIA_MIDDLEWARE_SRC}" "${AUTHELIA_MIDDLEWARE}"
        chmod 644 "${AUTHELIA_MIDDLEWARE}"
    else
        echo "WARNING: Default Authelia middleware not found at ${AUTHELIA_MIDDLEWARE_SRC}"
    fi
else
    echo "Authelia middleware already exists at ${AUTHELIA_MIDDLEWARE}"
fi

# ============================================
# Runtime Routing Label Generation
# ============================================
# Generate Traefik labels from generic routing declarations
# This reads /etc/halos/routing.d/*.yml and generates:
# - Docker-compose override files in /run/halos/routing-labels/
# - Per-app ForwardAuth middleware in /etc/halos/traefik-dynamic.d/
ROUTING_GENERATOR="${SCRIPT_DIR}/generate-routing-labels.sh"

if [ -f "${ROUTING_GENERATOR}" ]; then
    echo "Generating routing labels from /etc/halos/routing.d/..."
    # Export HALOS_DOMAIN for the generator script
    export HALOS_DOMAIN
    bash "${ROUTING_GENERATOR}"
else
    echo "WARNING: Routing generator not found at ${ROUTING_GENERATOR}"
fi

echo "Traefik prestart complete"
