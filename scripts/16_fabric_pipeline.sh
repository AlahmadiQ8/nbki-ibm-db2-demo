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
# Usage:
#   ./scripts/16_fabric_pipeline.sh --list
#   ./scripts/16_fabric_pipeline.sh --export "pl_bronze_customers"
#   ./scripts/16_fabric_pipeline.sh --create fabric/pl_bronze_customers.json "pl_name"
#   ./scripts/16_fabric_pipeline.sh --run    "pl_bronze_customers"
#
# Environment:
#   NBKI_FABRIC_WORKSPACE   workspace GUID (defaults to the demo workspace)
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${NBKI_FABRIC_WORKSPACE:-5c84bcc5-f497-4eac-b59b-5c2a36bec619}"
OUT_DIR="${REPO_ROOT}/fabric"
API="https://api.fabric.microsoft.com/v1"

token() {
  az account get-access-token --resource https://api.fabric.microsoft.com \
    --query accessToken -o tsv
}

# Find a DataPipeline item by display name. Fails loudly rather than returning
# an empty string, because an empty id in a URL produces a 404 that reads like
# the API is broken rather than like a typo.
pipeline_id() {
  local name="$1" id
  id="$(curl -fsS -H "Authorization: Bearer $(token)" "${API}/workspaces/${WS}/items?type=DataPipeline" \
        | python3 -c "
import json,sys
name=sys.argv[1]
for i in json.load(sys.stdin).get('value',[]):
    if i.get('displayName')==name: print(i['id']); break
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
    curl -fsS -H "Authorization: Bearer $(token)" "${API}/workspaces/${WS}/items?type=DataPipeline" \
      | python3 -c "
import json,sys
v=json.load(sys.stdin).get('value',[])
print(f'{len(v)} pipeline(s) in the workspace')
for i in v: print(' ', i['displayName'], i['id'])
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
part=next((p for p in parts if p['path'].endswith('pipeline-content.json')), None)
if not part:
    sys.exit('no pipeline-content.json in the definition; parts were: %s' % [p['path'] for p in parts])
content=json.loads(base64.b64decode(part['payload']))
out=pathlib.Path(sys.argv[1])
out.write_text(json.dumps(content, indent=2) + '\n')
print('wrote', out)
" "${OUT_DIR}/${name}.json"
    echo "    commit it: git add fabric/${name}.json"
    ;;

  --create)
    file="${2:?usage: --create <file.json> <display name>}"
    name="${3:?usage: --create <file.json> <display name>}"
    [[ -f "${file}" ]] || { echo "ERROR: ${file} not found" >&2; exit 1; }
    payload="$(python3 -c "
import base64,json,pathlib,sys
print(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode())
" "${file}")"
    body="$(python3 -c "
import json,sys
print(json.dumps({
 'displayName': sys.argv[1],
 'type': 'DataPipeline',
 'definition': {'parts': [
   {'path':'pipeline-content.json','payload':sys.argv[2],'payloadType':'InlineBase64'}]}}))
" "${name}" "${payload}")"
    curl -fsS -X POST -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
      -d "${body}" "${API}/workspaces/${WS}/items" | python3 -m json.tool
    ;;

  --run)
    name="${2:?usage: --run <pipeline display name>}"
    id="$(pipeline_id "${name}")"
    echo "==> Triggering ${name}"
    # The job instance URI comes back in the Location header, not the body.
    loc="$(curl -fsS -D - -o /dev/null -X POST -H "Authorization: Bearer $(token)" -H "Content-Length: 0" \
            "${API}/workspaces/${WS}/items/${id}/jobs/instances?jobType=Pipeline" \
          | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
    if [[ -z "${loc}" ]]; then
      echo "ERROR: no Location header returned; the run may not have started." >&2
      exit 1
    fi
    echo "    job: ${loc}"
    for _ in $(seq 1 60); do
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
    echo "ERROR: pipeline did not finish within 10 minutes." >&2
    exit 1
    ;;

  *)
    sed -n '/^# Usage:/,/^#$/p' "$0"
    exit 2
    ;;
esac
