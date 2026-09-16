#!/usr/bin/env python3
"""
15_client_test.py — prove the wire, from the operator workstation to Db2 on Azure.

This is the acceptance test for "I can point a SQL client at it": a real DRDA
connection over TLS, as the least-privileged account, asserting every row count
rather than settling for "it connected".

Three things are being proven at once, and all three have to hold:

  1. The NSG lets this machine reach 50001.
  2. Db2's TLS listener presents a certificate this client will accept.
  3. FABRICRO can read schema NBKI -- and, separately, still cannot write.

What it deliberately does NOT do is connect as db2inst1. If the instance owner
is what makes the demo work, the demo is not the one we want to show a bank.

Unlike the rest of this repo, this script needs a third-party package
(`ibm_db`). That is a deliberate exception: it is a client-side acceptance test,
not part of the seed pipeline, so it cannot stop a customer demo by failing to
install. The pipeline itself remains stdlib-only.

    .venv/bin/pip install ibm_db
    .venv/bin/python scripts/15_client_test.py

Environment (normally from ~/.nbki-demo/env.sh):
    NBKI_DB2_HOST     host to connect to -- follows the current network posture,
                      so it is the private address once locked to the VPN.
                      NOTE: this takes precedence over NBKI_DB2_PUBLIC, so
                      overriding the latter on the command line does nothing.
    NBKI_SECRET_DIR   where fabricro.pw and db2cert.arm live  (~/.nbki-demo)
"""

from __future__ import annotations

import os
import pathlib
import sys

try:
    import ibm_db
except ImportError:
    sys.exit(
        "ibm_db is not installed.\n"
        "    .venv/bin/pip install ibm_db\n"
        "It is intentionally not a dependency of the seed pipeline."
    )

# The figures the whole demo rests on. Hard-coded rather than read from the
# manifest on purpose: this test exists to catch the case where the manifest and
# the database agree with each other but disagree with reality.
EXPECTED = {
    "CUSTOMERS": 2_000,
    "CARDS": 6_146,
    "TRANSACTIONS": 13_305_915,
    "FRAUD_LABELS": 8_914_963,
    "AML_TRANSACTIONS": 5_078_345,
    "MCC_CODES": 109,
}

SCHEMA = os.environ.get("NBKI_DB2_SCHEMA", "NBKI")
DATABASE = os.environ.get("NBKI_DB2_DATABASE", "NBKI")
PORT = os.environ.get("NBKI_DB2_TLS_PORT", "50001")


def main() -> int:
    secret_dir = pathlib.Path(
        os.environ.get("NBKI_SECRET_DIR", pathlib.Path.home() / ".nbki-demo")
    )
    # NBKI_DB2_HOST is whichever address the current network posture allows.
    # After ./infra/deploy.sh --lock-to-vpn the public address accepts nothing
    # inbound, so this resolves to the private one and the test keeps working --
    # over the VPN, which is the point. NBKI_DB2_PUBLIC is the fallback for an
    # env.sh written before NBKI_DB2_HOST existed.
    host = os.environ.get("NBKI_DB2_HOST") or os.environ.get("NBKI_DB2_PUBLIC")
    if not host:
        sys.exit(f"NBKI_DB2_HOST is not set. source {secret_dir}/env.sh first.")

    pw_file = secret_dir / "fabricro.pw"
    cert = secret_dir / "db2cert.arm"
    for f in (pw_file, cert):
        if not f.is_file():
            sys.exit(f"missing {f} — run ./infra/start_db2.sh and "
                     f"./scripts/14_create_fabricro.sh first")

    # SECURITY=SSL plus SSLServerCertificate is what makes this a real TLS test.
    # Without the certificate the handshake fails, which is the point: a
    # self-signed certificate must be presented to the client explicitly.
    dsn = (
        f"DATABASE={DATABASE};"
        f"HOSTNAME={host};"
        f"PORT={PORT};"
        "PROTOCOL=TCPIP;"
        "UID=fabricro;"
        f"PWD={pw_file.read_text().strip()};"
        "SECURITY=SSL;"
        f"SSLServerCertificate={cert};"
    )

    print(f"==> Connecting to {host}:{PORT}/{DATABASE} over TLS as FABRICRO")
    try:
        conn = ibm_db.connect(dsn, "", "")
    except Exception as e:  # noqa: BLE001 — the driver raises a bare Exception
        print(f"\nFAILED to connect: {e}", file=sys.stderr)
        print(
            "\n  If this is a timeout, check the network posture:\n"
            "    - Locked to the VPN? Connect the Azure VPN Client.\n"
            "    - On the public path? The NSG rule for 50001 may have been\n"
            "      removed, or this machine's public address has changed;\n"
            "      re-run ./infra/deploy.sh, which re-reads it.",
            file=sys.stderr,
        )
        return 1

    server = ibm_db.server_info(conn)
    print(f"    connected: {server.DBMS_NAME} {server.DBMS_VER}")
    print()

    failures = 0
    print("-- Row counts, over TLS, as the read-only account")
    for table, expected in EXPECTED.items():
        stmt = ibm_db.exec_immediate(conn, f"SELECT COUNT(*) FROM {SCHEMA}.{table}")
        actual = int(ibm_db.fetch_tuple(stmt)[0])
        ok = actual == expected
        failures += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {table:<20} {actual:>12,}"
              + ("" if ok else f"   expected {expected:,}"))

    # Least privilege is a claim, so test it rather than assert it. A WHERE that
    # matches nothing still requires DELETE authority, so this is safe to run
    # against the loaded database.
    print()
    print("-- Least privilege")
    try:
        ibm_db.exec_immediate(conn, f"DELETE FROM {SCHEMA}.CUSTOMERS WHERE 1=0")
        print("  FAIL  FABRICRO was allowed to DELETE — it is not read-only")
        failures += 1
    except Exception as e:  # noqa: BLE001
        if "SQL0551N" in str(e):
            print("  PASS  DELETE refused with SQL0551N")
        else:
            print(f"  FAIL  DELETE refused, but not as expected: {e}")
            failures += 1

    ibm_db.close(conn)

    print()
    print("=" * 60)
    if failures:
        print(f"  {len(EXPECTED) + 1 - failures} passed, {failures} FAILED")
        print("=" * 60)
        return 1
    print(f"  {len(EXPECTED) + 1} passed, 0 failed")
    print("=" * 60)
    print()
    print("  Db2 on Azure is reachable from this machine over TLS, as a")
    print("  least-privileged account, and every control total ties.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
