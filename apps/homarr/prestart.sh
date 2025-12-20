#!/bin/bash
# Prestart script for homarr-container
# Custom script to handle SECRET_ENCRYPTION_KEY generation and runtime env setup
set -e

# Derive package name from script location
# Script is at /var/lib/container-apps/<package-name>/prestart.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"
RUN_DIR="/run/container-apps/${PACKAGE_NAME}"
RUNTIME_ENV="${RUN_DIR}/runtime.env"
ENV_FILE="${ETC_DIR}/env"

# Create runtime directory
mkdir -p "$(dirname "$RUNTIME_ENV")"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ENV_FILE}" ] && . "${ENV_FILE}"
set +a

# Generate SECRET_ENCRYPTION_KEY if not set or empty
if [ -z "$SECRET_ENCRYPTION_KEY" ]; then
    echo "Generating SECRET_ENCRYPTION_KEY..."
    SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)
    # Persist the generated key to the user env file
    echo "SECRET_ENCRYPTION_KEY=\"${SECRET_ENCRYPTION_KEY}\"" >> "${ENV_FILE}"
fi

# Set hostname and domain (matches mDNS publisher)
HOSTNAME="$(hostname -s)"
HALOS_DOMAIN="${HOSTNAME}.local"
echo "HOSTNAME=$HOSTNAME" > "$RUNTIME_ENV"
echo "HALOS_DOMAIN=$HALOS_DOMAIN" >> "$RUNTIME_ENV"

# Also write HALOS_DOMAIN to env file so docker-compose can use it in labels
# (runtime.env is not loaded by the systemd service currently)
if ! grep -q "^HALOS_DOMAIN=" "${ENV_FILE}" 2>/dev/null; then
    echo "HALOS_DOMAIN=\"${HALOS_DOMAIN}\"" >> "${ENV_FILE}"
fi

# Compute Homarr URL (now goes through Traefik on port 80)
HOMARR_URL="http://${HALOS_DOMAIN}/"
echo "HOMARR_URL=$HOMARR_URL" >> "$RUNTIME_ENV"

# Set OIDC URLs if not already configured
if ! grep -q "^AUTH_OIDC_ISSUER=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_ISSUER=\"http://auth.${HALOS_DOMAIN}\"" >> "${ENV_FILE}"
fi
if ! grep -q "^AUTH_LOGOUT_REDIRECT_URL=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_LOGOUT_REDIRECT_URL=\"http://auth.${HALOS_DOMAIN}/logout\"" >> "${ENV_FILE}"
fi
