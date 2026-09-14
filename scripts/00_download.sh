#!/usr/bin/env bash
#
# 00_download.sh — fetch the two source datasets from Kaggle.
#
# Nothing in this repo redistributes the data. We only script the download, so
# each user pulls it under the licence Kaggle serves it with.
#
#   computingvictor/transactions-fraud-datasets  Apache-2.0        ~1.4 GB
#   ealtman2019/ibm-transactions-...-aml         CDLA-Sharing-1.0  size varies by variant
#
# Usage:
#   ./scripts/00_download.sh                 # primary + AML HI-Small (default)
#   ./scripts/00_download.sh --primary-only  # skip the AML set entirely
#   ./scripts/00_download.sh --aml HI-Medium # dial up volume (~32M rows)
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_DIR="${REPO_ROOT}/data/raw"

PRIMARY_DS="computingvictor/transactions-fraud-datasets"
AML_DS="ealtman2019/ibm-transactions-for-anti-money-laundering-aml"

AML_VARIANT="HI-Small"
PRIMARY_ONLY=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary-only) PRIMARY_ONLY=1; shift ;;
    --aml)          AML_VARIANT="${2:?--aml needs a variant}"; shift 2 ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# HI = higher illicit ratio, LI = lower. Large is deliberately absent from the
# recommended set: Db2 Community Edition is capped at 4 cores / 16 GB and 180M
# rows is not a sensible target for it.
case "${AML_VARIANT}" in
  HI-Small|LI-Small|HI-Medium|LI-Medium) ;;
  HI-Large|LI-Large)
    echo "WARNING: ${AML_VARIANT} is ~180M rows. Db2 Community Edition is capped at" >&2
    echo "         4 cores / 16 GB. This is very unlikely to be a good idea." >&2
    ;;
  *) echo "unrecognised AML variant: ${AML_VARIANT}" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Preflight: fail fast and tell the user exactly how to fix it.
# ---------------------------------------------------------------------------

# Prefer a repo-local venv. The advice below tells you to create one, so it
# would be perverse not to look in it — without this the script recommends a fix
# and then fails to notice you applied it.
KAGGLE_BIN=""
if [[ -x "${REPO_ROOT}/.venv/bin/kaggle" ]]; then
  KAGGLE_BIN="${REPO_ROOT}/.venv/bin/kaggle"
elif command -v kaggle >/dev/null 2>&1; then
  KAGGLE_BIN="$(command -v kaggle)"
fi

if [[ -z "${KAGGLE_BIN}" ]]; then
  cat >&2 <<'EOF'
ERROR: the `kaggle` CLI was not found, on PATH or in ./.venv.

  python3 -m venv .venv && ./.venv/bin/pip install kaggle

This script picks up ./.venv/bin/kaggle automatically, so you do not need to
activate anything afterwards.

EOF
  exit 1
fi
echo "    using ${KAGGLE_BIN}"

CRED_FILE=""
CRED_KIND=""
# Kaggle has two credential formats in the wild and they are not interchangeable:
#   kaggle.json      legacy API token   {"username": ..., "key": ...}
#   credentials.json newer `kaggle auth login` (OAuth) {"access_token": ...}
# Checking only for the legacy name rejects a perfectly good OAuth login.
if [[ -f "${HOME}/.kaggle/kaggle.json" ]]; then
  CRED_FILE="${HOME}/.kaggle/kaggle.json"; CRED_KIND="legacy API token"
elif [[ -f "${HOME}/.kaggle/credentials.json" ]]; then
  CRED_FILE="${HOME}/.kaggle/credentials.json"; CRED_KIND="OAuth login"
fi

if [[ -z "${CRED_FILE}" && -z "${KAGGLE_USERNAME:-}" ]]; then
  cat >&2 <<EOF
ERROR: no Kaggle credentials found.

Looked for:
  ~/.kaggle/kaggle.json        (Settings -> API -> "Create New Token")
  ~/.kaggle/credentials.json   (produced by: kaggle auth login)
  KAGGLE_USERNAME + KAGGLE_KEY in the environment

Either route works. The quickest is:
  ./.venv/bin/kaggle auth login

Do not paste the token into a chat window or commit it. It is a bearer
credential for your whole Kaggle account.

EOF
  exit 1
fi

if [[ -n "${CRED_FILE}" ]]; then
  echo "    credential file: ${CRED_FILE} (${CRED_KIND})"

  if ! python3 -c "
import json, sys
try:
    d = json.load(open('${CRED_FILE}'))
except Exception as e:
    sys.exit(f'not valid JSON: {e}')
# Accept either format; require the fields that format actually uses.
if d.get('key'):
    if not d.get('username'):
        sys.exit(\"legacy token file has 'key' but no 'username'\")
elif d.get('access_token'):
    exp = d.get('access_token_expiration')
    if exp:
        import datetime
        try:
            when = datetime.datetime.fromtimestamp(float(exp))
            if when < datetime.datetime.now():
                print(f'    NOTE: access token expired {when:%Y-%m-%d %H:%M}; '
                      'the CLI should refresh it automatically.')
        except (TypeError, ValueError, OSError):
            pass
else:
    sys.exit(\"no 'key' and no 'access_token' — unrecognised credential format\")
"; then
    echo "ERROR: ${CRED_FILE} is present but unusable (see above)." >&2
    echo "       Re-authenticate with: ./.venv/bin/kaggle auth login" >&2
    exit 1
  fi

  perms="$(stat -f '%Lp' "${CRED_FILE}" 2>/dev/null || stat -c '%a' "${CRED_FILE}" 2>/dev/null || echo '')"
  if [[ -n "${perms}" && "${perms}" != "600" ]]; then
    echo "    NOTE: ${CRED_FILE} is mode ${perms}; tightening to 600"
    chmod 600 "${CRED_FILE}"
  fi
fi

echo "==> Checking Kaggle credentials"
# Two traps here, both found by testing with a deliberately invalid token:
#
#   1. The Kaggle CLI exits 0 even when authentication fails. Checking $? tells
#      you nothing; the failure is only in the output text.
#   2. Most read-only endpoints work anonymously. `datasets list` and
#      `datasets files` both succeed with a garbage token, and
#      `datasets list --mine` cheerfully reports "No datasets found" — which
#      looks like an empty account rather than a rejected credential.
#
# `competitions list` is the cheap call that genuinely requires auth, so that is
# what we probe, and we read its output rather than its exit status.
auth_out="$("${KAGGLE_BIN}" competitions list --page-size 1 2>&1 || true)"
if grep -qiE 'authentication required|401|403|unauthorized|invalid.*(key|token)' <<< "${auth_out}"; then
  echo "ERROR: Kaggle rejected the credentials." >&2
  echo >&2
  sed 's/^/       /' >&2 <<< "${auth_out}"
  echo >&2
  echo "       The token is missing or stale. Create a new one at" >&2
  echo "       kaggle.com -> Settings -> API -> 'Create New Token'. Clicking" >&2
  echo "       'Expire API Token' invalidates every previously issued token." >&2
  exit 1
fi
echo "    credentials OK"

mkdir -p "${RAW_DIR}"

# ---------------------------------------------------------------------------
# Provenance guard.
#
# The fixture generator writes to the same paths with the same filenames, on
# purpose — it means the rest of the pipeline needs no special cases. The
# consequence is that a naive "is the file already there?" check would see
# synthetic data, skip the download, and leave you profiling fixtures while
# believing you had the real thing. That is the kind of mistake that is only
# discovered in front of the customer.
# ---------------------------------------------------------------------------
PROVENANCE="${RAW_DIR}/.provenance"

if [[ -f "${PROVENANCE}" ]] && grep -q '"source": *"fixtures"' "${PROVENANCE}"; then
  echo "ERROR: ${RAW_DIR} currently holds SYNTHETIC FIXTURE data." >&2
  echo "       Downloading on top of it would leave a mix of real and fake rows." >&2
  echo >&2
  echo "       Clear it first:  rm -rf ${RAW_DIR}" >&2
  echo "       Then re-run this script." >&2
  exit 1
fi


# ---------------------------------------------------------------------------
# Primary — computingvictor. Relational: users -> cards -> transactions.
# ---------------------------------------------------------------------------

echo "==> Primary: ${PRIMARY_DS}"
PRIMARY_DIR="${RAW_DIR}/computingvictor"
mkdir -p "${PRIMARY_DIR}"

# Check for every file we actually need, not just one. A partial or interrupted
# download otherwise looks complete.
PRIMARY_FILES=(users_data.csv cards_data.csv transactions_data.csv
               mcc_codes.json train_fraud_labels.json)
PRIMARY_MISSING=0
for f in "${PRIMARY_FILES[@]}"; do
  [[ -f "${PRIMARY_DIR}/${f}" ]] || PRIMARY_MISSING=1
done

if [[ "${PRIMARY_MISSING}" -eq 0 && "${FORCE}" -eq 0 ]]; then
  echo "    all 5 files already present, skipping (--force to re-download)"
else
  # --unzip leaves the CSVs in place. Kaggle downloads are resumable; if this is
  # interrupted, re-running picks up where it left off.
  "${KAGGLE_BIN}" datasets download -d "${PRIMARY_DS}" -p "${PRIMARY_DIR}" --unzip
fi

# ---------------------------------------------------------------------------
# Secondary — IBM AML. A single wide table, used only to dial up volume.
# ---------------------------------------------------------------------------

if [[ "${PRIMARY_ONLY}" -eq 1 ]]; then
  echo "==> Skipping AML set (--primary-only)"
else
  echo "==> Secondary: ${AML_DS} [${AML_VARIANT}]"
  AML_DIR="${RAW_DIR}/aml"
  mkdir -p "${AML_DIR}"
  AML_FILE="${AML_VARIANT}_Trans.csv"

  if [[ -f "${AML_DIR}/${AML_FILE}" && "${FORCE}" -eq 0 ]]; then
    echo "    already present, skipping (--force to re-download)"
  else
    # Pull only the one variant we need. The full dataset is ~41 GB and there is
    # no reason to fetch all six sizes.
    "${KAGGLE_BIN}" datasets download -d "${AML_DS}" -f "${AML_FILE}" -p "${AML_DIR}"

    # Single-file downloads sometimes arrive zipped and sometimes do not,
    # depending on CLI version and file size. Handle both.
    if [[ -f "${AML_DIR}/${AML_FILE}.zip" ]]; then
      unzip -o -q "${AML_DIR}/${AML_FILE}.zip" -d "${AML_DIR}"
      rm -f "${AML_DIR}/${AML_FILE}.zip"
    fi
  fi
fi

echo
echo "==> Done. Contents of ${RAW_DIR}:"
find "${RAW_DIR}" -type f \( -name '*.csv' -o -name '*.json' -o -name '*.txt' \) \
  -exec ls -lh {} \; | awk '{printf "    %-10s %s\n", $5, $NF}'

# Record where this data came from, so nothing downstream has to guess and so a
# later fixture run cannot quietly overwrite real data without it being obvious.
cat > "${PROVENANCE}" <<JSON
{
  "source": "kaggle",
  "downloaded_by": "scripts/00_download.sh",
  "primary_dataset": "${PRIMARY_DS}",
  "aml_dataset": "${AML_DS}",
  "aml_variant": "${AML_VARIANT}",
  "downloaded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

echo
echo "Next: ./scripts/01_profile.py   (profile before writing any DDL)"
echo
echo "Expect the profiler to report differences from the fixture assumptions."
echo "That is what it is for. Re-run ./scripts/02_generate_ddl.py afterwards and"
echo "read its warnings before loading anything."
