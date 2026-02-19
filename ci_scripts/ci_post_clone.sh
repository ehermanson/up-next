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

echo "CI_BUILD_NUMBER=$CI_BUILD_NUMBER"
echo "CI_PRIMARY_REPOSITORY_PATH=$CI_PRIMARY_REPOSITORY_PATH"

if [ -z "$CI_BUILD_NUMBER" ]; then
    echo "ERROR: CI_BUILD_NUMBER is not set — version will not be updated!"
    exit 1
fi

PBXPROJ="$CI_PRIMARY_REPOSITORY_PATH/Up Next.xcodeproj/project.pbxproj"
VERSION="${MAJOR_VERSION}.${CI_BUILD_NUMBER}"

echo "Setting build number to $CI_BUILD_NUMBER..."
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER/" "$PBXPROJ"

echo "Setting marketing version to $VERSION..."
sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/" "$PBXPROJ"

# Verify the change took effect
echo "Verifying version in project file..."
grep "MARKETING_VERSION" "$PBXPROJ"
grep "CURRENT_PROJECT_VERSION" "$PBXPROJ"
