# wtf on Proxmox VE

Portable scripts for running the full `wtf` snapshot-fuzzing pipeline on
Proxmox VE: a Windows target VM you snapshot from, and one or more Ubuntu
fuzzer nodes (master + fuzz clients) that consume the snapshot.

Everything in this directory runs on a Proxmox host (`pve`/`qm` available)
or inside the guests it provisions. No Proxmox API token required.

## Layout

```
proxmox/
├── provision-windows-target.sh   # creates the Windows snapshot-source VM
├── provision-fuzzer-node.sh      # builds an Ubuntu template + clones fuzzer nodes
├── cloud-init/
│   └── fuzzer-user-data.yaml     # cloud-init that builds wtf inside the fuzzer VM
└── scripts/
    ├── start-master.sh           # run on the master VM
    └── start-fuzz.sh             # run on each fuzz-client VM
```

## Prerequisites on the Proxmox host

- Proxmox VE 8.x with `qm` in PATH.
- The default `local` storage with `snippets` content enabled (Datacenter →
  Storage → local → Content → Snippets). The fuzzer template uses this for
  cloud-init custom user-data.
- A storage pool for VM disks (default `local-lvm`).
- A Windows installation ISO and the VirtIO drivers ISO available, e.g.
  uploaded to `local:iso/`. Grab VirtIO from
  https://github.com/virtio-win/virtio-win-pkg-scripts.
- Your SSH public key at `~/.ssh/id_ed25519.pub` (or pass `--ssh-key`).

## 1. Provision the Windows target VM

```sh
./provision-windows-target.sh \
    --vmid 9000 \
    --name wtf-win-target \
    --iso local:iso/Win11.iso \
    --virtio-iso local:iso/virtio-win.iso
```

The script creates a 1-vCPU, 4GB-RAM VM with VirtIO disk + NIC, OVMF, the
QEMU guest agent enabled, and `COM1` exposed as a host-side Unix socket at
`/var/run/qemu-server/9000.serial0` (for KD). Start it with `qm start 9000`
and finish Windows setup in the noVNC console — load the VirtIO storage
driver from the second CD when the installer asks for a disk.

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

### (Optional) kernel debugging over COM1

If you need to live-debug the kernel while taking the snapshot, the
provision script wires `COM1` to a host socket. From any Linux box that can
reach the Proxmox host:

```sh
ssh root@<proxmox-host> 'socat - UNIX-CONNECT:/var/run/qemu-server/9000.serial0' \
    | windbg-equivalent
```

…and inside Windows:

```
bcdedit /debug on
bcdedit /dbgsettings serial debugport:1 baudrate:115200
```

## 2. Build the fuzzer template (once)

```sh
./provision-fuzzer-node.sh --build-template
```

This downloads the Ubuntu 24.04 cloud image, installs the cloud-init
snippet at `local:snippets/wtf-fuzzer-user.yaml`, creates VMID 9099 as a
template, and on first boot the template will `apt install` the build
toolchain, clone wtf, and run `build-release.sh`. The build happens inside
the cloned VMs, not the template itself, so first boot of each clone takes
a few minutes — watch progress via `tail -f /var/log/cloud-init-output.log`.

Override the wtf source with `--wtf-repo`/`--wtf-branch` if you're fuzzing
your own fork.

## 3. Clone master + fuzz clients

```sh
# master node — needs to be reachable by all fuzz clients on tcp/31337
./provision-fuzzer-node.sh --clone --vmid 9100 --name wtf-master \
    --cores 2 --memory 4096

# fuzz clients — give them lots of cores; one wtf fuzz process per core
./provision-fuzzer-node.sh --clone --vmid 9101 --name wtf-fuzz-01 \
    --cores 16 --memory 16384
./provision-fuzzer-node.sh --clone --vmid 9102 --name wtf-fuzz-02 \
    --cores 16 --memory 16384
```

## 4. Run the fuzzing job

SSH to the master and copy the snapshot you took in step 1 into
`~/wtf/targets/<name>/state/`. Then:

```sh
# on the master
./wtf/proxmox/scripts/start-master.sh hevd --max_len=1028 --runs=10000000

# on each fuzz client (rsync the target dir first)
rsync -a wtf-master:~/wtf/targets/hevd ~/wtf/targets/
sudo ./wtf/proxmox/scripts/start-fuzz.sh hevd <master-ip> \
    --backend=kvm --limit 10000000
```

The `kvm` backend requires `sudo` (needs `/dev/kvm` plus PMU MSR access).
For the `bochscpu` backend, drop `--backend=kvm` and skip `sudo`. `whv` is
Windows-only and not usable from Linux fuzzer nodes.

## Notes & gotchas

- **CPU type matters.** The Windows target VM uses `--cpu host` so the
  CPUID/MSR view in the snapshot matches what KVM exposes on the fuzzer
  nodes. If your fuzzer nodes run on different-generation hardware than
  the target host, pin both to a common Proxmox CPU model (e.g.
  `--cpu x86-64-v3`) on both `provision-*` scripts.
- **One vCPU only on the target.** wtf snapshots single-CPU state. Don't
  bump `--cores` on the Windows VM.
- **Nested virtualization.** Fuzzer nodes use `/dev/kvm` from inside the
  Proxmox guest, which requires nested virt enabled on the Proxmox host
  (`echo 'options kvm-intel nested=Y' > /etc/modprobe.d/kvm-intel.conf`,
  reboot, verify with `cat /sys/module/kvm_intel/parameters/nested`).
- **Snapshot transfer.** `mem.dmp` is the size of guest RAM (4GB here).
  Use `rsync` with `-z` if your fuzzer nodes are on a different host.
- **Coverage breakpoints.** For the `kvm`/`whv` backends you need a `.cov`
  file under `targets/<name>/coverage/`. Generate it with
  `scripts/gen_coveragefile_ida.py` (or the binja/ghidra variants) against
  the binaries you snapshotted.
