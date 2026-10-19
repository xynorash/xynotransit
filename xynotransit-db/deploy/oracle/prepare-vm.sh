#!/usr/bin/env bash
# Prepares a small Ubuntu VM to run the Xynotransit stack.
#
# Target: Oracle Cloud Always Free VM.Standard.E2.1.Micro (1 GB RAM, x86_64), Ubuntu 24.04 or 26.04
# (Minimal images work). Safe to run again: every step checks before it changes anything.
#
#   sudo ./prepare-vm.sh              do it
#   DRY_RUN=1 ./prepare-vm.sh         only print what would happen
#
# What it does:
#   1. adds a 2 GB swap file (the VM has no swap and only 1 GB of RAM)
#   2. installs Docker and the compose plugin
#   3. keeps Docker logs from filling the disk
#   4. opens TCP 80 and 443 in the VM's own firewall and saves the rule across reboots
#      (Oracle's Ubuntu images reject everything except SSH; the cloud security list is separate)
#   5. adds the login user to the docker group
set -euo pipefail

DRY_RUN=${DRY_RUN:-0}
SWAP_GB=${SWAP_GB:-2}
SWAPFILE=/swapfile

say() { printf '\n== %s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '   [dry run] %s\n' "$*"; else eval "$@"; fi
}

if [ "$DRY_RUN" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

TARGET_USER=${SUDO_USER:-ubuntu}
export DEBIAN_FRONTEND=noninteractive

say "1/5 Swap file (${SWAP_GB} GB)"
if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
  echo "   swap already active"
else
  run "fallocate -l ${SWAP_GB}G $SWAPFILE || dd if=/dev/zero of=$SWAPFILE bs=1M count=$((SWAP_GB * 1024))"
  run "chmod 600 $SWAPFILE"
  run "mkswap $SWAPFILE >/dev/null"
  run "swapon $SWAPFILE"
  if ! grep -qs "^$SWAPFILE " /etc/fstab; then
    run "echo '$SWAPFILE none swap sw 0 0' >> /etc/fstab"
  fi
fi
run "printf 'vm.swappiness=20\n' > /etc/sysctl.d/99-xynotransit.conf"
run "sysctl -q --system"

say "2/5 Docker and compose plugin"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "   Docker already installed: $(docker --version)"
else
  run "apt-get update -qq"
  run "apt-get install -y -qq ca-certificates curl git"
  # Ubuntu's own packages first: Docker's apt repository can lag behind a brand new release.
  if [ "$DRY_RUN" = 1 ] || apt-cache show docker.io >/dev/null 2>&1; then
    run "apt-get install -y -qq docker.io"
    run "apt-get install -y -qq docker-compose-v2 || apt-get install -y -qq docker-compose-plugin"
  else
    echo "   docker.io is not in this release's repositories: using Docker's official installer"
    run "curl -fsSL https://get.docker.com | sh"
  fi
  run "systemctl enable --now docker"
fi

say "3/5 Docker log rotation"
if [ ! -s /etc/docker/daemon.json ]; then
  run "mkdir -p /etc/docker"
  run "printf '{\n  \"log-driver\": \"local\",\n  \"log-opts\": { \"max-size\": \"10m\", \"max-file\": \"3\" }\n}\n' > /etc/docker/daemon.json"
  run "systemctl restart docker"
else
  echo "   /etc/docker/daemon.json exists, left unchanged"
fi

say "4/5 Firewall: allow TCP 80 and 443"
if command -v iptables >/dev/null 2>&1; then
  if iptables -C INPUT -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; then
    echo "   rule already present"
  else
    # Put it before the final REJECT rule so it is actually reached.
    pos=$(iptables -L INPUT --line-numbers -n 2>/dev/null | awk '/REJECT/ {print $1; exit}')
    run "iptables -I INPUT ${pos:-1} -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT"
  fi
  run "apt-get install -y -qq iptables-persistent"
  run "netfilter-persistent save"
else
  echo "   iptables not found: nothing to open inside the VM (the cloud security list still applies)"
fi

say "5/5 Docker group"
if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  echo "   $TARGET_USER is already in the docker group"
else
  run "usermod -aG docker $TARGET_USER"
  echo "   log out and back in once so $TARGET_USER can run docker without sudo"
fi

say "Done"
echo "   swap:     $(swapon --show=SIZE --noheadings 2>/dev/null | tr '\n' ' ')"
echo "   docker:   $(docker --version 2>/dev/null || echo 'not installed (dry run?)')"
echo "   firewall: $(iptables -S INPUT 2>/dev/null | grep -c 'dports 80,443' || true) rule(s) for 80,443"
echo
echo "Next: install the stack (see docs/DEPLOY.md)."
