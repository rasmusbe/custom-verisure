#!/bin/bash

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)

# Clone only the latest commit (--depth 1) to save time and bandwidth
git clone --depth 1 --branch master https://github.com/home-assistant/core.git "$TEMP_DIR"

# Make sure the custom components directory exists
mkdir -p "$ROOT_DIR/custom_components"

# Copy the verisure component
cp -r "$TEMP_DIR/homeassistant/components/verisure" "$ROOT_DIR/custom_components/"

# Get version from core
VERSION=$(grep -E "^(MAJOR|MINOR|PATCH)_VERSION" "$TEMP_DIR/homeassistant/const.py" | cut -d'=' -f2 | tr -d ' "' | tr '\n' '.' | sed 's/\.$//')
echo "Core version: $VERSION"

# Export the version
export HOMEASSISTANT_VERSION=$VERSION

# Clean up
rm -rf "$TEMP_DIR"

# Debug: Print file path and check if it exists
CONST_FILE="$ROOT_DIR/custom_components/verisure/const.py"
echo "Checking file: $CONST_FILE"
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
