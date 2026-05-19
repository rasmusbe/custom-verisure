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
UPSTREAM_SNAPSHOT_DIR="$ROOT_DIR/upstream_snapshot"

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
  log "Error: jq is required but not installed. Please install it to update JSON files."
  exit 1
fi

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

# Function to store an unpatched upstream snapshot for the next run's change detection
store_upstream_snapshot() {
  local upstream="$TEMP_DIR/homeassistant/components/verisure"
  log "Storing unpatched upstream snapshot..."
  if [ ! -d "$upstream" ]; then
    log "Error: Upstream verisure component not found in cloned repository"
    exit 1
  fi
  rm -rf "$UPSTREAM_SNAPSHOT_DIR"
  cp -r "$upstream" "$UPSTREAM_SNAPSHOT_DIR"
}

# Compare unpatched upstream against the last stored snapshot (before applying patches).
# Returns shell true when upstream changed and an update should run.
check_upstream_changes() {
  local upstream="$TEMP_DIR/homeassistant/components/verisure"

  if [ ! -d "$UPSTREAM_SNAPSHOT_DIR" ] || [ -z "$(ls -A "$UPSTREAM_SNAPSHOT_DIR" 2>/dev/null)" ]; then
    echo "No upstream snapshot found; treating as changed."
    return 0
  fi

  if diff -rq "$UPSTREAM_SNAPSHOT_DIR" "$upstream" >/dev/null 2>&1; then
    return 1
  fi

  echo "Upstream verisure component differs from last snapshot:"
  diff -rq "$UPSTREAM_SNAPSHOT_DIR" "$upstream" || true
  return 0
}

# Apply patches from patches directory (regenerates path layout first — not tracked in git)
apply_patches() {
  log "Rewriting patches/ paths for homeassistant/component layout..."
  if ! "$ROOT_DIR/scripts/regenerate_patch.sh"; then
    log "Error: regenerate_patch.sh failed"
    exit 1
  fi

  log "Applying patches..."
  cd "$TEMP_DIR/homeassistant/components"

  if [ ! -d "$ROOT_DIR/regenerated_patches" ] || [ ! "$(ls -A "$ROOT_DIR/regenerated_patches"/*.patch 2>/dev/null)" ]; then
    log "Error: No .patch files in patches/. Nothing to apply."
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

# Detect upstream changes before patches (patched vs unpatched comparison was a false positive)
if [ -d "$ROOT_DIR/custom_components/verisure" ]; then
  echo "Checking for upstream changes..."
  if check_upstream_changes; then
    echo "Changes detected in upstream component. Updating..."
  else
    echo "No changes detected in upstream component. Skipping update."
    rm -rf "$TEMP_DIR"
    exit 0
  fi
fi

store_upstream_snapshot

apply_patches

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

log "Update completed successfully"
