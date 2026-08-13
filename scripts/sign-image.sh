#!/usr/bin/env bash
# sign-image.sh — cosign-sign an image in the local (insecure) registry.
#
# Prereqs: cosign on PATH, private key in keys/cosign.key, local registry at
# 127.0.0.1:5000. Note: keep cosign.key OUT of git (see .gitignore); the POC
# repo ships only the public key.
set -euo pipefail

REG="${REG:-127.0.0.1:5000}"
IMAGE="${1:?usage: sign-image.sh <repo/image:tag>}"
KEY="${COSIGN_KEY:-keys/cosign.key}"
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"

cosign sign \
  --key "$KEY" \
  --allow-insecure-registry \
  --allow-http-registry \
  --yes \
  "$REG/$IMAGE"

echo "Signed $REG/$IMAGE"
