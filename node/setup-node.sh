#!/usr/bin/env bash
# setup-node.sh — wire cosign image-verification into a kind node's containerd.
#
# Run INSIDE the kind node container (it must contain the cosign binary at
# /usr/local/bin/cosign — copy it in, or install it, before running this).
#
# Usage: podman exec <node> bash /opt/setup-node.sh
#
# This script:
#   1. installs the cosign verifier binary + public key
#   2. adds the insecure-registry hosts.toml for the local HTTP registry
#   3. patches /etc/containerd/config.toml (verifier plugin + transfer/CRI
#      registry config_path) and removes the discard_unpacked_layers line that
#      would force local-pull mode and bypass verification
#   4. restarts containerd + kubelet
set -euo pipefail

BINDIR="/opt/containerd/image-verifier/bin"
VERIFIER_SRC="$(dirname "$0")/cosign-verifier"   # mounted/copied into the node
KEY_SRC="/opt/cosign.pub"
CFG="/etc/containerd/config.toml"
REG="10.89.0.100:5000"

apt_get() { command -v apt-get >/dev/null && apt-get update -qq && apt-get install -y -qq "$@"; }

echo ">> Ensuring cosign binary present"
if ! command -v cosign >/dev/null 2>&1; then
  echo "ERROR: cosign not on PATH inside node (/usr/local/bin/cosign). Copy the binary in first." >&2
  exit 1
fi

echo ">> Installing verifier + key"
mkdir -p "$BINDIR" /etc/containerd/certs.d/$REG
install -m 0755 "$VERIFIER_SRC" "$BINDIR/cosign-verifier"
install -m 0644 "$KEY_SRC" /opt/cosign.pub

echo ">> Writing insecure registry hosts.toml"
cat > /etc/containerd/certs.d/$REG/hosts.toml <<TOML
server = "http://$REG"
[host."http://$REG"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
TOML

echo ">> Patching containerd config"
# Remove the discard_unpacked_layers that would force local-pull (bypass) mode.
sed -i '/discard_unpacked_layers/d' "$CFG"
# Append the verifier + registry config additions (idempotent-ish guard).
if ! grep -q 'io.containerd.image-verifier.v1.bindir' "$CFG"; then
  cat >> "$CFG" <<CONF

[plugins."io.containerd.image-verifier.v1.bindir"]
  bin_dir = "$BINDIR"
  max_verifiers = 10
  per_verifier_timeout = "15s"

[plugins."io.containerd.transfer.v1"]
  config_path = "/etc/containerd/certs.d"

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
CONF
fi

echo ">> Restarting containerd + kubelet"
systemctl restart containerd
sleep 2
systemctl restart kubelet
sleep 1
systemctl is-active containerd kubelet
echo ">> Done. Verifier installed at $BINDIR/cosign-verifier"
