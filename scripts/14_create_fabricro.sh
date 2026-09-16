#!/usr/bin/env bash
#
# 14_create_fabricro.sh — create the read-only principal that Fabric connects as.
#
# db2/ddl/01_schema.sql has carried these grants as comments since the schema was
# first generated:
#
#   -- GRANT CONNECT ON DATABASE TO USER FABRICRO;
#   -- GRANT SELECTIN ON SCHEMA NBKI TO USER FABRICRO;
#
# They are commented out because Db2 LUW authenticates against the operating
# system: the grant is meaningless until the OS user exists, and the DDL
# generator has no business creating OS users. This script closes that gap.
#
# Why it matters here specifically: Db2 on this VM is reachable from the public
# internet on 50001. Handing Fabric `db2inst1` would put the instance owner --
# which can drop every table in the database -- on the far end of that. FABRICRO
# can connect and read schema NBKI, and nothing else.
#
# THE OS USER DOES NOT SURVIVE A CONTAINER REBUILD.
# It lives in the container's /etc/passwd, which is part of the image layer, not
# the /database volume. `db2_up.sh --recreate` therefore silently removes it
# while leaving the GRANTs in place, pointing at a user that no longer exists --
# and Fabric starts failing authentication for no visible reason. Re-run this
# script after any recreate. infra/start_db2.sh calls it for exactly that reason.
#
# Usage:  ./scripts/14_create_fabricro.sh
#
set -Eeuo pipefail

SECRET_DIR="${NBKI_SECRET_DIR:-${HOME}/.nbki-demo}"
# shellcheck source=/dev/null
source "${SECRET_DIR}/env.sh"

SSH_OPTS=(-i "${NBKI_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
# Reach the VM on whichever address the current posture allows. After
# ./infra/deploy.sh --lock-to-vpn the public address accepts nothing inbound, so
# using it here would fail with a timeout that looks like a dead VM.
DB2_HOST="${NBKI_DB2_HOST:-${NBKI_DB2_PUBLIC}}"
TARGET="${NBKI_ADMIN}@${DB2_HOST}"

FABRICRO_PW="$(cat "${SECRET_DIR}/fabricro.pw")"
DB="${NBKI_DB2_DATABASE:-NBKI}"
SCHEMA="${NBKI_DB2_SCHEMA:-NBKI}"

echo "==> Creating FABRICRO on the Db2 host"
ssh "${SSH_OPTS[@]}" "${TARGET}" "bash -seu" <<REMOTE
CONTAINER=db2demo
PW='${FABRICRO_PW}'
DB='${DB}'
SCHEMA='${SCHEMA}'

# --- the operating-system account -----------------------------------------
if docker exec "\$CONTAINER" id fabricro >/dev/null 2>&1; then
  echo "    OS user fabricro already exists"
else
  echo "    creating OS user fabricro"
  docker exec "\$CONTAINER" bash -c "useradd -m -g db2iadm1 -s /bin/bash fabricro"
fi
# Set the password every time: it is cheap, and it means a rotated secret on the
# workstation cannot drift out of step with the database.
docker exec "\$CONTAINER" bash -c "echo 'fabricro:\$PW' | chpasswd"

# Disable password aging. The image's default useradd policy sets a 90-day
# maximum, and an expired OS password makes Db2 reject the account -- which
# surfaces in Fabric as "Invalid connection credentials" with nothing wrong at
# the Fabric end and nothing changed by anyone. A demo service account that
# quietly stops working three months after it was built is a bad trade for a
# policy that protects nothing here.
docker exec "\$CONTAINER" bash -c "chage -M -1 -m 0 -I -1 fabricro"

# --- the database privileges ----------------------------------------------
# Shipped as one CLP script. Each `db2` invocation is a separate process and a
# connection made by one does not survive into the next, so a sequence of
# `docker exec db2 ...` calls would connect, grant nothing, and disconnect.
cat > /tmp/fabricro.sql <<SQL
CONNECT TO \$DB;
GRANT CONNECT ON DATABASE TO USER FABRICRO;
GRANT SELECTIN ON SCHEMA \$SCHEMA TO USER FABRICRO;
CONNECT RESET;
SQL
chmod 0644 /tmp/fabricro.sql
docker cp /tmp/fabricro.sql "\$CONTAINER:/tmp/nbki_load/fabricro.sql" >/dev/null
docker exec "\$CONTAINER" su - db2inst1 -c "db2 -tvf /tmp/nbki_load/fabricro.sql"
rm -f /tmp/fabricro.sql

# --- EXECUTE on the NULLID packages ---------------------------------------
# This is the other half of the -805 story. Setting packageCollection=NULLID on
# the Fabric connection tells the driver WHERE to look; the read-only user still
# needs to be allowed to run what it finds there. Granting per-package rather
# than handing out BINDADD keeps the account read-only.
docker exec "\$CONTAINER" su - db2inst1 -c "
  db2 connect to \$DB > /dev/null
  db2 -x \"SELECT 'GRANT EXECUTE ON PACKAGE NULLID.' || RTRIM(PKGNAME) || ' TO USER FABRICRO;' FROM SYSCAT.PACKAGES WHERE PKGSCHEMA='NULLID'\" > /tmp/nbki_load/grants.sql
  db2 connect reset > /dev/null
"
docker exec "\$CONTAINER" su - db2inst1 -c "
  printf 'CONNECT TO \$DB;\n' > /tmp/nbki_load/pkg.sql
  cat /tmp/nbki_load/grants.sql >> /tmp/nbki_load/pkg.sql
  printf 'CONNECT RESET;\n' >> /tmp/nbki_load/pkg.sql
  db2 -tf /tmp/nbki_load/pkg.sql | tail -2
"
REMOTE

# ---------------------------------------------------------------------------
# Prove it. Two assertions, and the second one matters as much as the first:
# FABRICRO must be able to read, and must NOT be able to write.
# ---------------------------------------------------------------------------
echo
echo "==> Verifying FABRICRO can read"
ssh "${SSH_OPTS[@]}" "${TARGET}" "bash -seu" <<REMOTE
CONTAINER=db2demo
cat > /tmp/ro_test.sql <<SQL
CONNECT TO ${DB} USER fabricro USING '${FABRICRO_PW}';
SELECT COUNT(*) AS CUSTOMERS FROM ${SCHEMA}.CUSTOMERS;
CONNECT RESET;
SQL
chmod 0644 /tmp/ro_test.sql
docker cp /tmp/ro_test.sql "\$CONTAINER:/tmp/nbki_load/ro_test.sql" >/dev/null
# Capture rather than pipe. Piping through grep/tail hands the pipeline's exit
# status to \`tail\`, and the \`rm\` afterwards would be the last command anyway, so
# the whole block would report success even when the SELECT was refused. This
# script is called unattended by infra/start.sh to repair a rebuilt container --
# exactly the moment a silent pass is most expensive.
out="\$(docker exec "\$CONTAINER" su - db2inst1 -c "db2 -tf /tmp/nbki_load/ro_test.sql" 2>&1 || true)"
rm -f /tmp/ro_test.sql
echo "\$out" | grep -vE '^\s*\$' | tail -6

if echo "\$out" | grep -qE 'SQL[0-9]{4}[NC]'; then
  echo "ERROR: FABRICRO could not read. Db2 reported an error above." >&2
  exit 1
fi
if ! echo "\$out" | grep -qE '^\s*2000\s*\$'; then
  echo "ERROR: FABRICRO connected but did not return the expected 2000 customers." >&2
  exit 1
fi
echo "    read verified: 2000 customers"
REMOTE

echo
echo "==> Verifying FABRICRO cannot write (this SHOULD fail with SQL0551N)"
ssh "${SSH_OPTS[@]}" "${TARGET}" "bash -seu" <<REMOTE
CONTAINER=db2demo
cat > /tmp/rw_test.sql <<SQL
CONNECT TO ${DB} USER fabricro USING '${FABRICRO_PW}';
DELETE FROM ${SCHEMA}.CUSTOMERS WHERE 1=0;
CONNECT RESET;
SQL
chmod 0644 /tmp/rw_test.sql
docker cp /tmp/rw_test.sql "\$CONTAINER:/tmp/nbki_load/rw_test.sql" >/dev/null
out="\$(docker exec "\$CONTAINER" su - db2inst1 -c "db2 -tf /tmp/nbki_load/rw_test.sql" 2>&1 || true)"
rm -f /tmp/rw_test.sql
if echo "\$out" | grep -q 'SQL0551N'; then
  echo "    correctly refused: SQL0551N (no DELETE privilege)"
else
  echo "ERROR: FABRICRO was NOT refused write access. It is not read-only." >&2
  echo "\$out" >&2
  exit 1
fi
REMOTE

echo
echo "==> FABRICRO is ready. Use it for the Fabric connection, not db2inst1."
