#!/bin/bash

# Shared Home Assistant version helpers for update.sh and CI.

# Strip beta/dev suffixes from homeassistant/core const.py version strings.
# Examples: 2026.7.0b4 -> 2026.7.0, 2026.8.0.dev0 -> 2026.8.0
normalize_release_version() {
  local version=$1
  version=$(echo "$version" | sed -E 's/[bB][0-9]*$//')
  version=$(echo "$version" | sed -E 's/\.dev[0-9]*$//')
  echo "$version"
}

# True when PATCH_VERSION from core is beta or dev (not a stable release).
is_ha_prerelease_patch() {
  echo "$1" | grep -qE '[bB]|dev'
}

# True when a manifest/hacs version is safe to tag on GitHub (no beta/dev suffix).
is_release_ready_version() {
  if echo "$1" | grep -qE '[bB]|\.dev[0-9]*$'; then
    return 1
  fi
  return 0
}

# Read MAJOR/MINOR/PATCH from homeassistant/const.py into env vars.
read_ha_version_from_const() {
  local const_py=$1

  if ! HA_MAJOR=$(grep -E '^MAJOR_VERSION' "$const_py" | cut -d'=' -f2 | tr -d ' "'); then
    return 1
  fi
  if ! HA_MINOR=$(grep -E '^MINOR_VERSION' "$const_py" | cut -d'=' -f2 | tr -d ' "'); then
    return 1
  fi
  if ! HA_PATCH_RAW=$(grep -E '^PATCH_VERSION' "$const_py" | cut -d'=' -f2 | tr -d ' "'); then
    return 1
  fi

  HA_RAW_VERSION="${HA_MAJOR}.${HA_MINOR}.${HA_PATCH_RAW}"
  HA_RELEASE_VERSION=$(normalize_release_version "$HA_RAW_VERSION")
  if is_ha_prerelease_patch "$HA_PATCH_RAW"; then
    HA_IS_STABLE=false
  else
    HA_IS_STABLE=true
  fi
  return 0
}

export_ha_version_env() {
  if [ -n "$GITHUB_ENV" ]; then
    {
      echo "HA_RAW_VERSION=$HA_RAW_VERSION"
      echo "HA_RELEASE_VERSION=$HA_RELEASE_VERSION"
      echo "HA_IS_STABLE=$HA_IS_STABLE"
    } >>"$GITHUB_ENV"
  fi
}

update_version_files() {
  local root_dir=$1
  local release_version=$2

  if [ -f "$root_dir/hacs.json" ]; then
    local temp_json
    temp_json=$(mktemp)
    jq --arg version "$release_version" '.homeassistant = $version' "$root_dir/hacs.json" >"$temp_json"
    mv "$temp_json" "$root_dir/hacs.json"
  fi

  local manifest_file="$root_dir/custom_components/verisure/manifest.json"
  if [ -f "$manifest_file" ]; then
    local temp_json
    temp_json=$(mktemp)
    jq --arg version "$release_version" '. + {version: $version}' "$manifest_file" >"$temp_json"
    mv "$temp_json" "$manifest_file"
  fi
}
