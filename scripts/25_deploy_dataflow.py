#!/usr/bin/env python3
"""
25_deploy_dataflow.py — create the Dataflow Gen2 from the committed Power Query.

Source of truth is `fabric/dataflows/df_silver_csv.pq`. This wraps it into a
Fabric Dataflow item definition (`mashup.pq` + `queryMetadata.json`, format
version 202502) and creates or updates the item.

What this does and does not do
------------------------------
It builds the **transformation**: both queries, with every one of the twelve CSV
defects handled. That is the part worth version-controlling and the part that
takes time to author.

It does **not** set the output destination. The destination binding is not in the
published dataflow definition schema -- the documented parts are `mashup.pq`,
`queryMetadata.json` and the optional `.mdf` transforms, and none of them
describes a Lakehouse sink. Rather than guess a shape and ship something that
looks configured and is not, the destination is two clicks in the portal:

    open df_silver_csv -> select the query -> Add data destination -> Lakehouse
    -> lh_silver -> table name -> Replace -> turn OFF "use automatic settings"

That last toggle matters: on automatic, the destination table is dropped and
recreated on every refresh, which can take relationships and measures with it.

This is the same rule the rest of the repo follows -- do not put an unverified
JSON shape into a committed artefact. The bronze Copy job's audit columns were
lost to exactly that, with an HTTP 400 to show for it.

Usage:
    .venv/bin/python scripts/25_deploy_dataflow.py
"""

from __future__ import annotations

import base64
import json
import pathlib
import re
import sys
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _fabric as fab  # noqa: E402

SRC = pathlib.Path(__file__).parent.parent / "fabric" / "dataflows" / "df_silver_csv.pq"
NAME = "df_silver_csv"

# Deterministic query IDs: a redeploy must not look like a different dataflow.
NS = uuid.UUID("6f1b2c3d-4e5a-4b6c-8d7e-9f0a1b2c3d4e")


def extract_queries(text: str) -> dict[str, str]:
    """Pull the named `let ... in ...` expressions out of the .pq file.

    The file is written to be *read* -- commentary first, then the query. The
    second query is commented out so the file stays a single valid expression
    when pasted straight into the portal's advanced editor, which is the other
    way this artefact gets used.
    """
    # Query 1: everything from the first top-level `let` to the matching `in`
    # result, ending before the second-query banner.
    banner = "// ====="
    head = text.split(banner)[0]
    m = re.search(r"^let\b.*", head, flags=re.S | re.M)
    if not m:
        raise RuntimeError("could not find the first `let` expression")
    q1 = m.group(0).strip()

    # Query 2 is commented out in the source; uncomment it.
    tail = text.split(banner)[-1]
    lines = []
    started = False
    for line in tail.splitlines():
        s = line.strip()
        if s.startswith("// let"):
            started = True
        if started and s.startswith("//"):
            lines.append(re.sub(r"^\s*//\s?", "", line))
    q2 = "\n".join(lines).strip()
    if not q2.startswith("let"):
        raise RuntimeError("could not find the commented MccCodes query")

    return {"CsvTransactions": q1, "MccCodes": q2}


def build_definition(queries: dict[str, str]) -> dict:
    mashup_parts = ['[StagingDefinition = [Kind = "FastCopy"]]', "section Section1;", ""]
    for name, expr in queries.items():
        mashup_parts.append(f"shared {name} =\n{expr};\n")
    mashup = "\n".join(mashup_parts)

    metadata = {
        "formatVersion": "202502",
        "name": NAME,
        "computeEngineSettings": {"allowFastCopy": True, "maxConcurrency": 1},
        "queryGroups": [],
        "documentLocale": "en-GB",
        "gatewayObjectId": None,
        "queriesMetadata": {
            name: {
                "queryId": str(uuid.uuid5(NS, name)),
                "queryName": name,
                "queryGroupId": None,
                "isHidden": False,
                "loadEnabled": True,
            }
            for name in queries
        },
        "connections": [],
        "fastCombine": False,
        "allowNativeQueries": True,
        # The CSVs carry three date formats and $-prefixed amounts. Letting
        # Power Query guess types would defeat the entire point of the demo --
        # the parsing is explicit, in the query, where it can be shown.
        "skipAutomaticTypeAndHeaderDetection": True,
    }

    def part(path: str, content: str) -> dict:
        return {
            "path": path,
            "payload": base64.b64encode(content.encode("utf-8")).decode(),
            "payloadType": "InlineBase64",
        }

    return {"parts": [part("mashup.pq", mashup),
                      part("queryMetadata.json", json.dumps(metadata, indent=2))]}


def main() -> int:
    queries = extract_queries(SRC.read_text())
    for name, q in queries.items():
        print(f"==> query {name}: {len(q.splitlines())} lines")

    definition = build_definition(queries)

    existing = fab.find_item(NAME, "Dataflow")
    if existing:
        fab.api("POST",
                f"workspaces/{fab.WORKSPACE}/dataflows/{existing['id']}/updateDefinition",
                {"definition": definition})
        print(f"==> updated dataflow {existing['id']}")
    else:
        created = fab.api("POST", f"workspaces/{fab.WORKSPACE}/dataflows", {
            "displayName": NAME,
            "description": "Cleans the hand-made Equation CSV extracts. "
                           "GENERATED from fabric/dataflows/df_silver_csv.pq. "
                           "Set the output destination in the portal.",
            "definition": definition,
        })
        print(f"==> created dataflow {created.get('id')}")

    print()
    print("    ONE MANUAL STEP REMAINS — the destination binding is not in the")
    print("    published definition schema, so it is not guessed here:")
    print()
    print("      open df_silver_csv -> select CsvTransactions")
    print("      -> Add data destination -> Lakehouse -> lh_silver")
    print("      -> table slv_csv_transactions -> Replace")
    print("      -> turn OFF 'use automatic settings'")
    print("      repeat for MccCodes -> slv_mcc_codes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
