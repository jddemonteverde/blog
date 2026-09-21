#!/usr/bin/env bash
# Host firewall (UFW) for a homelab Ubuntu server.
#
# Default-deny inbound. Allows SSH from the LAN only. On a k3s node it also
# allows the control plane from the LAN, pod/service traffic, and the
# node-to-node ports so multi-node networking keeps working. Public web ports
# (80/443) are OFF by default — enable them with --public-web only if you
# decide to port-forward to the ingress.
#
# Usage:
#   sudo ./firewall.sh                  # k3s server node (default)
#   sudo ./firewall.sh --agent          # k3s agent (worker) node
#   sudo ./firewall.sh --no-k3s         # plain server, no k3s rules
#   sudo ./firewall.sh --public-web     # also open 80/443 to everyone
#   sudo ./firewall.sh --ssh-port 2222  # if sshd listens elsewhere
#   sudo ./firewall.sh --lan 10.0.0.0/24
#   sudo ./firewall.sh --dry-run        # print the commands, change nothing
#   sudo ./firewall.sh --yes            # don't prompt before enabling
#
# The script is idempotent: re-running it re-applies the same rule set.
# When you add a node to the cluster, re-run it on EVERY node so the
# node-to-node rules are in place on all of them.

set -euo pipefail

# ---- Defaults (override with flags) --------------------------------------
LAN_CIDR="192.168.1.0/24"      # where you administer the box from
SSH_PORT="22"

K3S_ENABLED=1
K3S_ROLE="server"              # server | agent

# k3s defaults. Change these only if you pass --cluster-cidr / --service-cidr
# to the k3s installer.
K3S_POD_CIDR="10.42.0.0/16"
K3S_SVC_CIDR="10.43.0.0/16"
K3S_API_PORT="6443"

# Where the other cluster nodes live. Empty = same as LAN_CIDR. Narrow it
# with --nodes <cidr> if your nodes sit in their own subnet.
K3S_NODE_CIDR=""
# --------------------------------------------------------------------------

DRY_RUN=0
PUBLIC_WEB=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --public-web) PUBLIC_WEB=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --no-k3s)     K3S_ENABLED=0 ;;
    --agent)      K3S_ROLE="agent" ;;
    --server)     K3S_ROLE="server" ;;
    --ssh-port)   SSH_PORT="$2"; shift ;;
    --lan)        LAN_CIDR="$2"; shift ;;
    --nodes)      K3S_NODE_CIDR="$2"; shift ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$K3S_NODE_CIDR" ]] || K3S_NODE_CIDR="$LAN_CIDR"

# First non-loopback IPv4 address — only used in the final reminder.
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_IP="${HOST_IP:-<this host>}"

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  %s\n' "$*"
  else
    "$@"
  fi
}

if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then
  echo "This script must run as root: sudo $0 $*" >&2
  exit 1
fi

if ! command -v ufw >/dev/null; then
  echo "ufw not found — installing."
  run apt-get install -y ufw
fi

echo "== Plan =="
echo "  LAN:      $LAN_CIDR"
echo "  SSH port: $SSH_PORT"
if [[ $K3S_ENABLED -eq 1 ]]; then
  echo "  k3s:      $K3S_ROLE node, peers in $K3S_NODE_CIDR"
else
  echo "  k3s:      none"
fi
echo "  Web:      $([[ $PUBLIC_WEB -eq 1 ]] && echo 'open 80/443 to everyone' || echo 'closed')"
echo

echo "== Safety check =="
echo "Have a SECOND SSH session or the physical console open before continuing."
echo "If a rule is wrong you will fix it from there."
if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
  read -r -p "Continue? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

echo "== Making sure UFW filters IPv6 too =="
# The host may have a global IPv6 address; the rules below must apply to it.
run sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw

echo "== Resetting to a known state =="
# --force skips the interactive prompt. This wipes existing user rules so the
# script is idempotent. Firewall is disabled during reset; we enable at the end.
run ufw --force reset

echo "== Default policy: deny in, allow out, deny routed =="
run ufw default deny incoming
run ufw default allow outgoing
run ufw default deny routed

echo "== SSH: LAN only =="
# The rate limit (limit) blocks an IP after 6 attempts in 30s.
run ufw limit from "$LAN_CIDR" to any port "$SSH_PORT" proto tcp comment 'SSH from LAN'

if [[ $K3S_ENABLED -eq 1 ]]; then
  if [[ "$K3S_ROLE" == "server" ]]; then
    echo "== k3s control plane: LAN only =="
    # kubectl from your workstation, and agents joining the cluster.
    run ufw allow from "$LAN_CIDR" to any port "$K3S_API_PORT" proto tcp comment 'k3s API (kubectl, agents) from LAN'
  fi

  echo "== k3s pod and service networks =="
  # Without these, k3s pods can't reach services or each other once UFW is on.
  run ufw allow from "$K3S_POD_CIDR" to any comment 'k3s pods'
  run ufw allow from "$K3S_SVC_CIDR" to any comment 'k3s services'

  echo "== k3s node-to-node ports =="
  run ufw allow from "$K3S_NODE_CIDR" to any port 10250 proto tcp comment 'kubelet metrics (nodes)'
  run ufw allow from "$K3S_NODE_CIDR" to any port 8472 proto udp comment 'flannel VXLAN (nodes)'
  run ufw allow from "$K3S_NODE_CIDR" to any port 51820 proto udp comment 'flannel wireguard (nodes)'
  if [[ "$K3S_ROLE" == "server" ]]; then
    run ufw allow from "$K3S_NODE_CIDR" to any port 2379:2380 proto tcp comment 'etcd (HA servers)'
  fi
else
  echo "== k3s: skipped (--no-k3s) =="
fi

if [[ $PUBLIC_WEB -eq 1 ]]; then
  echo "== Public web: 80/443 open to everyone =="
  run ufw allow 80/tcp comment 'HTTP ingress'
  run ufw allow 443/tcp comment 'HTTPS ingress'
else
  echo "== Public web: NOT opened (pass --public-web if you port-forward 80/443) =="
fi

echo "== Logging =="
run ufw logging low

echo "== Enabling =="
run ufw --force enable

echo
echo "== Result =="
if [[ $DRY_RUN -eq 0 ]]; then
  ufw status verbose
  echo
  echo "Now, from your workstation, open a NEW ssh session to $HOST_IP and confirm it works"
  echo "before closing the one you kept as a safety net."
else
  echo "(dry run — nothing changed)"
fi
