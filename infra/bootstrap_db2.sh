#!/usr/bin/env bash
#
# bootstrap_db2.sh — turn the bare Ubuntu VM into a Db2 host.
#
# Runs from the operator workstation and drives the VM over SSH. Split into
# phases on purpose:
#
#   1. packages + group membership
#   2. everything that needs `docker` to work as the operator account
#
# They cannot be one SSH session. `usermod -aG docker` does not affect a login
# that is already open, so a single session would add the group and then still
# get "permission denied on /var/run/docker.sock" three lines later. A second
# connection is the fix, not a `newgrp` trick.
#
# The Db2 password is passed on this SSH channel rather than through cloud-init
# user-data: user-data stays readable inside the VM and in the VM model for the
# life of the machine, which is not an appropriate home for the instance owner's
# credential.
#
# Usage:  ./infra/bootstrap_db2.sh
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

echo "==> Waiting for cloud-init to finish"
# "The VM deployment succeeded" says nothing about whether the machine has
# finished booting itself. Ask the machine.
ssh "${SSH_OPTS[@]}" "${TARGET}" 'sudo cloud-init status --wait' || true

echo "==> Phase 1: packages"
ssh "${SSH_OPTS[@]}" "${TARGET}" "bash -seu" <<REMOTE
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg rsync >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io >/dev/null
fi

sudo usermod -aG docker "${NBKI_ADMIN}"

# The load script writes a ~1.1 GB header-stripped .del file next to the CSVs,
# so the operator account must own this tree outright. A root-owned clone looks
# fine until 04_load.sh fails on the largest table, eight minutes in.
sudo mkdir -p ${REMOTE_ROOT}
sudo chown -R "${NBKI_ADMIN}:${NBKI_ADMIN}" ${REMOTE_ROOT}
REMOTE

echo "==> Phase 2: verifying docker is usable as ${NBKI_ADMIN}"
ssh "${SSH_OPTS[@]}" "${TARGET}" 'docker version --format "{{.Server.Version}}"'

echo
echo "==> Bootstrap complete"
echo "    Next: ./scripts/11_sync_to_vm.sh   (this is the long one)"
