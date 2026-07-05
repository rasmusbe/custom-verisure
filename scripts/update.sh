#!/bin/bash

# Exit on error
set -e

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/version.sh
source "$ROOT_DIR/scripts/version.sh"

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

if ! read_ha_version_from_const "$TEMP_DIR/homeassistant/const.py"; then
  log "Error: Failed to extract version information"
  exit 1
fi

export_ha_version_env
log "Detected Home Assistant version: $HA_RAW_VERSION (release: $HA_RELEASE_VERSION, stable: $HA_IS_STABLE)"

MIN_VSURE_VERSION="2.7.1"

# Returns shell true when $1 >= $2 (semver).
version_ge() {
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Returns shell true when upstream master has the Verisure session work we wait for.
check_upstream_readiness() {
  local upstream="$TEMP_DIR/homeassistant/components/verisure"
  local manifest="$upstream/manifest.json"
  local coordinator="$upstream/coordinator.py"

  if [ ! -f "$manifest" ] || [ ! -f "$coordinator" ]; then
    log "Upstream Verisure component incomplete; not ready for sync."
    return 1
  fi

  local vsure_req
  vsure_req=$(jq -r '.requirements[] | select(startswith("vsure"))' "$manifest")
  if [ -z "$vsure_req" ] || [ "$vsure_req" = "null" ]; then
    log "Upstream manifest has no vsure requirement; not ready for sync."
    return 1
  fi

  local vsure_version
  vsure_version=$(echo "$vsure_req" | sed -n 's/.*==\([0-9.]*\).*/\1/p')
  if [ -z "$vsure_version" ]; then
    log "Could not parse vsure version from: $vsure_req"
    return 1
  fi

  if ! version_ge "$vsure_version" "$MIN_VSURE_VERSION"; then
    log "Upstream pins vsure $vsure_version (need >= $MIN_VSURE_VERSION); not ready for sync."
    return 1
  fi

  if ! grep -q 'COOKIE_REFRESH_INTERVAL' "$coordinator" ||
    ! grep -q '_raise_rate_limited' "$coordinator"; then
    log "Upstream coordinator missing session-refresh behavior; not ready for sync."
    return 1
  fi

  return 0
}

skip_sync_upstream_not_ready() {
  log "Skipping sync: homeassistant/core master does not yet include required Verisure changes (expected in 2026.7.0)."
  if [ -n "$GITHUB_ENV" ]; then
    echo "VERISURE_SYNC_SKIPPED=true" >>"$GITHUB_ENV"
  fi
  rm -rf "$TEMP_DIR"
  TEMP_DIR=""
  exit 0
}

if ! check_upstream_readiness; then
  skip_sync_upstream_not_ready
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

manifest_needs_version_update() {
  local manifest_file="$ROOT_DIR/custom_components/verisure/manifest.json"
  local current_version normalized_current

  if [ ! -f "$manifest_file" ]; then
    return 1
  fi

  current_version=$(jq -r .version "$manifest_file")
  normalized_current=$(normalize_release_version "$current_version")

  if [ "$current_version" != "$normalized_current" ]; then
    log "Manifest has prerelease version $current_version; will normalize to $normalized_current."
    return 0
  fi

  if [ "$HA_IS_STABLE" = true ] && [ "$(printf '%s\n' "$current_version" "$HA_RELEASE_VERSION" | sort -V | tail -n1)" = "$HA_RELEASE_VERSION" ] && [ "$current_version" != "$HA_RELEASE_VERSION" ]; then
    log "Home Assistant stable release advanced to $HA_RELEASE_VERSION (manifest: $current_version)."
    return 0
  fi

  return 1
}

run_version_only_update() {
  local target_version=$1

  log "Updating version metadata only to $target_version..."
  update_version_files "$ROOT_DIR" "$target_version"

  if [ -n "$GITHUB_ENV" ]; then
    echo "VERISURE_UPDATE_MODE=version_only" >>"$GITHUB_ENV"
  fi

  rm -rf "$TEMP_DIR"
  TEMP_DIR=""
  log "Version-only update completed successfully"
  exit 0
}

# Detect upstream changes before patches (patched vs unpatched comparison was a false positive)
if [ -d "$ROOT_DIR/custom_components/verisure" ]; then
  echo "Checking for upstream changes..."
  if check_upstream_changes; then
    echo "Changes detected in upstream component. Updating..."
  elif manifest_needs_version_update; then
    current_version=$(jq -r .version "$ROOT_DIR/custom_components/verisure/manifest.json")
    target_version=$(normalize_release_version "$current_version")
    if [ "$HA_IS_STABLE" = true ]; then
      target_version="$HA_RELEASE_VERSION"
    fi
    run_version_only_update "$target_version"
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

log "Updating version metadata to $HA_RELEASE_VERSION..."
update_version_files "$ROOT_DIR" "$HA_RELEASE_VERSION"

log "Update completed successfully"

if [ -n "$GITHUB_ENV" ]; then
  echo "VERISURE_UPDATE_MODE=full" >>"$GITHUB_ENV"
fi
