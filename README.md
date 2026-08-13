# cosign-containerd-poc

Proof of concept: wire a **kind** Kubernetes cluster's containerd to require
**cosign** signatures on every image pull, and observe pass/fail in Kubernetes
events.

When an image is referenced in a Pod, the kubelet asks containerd to pull it.
containerd's [`ImageVerifier` plugin (bindir)](https://github.com/containerd/containerd/blob/main/docs/image-verification.md)
executes every verifier binary found in `bin_dir`. A verifier that returns exit
code `0` allows the pull; any other exit code blocks it. We drop a small
`cosign-verifier` binary there that runs `cosign verify --key` against the
image — so a **signed** image is allowed and an **unsigned / wrong-key** image
is blocked, and the refusal is surfaced in a `Failed to pull image` Kubernetes
event.

## Layout

```
verifier/cosign-verifier              # containerd bindir verifier (runs cosign verify)
keys/cosign.pub                       # trusted cosign public key (the one that ACCEPTS)
node/setup-node.sh                    # wire a kind node: verifier + config + restart
node/containerd-verifier-config.toml  # containerd config additions (documented)
node/hosts.toml                       # insecure-registry hosts.toml for the local registry
deploy/signed-ok.yaml                 # pulls a SIGNED image -> Running
deploy/unsigned-bad.yaml              # pulls an UNSIGNED image -> ImagePullBackOff
scripts/sign-image.sh                 # cosign-sign an image in the local registry
docs/walkthrough.md                   # full end-to-end walkthrough + observed output
```

> Private keys never ship in the repo. `keys/cosign.pub` is public.
> Generate your own keypair with `cosign generate-key-pair` and keep
> `cosign.key` out of git.

## The two pitfalls (read this)

1. **Local-pull mode bypasses the verifier.** kind's default containerd config
   sets `discard_unpacked_layers = true`, which makes containerd fall back to
   *local image pull mode*, and the image verifier **only runs on the transfer
   service path**. Symptoms: signed & unsigned images both pull fine (no
   verification at all). Fix: remove `discard_unpacked_layers` (see
   `node/setup-node.sh`), and confirm with
   `journalctl -u containerd | grep -i "discard"` that the fallback warning is gone.
2. **The transfer resolver needs the registry marked insecure.** Set the CRI
   `registry.config_path` (and transfer `config_path`) to a certs.d directory
   containing a `hosts.toml` for the plain-HTTP local registry. Otherwise the
   resolver tries HTTPS and never even reaches the verification step.

## Quick start (on a kind cluster over podman)

```bash
# 1. Local registry reachable from both host and kind node
podman run -d --name local-registry --network kind --ip 10.89.0.100 \
  -p 127.0.0.1:5000:5000 docker.io/library/registry:2

# 2. Push an image and sign it (see scripts/sign-image.sh)
podman push --tls-verify=false 127.0.0.1:5000/poc/nginx:signed2
./scripts/sign-image.sh poc/nginx:signed2          # needs cosign + keys/cosign.key

# 3. Wire verification into the node
podman cp verifier/cosign-verifier <node>:/opt/cosign-verifier
podman cp keys/cosign.pub        <node>:/opt/cosign.pub
podman cp node/setup-node.sh     <node>:/opt/setup-node.sh
podman exec <node> bash /opt/setup-node.sh

# 4. Deploy both manifests and watch
kubectl apply -f deploy/
kubectl get pods
kubectl describe pod -l app=unsigned-bad | sed -n '/Events:/,$p'
```

See [docs/walkthrough.md](docs/walkthrough.md) for the observed pass/fail output
and the exact Kubernetes events.
