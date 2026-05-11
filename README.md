# homeassistant-custom-verisure

Home Assistant’s upstream **Verisure** integration shipped as a [HACS](https://hacs.xyz/)-friendly custom component (`custom_components/verisure`). The tree tracks [home-assistant/core](https://github.com/home-assistant/core); durable local changes belong in **`patches/`**.

## Sync and patches

- **`patches/*.patch`** use paths **`custom_components/verisure/`** (source of truth in git).

- **`regenerated_patches/`** holds the same diffs rewritten to **`homeassistant/components/verisure/`** so `git apply` works against a core checkout. That directory is **gitignored** and produced automatically.

- **`./scripts/update.sh`** (used by CI) clones **`master`** from core, runs regeneration, applies all patches, copies the result into **`custom_components/verisure/`**, updates **`hacs.json`** and **`manifest.json`** `version`, and tightens the scan interval in **`const.py`**.

- **`./scripts/regenerate_patch.sh`** only regenerates into `regenerated_patches/`; use it if you want to inspect those files without running a full update.

To verify changes locally: install **`jq`**, then run `./scripts/update.sh` (requires network for the clone).

## CI

[`.github/workflows/sync-code.yml`](.github/workflows/sync-code.yml) runs `./scripts/update.sh` on a schedule and commits updates under **`custom_components/verisure`** when upstream or patch output changes. Commit **`patches/`** in pull requests when you change behavior that must survive the next sync.
