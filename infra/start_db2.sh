#!/usr/bin/env bash
#
# start_db2.sh — bring Db2 up on the VM and give it a TLS listener.
#
# Runs from the operator workstation, drives the VM over SSH.
#
# Why TLS at all
# --------------
# docs/feasibility.md specifies TLS via ssl_svcename + DB2COMM=TCPIP,SSL and a
# dedicated read-only account, and says "no public IP". This build keeps the
# public address for SQL-client convenience, which makes the other two
# non-optional rather than nice-to-have: an instance-owner credential crossing
# the public internet in the clear is not something to demo to a bank.
#
# So the split is:
#   50000  cleartext DRDA, published on 127.0.0.1 only, never leaves the host
#   50001  TLS, published on 0.0.0.0 and firewalled to two sources by the NSG
#
# Ordering note: the container has to publish 50001 from the moment it is
# created, because published ports cannot be added to a running container. The
# port therefore exists before anything is listening on it, which is fine and
# briefly looks broken.
#
# Usage:
#   ./infra/start_db2.sh              # start + configure TLS (idempotent)
#   ./infra/start_db2.sh --recreate   # rebuild the container, keep the volume
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
REMOTE_ROOT=/opt/nbki
TLS_PORT=50001

DB2_PASSWORD="$(cat "${SECRET_DIR}/db2inst1.pw")"
KEYSTORE_PW="$(cat "${SECRET_DIR}/db2inst1.pw")"

RECREATE=""
# Cleartext bind. Loopback by default so 50000 never leaves the host. Set
# NBKI_DB2_CLEARTEXT_BIND=0.0.0.0 together with ./infra/deploy.sh
# --gateway-cleartext if the pipeline Copy path turns out not to speak TLS; the
# NSG then still restricts 50000 to the gateway NIC alone.
CLEARTEXT_BIND="${NBKI_DB2_CLEARTEXT_BIND:-127.0.0.1}"
[[ "${1:-}" == "--recreate" ]] && RECREATE="--recreate"

echo "==> Starting Db2 (first start pulls nothing but takes a few minutes to answer SQL)"
ssh "${SSH_OPTS[@]}" "${TARGET}" \
  "cd ${REMOTE_ROOT} && DB2_BIND=${CLEARTEXT_BIND} DB2_TLS_PORT=${TLS_PORT} DB2_PASSWORD='${DB2_PASSWORD}' ./scripts/db2_up.sh ${RECREATE}"

# ---------------------------------------------------------------------------
# TLS. Everything below is idempotent: if the keystore already exists we leave
# it alone, because regenerating it would invalidate the certificate already
# trusted by the gateway.
# ---------------------------------------------------------------------------
echo
echo "==> Configuring the TLS listener on ${TLS_PORT}"
ssh "${SSH_OPTS[@]}" "${TARGET}" "bash -seu" <<REMOTE
CONTAINER=db2demo
KSPW='${KEYSTORE_PW}'
PRIVATE_IP='${NBKI_DB2_PRIVATE}'
PUBLIC_IP='${NBKI_DB2_PUBLIC}'
TLS_PORT=${TLS_PORT}

# The instance home sits on the /database volume, so the keystore survives a
# container restart -- but NOT a --wipe, which destroys the volume.
SSLDIR=/database/config/db2inst1/ssl

docker exec "\$CONTAINER" bash -c "mkdir -p \$SSLDIR && chown db2inst1:db2iadm1 \$SSLDIR"

if docker exec "\$CONTAINER" test -f "\$SSLDIR/key.kdb"; then
  echo "    keystore already present, leaving it alone"
else
  echo "    creating keystore and self-signed certificate"
  # -san_ipaddr covers BOTH addresses. The gateway dials the private address and
  # a SQL client on the workstation dials the public one; a certificate naming
  # only one of them fails validation for the other.
  docker exec "\$CONTAINER" su - db2inst1 -c "
    set -e
    gsk8capicmd_64 -keydb -create -db \$SSLDIR/key.kdb -pw '\$KSPW' -type cms -stash
    gsk8capicmd_64 -cert -create -db \$SSLDIR/key.kdb -pw '\$KSPW' \
      -label db2cert -dn 'CN=vm-db2,O=NBKI Demo' \
      -size 2048 -sigalg SHA256WithRSA -expire 3650 -default_cert yes \
      -san_ipaddr '\$PRIVATE_IP,\$PUBLIC_IP'
    gsk8capicmd_64 -cert -extract -db \$SSLDIR/key.kdb -pw '\$KSPW' \
      -label db2cert -target \$SSLDIR/db2cert.arm -format ascii
  "
fi

echo "    applying dbm cfg"
# Re-applied on EVERY run, not just first configuration, and DB2COMM is the
# reason. The Db2 Community Edition image's entrypoint sets DB2COMM=TCPIP each
# time the container starts, silently dropping SSL. Everything else survives on
# the /database volume -- keystore, SSL_SVCENAME, SSL_SVR_LABEL -- and the port
# stays published, so the configuration looks entirely correct while nothing
# listens on the TLS port. Observed after a deallocate/start cycle: Fabric simply
# reports the source unreachable. Setting it again costs a second.
docker exec "\$CONTAINER" su - db2inst1 -c "
  set -e
  db2 update dbm cfg using SSL_SVR_KEYDB \$SSLDIR/key.kdb
  db2 update dbm cfg using SSL_SVR_STASH \$SSLDIR/key.sth
  db2 update dbm cfg using SSL_SVR_LABEL db2cert
  db2 update dbm cfg using SSL_SVCENAME \$TLS_PORT
  db2set -i db2inst1 DB2COMM=TCPIP,SSL
" >/dev/null

echo "    restarting the instance so the listener picks it up"
docker exec "\$CONTAINER" su - db2inst1 -c "db2stop force" >/dev/null 2>&1 || true
docker exec "\$CONTAINER" su - db2inst1 -c "db2start" >/dev/null
docker exec "\$CONTAINER" su - db2inst1 -c "db2 activate database ${NBKI_DB2_DATABASE:-NBKI}" >/dev/null 2>&1 || true

echo "    verifying the instance is listening on \$TLS_PORT"
listening=0
for i in \$(seq 1 30); do
  if docker exec "\$CONTAINER" bash -c "ss -ltn 2>/dev/null | grep -q ':\$TLS_PORT ' || netstat -ltn 2>/dev/null | grep -q ':\$TLS_PORT '"; then
    listening=1
    break
  fi
  sleep 5
done

# Do not trust the socket probe alone. Both \`ss\` and \`netstat\` are silenced with
# 2>/dev/null, so an image without either would make the probe fail forever and
# this script would otherwise print "Db2 is up with a TLS listener" after 150
# seconds of silence. Confirm against Db2's own configuration as well, which
# needs no tools at all.
cfg_ok=0
if docker exec "\$CONTAINER" su - db2inst1 -c "db2 get dbm cfg" \
     | grep -Ei 'SSL_SVCENAME' | grep -q "\$TLS_PORT"; then
  cfg_ok=1
fi

if (( listening == 0 && cfg_ok == 0 )); then
  echo "ERROR: nothing is listening on \$TLS_PORT and SSL_SVCENAME is not set to it." >&2
  echo "       docker logs --tail 50 \$CONTAINER" >&2
  echo "       docker exec \$CONTAINER su - db2inst1 -c 'db2 get dbm cfg | grep -i ssl'" >&2
  exit 1
fi
if (( listening == 1 )); then
  echo "    listening"
else
  echo "    WARNING: could not probe the socket, but SSL_SVCENAME is set correctly"
fi

docker exec "\$CONTAINER" su - db2inst1 -c "db2 get dbm cfg" \
  | grep -Ei 'SSL_SVCENAME|SSL_SVR_LABEL' || true
REMOTE

# ---------------------------------------------------------------------------
# Pull the certificate back. The gateway VM has to trust it, and so does any
# SQL client on the workstation.
# ---------------------------------------------------------------------------
echo
echo "==> Retrieving the certificate for the gateway and SQL clients"
ssh "${SSH_OPTS[@]}" "${TARGET}" \
  'docker exec db2demo cat /database/config/db2inst1/ssl/db2cert.arm' \
  > "${SECRET_DIR}/db2cert.arm"
chmod 0600 "${SECRET_DIR}/db2cert.arm"
echo "    -> ${SECRET_DIR}/db2cert.arm"

echo
echo "==> Db2 is up with a TLS listener"
echo "    cleartext  ${CLEARTEXT_BIND}:50000$( [[ "${CLEARTEXT_BIND}" == "127.0.0.1" ]] && echo '   (host-local only)' || echo '     (NSG: gateway NIC only)' )"
echo "    TLS        0.0.0.0:${TLS_PORT}      (NSG: operator IP + gateway NIC)"
echo
echo "    Next: ./scripts/11_sync_to_vm.sh must finish, then run 04_load.sh on the VM"
