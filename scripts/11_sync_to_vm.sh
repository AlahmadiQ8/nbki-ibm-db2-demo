#!/usr/bin/env bash
#
# 11_sync_to_vm.sh — put the repo and the prepared data on the Db2 VM.
#
# Why rsync and not a blob staging account
# ----------------------------------------
# The original design staged through Azure Blob. That is not possible in this
# subscription: an `ASC DataProtection` policy assignment sets
# `publicNetworkAccess: Disabled` on every new storage account within about a
# minute of creation, and also sets `allowSharedKeyAccess: false`. The account
# becomes reachable only from inside a VNet through a private endpoint, and an
# attempt to re-enable public access is silently reverted. Key Vault gets the
# same treatment.
#
# A workstation therefore cannot write to it at all. Since the slow leg is this
# machine's upload either way, the blob hop bought nothing but a dependency, so
# the data goes straight to the VM over SSH. Recorded in docs/roadmap.md.
#
# What ships, and what does not:
#   * the working tree, so the VM runs the code being tested rather than
#     whatever is currently pushed to the branch
#   * data/prepared/  -- the six CSVs plus manifest.json, 1.7 GB
#   * csv-drop/incoming/ and csv-drop/manifest.json -- the fallback path
#   * db2/delta/      -- the incremental batch
#   * NOT data/raw/   -- 1.8 GB of Kaggle source that only 03_prepare.py reads,
#                        and 03_prepare.py has already run
#
# Paths are preserved exactly. 04_load.sh, 05_verify.sh and 09_reconcile.sh all
# compute their locations from REPO_ROOT and accept no override, so the layout on
# the VM has to mirror this one file for file.
#
# Usage:
#   ./scripts/11_sync_to_vm.sh            # sync, then verify checksums
#   ./scripts/11_sync_to_vm.sh --verify   # verify only, transfer nothing
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_DIR="${NBKI_SECRET_DIR:-${HOME}/.nbki-demo}"
# shellcheck source=/dev/null
source "${SECRET_DIR}/env.sh"

SSH_OPTS=(-i "${NBKI_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
# Reach the VM on whichever address the current posture allows. After
# ./infra/deploy.sh --lock-to-vpn the public address accepts nothing inbound, so
# using it here would fail with a timeout that looks like a dead VM.
DB2_HOST="${NBKI_DB2_HOST:-${NBKI_DB2_PUBLIC}}"
TARGET="${NBKI_ADMIN}@${DB2_HOST}"
REMOTE_ROOT=/opt/nbki

VERIFY_ONLY=0
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY=1

# The files whose integrity actually matters. Everything else is code and will
# fail loudly by itself if it arrives damaged.
DATA_FILES=(
  data/prepared/CUSTOMERS.csv
  data/prepared/CARDS.csv
  data/prepared/TRANSACTIONS.csv
  data/prepared/FRAUD_LABELS.csv
  data/prepared/AML_TRANSACTIONS.csv
  data/prepared/MCC_CODES.csv
  data/prepared/manifest.json
  csv-drop/manifest.json
)
while IFS= read -r f; do DATA_FILES+=("$f"); done < <(
  cd "${REPO_ROOT}" && find csv-drop/incoming -name '*.csv' -type f | sort
)
while IFS= read -r f; do DATA_FILES+=("$f"); done < <(
  cd "${REPO_ROOT}" && find db2/delta -type f \( -name '*.sql' -o -name '*.json' \) | sort
)

cd "${REPO_ROOT}"

if (( ! VERIFY_ONLY )); then
  echo "==> Checking the artefacts exist locally"
  missing=0
  for f in "${DATA_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "    MISSING  $f" >&2; missing=1; }
  done
  if (( missing )); then
    echo >&2
    echo "ERROR: gitignored artefacts are missing. Generate them first:" >&2
    echo "       ./scripts/03_prepare.py        -> data/prepared/" >&2
    echo "       ./scripts/06_make_delta.py     -> db2/delta/" >&2
    echo "       ./scripts/07_make_csv_drop.py  -> csv-drop/incoming/" >&2
    exit 1
  fi
  echo "    ${#DATA_FILES[@]} data artefacts present"

  # -z matters here. The payload is 1.7 GB of CSV, it compresses several times
  # over, and the bottleneck is a domestic uplink rather than either CPU.
  #
  # --progress, not --info=progress2. macOS ships openrsync advertising "rsync
  # version 2.6.9 compatible"; --info arrived in rsync 3.1 and is rejected
  # outright here. Same family as the BSD/GNU `seq` divergence already recorded
  # in the README: the script has to run on the machine it is actually on.
  echo "==> Syncing to ${TARGET}:${REMOTE_ROOT}  (1.7 GB compressed in flight)"
  rsync -az --partial --progress \
    --exclude '.git/' \
    --exclude '.venv/' \
    --exclude '__pycache__/' \
    --exclude 'data/raw/' \
    --exclude 'data/profile/' \
    --exclude '.DS_Store' \
    -e "ssh ${SSH_OPTS[*]}" \
    "${REPO_ROOT}/" "${TARGET}:${REMOTE_ROOT}/"
  echo
fi

# ---------------------------------------------------------------------------
# Verify. rsync does checksum each file it transfers, but --partial plus an
# interrupted run is exactly the case where a file can be left short, and a
# truncated 1.2 GB CSV looks identical to a good one until Db2 is eight minutes
# into a LOAD. Comparing digests costs a couple of minutes and removes the
# question entirely.
# ---------------------------------------------------------------------------
echo "==> Verifying checksums on both ends"
local_sums="$(mktemp)"
remote_sums="$(mktemp)"
trap 'rm -f "${local_sums}" "${remote_sums}"' EXIT

for f in "${DATA_FILES[@]}"; do
  shasum -a 256 "$f"
done | awk '{print $1"  "$2}' | sort -k2 > "${local_sums}"

printf '%s\n' "${DATA_FILES[@]}" \
  | ssh "${SSH_OPTS[@]}" "${TARGET}" "cd ${REMOTE_ROOT} && xargs sha256sum" \
  | awk '{print $1"  "$2}' | sort -k2 > "${remote_sums}"

if diff -u "${local_sums}" "${remote_sums}" > /tmp/nbki_sum_diff.txt; then
  echo "    ${#DATA_FILES[@]}/${#DATA_FILES[@]} match"
else
  echo >&2
  echo "ERROR: checksum mismatch between this machine and the VM." >&2
  echo "       Re-run ./scripts/11_sync_to_vm.sh -- rsync will resume." >&2
  head -30 /tmp/nbki_sum_diff.txt >&2
  exit 1
fi

echo
echo "==> Data is on the VM and verified"
echo "    Next: ./infra/start_db2.sh"
