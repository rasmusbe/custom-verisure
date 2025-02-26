#!/bin/bash

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
ORIGINAL_FILES_DIR="$ROOT_DIR/original_files"

# Ensure original_files directory exists
mkdir -p "$ORIGINAL_FILES_DIR"

# Clone only the latest commit (--depth 1) to save time and bandwidth
echo "Cloning Home Assistant repository..."
git clone --depth 1 --branch master https://github.com/home-assistant/core.git "$TEMP_DIR" >/dev/null 2>&1 || {
  echo "Error: Failed to clone Home Assistant repository"
  exit 1
}
echo "Home Assistant repository cloned successfully"

# Get version from core
VERSION=$(grep -E "^(MAJOR|MINOR|PATCH)_VERSION" "$TEMP_DIR/homeassistant/const.py" | cut -d'=' -f2 | tr -d ' "' | tr '\n' '.' | sed 's/\.$//')

# Export the version to global environment
export HOMEASSISTANT_VERSION=$VERSION

# Export the version to GitHub Actions environment if GITHUB_ENV is set
if [ -n "$GITHUB_ENV" ]; then
  echo "HOMEASSISTANT_VERSION=$HOMEASSISTANT_VERSION" >>"$GITHUB_ENV"
fi

# Function to store original files
store_original_files() {
  echo "Storing original unpatched files..."
  rm -f "$ORIGINAL_FILES_DIR/const.py" "$ORIGINAL_FILES_DIR/manifest.json"
  cp "$TEMP_DIR/homeassistant/components/verisure/const.py" "$ORIGINAL_FILES_DIR/const.py"
  cp "$TEMP_DIR/homeassistant/components/verisure/manifest.json" "$ORIGINAL_FILES_DIR/manifest.json"
}

# Function to check if component has changed
check_component_changes() {
  local has_changes=0

  if [ ! -f "$ORIGINAL_FILES_DIR/const.py" ] || [ ! -f "$ORIGINAL_FILES_DIR/manifest.json" ]; then
    echo "Original files not found. Storing new version..."
    store_original_files
    return 0
  fi

  # Create temporary directory for comparison
  local COMP_DIR
  COMP_DIR=$(mktemp -d)
  cp -r "$ROOT_DIR/custom_components/verisure" "$COMP_DIR/"

  # Restore original files for comparison
  rm -f "$COMP_DIR/verisure/manifest.json" "$COMP_DIR/verisure/const.py"
  cp "$ORIGINAL_FILES_DIR/const.py" "$COMP_DIR/verisure/const.py"
  cp "$ORIGINAL_FILES_DIR/manifest.json" "$COMP_DIR/verisure/manifest.json"

  diff -r "$COMP_DIR/verisure" "$TEMP_DIR/homeassistant/components/verisure" >/dev/null 2>&1
  local diff_result=$?
  if [ $diff_result -ne 0 ]; then
    echo "Changes found:"
    has_changes=1
  fi

  rm -rf "$COMP_DIR"
  # Return 0 if we have changes, 1 if we don't
  [ $has_changes -eq 1 ]
  return $?
}

# Check if component exists and if there are changes
if [ -d "$ROOT_DIR/custom_components/verisure" ]; then
  echo "Checking for upstream changes..."
  if check_component_changes; then
    echo "Changes detected in upstream component. Updating..."
  else
    echo "No changes detected in upstream component. Skipping update."
    rm -rf "$TEMP_DIR"
    exit 0
  fi
fi

# Store original files before any modifications
store_original_files

# Remove the verisure component if it exists
rm -rf "$ROOT_DIR/custom_components/verisure"

# Make sure the custom components directory exists
mkdir -p "$ROOT_DIR/custom_components"

# Copy the verisure component
cp -r "$TEMP_DIR/homeassistant/components/verisure" "$ROOT_DIR/custom_components/"

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

# Update version in manifest.json
MANIFEST_FILE="$ROOT_DIR/custom_components/verisure/manifest.json"
if [ -f "$MANIFEST_FILE" ]; then
  # Create a temporary file for the new JSON
  TEMP_JSON=$(mktemp)
  jq --arg version "$VERSION" '. + {version: $version}' "$MANIFEST_FILE" >"$TEMP_JSON"
  rm -f "$MANIFEST_FILE"
  mv "$TEMP_JSON" "$MANIFEST_FILE"
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
  sed -i '' "s/DEFAULT_SCAN_INTERVAL = timedelta(minutes=1)/DEFAULT_SCAN_INTERVAL = timedelta(seconds=15)/" "$CONST_FILE"
else
  # Linux version
  sed -i "s/DEFAULT_SCAN_INTERVAL = timedelta(minutes=1)/DEFAULT_SCAN_INTERVAL = timedelta(seconds=15)/" "$CONST_FILE"
fi
