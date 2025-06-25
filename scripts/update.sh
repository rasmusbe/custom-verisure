#!/bin/bash

# Exit on error
set -e

# Function for cleanup
cleanup() {
  local exit_code=$?
  echo "Performing cleanup..."
  [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
  exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT

# Function for logging
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
ORIGINAL_FILES_DIR="$ROOT_DIR/original_files"

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
  log "Error: jq is required but not installed. Please install it to update JSON files."
  exit 1
fi

# Ensure original_files directory exists
mkdir -p "$ORIGINAL_FILES_DIR"

# Clone only the latest commit (--depth 1) to save time and bandwidth
log "Cloning Home Assistant repository..."
if ! git clone --depth 1 --branch master https://github.com/home-assistant/core.git "$TEMP_DIR" >/dev/null 2>&1; then
  log "Error: Failed to clone Home Assistant repository"
  exit 1
fi
log "Home Assistant repository cloned successfully"

# Get version from core
if ! VERSION=$(grep -E "^(MAJOR|MINOR|PATCH)_VERSION" "$TEMP_DIR/homeassistant/const.py" | cut -d'=' -f2 | tr -d ' "' | tr '\n' '.' | sed 's/\.$//'); then
  log "Error: Failed to extract version information"
  exit 1
fi

# Export the version to global environment
export HOMEASSISTANT_VERSION=$VERSION
log "Detected Home Assistant version: $VERSION"

# Export the version to GitHub Actions environment if GITHUB_ENV is set
if [ -n "$GITHUB_ENV" ]; then
  echo "HOMEASSISTANT_VERSION=$HOMEASSISTANT_VERSION" >>"$GITHUB_ENV"
  log "Version exported to GitHub Actions environment"
fi

# Function to store original files
store_original_files() {
  log "Storing original unpatched files..."
  if [ ! -f "$TEMP_DIR/homeassistant/components/verisure/const.py" ] || [ ! -f "$TEMP_DIR/homeassistant/components/verisure/manifest.json" ]; then
    log "Error: Source files not found in cloned repository"
    exit 1
  fi
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
  # Return 1 if we have changes, 0 if we don't
  [ $has_changes -eq 1 ]
  return $?
}

# Apply patches from patches directory
apply_patches() {
  log "Applying patches..."
  cd "$TEMP_DIR/homeassistant/components"

  # Only use regenerated patches
  if [ ! -d "$ROOT_DIR/regenerated_patches" ] || [ ! "$(ls -A "$ROOT_DIR/regenerated_patches"/*.patch 2>/dev/null)" ]; then
    log "Error: No regenerated patches found. Please run ./scripts/regenerate_patch.sh first"
    exit 1
  fi

  PATCH_DIR="$ROOT_DIR/regenerated_patches"
  log "Using regenerated patches from $PATCH_DIR"

  for patch in "$PATCH_DIR"/*.patch; do
    if [ -f "$patch" ]; then
      log "Applying patch: $patch"
      if ! git apply "$patch"; then
        log "Error: Failed to apply patch $patch"
        exit 1
      fi
    fi
  done
  cd "$ROOT_DIR"
}

# Apply patches to the upstream component before comparison
apply_patches

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
  TEMP_JSON=$(mktemp) || {
    log "Error: Failed to create temporary file"
    exit 1
  }
  jq --arg version "$VERSION" '.homeassistant = $version' "$ROOT_DIR/hacs.json" >"$TEMP_JSON"
  rm -f "$ROOT_DIR/hacs.json"
  mv "$TEMP_JSON" "$ROOT_DIR/hacs.json"
else
  echo "Warning: hacs.json not found"
fi

# Update version in manifest.json
MANIFEST_FILE="$ROOT_DIR/custom_components/verisure/manifest.json"
if [ -f "$MANIFEST_FILE" ]; then
  log "Updating version in manifest.json..."
  # Create a temporary file for the new JSON
  TEMP_JSON=$(mktemp)
  if ! jq --arg version "$VERSION" '. + {version: $version}' "$MANIFEST_FILE" >"$TEMP_JSON"; then
    log "Error: Failed to update manifest.json"
    exit 1
  fi
  rm -f "$MANIFEST_FILE"
  mv "$TEMP_JSON" "$MANIFEST_FILE"
fi

CONST_FILE="$ROOT_DIR/custom_components/verisure/const.py"
if [ ! -f "$CONST_FILE" ]; then
  log "Error: $CONST_FILE does not exist!"
  exit 1
fi

# Patch const.py to have tighter interval - compatible with both Linux and macOS
log "Updating scan interval in const.py..."
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS requires an extension argument for -i
  if ! sed -i '' "s/DEFAULT_SCAN_INTERVAL = timedelta(minutes=1)/DEFAULT_SCAN_INTERVAL = timedelta(seconds=15)/" "$CONST_FILE"; then
    log "Error: Failed to update scan interval"
    exit 1
  fi
else
  # Linux version
  if ! sed -i "s/DEFAULT_SCAN_INTERVAL = timedelta(minutes=1)/DEFAULT_SCAN_INTERVAL = timedelta(seconds=15)/" "$CONST_FILE"; then
    log "Error: Failed to update scan interval"
    exit 1
  fi
fi

log "Update completed successfully"
