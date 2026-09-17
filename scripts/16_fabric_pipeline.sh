#!/usr/bin/env bash
#
# 16_fabric_pipeline.sh — export and re-create Fabric Data Factory pipelines.
#
# Why this exists
# ---------------
# The Copy activity that reads Db2 is the one artefact of this demo that is
# quickest to BUILD in the portal and most dangerous to leave there. Built by
# hand, it lives only in a workspace: nobody can review it, it is not in the
# repo, and rebuilding it before a customer session means clicking through the
# Copy assistant again and hoping the settings match.
#
# So: build it once in the portal, export it here, commit the JSON. After that it
# is reviewable, diffable, and can be recreated into a clean workspace in one
# command.
#
# Exporting rather than hand-authoring is deliberate. The pipeline schema for a
# Db2 source -- the exact spelling of the source type, how the connection is
# referenced, how the Lakehouse sink is addressed -- is not documented in a form
# worth guessing at, and a wrong guess produces a pipeline that is accepted by
# the API and fails at runtime. Let the portal emit it, then keep what it emits.
#
# Handles both item types that can carry a Copy: DataPipeline and CopyJob. The
# Copy job wizard is the quicker way to build one and produces a CopyJob item,
# not a pipeline -- so a tool that only knew about pipelines would report "not
# found" for something plainly visible in the workspace.
#
# Usage:
#   ./scripts/16_fabric_pipeline.sh --list
#   ./scripts/16_fabric_pipeline.sh --export "pl_bronze_customers"
#   ./scripts/16_fabric_pipeline.sh --create fabric/cj_bronze_db2.json "cj_name" [CopyJob|DataPipeline]
#   ./scripts/16_fabric_pipeline.sh --run    "cj_bronze_db2"
#   ./scripts/16_fabric_pipeline.sh --delete "cj_name"
#   ./scripts/16_fabric_pipeline.sh --verify-restore fabric/cj_bronze_db2.json
#   ./scripts/16_fabric_pipeline.sh --reland fabric/cj_bronze_db2.json "cj_bronze_db2"
#
# --reland deletes, recreates and runs. A CDC Copy job only does a full
# snapshot on its FIRST run, and the incremental path fails against Db2, so
# recreating is how you get a clean re-land.
#
# --verify-restore creates the item from the committed file, reads the
# definition back, compares, and deletes it. It never RUNS the item: an exported
# definition still points at the real lakehouse, so running a "test" copy could
# truncate or re-land verified bronze.
#
# Environment:
#   NBKI_FABRIC_WORKSPACE   workspace GUID (defaults to the demo workspace)
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${NBKI_FABRIC_WORKSPACE:-5c84bcc5-f497-4eac-b59b-5c2a36bec619}"
OUT_DIR="${REPO_ROOT}/fabric"
# Minutes to wait in --run before giving up. The Copy job policy allows 12h.
NBKI_RUN_TIMEOUT_MIN="${NBKI_RUN_TIMEOUT_MIN:-720}"
API="https://api.fabric.microsoft.com/v1"

# curl -f prints nothing but the status line on an HTTP error, and the Fabric
# API puts the only useful information in the RESPONSE BODY. `CapacityNotActive`
# -- a paused F-SKU, which this tenant does that on a schedule -- arrives as a
# bare "404", which reads like a wrong workspace id or a bad token and sends you
# looking in entirely the wrong place.
#
# So: no -f on the calls that can fail this way. Show the body, then fail.
api_post() {
  local url="$1"; shift
  local out code
  out="$(curl -sS -w '\n%{http_code}' -X POST \
          -H "Authorization: Bearer $(token)" "$@" "${url}")"
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [[ "${code}" != 2* ]]; then
    echo "ERROR: POST ${url} returned HTTP ${code}" >&2
    echo "${out}" >&2
    if grep -q 'CapacityNotActive' <<< "${out}"; then
      echo >&2
      echo "       The Fabric capacity is PAUSED. Resume it:" >&2
      echo "         az resource show -g fabric-playground-sweden -n momof8sweden \\" >&2
      echo "           --resource-type Microsoft.Fabric/capacities --query properties.state -o tsv" >&2
      echo "         az rest --method post --url \"https://management.azure.com/subscriptions/\$(az account show --query id -o tsv)/resourceGroups/fabric-playground-sweden/providers/Microsoft.Fabric/capacities/momof8sweden/resume?api-version=2023-11-01\"" >&2
    fi
    return 1
  fi
  printf '%s' "${out}"
}

token() {
  az account get-access-token --resource https://api.fabric.microsoft.com \
    --query accessToken -o tsv
}

# Find a DataPipeline item by display name. Fails loudly rather than returning
# an empty string, because an empty id in a URL produces a 404 that reads like
# the API is broken rather than like a typo.
pipeline_id() {
  local name="$1" id
  id="$(curl -fsS -H "Authorization: Bearer $(token)" "${API}/workspaces/${WS}/items" \
        | python3 -c "
import json,sys
name=sys.argv[1]
for i in json.load(sys.stdin).get('value',[]):
    if i.get('displayName')==name and i.get('type') in ('DataPipeline','CopyJob'):
        print(i['id']); break
" "${name}")"
  if [[ -z "${id}" ]]; then
    echo "ERROR: no DataPipeline named '${name}' in workspace ${WS}." >&2
    echo "       ./scripts/16_fabric_pipeline.sh --list" >&2
    exit 1
  fi
  printf '%s' "${id}"
}

case "${1:-}" in
  --list)
    curl -fsS -H "Authorization: Bearer $(token)" "${API}/workspaces/${WS}/items" \
      | python3 -c "
import json,sys
v=[i for i in json.load(sys.stdin).get('value',[]) if i.get('type') in ('DataPipeline','CopyJob')]
print(f'{len(v)} copy item(s) in the workspace')
for i in v: print(f\"  {i['type']:<13} {i['displayName']:<28} {i['id']}\")
"
    ;;

  --export)
    name="${2:?usage: --export <pipeline display name>}"
    id="$(pipeline_id "${name}")"
    mkdir -p "${OUT_DIR}"
    # getDefinition is a POST, not a GET -- an easy half hour to lose.
    curl -fsS -X POST -H "Authorization: Bearer $(token)" -H "Content-Length: 0" \
      "${API}/workspaces/${WS}/items/${id}/getDefinition" \
      | python3 -c "
import base64, json, pathlib, sys
d=json.load(sys.stdin)
parts=d.get('definition',{}).get('parts',[])
# DataPipeline emits pipeline-content.json; CopyJob emits copyjob-content.json.
part=next((p for p in parts if p['path'].endswith(('pipeline-content.json','copyjob-content.json'))), None)
if not part:
    sys.exit('no content part in the definition; parts were: %s' % [p['path'] for p in parts])
content=json.loads(base64.b64decode(part['payload']))
out=pathlib.Path(sys.argv[1])
out.write_text(json.dumps(content, indent=2) + '\n')
print('wrote', out)
" "${OUT_DIR}/${name}.json"
    echo "    commit it: git add fabric/${name}.json"
    ;;

  --create)
    file="${2:?usage: --create <file.json> <display name> [item type]}"
    name="${3:?usage: --create <file.json> <display name> [item type]}"
    itype="${4:-}"
    [[ -f "${file}" ]] || { echo "ERROR: ${file} not found" >&2; exit 1; }

    # The exported artefact is the *content* part only -- it does not record
    # which kind of item produced it, and the two kinds need different values
    # for both `type` and the definition part `path`. Posting a CopyJob
    # definition as a DataPipeline fails in a way that never mentions the type.
    #
    # So: infer it structurally, and let the caller override. A CopyJob's
    # content carries `activities` as a SIBLING of `properties`; a
    # DataPipeline's activities live INSIDE `properties`.
    if [[ -z "${itype}" ]]; then
      itype="$(python3 - "${file}" <<'INFER'
import json, sys
d = json.load(open(sys.argv[1]))
print("CopyJob" if "activities" in d else "DataPipeline")
INFER
)"
      echo "==> inferred item type: ${itype}  (override with a 4th argument)"
    fi
    # Each item type has its OWN create endpoint. Posting a CopyJob to the
    # generic /items collection returns a bare 404 -- which reads like a wrong
    # workspace id or an expired token, and sends you looking in the wrong place
    # entirely. /items is fine for reading and deleting; only create is typed.
    case "${itype}" in
      CopyJob)      part_path="copyjob-content.json";  create_url="${API}/workspaces/${WS}/copyJobs" ;;
      DataPipeline) part_path="pipeline-content.json"; create_url="${API}/workspaces/${WS}/dataPipelines" ;;
      *) echo "ERROR: item type must be CopyJob or DataPipeline, got '${itype}'" >&2; exit 1 ;;
    esac

    payload="$(base64 < "${file}" | tr -d '\n')"
    # No "type" field: the typed endpoint already knows what it is creating, and
    # sending it is rejected.
    body="$(python3 - "${name}" "${part_path}" "${payload}" <<'BODY'
import json, sys
name, part_path, payload = sys.argv[1:4]
print(json.dumps({
    "displayName": name,
    "definition": {"parts": [
        {"path": part_path, "payload": payload, "payloadType": "InlineBase64"}]}}))
BODY
)"
    api_post "${create_url}" -H "Content-Type: application/json" \
      -d "${body}" | python3 -m json.tool
    ;;

  --reland)
    # Delete, recreate and run -- the only reliable way to re-land bronze.
    #
    # A Copy job in CDC mode runs its initial snapshot on the FIRST run and
    # takes the incremental path on every run after that. The incremental path
    # fails against Db2 (see scripts/19_make_bronze_copyjob.py for the minimal
    # reproduction), so the job is effectively single-use. Recreating it resets
    # it to "never run", and the next run is a clean full snapshot.
    #
    # Deleting a Fabric item does NOT immediately release its display name --
    # recreating too soon returns HTTP 409 ItemDisplayNameNotAvailableYet, which
    # is retriable and clears within a few minutes. Hence the retry loop.
    file="${2:?usage: --reland <file.json> <display name> [item type]}"
    name="${3:?usage: --reland <file.json> <display name> [item type]}"
    itype="${4:-}"
    [[ -f "${file}" ]] || { echo "ERROR: ${file} not found" >&2; exit 1; }

    if curl -fsS -H "Authorization: Bearer $(token)" "${API}/workspaces/${WS}/items" \
         | grep -q "\"displayName\":\"${name}\""; then
      echo "==> deleting existing ${name}"
      "$0" --delete "${name}" >/dev/null
    fi

    echo "==> recreating ${name} (the display name can take a few minutes to free)"
    created=0
    for attempt in $(seq 1 10); do
      if [[ -n "${itype}" ]]; then
        "$0" --create "${file}" "${name}" "${itype}" >/dev/null 2>&1 && { created=1; break; }
      else
        "$0" --create "${file}" "${name}" >/dev/null 2>&1 && { created=1; break; }
      fi
      echo "    attempt ${attempt}: name still held, waiting 60s"
      sleep 60
    done
    if (( created == 0 )); then
      echo "ERROR: could not recreate ${name} after 10 attempts." >&2
      "$0" --create "${file}" "${name}" ${itype:+"${itype}"} >&2 || true
      exit 1
    fi
    echo "    created"
    exec "$0" --run "${name}"
    ;;

  --update)
    # Replace an existing item's definition IN PLACE.
    #
    # Delete-and-recreate would also work, but it throws away the Copy job's
    # incremental state -- so the next run reverts to a full snapshot, which for
    # this job means re-landing 27M rows and losing whatever incremental
    # behaviour you were trying to test.
    file="${2:?usage: --update <file.json> <display name> [item type]}"
    name="${3:?usage: --update <file.json> <display name> [item type]}"
    itype="${4:-}"
    [[ -f "${file}" ]] || { echo "ERROR: ${file} not found" >&2; exit 1; }
    id="$(pipeline_id "${name}")"
    if [[ -z "${itype}" ]]; then
      itype="$(python3 - "${file}" <<'INFER2'
import json, sys
d = json.load(open(sys.argv[1]))
print("CopyJob" if "activities" in d else "DataPipeline")
INFER2
)"
    fi
    case "${itype}" in
      CopyJob)      part_path="copyjob-content.json" ;;
      DataPipeline) part_path="pipeline-content.json" ;;
      *) echo "ERROR: item type must be CopyJob or DataPipeline" >&2; exit 1 ;;
    esac
    payload="$(base64 < "${file}" | tr -d '\n')"
    body="$(python3 - "${part_path}" "${payload}" <<'BODY2'
import json, sys
part_path, payload = sys.argv[1:3]
print(json.dumps({"definition": {"parts": [
    {"path": part_path, "payload": payload, "payloadType": "InlineBase64"}]}}))
BODY2
)"
    api_post "${API}/workspaces/${WS}/items/${id}/updateDefinition?updateMetadata=false" \
      -H "Content-Type: application/json" -d "${body}" >/dev/null
    echo "updated ${name} (${id}) from ${file}"
    ;;

  --delete)
    name="${2:?usage: --delete <display name>}"
    id="$(pipeline_id "${name}")"
    curl -fsS -X DELETE -H "Authorization: Bearer $(token)" \
      "${API}/workspaces/${WS}/items/${id}"
    echo "deleted ${name} (${id})"
    ;;

  --verify-restore)
    # Prove a committed definition can actually be restored -- WITHOUT running it.
    #
    # Running a restored job would be actively dangerous. The exported definition
    # still embeds the real connection, the real lakehouse and the real table
    # names, so a "harmless test run" could truncate or re-land verified bronze.
    #
    # Creating the item, reading its definition back, comparing, and deleting
    # exercises exactly the part that was broken -- the create path -- and
    # touches no data at all.
    file="${2:?usage: --verify-restore <file.json> [item type]}"
    itype="${3:-}"
    [[ -f "${file}" ]] || { echo "ERROR: ${file} not found" >&2; exit 1; }
    tmp_name="_restoretest_$$"
    echo "==> creating ${tmp_name} from ${file}"
    if [[ -n "${itype}" ]]; then
      "$0" --create "${file}" "${tmp_name}" "${itype}" >/dev/null
    else
      "$0" --create "${file}" "${tmp_name}" >/dev/null
    fi
    # Delete it however this exits, including on a failed comparison. A leftover
    # item pointing at the real lakehouse is exactly what must not be left behind.
    trap "\"$0\" --delete \"${tmp_name}\" >/dev/null 2>&1 || true" EXIT
    echo "==> reading its definition back"
    "$0" --export "${tmp_name}" >/dev/null
    if python3 - "${file}" "${OUT_DIR}/${tmp_name}.json" <<'CMP'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
CMP
    then
      rm -f "${OUT_DIR}/${tmp_name}.json"
      echo "    definition round-trips identically"
      echo
      echo "RESTORE OK -- the committed definition can be recreated."
      echo "NOTE: this proves the API accepts and round-trips the definition."
      echo "      It does NOT prove runtime behaviour; the job was deliberately"
      echo "      not run, because it points at the real bronze tables."
    else
      echo "    definition came back DIFFERENT:" >&2
      diff <(python3 -m json.tool "${file}") \
           <(python3 -m json.tool "${OUT_DIR}/${tmp_name}.json") >&2 || true
      rm -f "${OUT_DIR}/${tmp_name}.json"
      exit 1
    fi
    ;;

  --run)
    name="${2:?usage: --run <pipeline display name>}"
    id="$(pipeline_id "${name}")"
    echo "==> Triggering ${name}"
    # The job instance URI comes back in the Location header, not the body.
    # CopyJob runs under a different jobType than a pipeline.
    itype="$(curl -fsS -H "Authorization: Bearer $(token)" "${API}/workspaces/${WS}/items/${id}" \
             | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")"
    jobtype="Pipeline"; [[ "${itype}" == "CopyJob" ]] && jobtype="CopyJob"
    echo "    item type: ${itype}, jobType: ${jobtype}"
    loc="$(curl -fsS -D - -o /dev/null -X POST -H "Authorization: Bearer $(token)" -H "Content-Length: 0" \
            "${API}/workspaces/${WS}/items/${id}/jobs/instances?jobType=${jobtype}" \
          | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
    if [[ -z "${loc}" ]]; then
      echo "ERROR: no Location header returned; the run may not have started." >&2
      exit 1
    fi
    echo "    job: ${loc}"
    # The job policy allows 12 hours; polling for 10 minutes and then declaring
    # failure is how a perfectly healthy 27M-row load gets reported as broken.
    deadline=$(( $(date +%s) + NBKI_RUN_TIMEOUT_MIN * 60 ))
    while (( $(date +%s) < deadline )); do
      st="$(curl -fsS -H "Authorization: Bearer $(token)" "${loc}" \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))")"
      echo "    status: ${st}"
      case "${st}" in
        Completed) exit 0 ;;
        Failed|Cancelled|Deduped)
          curl -fsS -H "Authorization: Bearer $(token)" "${loc}" | python3 -m json.tool >&2
          exit 1 ;;
      esac
      sleep 10
    done
    echo "ERROR: did not finish within ${NBKI_RUN_TIMEOUT_MIN} minutes." >&2
    echo "       Raise it with NBKI_RUN_TIMEOUT_MIN=<minutes>, or check the" >&2
    echo "       run in the portal -- it may still be going." >&2
    exit 1
    ;;

  *)
    sed -n '/^# Usage:/,/^#$/p' "$0"
    exit 2
    ;;
esac
