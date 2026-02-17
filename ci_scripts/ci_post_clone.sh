#!/bin/bash
set -e

echo "Generating Info.plist from template..."

if [ -z "$TMDB_API_KEY" ]; then
    echo "Error: TMDB_API_KEY environment variable is not set"
    exit 1
fi

sed "s/YOUR_API_KEY_HERE/${TMDB_API_KEY}/" "$CI_PRIMARY_REPOSITORY_PATH/Up Next/Info.plist.template" > "$CI_PRIMARY_REPOSITORY_PATH/Up Next/Info.plist"

echo "Info.plist generated successfully"

# Auto-set build and marketing version from Xcode Cloud build number
# Marketing version: {MAJOR}.{CI_BUILD_NUMBER} (e.g. 1.25)
# Build number: CI_BUILD_NUMBER (e.g. 25)
# To bump the major version, change MAJOR_VERSION below.
MAJOR_VERSION=1

if [ -n "$CI_BUILD_NUMBER" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"

    echo "Setting build number to $CI_BUILD_NUMBER..."
    agvtool new-version -all "$CI_BUILD_NUMBER"

    VERSION="${MAJOR_VERSION}.${CI_BUILD_NUMBER}"
    echo "Setting marketing version to $VERSION..."
    agvtool new-marketing-version "$VERSION"
fi
