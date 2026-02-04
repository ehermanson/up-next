#!/bin/bash
set -e

echo "Generating Info.plist from template..."

if [ -z "$TMDB_API_KEY" ]; then
    echo "Error: TMDB_API_KEY environment variable is not set"
    exit 1
fi

sed "s/YOUR_API_KEY_HERE/${TMDB_API_KEY}/" "$CI_PRIMARY_REPOSITORY_PATH/Up Next/Info.plist.template" > "$CI_PRIMARY_REPOSITORY_PATH/Up Next/Info.plist"

echo "Info.plist generated successfully"
