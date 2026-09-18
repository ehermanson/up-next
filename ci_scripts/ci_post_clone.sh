#!/bin/bash
set -e

echo "Generating Info.plist from template..."

if [ -z "$TMDB_API_KEY" ]; then
    echo "Error: TMDB_API_KEY environment variable is not set"
    exit 1
fi

# Parse the plist rather than interpolating credentials into shell/sed expressions.
python3 - <<'PYTHON'
import os
from pathlib import Path
import plistlib
root = Path(os.environ["CI_PRIMARY_REPOSITORY_PATH"])
template = root / "Up Next/Info.plist.template"
config = plistlib.loads(template.read_bytes())
config["TMDB_API_KEY"] = os.environ["TMDB_API_KEY"]
config["TYPESAFE_API_KEY"] = os.environ.get("TYPESAFE_API_KEY", "")
(root / "Up Next/Info.plist").write_bytes(plistlib.dumps(config, sort_keys=False))
PYTHON
if [ -z "$TYPESAFE_API_KEY" ]; then
    echo "TYPESAFE_API_KEY is unset; Collections will use TMDB recommendations."
fi

echo "Info.plist generated successfully"

# Auto-set build number from Xcode Cloud.
# Marketing version is managed manually in Xcode (General > Identity > Version).
# To release a new version, update MARKETING_VERSION in the project, commit, and push.

if [ -z "$CI_BUILD_NUMBER" ]; then
    echo "ERROR: CI_BUILD_NUMBER is not set!"
    exit 1
fi

PBXPROJ="$CI_PRIMARY_REPOSITORY_PATH/Up Next.xcodeproj/project.pbxproj"

echo "Setting build number to $CI_BUILD_NUMBER..."
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER/" "$PBXPROJ"

grep "MARKETING_VERSION" "$PBXPROJ"
grep "CURRENT_PROJECT_VERSION" "$PBXPROJ"
