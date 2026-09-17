#!/usr/bin/env python3
"""
_onelake.py — read Delta tables out of OneLake with nothing but a token.

Why this exists
---------------
Verifying what actually landed in the bronze lakehouse needs a way to read it.
The three obvious routes are all closed on this workstation:

  * the SQL analytics endpoint needs an ODBC driver and pyodbc, neither of which
    is installed, and installing an MSSQL driver on a shared machine to check a
    row count is disproportionate;
  * the `fabric-sqlendpoint` MCP tool returns "re-authentication required",
    which is an interactive step;
  * a Spark notebook works, but needs a live session on the capacity and turns a
    thirty-second check into a multi-minute one.

What is always available is the OneLake DFS REST API and an Entra token. A Delta
table is just files, so that is enough -- the transaction log gives the schema
and exact row counts without reading any data at all, and the Parquet footers
give everything else.

The HTTP range trick
--------------------
Bronze holds 27.3M rows. Downloading every Parquet file to sum one column would
move gigabytes for a handful of numbers.

Parquet is designed to avoid that: the footer carries per-column-chunk offsets,
so a reader that can seek fetches only the chunks it needs. `HttpRangeFile`
below is a seekable file object backed by HTTP Range requests, which is all
pyarrow needs to do exactly that. Summing one column of a wide table reads that
column and nothing else.

Tokens are per-resource. OneLake data-plane calls need a *storage* token
(https://storage.azure.com), NOT the Fabric API token used for item management.
Using the wrong one gives 401 with no hint as to which.
"""

from __future__ import annotations

import io
import json
import subprocess
import urllib.error
import urllib.request

ONELAKE = "https://onelake.dfs.fabric.microsoft.com"
_TOKEN_CACHE: dict[str, str] = {}


def token(resource: str = "https://storage.azure.com") -> str:
    """Entra token via the Azure CLI, cached for the life of the process."""
    if resource not in _TOKEN_CACHE:
        _TOKEN_CACHE[resource] = subprocess.run(
            ["az", "account", "get-access-token", "--resource", resource,
             "--query", "accessToken", "-o", "tsv"],
            check=True, capture_output=True, text=True).stdout.strip()
    return _TOKEN_CACHE[resource]


def _get(url: str, extra_headers: dict[str, str] | None = None) -> bytes:
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token()}")
    for k, v in (extra_headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:400]
        raise RuntimeError(f"HTTP {e.code} for {url}\n{body}") from None


class HttpRangeFile(io.RawIOBase):
    """A seekable, read-only file over HTTP Range requests, for pyarrow."""

    def __init__(self, url: str, size: int):
        self._url, self._size, self._pos = url, size, 0

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def seek(self, offset: int, whence: int = io.SEEK_SET) -> int:
        base = {io.SEEK_SET: 0, io.SEEK_CUR: self._pos, io.SEEK_END: self._size}[whence]
        self._pos = max(0, min(self._size, base + offset))
        return self._pos

    def tell(self) -> int:
        return self._pos

    def read(self, size: int = -1) -> bytes:
        if size < 0:
            size = self._size - self._pos
        size = min(size, self._size - self._pos)
        if size <= 0:
            return b""
        end = self._pos + size - 1
        data = _get(self._url, {"Range": f"bytes={self._pos}-{end}"})
        self._pos += len(data)
        return data

    def readall(self) -> bytes:
        return self.read(-1)


def list_dir(workspace: str, path: str, recursive: bool = False) -> list[dict]:
    """List a OneLake directory. `path` is relative to the workspace."""
    url = (f"{ONELAKE}/{workspace}?resource=filesystem"
           f"&recursive={'true' if recursive else 'false'}&directory={path}")
    return json.loads(_get(url)).get("paths") or []


def list_tables(workspace: str, lakehouse: str) -> list[str]:
    entries = list_dir(workspace, f"{lakehouse}/Tables")
    return sorted(e["name"].split("/")[-1] for e in entries
                  if e.get("isDirectory") == "true")


def read_delta_log(workspace: str, lakehouse: str, table: str) -> dict:
    """Replay the Delta log: schema, live files, and exact row count.

    Row counts come from the log's own `numRecords` statistics, so a count costs
    no data transfer at all. `remove` entries are honoured -- a file that has
    been tombstoned by a merge is still physically present, and counting it
    would silently double-count every upserted row.
    """
    base = f"{lakehouse}/Tables/{table}/_delta_log"
    entries = [e for e in list_dir(workspace, base, recursive=True)
               if e["name"].endswith(".json")]
    if not entries:
        raise RuntimeError(f"no Delta log for table '{table}' -- is it a Delta table?")

    schema, files = None, {}
    for e in sorted(entries, key=lambda x: x["name"]):
        url = f"{ONELAKE}/{workspace}/{e['name']}"
        for line in _get(url).decode("utf-8").splitlines():
            if not line.strip():
                continue
            action = json.loads(line)
            if "metaData" in action:
                schema = json.loads(action["metaData"]["schemaString"])
            elif "add" in action:
                add = action["add"]
                stats = json.loads(add["stats"]) if add.get("stats") else {}
                files[add["path"]] = {
                    "size": add.get("size", 0),
                    "numRecords": stats.get("numRecords"),
                }
            elif "remove" in action:
                files.pop(action["remove"]["path"], None)

    counts = [f["numRecords"] for f in files.values()]
    return {
        "schema": {f["name"]: f["type"] for f in (schema or {}).get("fields", [])},
        "files": files,
        # None, not 0, when any file lacks stats -- an understated count that
        # looks authoritative is worse than an honest "unknown".
        "num_records": None if any(c is None for c in counts) else sum(counts),
    }


def open_parquet(workspace: str, lakehouse: str, table: str, path: str, size: int):
    """A pyarrow ParquetFile over the remote file, fetched by range."""
    import pyarrow.parquet as pq
    url = f"{ONELAKE}/{workspace}/{lakehouse}/Tables/{table}/{path}"
    return pq.ParquetFile(HttpRangeFile(url, size))
