#!/bin/bash
# Version-field consistency check: the four version fields in project.yml
# must agree, else the packaged IPA reports a version that disagrees with
# the marketing release. Exits non-zero with a diff-style report on drift.

set -euo pipefail

cd "$(dirname "$0")/.."

YML="project.yml"
[ -f "$YML" ] || { echo "ERROR: $YML not found"; exit 1; }

# Extract the value of a YAML field from the settings/base section
# (the project.yml structure we maintain).
yml_value() {
  local key="$1"
  grep -E "^        $key:" "$YML" | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | head -1
}

MARKETING=$(yml_value MARKETING_VERSION)
BUILD=$(yml_value CURRENT_PROJECT_VERSION)
MARKETING_PLIST=$(yml_value CFBundleShortVersionString)
BUILD_PLIST=$(yml_value CFBundleVersion)

if [[ "$MARKETING" != "$MARKETING_PLIST" ]]; then
    echo "ERROR: MARKETING_VERSION ($MARKETING) != CFBundleShortVersionString ($MARKETING_PLIST)"
    exit 1
fi
if [[ "$BUILD" != "$BUILD_PLIST" ]]; then
    echo "ERROR: CURRENT_PROJECT_VERSION ($BUILD) != CFBundleVersion ($BUILD_PLIST)"
    exit 1
fi
echo "version-check: $MARKETING / $BUILD OK"
