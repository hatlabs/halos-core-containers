#!/bin/bash
set -euo pipefail

# This script is called by the shared workflow but intentionally does NOT
# generate a debian/changelog. Container packages are built dynamically using
# container-packaging-tools, which generates its own versioned packages.
#
# The VERSION file is a meta/bundle version for git tags only,
# not used for individual package versions.

# Parse arguments (we accept them but don't use them)
UPSTREAM=""
REVISION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --upstream)
            UPSTREAM="$2"
            shift 2
            ;;
        --revision)
            REVISION="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "Skipping changelog generation (using container-packaging-tools)"
echo "Container packages get versions from metadata.yaml in each app directory"
echo "Bundle version: ${UPSTREAM:-unknown}-${REVISION:-unknown}"
