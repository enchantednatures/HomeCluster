# Rusalka Arch VM

`rusalka` is a persistent Arch Linux workstation running as a KubeVirt
`VirtualMachine` in the `vms` namespace. It boots the official Arch Linux
cloud image under cloud-init and keeps the RTX 3080, GPU audio, and Intel XHCI
USB controller passthrough that only exist on `gateway-1`.

| Item | Value |
| --- | --- |
| Tailscale hostname | `rusalka` / `rusalka.rya-bebop.ts.net` |
| Compute | 8 vCPU, 16 GiB guest memory |
| Root disk | `rusalka-root`, 120 GiB on `ceph-block-ssd`, imported from the pinned Arch `cloudimg` qcow2 |
| Machine | `pc-q35-rhel9.2.0`, BIOS bootloader |
| Node | `gateway-1` |
| Passthrough | RTX 3080 (`nvidia.com/RTX3080`), RTX 3080 audio (`nvidia.com/RTX3080_AUDIO`), Intel XHCI USB (`usb/intel-xhci`) |
| Interface MAC | `f2:5a:1c:9e:00:01`, pinned on the `default` interface |
| SSH Service | `rusalka-ssh`, `LoadBalancer` with `loadBalancerClass: tailscale`, port 22 only |
| Cloud-init Secret | `rusalka-cloud-init` |
| Public ingress | None. Tailscale only. |

The manifests live in `kubernetes/apps/vms/rusalka/app/`. The Flux
Kustomization is `rusalka` in `flux-system`, with path
`./kubernetes/apps/vms/rusalka/app`.

## Boot and cloud-init

CDI imports the pinned Arch cloud image into the `rusalka-root` DataVolume. The
VM attaches that root disk plus a `cloudinitdisk` that reads
`cloudInitNoCloud.secretRef: rusalka-cloud-init`. cloud-init creates `hcasten`,
installs the public keys, disables password SSH, and enables `sshd` on first
boot. There is no installer ISO and no interactive first-boot step.

The Secret stores the same cloud-config under both `stringData.userdata` and
`stringData.userData`. KubeVirt has used both key spellings, so the Secret keeps
both in sync.

cloud-init runs only on the first boot of a root filesystem. If you change the
Secret, editing and re-encrypting it is not enough: the running guest keeps the
old `authorized_keys`. To apply a new key or cloud-config, update the Secret and
then rebuild or recreate the VM so cloud-init runs against a fresh root. Plan
for that downtime. There is no VolSync backup for this VM, and a lost
`rusalka-root` DataVolume cannot be restored from Git.

## SSH

SSH is key-only and reachable through Tailscale. From a machine on your
tailnet:

```sh
ssh hcasten@rusalka
```

or, using the full MagicDNS name:

```sh
ssh hcasten@rusalka.rya-bebop.ts.net
```

`hcasten` has passwordless `sudo`. Password authentication is disabled with
`ssh_pwauth: false`. Root key login is allowed with
`PermitRootLogin prohibit-password`; the root password is disabled, so root can
only log in with one of the configured keys.

The public keys live in the SOPS-encrypted cloud-init Secret
`rusalka-cloud-init`. Do not add keys anywhere else, and do not commit private
keys.

## VNC

VNC is the KubeVirt `virtualmachineinstances/vnc` subresource. It is not a guest
port, and there is no port 5900 Service. Open a viewer with `virtctl`:

```sh
virtctl vnc rusalka -n vms
```

On macOS you can start a local proxy and connect Screen Sharing to it:

```sh
virtctl vnc rusalka -n vms --proxy-only
```

That command prints the local address and port to use. Both forms tunnel through
the Kubernetes API, so they need a working kubeconfig, not Tailscale SSH.

The Arch cloud image has no VNC server installed. The console you see is the
guest framebuffer, and it stays usable only while the VMI is running.

## Stable interface MAC

The `default` interface is pinned to `f2:5a:1c:9e:00:01`. On first boot,
cloud-init generates the guest network unit that matches that MAC. Without the
pin, KubeVirt assigns a new random pod MAC on every VMI recreation, the guest
unit stops matching, `eth0` stays down, and SSH breaks even though the VMI
reports `Ready`.

If you change the MAC, update the guest network configuration in the same
change. Otherwise the VM loses its network on the next VMI recreation.

## Omarchy

Omarchy is installed manually after Arch boots. cloud-init does not install a
desktop, a display manager, or Omarchy itself. Log in as `hcasten` over SSH or
open the console with `virtctl vnc`, then run the interactive Omarchy installer.
Treat that install as a guest-side step, not as Git-managed state.

## Access model

There is no Cloudflared route, no Istio VirtualService, and no public SSH for
this VM. `rusalka-ssh` is a Tailscale `LoadBalancer` that exposes only port 22.
Use Tailscale for SSH and `virtctl vnc` for the console.
