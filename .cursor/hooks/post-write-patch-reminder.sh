#!/usr/bin/env bash
# postToolUse: after tools that write patches/, remind to run update locally.
set -euo pipefail

input=""
if ! input=$(cat); then
  echo "{}"
  exit 0
fi

path=""
tool_lower=""

if command -v jq >/dev/null 2>&1; then
  path=$(echo "$input" | jq -r '
    (
      .tool_input.relative_workspace_path //
      .tool_input.path //
      .tool_input.file_path //
      .tool_input.target_file //
      .tool_input.file //
      .input.relative_workspace_path //
      .input.path //
      .input.file_path //
      .input.target_file //
      empty
    ) | if . == null then "" else tostring end
  ' 2>/dev/null || echo "")

  tool_lower=$(echo "$input" | jq -r '
    (.tool_name // .tool // .name // "") | ascii_downcase
  ' 2>/dev/null || echo "")
fi

# Fallback: best-effort grep when jq is missing or returned empty path
if [[ -z "$path" ]]; then
  if [[ "$input" =~ patches/[^\"]+\.patch ]]; then
    path=$(printf '%s' "$input" | grep -oE 'patches/[^"]+\.patch' | head -n1 || true)
  fi
fi

is_under_patches_patch() {
  local p="$1"
  [[ "$p" == *.patch ]] || return 1
  [[ "$p" == patches/* ]] || [[ "$p" == */patches/* ]]
}

if [[ -z "$path" ]] || ! is_under_patches_patch "$path"; then
  echo "{}"
  exit 0
fi

# Allowlist write-like tools only (avoid noise on Read / search of patches/)
case "$tool_lower" in
  write | apply_patch | applypatch | search_replace | strreplace | replace | edit | patch)
    ;;
  *)
    echo "{}"
    exit 0
    ;;
esac

msg="Patch source updated (${path}). Run ./scripts/update.sh locally when you can (jq, git, network) so patches regenerate and apply cleanly. Optional: ./scripts/regenerate_patch.sh only inspects regenerated_patches/."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$msg" '{additional_context: $ctx}'
else
  printf '{"additional_context":"%s"}\n' "${msg//\"/\\\"}"
fi

exit 0
