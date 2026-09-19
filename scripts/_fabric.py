#!/usr/bin/env python3
"""
_fabric.py — talk to the Fabric REST API, and run notebooks from a workstation.

Why this exists
---------------
`_onelake.py` reads data out of OneLake. This is its control-plane sibling: it
creates and updates items, uploads notebook definitions, starts notebook runs,
and waits for them.

The constraint that shaped it
-----------------------------
There is **no T-SQL client on this workstation** -- no ODBC driver, no pyodbc,
and the `fabric-sqlendpoint` MCP tool answers `-32601 method not found`. So the
gold layer, which is T-SQL, cannot be applied from here directly.

The way through is that Fabric runs T-SQL for us. A **T-SQL notebook** is a
first-class Fabric item: it carries SQL, binds to a warehouse, runs on demand
through this API, and can be called from a pipeline. So the loop is

    author .sql in the repo -> build .ipynb -> upload -> run -> poll -> verify

and verification comes back through `_onelake.py`, because a Warehouse stores
its tables as Delta in OneLake exactly as a Lakehouse does. No ODBC anywhere.

That is also the better demo artefact. A stored procedure is invisible; a T-SQL
notebook is the gold build on screen, in the customer's own language, running.

Tokens are per-resource, and the two are not interchangeable:
  * control plane (this file)  -> https://api.fabric.microsoft.com
  * OneLake data plane         -> https://storage.azure.com   (see _onelake.py)
Using the wrong one gives 401 with no hint as to which.
"""

from __future__ import annotations

import base64
import json
import subprocess
import time
import urllib.error
import urllib.request

FABRIC = "https://api.fabric.microsoft.com/v1"
WORKSPACE = "5c84bcc5-f497-4eac-b59b-5c2a36bec619"  # nbki-db2-demo

# Item IDs, so nothing downstream has to guess. Refresh with `list_items()`.
ITEMS = {
    "lh_bronze": "56ba34ce-c8c8-467e-a1a9-8952b7b03dba",
    "lh_silver": "954f8d69-eae5-4bc7-9334-0b14ac82dd1e",
    "wh_gold": "be1fe7e3-c8be-4f90-b7ee-76b3d603f40d",
}

_TOKEN: dict[str, str] = {}


def token(resource: str = "https://api.fabric.microsoft.com") -> str:
    """Entra token via the Azure CLI, cached for the life of the process."""
    if resource not in _TOKEN:
        _TOKEN[resource] = subprocess.run(
            ["az", "account", "get-access-token", "--resource", resource,
             "--query", "accessToken", "-o", "tsv"],
            check=True, capture_output=True, text=True).stdout.strip()
    return _TOKEN[resource]


def _request(method: str, url: str, body: dict | None = None) -> tuple[int, dict, dict]:
    """Returns (status, parsed_body, headers). Never raises on 4xx/5xx."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {}), dict(r.headers)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw.decode("utf-8", "replace")[:600]}
        return e.code, parsed, dict(e.headers)


def api(method: str, path: str, body: dict | None = None) -> dict:
    """Call the Fabric API, following long-running operations to completion.

    A 202 means Fabric accepted the work but has not done it. Returning at that
    point is how you end up asserting an item exists moments before it does.
    """
    status, parsed, headers = _request(method, f"{FABRIC}/{path}", body)

    if status == 202 and headers.get("Location"):
        loc = headers["Location"]
        for _ in range(60):
            time.sleep(int(headers.get("Retry-After", 3)))
            s, p, _h = _request("GET", loc)
            state = (p or {}).get("status", "")
            if state in ("Succeeded", "Completed"):
                # The result, when there is one, hangs off /result.
                s2, p2, _ = _request("GET", loc.rstrip("/") + "/result")
                return p2 if s2 < 300 else p
            if state in ("Failed", "Cancelled", "Deduped"):
                raise RuntimeError(f"operation {state}: {json.dumps(p)[:500]}")
        raise RuntimeError("operation did not finish in time")

    if status >= 300:
        raise RuntimeError(f"HTTP {status} {method} {path}\n{json.dumps(parsed)[:600]}")
    return parsed


def list_items() -> list[dict]:
    return api("GET", f"workspaces/{WORKSPACE}/items").get("value", [])


def find_item(display_name: str, item_type: str | None = None) -> dict | None:
    for i in list_items():
        if i["displayName"] == display_name and (not item_type or i["type"] == item_type):
            return i
    return None


def refresh_sql_endpoint(lakehouse_name: str = "lh_silver") -> bool:
    """Force the SQL analytics endpoint to re-read the lakehouse's Delta logs.

    Why this is not optional
    ------------------------
    A Spark write to `lh_silver` is **not** immediately visible to `wh_gold`'s
    cross-database query. The sync is a background process. Build gold too soon
    after silver and it either cannot see a table or -- far worse -- silently
    reads the previous version and produces a completely plausible star schema
    built on yesterday's numbers.

    A pipeline has a first-class activity for this. From here, the REST API is
    the equivalent. Failure is reported but not fatal: the background sync gets
    there on its own eventually, and turning a slow sync into a hard build
    failure would be a worse trade.
    """
    ep = find_item(lakehouse_name, "SQLEndpoint")
    if not ep:
        print(f"    ! no SQL endpoint found for {lakehouse_name}")
        return False
    try:
        api("POST", f"workspaces/{WORKSPACE}/sqlEndpoints/{ep['id']}"
                    f"/refreshMetadata?preview=true", {})
        print(f"    refreshed the {lakehouse_name} SQL analytics endpoint")
        return True
    except RuntimeError as e:
        print(f"    ! endpoint refresh failed, continuing: {str(e)[:160]}")
        return False


# --------------------------------------------------------------------------
# Notebooks
# --------------------------------------------------------------------------

def build_ipynb(cells: list[tuple[str, str]], language: str,
                lakehouse: dict | None = None,
                warehouse: dict | None = None) -> dict:
    """Assemble a Fabric notebook.

    `cells` is a list of (kind, source) where kind is 'md', 'code' or 'params'.

    The `dependencies` block in the metadata is what binds the notebook to its
    default lakehouse or to a primary warehouse. Without it a T-SQL notebook has
    nothing to run against, and a PySpark notebook has no default table root.
    """
    is_sql = language == "sql"
    meta: dict = {
        "language_info": {"name": language},
        "kernelspec": {"name": "synapse_pyspark", "display_name": "Synapse PySpark"},
    }
    deps: dict = {}
    if lakehouse:
        deps["lakehouse"] = lakehouse
    if warehouse:
        deps["warehouse"] = warehouse
    if deps:
        meta["dependencies"] = deps

    out = []
    for kind, src in cells:
        lines = src.strip("\n").splitlines(keepends=True)
        if kind == "md":
            out.append({"cell_type": "markdown", "metadata": {}, "source": lines})
        else:
            # A 'params' cell carries the `parameters` tag, which is the only
            # thing that makes its variables overridable from a pipeline.
            cell_meta: dict = {"tags": ["parameters"]} if kind == "params" else {}
            if is_sql:
                cell_meta["language"] = "sql"
            out.append({
                "cell_type": "code", "metadata": cell_meta, "source": lines,
                "outputs": [], "execution_count": None,
            })
    return {"nbformat": 4, "nbformat_minor": 5, "metadata": meta, "cells": out}


def deploy_notebook(display_name: str, ipynb: dict, description: str = "") -> str:
    """Create or update a notebook item from an .ipynb document. Returns its ID."""
    payload = base64.b64encode(json.dumps(ipynb).encode()).decode()
    definition = {
        "format": "ipynb",
        "parts": [{
            "path": "notebook-content.ipynb",
            "payload": payload,
            "payloadType": "InlineBase64",
        }],
    }
    existing = find_item(display_name, "Notebook")
    if existing:
        # No `?updateMetadata=True`: that flag demands a `.platform` part in the
        # payload, and the display name / description are not what we are
        # changing here. The definition is.
        api("POST",
            f"workspaces/{WORKSPACE}/notebooks/{existing['id']}/updateDefinition",
            {"definition": definition})
        return existing["id"]

    created = api("POST", f"workspaces/{WORKSPACE}/notebooks", {
        "displayName": display_name,
        "description": description,
        "definition": definition,
    })
    return created["id"]


def run_notebook(notebook_id: str, parameters: dict | None = None,
                 timeout_s: int = 3600, poll_s: int = 15) -> dict:
    """Start a notebook run and block until it finishes. Raises on failure."""
    body: dict = {}
    if parameters:
        body["executionData"] = {
            "parameters": {
                k: {"value": v, "type": _param_type(v)} for k, v in parameters.items()
            }
        }

    status, parsed, headers = _request(
        "POST",
        f"{FABRIC}/workspaces/{WORKSPACE}/items/{notebook_id}/jobs/instances"
        "?jobType=RunNotebook",
        body or None,
    )
    if status >= 300:
        raise RuntimeError(f"could not start notebook: HTTP {status} "
                           f"{json.dumps(parsed)[:500]}")

    loc = headers.get("Location")
    if not loc:
        raise RuntimeError("notebook run started but returned no Location header")

    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        time.sleep(poll_s)
        _s, p, _h = _request("GET", loc)
        state = p.get("status", "")
        if state != last:
            print(f"    … {state}")
            last = state
        if state in ("Completed", "Succeeded"):
            return p
        if state in ("Failed", "Cancelled", "Deduped"):
            raise RuntimeError(f"notebook run {state}: "
                               f"{json.dumps(p.get('failureReason') or p)[:800]}")
    raise RuntimeError(f"notebook run did not finish within {timeout_s}s")


def _param_type(v) -> str:
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    return "string"
