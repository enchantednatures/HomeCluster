# gateway-1 NVIDIA GPU and Ollama

`gateway-1` is the bare-metal gaming desktop. Its RTX 3080 was previously
passed through to the `rusalka` KubeVirt workstation. It now runs on the host
and serves the `ollama` workload in Kubernetes.

## Current layout

| Item | Value |
| --- | --- |
| Node | `gateway-1` |
| GPU | NVIDIA GeForce RTX 3080, 10 GB, PCI `0000:07:00.0` |
| Talos extensions | `nvidia-open-gpu-kernel-modules-lts` 580.178.04-v1.13.9, `nvidia-container-toolkit-lts` 580.178.04-v1.19.1 |
| GPU operator | `gpu-operator` v26.7.2, driver/toolkit disabled |
| Ollama | `ollama/ollama:0.40.16`, one replica, pinned to `gateway-1` |
| Model volume | `ollama-models`, `ceph-block-ssd`, 80 GiB |
| Model | `gemma3:12b`, 100% GPU, 8192 context |
| Tandoor provider | `Ollama Gemma 3 12B`, `openai/gemma3:12b` |

## Talos image

The node boots a custom Image Factory installer containing the previous
extensions plus the NVIDIA LTS modules:

```text
factory.talos.dev/metal-installer/4ebcabb2d7f801a86eb96539ad46973e1144408650e7b3c3649cc6e59a8cb5a5:v1.13.9
```

The machine configuration is not stored in this repository. The applied
changes were:

```yaml
machine:
  install:
    image: factory.talos.dev/metal-installer/4ebcabb2d7f801a86eb96539ad46973e1144408650e7b3c3649cc6e59a8cb5a5:v1.13.9
  kernel:
    modules:
      - name: nvidia
      - name: nvidia_uvm
      - name: nvidia_drm
      - name: nvidia_modeset
---
apiVersion: v1alpha1
kind: PCIDriverRebindConfig
name: "0000:07:00.0"
$patch: delete
---
apiVersion: v1alpha1
kind: PCIDriverRebindConfig
name: "0000:07:00.1"
$patch: delete
```

Then upgrade the node:

```sh
talosctl -n 192.168.1.46 patch mc --patch @gateway-1-nvidia.patch.yaml --mode no-reboot
talosctl -n 192.168.1.46 upgrade \
  --image factory.talos.dev/metal-installer/4ebcabb2d7f801a86eb96539ad46973e1144408650e7b3c3649cc6e59a8cb5a5:v1.13.9
```

Verify:

```sh
talosctl -n 192.168.1.46 get extensions
talosctl -n 192.168.1.46 get modules
talosctl -n 192.168.1.46 read /proc/driver/nvidia/version
```

## Why the GPU operator has driver/toolkit disabled

Talos supplies the NVIDIA kernel modules, userspace libraries, containerd CDI
configuration, and the `nvidia` runtime classes. The operator's toolkit
container tries to write `/etc/containerd/conf.d`, which is read-only on
Talos, so only its device plugin, feature discovery, validator, and DCGM
exporter are used.

Two Talos-specific workarounds are required:

- The validator only searches `/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`, and
  `/opt/bin` for `nvidia-smi`. The Talos extension installs it in
  `/usr/local/bin`, so the `nvidia-smi-host-shim` DaemonSet symlinks it into
  `/opt/bin`.
- The same shim creates `/run/nvidia/validations/toolkit-ready`, which the
  device plugin and validator normally expect the toolkit container to write.

Both are in `kubernetes/operators/nvidia-gpu-operator/app/daemonset.yaml`.

## Operating Ollama

```sh
kubectl -n ollama get pods
kubectl -n ollama exec deploy/ollama -- ollama list
kubectl -n ollama exec deploy/ollama -- ollama ps
kubectl -n ollama exec deploy/ollama -- nvidia-smi
```

Pull another model:

```sh
kubectl -n ollama exec deploy/ollama -- ollama pull <model>
```

The model store is a Ceph RBD volume, so the pod is pinned to `gateway-1` and
uses `strategy: Recreate`.

## Tandoor

Tandoor reaches the OpenAI-compatible endpoint at:

```text
http://ollama.ollama.svc.cluster.local:11434/v1
```

The custom URL is whitelisted through `AI_ALLOWED_URLS` in the Tandoor
HelmRelease. A global AI provider named `Ollama Gemma 3 12B` is configured with
model `openai/gemma3:12b` and API key `ollama`. `GUNICORN_TIMEOUT` is raised to
180 seconds because AI calls are synchronous.

## Reverting to rusalka

Restore the GPU passthrough in all three places together:

1. Re-add `PCIDriverRebindConfig` for `0000:07:00.0` and `0000:07:00.1` to the
   Talos machine configuration.
2. Re-add the two RTX 3080 entries to KubeVirt `permittedHostDevices`.
3. Re-add `gpus` and the GPU audio `hostDevices` to the `rusalka` VM, set
   `runStrategy: Always`, and remove the Ollama deployment or point it at a
   different GPU node.

Rusalka and the host NVIDIA driver cannot own the GPU at the same time.

## Known issue

`gateway-1` has a history of `NodeNotReady` events and kubelet/apid restarts.
The Ollama pod is correctly running on the GPU, but node-level instability
will interrupt inference until the underlying hardware or Talos issue is
fixed.
