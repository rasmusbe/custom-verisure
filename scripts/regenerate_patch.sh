#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES_DIR="$ROOT_DIR/patches"
# Generated layout for git apply onto homeassistant/core (gitignored; update.sh invokes this automatically)
REGENERATED_PATCHES_DIR="$ROOT_DIR/regenerated_patches"

mkdir -p "$REGENERATED_PATCHES_DIR"

# Drop previous outputs so renames/removals in patches/ do not leave stale .patch files.
find "$REGENERATED_PATCHES_DIR" -maxdepth 1 -name '*.patch' -delete

echo "Rewriting patch paths for all patches in $PATCHES_DIR..."

for patch_file in "$PATCHES_DIR"/*.patch; do
  [ -f "$patch_file" ] || continue
  patch_name=$(basename "$patch_file")
  out_patch="$REGENERATED_PATCHES_DIR/$patch_name"
  echo "Processing $patch_name"
  sed -e 's|custom_components/verisure/|homeassistant/components/verisure/|g' \
    "$patch_file" >"$out_patch"
  echo "Wrote $out_patch"
done

echo "All patch paths rewritten to $REGENERATED_PATCHES_DIR"
