# Lab netboot integration

Run from the collection root with a current Casval lease. This scenario creates
five disposable KubeVirt guests in `molecule`: a Debian builder, a Debian
NFS/HTTP server, RouterOS CHR, and two board substitutes. Every guest requires
Casval placement; generated persistent disks use `lvms-casval`.

## Run

Install `requirements-molecule.txt` in a local virtual environment and activate
it. `ansible-pylibssh` needs the libssh development headers when a wheel is not
available for the controller's Python version. The controller also needs `oc`,
`ssh`, `sshpass`, `rsync`, and the selected credential profile.

```bash
use ocp
oc whoami --show-server
oc whoami
make molecule-kubevirt
```

The credential must manage VMs, VMIs, Services, DataVolumes/PVCs and
UserDefinedNetworks and read their generated NetworkAttachmentDefinitions in
`molecule`, and read/list Nodes. The existing
`ocp-ansible-molecule` profile lacks secondary-network permissions; use a
suitable profile rather than changing shared RBAC as part of a test.

The dependency phase installs the centrally pinned test collections and builds
and installs this checkout into its local `.ansible/collections`. Tests therefore
exercise the working collection, including uncommitted changes. The normal
`make molecule` suite excludes this live-cluster scenario; invoke it explicitly.

The default run seeds a cached build with the generated, bootable Debian x86
fixture, then runs the actual `image_build` cache-hit and publication workflows.
To force real compilation instead of reusing the seeded cache:

```bash
LAB_NETBOOT_BUILD=true make molecule-kubevirt
```

The builder has four CPUs, 8 GiB RAM and a 100 GiB boot disk. A real build can
take considerably longer than the fixture tests and requires upstream build
and package registries. The default run verifies cached-image reuse and
publication without simulating compilation.

Uncached `uefi-x86/current` compilation at the lab pin `v26.8.0-trunk.180`
failed on 2026-11-10 because Armbian's Apple-driver kernel patches no longer
applied to the fetched kernel source. The optional build exposes this upstream
compatibility failure; it has not passed full compilation. The default cached
build and publication checks remain independently testable.

## Functional checks

- Reuse a cached image through `image_build`, publish it over the real
  builder/controller/server SSH path, and verify its downloaded checksum.
- Stage one image for two hosts through the real collection playbook; verify
  independent SSH identities, cached extraction and forced refresh.
- Upload actual kernel/initrd/DTB bytes and MAC-specific pins through the
  RouterOS reference playbooks, retrieve them over TFTP, and compare the kernel
  bytes against the image.
- Exercise compressed and raw images from local and HTTP sources against real
  managed disks. Reject partition targets, mounted disks and malformed inputs;
  verify rejected writes leave the target unchanged.
- Provision local filesystems, validate their generated mount table with
  `findmnt`, retain application data across reprovisioning, and verify an
  excluded disk remains byte-identical.
- Authenticate as the bootstrapped automation user and execute `sudo -n`.
- Boot a real kernel onto NFS, simulated SD and local root filesystems. Check
  the kernel boot ID changes and run `board_boot_verify` against the actual `/`.
- Exercise publication retention through HTTP responses for current, stale and
  unmanaged artifacts.

The sequence omits Molecule's blanket idempotence action because imaging,
forced refresh and kernel transitions intentionally change state. The cached
staging and data-preservation cases exercise their repeat-run contracts directly.

## Virtual-board boundary

The power transport uses kexec with the selected x86 kernel/rootfs. It exercises
Linux NFS-root, disk imaging, local provisioning and boot verification without
pretending to emulate Rockchip BootROM, U-Boot `localcmd`, SPI flash, actual
SD/eMMC controllers, PHY behavior or switch PoE. The DTB is an explicitly marked
transport fixture. Firmware and physical cold-boot acceptance remain hardware
tests. The lab-specific wrappers have their companion `armbian-netboot` scenario
in `igou-ansible`.

CHR uses e1000 interfaces: the default virtio interfaces were inactive in the
tested image. CDI receives an unpacked raw CHR image from this run's HTTP
Service; importing the vendor ZIP directly produces an unbootable disk despite
a successful CDI import. Setup creates a dedicated test account because the
factory admin's interactive password-change prompt blocks network_cli.
Kernel downloads run one at a time because the free CHR license limits
transmission to 1 Mbps per interface; allow several minutes for TFTP verification.
See [MikroTik's CHR licensing documentation](https://help.mikrotik.com/docs/spaces/ROS/pages/18350234/Cloud%20Hosted%20Router%20CHR).

## Recovery and cleanup

```bash
MOLECULE_GLOB='extensions/molecule/*/molecule.yml' molecule destroy -s lab_netboot
```

Keep the Molecule ephemeral directory until destroy succeeds. The provisioner
owns VM/Service/DataVolume/PVC lifecycle. Consumer state records the private
OVN Layer 2 UserDefinedNetwork and fixture HTTP Service; cleanup verifies their
ownership and removes them only after guest destruction. Passwords and keys are generated per run,
kept outside Git and removed after successful cleanup. Never reset Molecule
state or delete the shared namespace to recover a failed run.
