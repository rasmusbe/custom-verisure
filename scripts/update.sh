#!/bin/bash

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)

# Clone only the latest commit (--depth 1) to save time and bandwidth
echo "Cloning Home Assistant repository..."
git clone --depth 1 --branch master https://github.com/home-assistant/core.git "$TEMP_DIR" >/dev/null 2>&1 || {
  echo "Error: Failed to clone Home Assistant repository"
  exit 1
}
echo "Home Assistant repository cloned successfully"

# Remove the verisure component if it exists
rm -rf "$ROOT_DIR/custom_components/verisure"

# Make sure the custom components directory exists
mkdir -p "$ROOT_DIR/custom_components"

# Copy the verisure component
cp -r "$TEMP_DIR/homeassistant/components/verisure" "$ROOT_DIR/custom_components/"

# Get version from core
VERSION=$(grep -E "^(MAJOR|MINOR|PATCH)_VERSION" "$TEMP_DIR/homeassistant/const.py" | cut -d'=' -f2 | tr -d ' "' | tr '\n' '.' | sed 's/\.$//')

# Export the version to global environment
export HOMEASSISTANT_VERSION=$VERSION

# Export the version to GitHub Actions environment if GITHUB_ENV is set
if [ -n "$GITHUB_ENV" ]; then
  echo "HOMEASSISTANT_VERSION=$HOMEASSISTANT_VERSION" >>"$GITHUB_ENV"
fi

# Update the homeassistant version in hacs.json using jq
if [ -f "$ROOT_DIR/hacs.json" ]; then
  # Create a temporary file for the new JSON
  TEMP_JSON=$(mktemp)
  jq --arg version "$VERSION" '.homeassistant = $version' "$ROOT_DIR/hacs.json" >"$TEMP_JSON"
  rm -f "$ROOT_DIR/hacs.json"
  mv "$TEMP_JSON" "$ROOT_DIR/hacs.json"
else
  echo "Warning: hacs.json not found"
fi

# Clean up
rm -rf "$TEMP_DIR"

CONST_FILE="$ROOT_DIR/custom_components/verisure/const.py"
if [ ! -f "$CONST_FILE" ]; then
  echo "Error: $CONST_FILE does not exist!"
  exit 1
fi

# Patch const.py to have tighter interval - compatible with both Linux and macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS requires an extension argument for -i
  sed -i '' "s/DEFAULT_SCAN_INTERVAL = timedelta(minutes=1)/DEFAULT_SCAN_INTERVAL = timedelta(seconds=30)/" "$CONST_FILE"
else
  # Linux version
  sed -i "s/DEFAULT_SCAN_INTERVAL = timedelta(minutes=1)/DEFAULT_SCAN_INTERVAL = timedelta(seconds=30)/" "$CONST_FILE"
fi
