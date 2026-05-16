# wtf on Proxmox VE

Portable scripts for running the full `wtf` snapshot-fuzzing pipeline on
Proxmox VE: a Windows target VM you snapshot from, and one or more Ubuntu
fuzzer nodes (master + fuzz clients) that consume the snapshot.

Everything in this directory runs on a Proxmox host (`pve`/`pct`/`qm`
available) or inside the guests it provisions. No Proxmox API token
required.

## Layout

```
proxmox/
├── provision-fuzzer-lxc.sh       # provisions an Ubuntu LXC fuzzer node (recommended)
├── provision-fuzzer-node.sh      # VM-based alternative (cloud-init template + clones)
├── cloud-init/
│   └── fuzzer-user-data.yaml     # cloud-init that builds wtf inside the fuzzer VM
└── scripts/
    ├── start-master.sh           # run on the master VM/CT
    └── start-fuzz.sh             # run on each fuzz-client VM/CT
```

The Windows target VM is provisioned manually (see step 1 below); the
fuzzer nodes are automated.

### LXC vs VM for fuzzer nodes

The LXC path is recommended for almost everyone — `--kvm` makes a
privileged container that bind-mounts `/dev/kvm` from the host, so you get
native (non-nested) KVM speed without installing build tools on the
Proxmox host itself.

| | LXC (`provision-fuzzer-lxc.sh`) | VM (`provision-fuzzer-node.sh`) |
| --- | --- | --- |
| `bochscpu` backend | ✅ default (unprivileged) | ✅ |
| `kvm` backend | ✅ with `--kvm` (privileged + `/dev/kvm` passthrough) | ✅ via **nested** KVM |
| Boot time | seconds | minutes (cloud-init builds wtf on first boot) |
| RAM/CPU overhead | minimal (shares host kernel) | full guest kernel per node |
| Isolation | weaker — shared kernel; privileged ≈ root on host | strong (separate kernel) |
| Best for | master + most fuzz clients | when you want hard isolation |

Use VMs only if you really need separate kernels (e.g. you're fuzzing
something that could escape a container, or you're sharing the host with
other tenants).

## Prerequisites on the Proxmox host

- Proxmox VE 8.x with `pct` (LXC) and `qm` (VM) in PATH.
- A storage pool for VM/CT disks (default `local-lvm`) and the LXC template
  storage (default `local`).
- A Windows installation ISO and the VirtIO drivers ISO available, e.g.
  uploaded to `local:iso/`. Grab VirtIO from
  https://github.com/virtio-win/virtio-win-pkg-scripts.
- Your SSH public key at `~/.ssh/id_ed25519.pub` (or pass `--ssh-key`).
- **Only if you use the VM script (`provision-fuzzer-node.sh`):** the
  `local` storage needs the `snippets` content type enabled so cloud-init
  custom user-data can be staged. Easiest way:
  ```sh
  pvesm set local --content iso,vztmpl,backup,snippets
  ```
  The LXC script does not need this.

## 1. Create the Windows target VM (manual)

Create this VM yourself through the Proxmox UI (Datacenter → Create VM) or
`qm` on the host. The settings that matter for wtf:

| Setting | Value | Why |
| --- | --- | --- |
| OS type | Microsoft Windows 11/2019/2022 | matches your install ISO |
| Machine | `q35` | required for OVMF / modern Windows |
| BIOS | `OVMF (UEFI)` + EFI disk | Windows 11 needs UEFI + Secure Boot |
| CPU type | `host` (or a fixed model like `x86-64-v3`) | snapshot CPUID must match the fuzzer node CPU |
| Sockets / Cores | **1 / 1** | wtf snapshots single-CPU state — do not bump this |
| Memory | 4096 MiB, ballooning off | wtf README recommendation |
| SCSI controller | `VirtIO SCSI single` | |
| Disk | 64 GiB VirtIO SCSI, discard on, iothread on | |
| Network | `virtio`, bridge `vmbr0` | |
| CD-ROM 1 | your Windows ISO | |
| CD-ROM 2 | `virtio-win.iso` | load storage driver during install |
| QEMU Agent | enabled | |
| Tablet pointer | disabled | reduces snapshot churn |

### Add a COM1 serial port for KD (required for kernel debugging)

wtf takes the snapshot from a debugger session, so you need a serial port
exposed on the VM and reachable from a debugger. Add it after the VM is
created:

```sh
qm set <vmid> --serial0 socket
```

Once the VM is started, Proxmox exposes COM1 on the host as a Unix socket
at `/var/run/qemu-server/<vmid>.serial0`. To attach a debugger from
another machine, forward it over SSH/TCP:

```sh
# on the Proxmox host, expose the socket as a TCP listener
socat TCP-LISTEN:5555,reuseaddr,fork \
      UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0
```

Then connect windbg/kd to `tcp:port=5555,server=<proxmox-host>` (or use
windbg's `com:pipe,…` over an SSH tunnel).

Inside Windows, enable kernel debugging over COM1 once and reboot:

```
bcdedit /debug on
bcdedit /dbgsettings serial debugport:1 baudrate:115200
```

### Inside the Windows VM

1. Install the
   [Windows SDK Debugging Tools](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/)
   (windbg / kd).
2. Drop [snapshot.dll](https://github.com/0vercl0k/snapshot) somewhere
   reachable by windbg.
3. Bring the process you want to fuzz to the desired state (see the
   [wtf README](../README.md#how-does-it-work) walkthrough).
4. Take the snapshot:
   ```
   kd> .load c:\path\to\snapshot.dll
   kd> !snapshot c:\state
   ```
5. Copy `c:\state\{mem.dmp,regs.json,symbol-store.json}` to the master VM
   under `~/wtf/targets/<your-target>/state/`.

## 2. Provision fuzzer nodes (LXC, recommended)

Each invocation builds one container end-to-end: downloads the Ubuntu
24.04 LXC template on first run, `pct create`s the container, installs
the build toolchain, clones wtf, runs `build-release.sh`, and prints the
container's IP when it's ready.

```sh
# master node — bochscpu only, no /dev/kvm needed
./provision-fuzzer-lxc.sh --ctid 9201 --hostname wtf-master \
    --cores 2 --memory 4096

# kvm-backend fuzz client (privileged, /dev/kvm bind-mounted from host)
./provision-fuzzer-lxc.sh --ctid 9202 --hostname wtf-fuzz-01 \
    --cores 16 --memory 16384 --kvm

# bochscpu-only fuzz client (unprivileged, lighter)
./provision-fuzzer-lxc.sh --ctid 9203 --hostname wtf-fuzz-bx-01 \
    --cores 16 --memory 16384
```

What `--kvm` does:
- Sets the container to **privileged** (`--unprivileged 0`).
- Bind-mounts `/dev/kvm` from the host into the container and allows the
  device in the cgroup. Uses `pct set --dev0 /dev/kvm` on Proxmox VE 8.2+,
  falls back to writing raw `lxc.*` config to `/etc/pve/lxc/<ctid>.conf`
  on older versions.
- Sets the in-container `kvm` group GID to match the host's so the `wtf`
  user can access `/dev/kvm` without sudo.

Override the wtf source with `--wtf-repo`/`--wtf-branch` if you're fuzzing
your own fork.

## 3. (Alternative) Provision fuzzer nodes as VMs

Skip this section if you used the LXC path. Use VMs only if you need
hard kernel-level isolation.

Build the cloud-init template once:

```sh
./provision-fuzzer-node.sh --build-template
```

This downloads the Ubuntu 24.04 cloud image, installs the cloud-init
snippet at `local:snippets/wtf-fuzzer-user.yaml`, and creates VMID 9099 as
a template. On first boot of each clone, cloud-init will `apt install` the
build toolchain, clone wtf, and run `build-release.sh` — first boot of
each clone takes a few minutes (watch via
`tail -f /var/log/cloud-init-output.log` inside the VM).

Then clone master + fuzz clients:

```sh
./provision-fuzzer-node.sh --clone --vmid 9100 --name wtf-master \
    --cores 2 --memory 4096
./provision-fuzzer-node.sh --clone --vmid 9101 --name wtf-fuzz-01 \
    --cores 16 --memory 16384
```

VM fuzz clients use **nested** KVM, which requires nested virt enabled on
the Proxmox host — see "Notes & gotchas" below.

## 4. Run the fuzzing job

SSH to the master and copy the snapshot you took in step 1 into
`~/wtf/targets/<name>/state/`. Then:

```sh
# on the master
./wtf/proxmox/scripts/start-master.sh hevd --max_len=1028 --runs=10000000

# on each fuzz client (rsync the target dir first)
rsync -a wtf-master:~/wtf/targets/hevd ~/wtf/targets/
./wtf/proxmox/scripts/start-fuzz.sh hevd <master-ip> \
    --backend=kvm --limit 10000000
```

Backend selection:
- **LXC w/ `--kvm`**: drop the `sudo` — the `wtf` user is in the `kvm`
  group and `/dev/kvm` is bind-mounted.
- **VM with nested KVM**: needs `sudo` (PMU MSR access requires it).
- **bochscpu**: drop `--backend=kvm`, no sudo. Works on every flavor.
- **whv**: Windows-only, not usable from Linux fuzzer nodes.

## Notes & gotchas

- **CPU type matters.** The Windows target VM uses `--cpu host` so the
  CPUID/MSR view in the snapshot matches what KVM exposes on the fuzzer
  nodes. If your fuzzer nodes run on different-generation hardware than
  the target host, pin both to a common Proxmox CPU model (e.g.
  `--cpu x86-64-v3`) on both `provision-*` scripts.
- **One vCPU only on the target.** wtf snapshots single-CPU state. Don't
  bump `--cores` on the Windows VM.
- **Nested virtualization** is only needed for the **VM** fuzzer path
  (`provision-fuzzer-node.sh`) — those use `/dev/kvm` from inside a guest.
  Enable on the host with
  `echo 'options kvm-intel nested=Y' > /etc/modprobe.d/kvm-intel.conf`,
  reboot, and verify with `cat /sys/module/kvm_intel/parameters/nested`.
  LXC `--kvm` containers bind-mount the host's `/dev/kvm` directly, so
  nested virt is not required for them.
- **Privileged LXC security.** `--kvm` makes the container privileged
  (root in the CT ≈ root on the host for many kernel APIs). That's fine
  if you trust the workload — wtf is fuzzing snapshots, not running
  untrusted code natively — but don't run other people's workloads in
  the same container.
- **Snapshot transfer.** `mem.dmp` is the size of guest RAM (4GB here).
  Use `rsync` with `-z` if your fuzzer nodes are on a different host.
- **Coverage breakpoints.** For the `kvm`/`whv` backends you need a `.cov`
  file under `targets/<name>/coverage/`. Generate it with
  `scripts/gen_coveragefile_ida.py` (or the binja/ghidra variants) against
  the binaries you snapshotted.
