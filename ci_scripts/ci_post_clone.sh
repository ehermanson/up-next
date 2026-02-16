#!/bin/bash
set -e

echo "Generating Info.plist from template..."

if [ -z "$TMDB_API_KEY" ]; then
    echo "Error: TMDB_API_KEY environment variable is not set"
    exit 1
fi

sed "s/YOUR_API_KEY_HERE/${TMDB_API_KEY}/" "$CI_PRIMARY_REPOSITORY_PATH/Up Next/Info.plist.template" > "$CI_PRIMARY_REPOSITORY_PATH/Up Next/Info.plist"

echo "Info.plist generated successfully"

# Auto-increment build number using Xcode Cloud's build number
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    agvtool new-version -all "$CI_BUILD_NUMBER"
    echo "Build number set to $CI_BUILD_NUMBER"
fi
