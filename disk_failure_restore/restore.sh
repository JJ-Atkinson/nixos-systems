#!/usr/bin/env bash
# Restic restore runbook for the 2026-05-21 disk failure.
# This script handles Steps 3-5 from README.md (env setup, latest restore,
# layered gap-fill). Steps 1-2 (partitioning, mkfs) and Steps 6-7 (data
# placement, nixos-install) are manual — see README.md.
#
# Usage:
#   ./restore.sh /path/to/target     # restore into TARGET
#
# Required env (export before running, or the script will prompt):
#   SOPS_AGE_KEY_FILE — path to host age key (typically /tmp/age-key.txt)
#   FLAKE_PATH        — path to a checkout of nixos-systems (typically /etc/nixos
#                       once you have a working filesystem, or /tmp/flake on
#                       the rescue ISO)
#
# Optional env:
#   GAP_FILL_MODE     — "simple" (default) or "precise"
#                       simple   = layered --overwrite never; small risk of
#                                  resurrected deletions
#                       precise  = only fills paths in skipped-files.txt
#   RESTIC_CACHE_DIR  — defaults to /tmp/restic-cache
#   SNAPSHOTS         — space-separated list of older snapshots to gap-fill from.
#                       Defaults to "72f6264b 6ed1863f 64786595 557f18c5"

set -euo pipefail

LATEST_SNAPSHOT="${LATEST_SNAPSHOT:-f23d3e9a}"
DEFAULT_SNAPSHOTS="72f6264b 6ed1863f 64786595 557f18c5"
SNAPSHOTS="${SNAPSHOTS:-$DEFAULT_SNAPSHOTS}"
GAP_FILL_MODE="${GAP_FILL_MODE:-simple}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 <target-dir>" >&2
  echo "       $0 /mnt           # restore directly into mounted subvolumes" >&2
  echo "       $0 /recovery      # restore into staging dir for later move" >&2
  exit 64
fi
if [ ! -d "$TARGET" ]; then
  echo "error: target directory $TARGET does not exist" >&2
  exit 64
fi

# Resolve script dir so we can find skipped-files.txt sibling
HERE="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------------
# Step 3: set up restic environment
# ------------------------------------------------------------------

echo "==> Step 3: set up restic environment"

if [ -z "${SOPS_AGE_KEY_FILE:-}" ]; then
  echo "error: SOPS_AGE_KEY_FILE not set" >&2
  echo "       export SOPS_AGE_KEY_FILE=/tmp/age-key.txt (or wherever the host age key lives)" >&2
  exit 64
fi
if [ ! -r "$SOPS_AGE_KEY_FILE" ]; then
  echo "error: cannot read $SOPS_AGE_KEY_FILE" >&2
  exit 64
fi

if [ -z "${FLAKE_PATH:-}" ]; then
  echo "error: FLAKE_PATH not set" >&2
  echo "       export FLAKE_PATH=/etc/nixos  (or wherever this folder lives)" >&2
  exit 64
fi
RESTIC_YAML="$FLAKE_PATH/secrets/host_nixos/restic.yaml"
if [ ! -r "$RESTIC_YAML" ]; then
  echo "error: cannot read $RESTIC_YAML" >&2
  echo "       FLAKE_PATH must point at a checkout of nixos-systems" >&2
  exit 64
fi

for cmd in sops restic; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: $cmd not in PATH" >&2
    echo "       try: nix shell --extra-experimental-features 'nix-command flakes' nixpkgs#restic nixpkgs#sops" >&2
    exit 127
  fi
done

CREDS_FILE="$(mktemp)"
trap 'rm -f "$CREDS_FILE"' EXIT
chmod 600 "$CREDS_FILE"
sops --decrypt "$RESTIC_YAML" > "$CREDS_FILE"

export RESTIC_REPOSITORY=$(awk '/^remote_repo_uri:/ {print $2}' "$CREDS_FILE")
export RESTIC_PASSWORD=$(awk '/^remote_repo_secret:/ {print $2}' "$CREDS_FILE")
export RESTIC_CACHE_DIR
mkdir -p "$RESTIC_CACHE_DIR"

# Sanity check
if ! restic snapshots --latest 1 --no-lock >/dev/null 2>&1; then
  echo "error: restic cannot reach the repository" >&2
  echo "       repo: $(echo "$RESTIC_REPOSITORY" | sed 's|.*@||')" >&2
  echo "       check network and that the rest-server is up" >&2
  exit 1
fi
echo "    repo reachable: $(echo "$RESTIC_REPOSITORY" | sed 's|.*@||')"

# ------------------------------------------------------------------
# Step 4: restore the latest snapshot
# ------------------------------------------------------------------

echo
echo "==> Step 4: restore latest snapshot ($LATEST_SNAPSHOT) to $TARGET"
echo "    expected size: ~434 GiB; expected time: hours on 1 Gbps LAN"
echo
read -rp "Proceed? [y/N] " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit 1; }

sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,RESTIC_CACHE_DIR \
  restic restore "$LATEST_SNAPSHOT" --target "$TARGET" --overwrite always

# ------------------------------------------------------------------
# Step 5: gap-fill from older snapshots
# ------------------------------------------------------------------

echo
echo "==> Step 5: gap-fill from older snapshots ($GAP_FILL_MODE mode)"
echo "    snapshots: $SNAPSHOTS"

case "$GAP_FILL_MODE" in
  simple)
    for SNAP in $SNAPSHOTS; do
      echo
      echo "    ==> $SNAP"
      sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,RESTIC_CACHE_DIR \
        restic restore "$SNAP" --target "$TARGET" --overwrite never
    done
    ;;
  precise)
    GAP_LIST="$HERE/skipped-files.txt"
    if [ ! -r "$GAP_LIST" ]; then
      echo "error: gap list not found at $GAP_LIST" >&2
      exit 1
    fi
    echo "    using gap list: $GAP_LIST ($(wc -l <"$GAP_LIST") paths)"
    for SNAP in $SNAPSHOTS; do
      echo
      echo "    ==> $SNAP"
      sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,RESTIC_CACHE_DIR \
        restic restore "$SNAP" --target "$TARGET" \
          --include-file "$GAP_LIST" --overwrite never
    done

    echo
    echo "==> Audit: paths from gap list still missing in $TARGET"
    MISSING="$(mktemp)"
    while IFS= read -r p; do
      [ -e "${TARGET}${p}" ] || echo "$p"
    done < "$GAP_LIST" > "$MISSING"
    echo "    $(wc -l <"$MISSING") paths still missing — logged to $MISSING"
    head -10 "$MISSING"
    ;;
  *)
    echo "error: unknown GAP_FILL_MODE: $GAP_FILL_MODE (must be 'simple' or 'precise')" >&2
    exit 64
    ;;
esac

echo
echo "==> done. Next steps (manual — see README.md):"
echo "    Step 6: move data into subvolume layout (if you restored into staging)"
echo "    Step 7: clone fresh /etc/nixos from GitHub, run nixos-install"
echo "    Verification checklist: see README.md"
