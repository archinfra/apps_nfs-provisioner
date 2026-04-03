# apps_nfs-provisioner

Offline builder and self-extracting installer for `nfs-subdir-external-provisioner`.

## What It Improves

- Polished build and install output
- Default NFS export path set to `/data/nfs-share`
- Interactive prompt for the NFS server when it is not passed in
- Offline image packaging for `amd64` and `arm64`
- Helm passthrough support after `--`

## Project Layout

```text
.
|-- build.sh
|-- install.sh
|-- charts/
`-- images/
```

## Build

```bash
chmod +x build.sh install.sh
./build.sh --arch amd64
```

Artifacts:

```text
dist/nfs-provisioner-installer-amd64.run
dist/nfs-provisioner-installer-amd64.run.sha256
```

## Install

Standard install:

```bash
./dist/nfs-provisioner-installer-amd64.run install \
  --nfs-server 192.168.10.20
```

Custom export path:

```bash
./dist/nfs-provisioner-installer-amd64.run install \
  --nfs-server 192.168.10.20 \
  --nfs-path /data/custom-share
```

Interactive server input:

```bash
./dist/nfs-provisioner-installer-amd64.run install
```

If `--nfs-server` is omitted, the installer prompts for it interactively. If `--nfs-path` is omitted, it defaults to `/data/nfs-share`.

## Helm Passthrough

Anything after `--` is forwarded directly to `helm`:

```bash
./dist/nfs-provisioner-installer-amd64.run install \
  --nfs-server 192.168.10.20 \
  -- --wait --timeout 5m
```

## Default Runtime Values

- release name: `nfs-subdir-external-provisioner`
- namespace: `kube-system`
- replicas: `1`
- storageClass name: `nfs`
- default storageClass: `true`
- nfs path: `/data/nfs-share`
