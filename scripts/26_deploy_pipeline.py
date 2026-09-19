#!/usr/bin/env python3
"""
26_deploy_pipeline.py — the runnable end-to-end medallion pipeline.

    nb_silver  ──(Succeeded)──>  nb_gold_runner

One button, bronze already landed, silver and gold rebuilt and verified. This is
the artefact to press during the demo.

What is here and what is not
----------------------------
**Here:** the two Spark notebook legs, which are the ones this repo can author
and *prove* by running them. `TridentNotebook` is the documented activity type
for a Fabric notebook.

**Not here, deliberately:**

* The **Copy job leg** (`cj_bronze_db2`). Its pipeline activity is GA, but Learn
  documents neither whether it waits for completion nor what it returns, and the
  job itself takes 10m31s and re-lands 27.3M rows. Chaining an unverified,
  ten-minute, stateful step in front of the demo is a bad trade. Bronze is
  already landed; run the Copy job separately when you want to re-land.
* The **Dataflow leg**. `df_silver_csv` has no output destination yet -- that
  binding is not in the published definition schema (see
  `scripts/25_deploy_dataflow.py`). Add both legs in the portal once the
  destination is set.
* A **Refresh SQL analytics endpoint** activity. It exists, but rather than guess
  its JSON, `nb_gold_runner` calls the refresh REST API itself as its first act.
  Same effect, one less unverified shape. If you add the activity in the portal
  later, the notebook's own call becomes harmless redundancy.

That split follows the repo's standing rule: do not commit a JSON shape that has
not been run. Three hand-authored pipeline definitions each failed differently
before this rule existed.

Usage:
    .venv/bin/python scripts/26_deploy_pipeline.py            # deploy and run
    .venv/bin/python scripts/26_deploy_pipeline.py --no-run
"""

from __future__ import annotations

import argparse
import base64
import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _fabric as fab  # noqa: E402

NAME = "pl_medallion"


def notebook_activity(name: str, notebook_id: str,
                      depends_on: str | None = None) -> dict:
    act: dict = {
        "name": name,
        "type": "TridentNotebook",
        "dependsOn": [],
        "policy": {
            "timeout": "0.02:00:00",
            "retry": 0,
            "retryIntervalInSeconds": 30,
            "secureOutput": False,
            "secureInput": False,
        },
        "typeProperties": {
            "notebookId": notebook_id,
            "workspaceId": fab.WORKSPACE,
        },
    }
    if depends_on:
        act["dependsOn"] = [{
            "activity": depends_on,
            "dependencyConditions": ["Succeeded"],
        }]
    return act


def build_definition(silver_id: str, gold_id: str) -> dict:
    content = {
        "properties": {
            "activities": [
                notebook_activity("Silver - conform, validate, quarantine",
                                  silver_id),
                notebook_activity("Gold - build the star schema", gold_id,
                                  depends_on="Silver - conform, validate, quarantine"),
            ],
            "annotations": [],
        }
    }
    payload = base64.b64encode(json.dumps(content).encode()).decode()
    return {"parts": [{
        "path": "pipeline-content.json",
        "payload": payload,
        "payloadType": "InlineBase64",
    }]}


def run_pipeline(pipeline_id: str, timeout_s: int = 7200) -> dict:
    status, parsed, headers = fab._request(
        "POST",
        f"{fab.FABRIC}/workspaces/{fab.WORKSPACE}/items/{pipeline_id}"
        f"/jobs/instances?jobType=Pipeline", {})
    if status >= 300:
        raise RuntimeError(f"could not start pipeline: HTTP {status} "
                           f"{json.dumps(parsed)[:400]}")
    loc = headers.get("Location")
    if not loc:
        raise RuntimeError("pipeline started but returned no Location header")

    deadline, last = time.time() + timeout_s, ""
    while time.time() < deadline:
        time.sleep(20)
        _s, p, _h = fab._request("GET", loc)
        state = p.get("status", "")
        if state != last:
            print(f"    … {state}")
            last = state
        if state in ("Completed", "Succeeded"):
            return p
        if state in ("Failed", "Cancelled", "Deduped"):
            raise RuntimeError(f"pipeline {state}: "
                               f"{json.dumps(p.get('failureReason') or p)[:600]}")
    raise RuntimeError(f"pipeline did not finish within {timeout_s}s")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-run", action="store_true")
    args = ap.parse_args()

    silver = fab.find_item("nb_silver", "Notebook")
    gold = fab.find_item("nb_gold_runner", "Notebook")
    if not silver or not gold:
        print("!! deploy the notebooks first: 20_deploy_silver.py, "
              "22_deploy_gold.py", file=sys.stderr)
        return 1
    print(f"==> nb_silver       {silver['id']}")
    print(f"==> nb_gold_runner  {gold['id']}")

    definition = build_definition(silver["id"], gold["id"])
    existing = fab.find_item(NAME, "DataPipeline")
    if existing:
        fab.api("POST", f"workspaces/{fab.WORKSPACE}/dataPipelines/"
                        f"{existing['id']}/updateDefinition",
                {"definition": definition})
        pid = existing["id"]
        print(f"==> updated pipeline {pid}")
    else:
        created = fab.api("POST", f"workspaces/{fab.WORKSPACE}/dataPipelines", {
            "displayName": NAME,
            "description": "Silver then gold, end to end. GENERATED by "
                           "scripts/26_deploy_pipeline.py.",
            "definition": definition,
        })
        pid = created.get("id")
        print(f"==> created pipeline {pid}")

    if args.no_run:
        print("==> --no-run, stopping here")
        return 0

    print("==> running the pipeline")
    t0 = time.time()
    run_pipeline(pid)
    print(f"==> completed in {time.time() - t0:.0f}s")
    print("    verify: scripts/21_verify_silver.py && scripts/23_verify_gold.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
