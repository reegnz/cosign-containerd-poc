# Walkthrough — observed pass & fail

Environment: kind cluster `dev` (k8s v1.36.1) on an unprivileged Proxmox LXC,
containerd **v2.3.1**, cosign **v3.1.3**, podman rootful, local `registry:2` at
`10.89.0.100:5000` on the kind network.

## Setup summary

```bash
# host: load cosign into the node + install verifier/key + patch config
podman cp /usr/local/bin/cosign  dev-control-plane:/usr/local/bin/cosign
podman cp verifier/cosign-verifier dev-control-plane:/opt/containerd/image-verifier/bin/
podman cp keys/cosign.pub         dev-control-plane:/opt/cosign.pub
podman exec dev-control-plane bash /opt/setup-node.sh   # patch config + restart
```

Node containerd config additions (see `node/containerd-verifier-config.toml`):
the `[plugins."io.containerd.image-verifier.v1.bindir"]` stanza, plus setting
`config_path = "/etc/containerd/certs.d"` for both the transfer service and the
CRI registry, plus removing `discard_unpacked_layers`.

## Failing case (unsigned image)

```bash
kubectl apply -f deploy/unsigned-bad.yaml    # image: .../busybox:unsigned5 (not signed)
```

```text
NAME                            READY   STATUS             RESTARTS
unsigned-bad-7cb8d8bc4d-hnvxj   0/1     ImagePullBackOff   0

Events:
  Normal   Scheduled  18s   default-scheduler  Successfully assigned ... to dev-control-plane
  Normal   BackOff    17s   kubelet            Back-off pulling image "10.89.0.100:5000/poc/busybox:unsigned5"
  Warning  Failed     17s   kubelet            Error: ImagePullBackOff
  Normal   Pulling    1s (x2) kubelet          Pulling image ".../busybox:unsigned5"
  Warning  Failed     1s (x2) kubelet          Failed to pull image ".../busybox:unsigned5":
      failed to pull and unpack image ".../busybox:unsigned5":
      image verifier bindir blocked pull of .../busybox:unsigned5 with digest sha256:7b9a...
      for reason: verifier cosign-verifier rejected image (exit code 1):
      REJECTED: image .../busybox:unsigned5 failed signature verification:
      error during command execution: no signatures found
  Warning  Failed     1s (x2) kubelet          Error: ErrImagePull
```

containerd debug log corroborates:

```text
level=warning "Image verifier blocked pull"
  digest="sha256:7b9a..." name=".../busybox:unsigned5"
  ok=false reason="verifier cosign-verifier rejected image (exit code 1): REJECTED: ..."
```

## Passing case (signed image)

```bash
kubectl apply -f deploy/signed-ok.yaml        # image: .../nginx:signed2 (cosign-signed)
```

```text
NAME                        READY   STATUS    RESTARTS
signed-ok-6975f789cc-dpz7r  1/1     Running   0

Events:
  Normal  Scheduled  18s  default-scheduler  Successfully assigned ... to dev-control-plane
  Normal  Pulling    18s  kubelet            Pulling image ".../nginx:signed2"
  Normal  Pulled     17s  kubelet            Successfully pulled image ".../nginx:signed2" in 533ms
  Normal  Created    17s  kubelet            Container created
  Normal  Started    17s  kubelet            Container started
```

## Debugging log

To see the verifier actually firing, raise containerd log level to debug:

```bash
sudo tee -a /etc/containerd/config.toml <<'EOF'
[log]
  level = "debug"
EOF
systemctl restart containerd
journalctl -u containerd -f | grep -iE "verif|blocked|allowed"
```

## Key insight

Image verification is enforced by **containerd at pull time**, so it is engine
level and independent of RBAC/policy engines layered on top. A Pod can only
Reference the image; whether it is actually pulled is gated by this verifier.
