#!/usr/bin/env bash
# Deploy the DOJO on an Oracle Cloud Ampere A1 (ARM64) instance running Ubuntu 24.04.
#
# Usage (as root):
#   DOJO_HOST=dojo.example.com bash deploy-oracle-arm.sh
#
# Optional:
#   REPO_DIR=/srv/dojo        where the repo lives
#   DATA_DIR=/srv/dojo-data   where the dojo keeps all data (use a block volume)
#   DOJO_SSH_PORT=2222        host port that maps to the dojo's SSH service
#   MOVE_HOST_SSH=1           move the host's own sshd from 22 to 2222 so the
#                             dojo can own port 22 (do this only if you know
#                             how to reconnect)
#
# Notes:
#  * The image is built natively for arm64. Kata Containers are amd64-only, so
#    this build skips them and "privileged" challenges fall back to runc.
#  * Challenge images are amd64; qemu-user static + binfmt makes them run
#    (emulated) on ARM. Registering binfmt on the host is done below.

set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "Run as root (sudo -i)" >&2
  exit 1
fi

: "${DOJO_HOST:?Set DOJO_HOST, e.g. DOJO_HOST=dojo.example.com}"
REPO_DIR=${REPO_DIR:-/srv/dojo}
DATA_DIR=${DATA_DIR:-/srv/dojo-data}
DOJO_SSH_PORT=${DOJO_SSH_PORT:-2222}
MOVE_HOST_SSH=${MOVE_HOST_SSH:-0}

echo "=== [1/7] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git qemu-user-static binfmt-support

echo "=== [2/7] Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

echo "=== [3/7] amd64 emulation (binfmt) ==="
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
  update-binfmts --enable qemu-x86_64 || true
fi
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
  docker run --privileged --rm tonistiigi/binfmt --install amd64
fi
systemctl restart systemd-binfmt || true

echo "=== [4/7] Kernel + swap ==="
modprobe br_netfilter || true
if ! swapon --show | grep -q .; then
  fallocate -l 8G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "=== [5/7] SSH port check ==="
if [ "$MOVE_HOST_SSH" = "1" ]; then
  sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
  grep -q '^Port 2222' /etc/ssh/sshd_config || echo 'Port 2222' >> /etc/ssh/sshd_config
  systemctl restart ssh || systemctl restart sshd
  echo "Host SSH moved to 2222; the dojo can now use 22."
else
  echo "Host SSH left on 22; exposing the dojo's SSH service on ${DOJO_SSH_PORT} instead."
fi

echo "=== [6/7] Build image (this takes a while) ==="
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone https://github.com/shemajacque/dojo.git "$REPO_DIR"
fi
cd "$REPO_DIR"
git pull --ff-only || true
mkdir -p "$DATA_DIR"
DOCKER_BUILDKIT=1 docker build -t pwncollege/dojo .

echo "=== [7/7] Run ==="
docker rm -f dojo >/dev/null 2>&1 || true
docker run \
  --name dojo \
  --privileged \
  --restart unless-stopped \
  -v "${REPO_DIR}:/opt/pwn.college" \
  -v "${DATA_DIR}:/data:shared" \
  -p 80:80 -p 443:443 -p "${DOJO_SSH_PORT}:22" \
  -e "DOJO_HOST=${DOJO_HOST}" \
  -e DOJO_ENV=production \
  -d \
  pwncollege/dojo

echo
echo "Started. First boot builds the workspace and challenge images, which can take 30-90 minutes."
echo "Follow it with:  docker exec dojo dojo logs"
echo "Then open:       https://${DOJO_HOST}   (log in as admin / admin, then change the password)"
echo "Workspace host:  https://workspace.${DOJO_HOST}"
echo "Dojo SSH:        ssh -p ${DOJO_SSH_PORT} <user>@${DOJO_HOST}"
