.. _ansible_collections.david_igou.armbian.docsite.reprovision-local-disk:

Runbook: Reprovision a board's local disk
==========================================

How to safely apply (or change) the declarative ``armbian_local_disks`` layout
on a board, using the ``reprovision_to_local.yml`` lifecycle playbook from #77 /
PR #80.

When to use
-----------

- **First time** putting a board on local-disk boot — board currently runs on
  ``armbian_boot_mode: nfs``, you want to provision its NVMe (or SATA, eMMC, USB
  SSD) and flip to ``armbian_boot_mode: local``.
- **Changing the layout** — board is already on local boot but you want a
  different partition shape (add ``/var``, drop ``/boot``, change sizes). The
  lifecycle re-runs end-to-end and your inventory drives the new shape.
  Preserved partitions survive if their label hasn't changed.
- **Recovering** a board whose local rootfs is corrupted — set ``force: true``
  on the binding, re-run; everything wipes including preserved partitions.

NOT for: kernel updates (#78 — separate flow), one-off bootstrap of a freshly
flashed board (use ``bootstrap_armbian.yml`` first), or changing ``boot_mode``
without touching disk (use ``set_boot_mode.yml``).

Pre-flight checklist
--------------------

Before running the playbook, verify:

.. list-table::
   :header-rows: 1
   :widths: 34 40 26

   * - Check
     - Command
     - Expected
   * - Board reachable
     - ``ansible <fqdn> -m ping``
     - ``SUCCESS / pong``
   * - Router reachable
     - ``ansible <router-fqdn> -m community.routeros.command -a 'commands="/system identity print"'``
     - identity line
   * - Per-model TFTP rows present
     - ``ansible <router-fqdn> -m community.routeros.command -a 'commands="/ip tftp print where req-filename~\"<model>\""'``
     - three rows (vmlinuz, initrd.img, board.dtb) with HITS ≥ 1
   * - Inventory has ``armbian_local_disks`` set
     - ``ansible-inventory --host <fqdn>`` then look for the key
     - list of disk bindings
   * - Inventory has ``armbian_poe_switch`` + ``armbian_poe_port``
     - same ``ansible-inventory --host``
     - both present
   * - (Optional) UART dongle present on serial host
     - ``ls /dev/ttyUSB0`` on the serial host
     - char device exists

If TFTP rows are missing, run ``playbooks/stage_router.yml`` first.

If ``armbian_local_disks`` is not set, the playbook will fail in Phase 2
pre-tasks with a clear assertion message — you need to add the binding before
the playbook can proceed.

DSL: declaring the layout
-------------------------

``armbian_local_disks`` is a per-host list. Each element is one disk binding
with ``device``, optional ``wipe`` / ``force``, and a ``layout`` list of
partition specs. Example:

.. code-block:: yaml

   armbian_local_disks:
     - device: /dev/nvme0n1
       wipe: true            # default true; set false for read-only audit mode
       force: false          # default false; true bypasses preserve idempotency
       layout:
         - id: var           # unique within this disk's layout
           size: 20GiB       # MiB|GiB|TiB or 'grow' (exactly one 'grow' per disk)
           type: var         # esp | linux | root | var | home | srv | swap
           format: ext4      # vfat | ext4 | xfs | btrfs | swap
           label: armbi_var  # required if preserve_on_reprovision: true
           mount: /var       # absolute path; written to /etc/fstab
           preserve_on_reprovision: true   # label-keyed idempotency; default false
         - id: root
           size: grow
           type: root
           format: ext4
           label: armbi_root_local
           mount: /

Environment-specific caveats observed in practice
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- **vfat labels must be uppercase ≤11 chars** (FAT spec). The role's pre-flight
  ``_validate.yml`` catches lowercase / overlong labels.
- **``linux`` type translates to ``linux-generic``** for systemd-repart. Use
  ``type: linux`` in the DSL; the template translates.
- **``systemd-repart`` is in a separate package on Debian 13 (Trixie)**.
  ``_apply_repart.yml`` installs it idempotently — no operator action needed on
  Trixie or later.
- **If the running kernel lacks ``CONFIG_VFAT_FS``** (some Armbian rk3588 edge
  kernels do), ``mount.vfat`` fails. Drop the ESP entry from the layout for
  those boards — passthrough boot doesn't read ``/boot/efi`` anyway.
- **If ``/boot`` adds no value for your boot model** (always true under
  passthrough), drop it. Kernel files still rsync into ``/boot/`` as a directory
  inside the root partition; nothing reads them at boot.

Procedure
---------

.. code-block:: bash

   # 1. Edit inventory: add or change armbian_local_disks for
   #    your host. Use `ansible-inventory --host <fqdn>` to verify the
   #    schema parses.

   # 2. Run the lifecycle.
   ansible-playbook playbooks/reprovision_to_local.yml \
     --limit <fqdn> \
     -e target_hosts=<fqdn> \
     -e capture_serial=true     # optional UART tail in diagnostic bundle on failure

``-e target_hosts=<fqdn>``: required if your inventory uses FQDNs
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The playbook's ``hosts:`` default is ``orange-pi-5-max-01`` (short name);
``--limit`` narrows the inventory subset, but ``hosts:`` ALSO needs to match an
inventory entry. If your inventory keys hosts by FQDN (e.g.
``orange-pi-5-max-01.example.lan``), pass ``-e target_hosts=<fqdn>`` to override
the playbook default.

What the playbook does (4 plays)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

1. **Set boot mode to nfs + verify** — board comes up on the NFS rootfs
   (PoE-cycle + PXE + wait for SSH + assert ``findmnt /`` reports nfs/nfs4).
   Uses the same ``_lifecycle_set_and_verify`` block used by Phase 4; on failure
   here the board is already on NFS so no revert needed.
2. **Cross-binding validation + per-disk provision** — asserts no two disks
   share a mount path, exactly one partition declares ``mount: /``, then loops
   ``disk_provision`` per disk binding. Each invocation runs:

   - ``_validate.yml`` (9 checks)
   - ``_render_repart.yml`` (DSL → ``/run/disk_provision/<dev>/repart.d/*.conf``)
   - ``_preserve_scan.yml`` (lsblk → set of preserved partition ids)
   - ``_apply_repart.yml`` (install systemd-repart if missing → run with
     ``--empty=force`` on fresh disk OR ``--empty=refuse`` + filtered
     definitions when preserves exist → partprobe → blkid wait)
   - ``_populate.yml`` (mount in dep order → rsync from ``/`` with preserve
     excludes → write fstab → rewrite extlinux.conf → unmount in reverse order)
3. **Set boot mode to local + verify** — render new pxelinux.cfg with ``default
   local``, upload to router, PoE-cycle, wait, assert ``findmnt /`` reports a
   local block device.
4. **Auto-revert rescue** wrapping Phase 3 — if the local boot fails, capture
   diagnostic bundle (findmnt, /proc/cmdline, lsblk, journalctl -k, UART tail if
   ``capture_serial=true``), set boot mode back to nfs, verify the board
   recovered, fail loudly with a pointer to the bundle path.

Approximate runtime on PoE-powered NVMe board: **3–4 minutes** for a first-time
provision; **5–10 minutes** if rsync source is large.

Post-run verification
---------------------

.. code-block:: bash

   # Confirm rootfs source
   ansible <fqdn> -m shell -a 'findmnt -no SOURCE,LABEL,FSTYPE /'
   # expected:  /dev/nvme0n1p<N>  armbi_root_local  ext4

   # Confirm kernel cmdline says root=LABEL=...
   ansible <fqdn> -m shell -a 'cat /proc/cmdline'
   # expected:  root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console=...

   # Confirm running kernel comes from TFTP (not the disk's /boot)
   ansible <fqdn> -m shell -a 'uname -r'
   # this is whatever's on the router's TFTP, not necessarily what's in /boot
   # on the local disk (passthrough boot decouples them)

   # Confirm fstab has LABEL= entries for every mount in the layout
   ansible <fqdn> -m shell -a 'cat /etc/fstab' --become

   # Confirm preserved partitions survived (if any)
   ansible <fqdn> -m shell -a 'ls -la /var/<your-sentinel-file>'

Failure recovery
----------------

The lifecycle's Phase 3 (local boot + verify) is wrapped in ``block/rescue``. If
local boot fails, the playbook automatically:

1. Captures ``./diagnostics/<host>-<iso8601>/`` with findmnt, cmdline, lsblk,
   route, resolv.conf, U-Boot debs, journal, router TFTP log, and last 200 UART
   lines if ``capture_serial=true``.
2. Sets boot mode back to ``nfs`` and PoE-cycles.
3. Verifies the board is back on NFS.
4. Fails the playbook with the diagnostic bundle path in the failure message.

If Phase 2 (disk_provision) fails (e.g. systemd-repart rejects the layout, mount
fails), there is NO auto-revert — the playbook aborts with the failure. The
board is still NFS-booted (Phase 1 already flipped it), so re-running after
fixing the issue is safe.

If Phase 1 (initial NFS flip) fails, the board may be stuck on its previous
mode. Use ``set_boot_mode.yml -e armbian_boot_mode=sd`` (or whatever known-good
mode you have) to recover, then debug the NFS infrastructure (TFTP rows, NFS
export, board's MAC in pxelinux.cfg).

Worked example: removing ``/boot`` from ``orange-pi-5-max-01``
--------------------------------------------------------------

Context: the board was previously provisioned with ESP + /boot + /var + root.
After the first-pass E2E, we observed that ``/boot`` is functionally inert under
our passthrough boot model — the kernel comes from TFTP, not the local disk's
``/boot``. The 1 GiB partition contributes nothing and creates a footgun
(``apt``-installed kernels land there but don't boot).

1. Edit inventory
~~~~~~~~~~~~~~~~~

``.inventory/inventory.yaml`` (gitignored — this is the real inventory, not the
documentation sample):

.. code-block:: yaml

   orange-pi-5-max-01.example.lan:
     # ... existing entries ...
     armbian_local_disks:
       - device: /dev/nvme0n1
         wipe: true
         layout:
           # /boot DROPPED — see runbook for reasoning under passthrough boot
           - id: var
             size: 20GiB
             type: var
             format: ext4
             label: armbi_var
             mount: /var
             preserve_on_reprovision: true
           - id: root
             size: grow
             type: root
             format: ext4
             label: armbi_root_local
             mount: /

2. Verify inventory parses
~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   ansible-inventory --host orange-pi-5-max-01.example.lan \
     | jq '.armbian_local_disks[0].layout | length'
   # expected: 2

3. Run the lifecycle
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   ansible-playbook playbooks/reprovision_to_local.yml \
     --limit orange-pi-5-max-01.example.lan \
     -e target_hosts=orange-pi-5-max-01.example.lan \
     -e capture_serial=true

4. What happens on the disk
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Before run (4 partitions on NVMe)::

    nvme0n1p1  vfat  ARMBI_ESP          512M  ← orphan from earlier run
    nvme0n1p2  ext4  armbi_boot           1G  ← about to be removed
    nvme0n1p3  ext4  armbi_var           20G  ← preserved (label match)
    nvme0n1p4  ext4  armbi_root_local  97.7G  ← matches new root def

``_preserve_scan.yml`` finds ``armbi_var`` matches the layout's preserve flag →
marks ``var`` to skip wipe.

``_apply_repart.yml`` runs with ``--empty=refuse`` (because we have preserves)
and filtered definitions (only ``root`` — ``var`` filtered out, ``boot`` not in
the new layout). systemd-repart's behavior:

- **Existing partition matching a definition's Type+Label**: preserved (root
  partition matches → stays).
- **Existing partition mentioned via preserve scan**: not in definitions →
  systemd-repart never sees it → left alone (var partition).
- **Existing partition unmentioned anywhere**: systemd-repart's default with
  ``--empty=refuse`` is to leave it alone. The old /boot partition
  (linux-generic, armbi_boot label) doesn't match any current definition → stays
  as an orphan partition.
- **Old ESP** stays too (same reason — orphan from prior runs).

After run (4 partitions, but only 2 are managed by current layout)::

    nvme0n1p1  vfat  ARMBI_ESP          512M  ← orphan (still unmanaged)
    nvme0n1p2  ext4  armbi_boot           1G  ← orphan (not in layout)
    nvme0n1p3  ext4  armbi_var           20G  ← preserved
    nvme0n1p4  ext4  armbi_root_local  97.7G  ← managed

Generated fstab on the new root partition (mounts only the layout's declared
mounts)::

    tmpfs           /tmp  tmpfs  defaults,nosuid       0 0
    LABEL=armbi_root_local  /     ext4   defaults,noatime     0 1
    LABEL=armbi_var         /var  ext4   defaults,noatime     0 2

No ``/boot`` entry — ``/boot`` is now a regular directory inside the root
partition, populated by the rsync from the NFS source.

5. Reclaiming the orphan partitions (optional)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Orphan partitions consume disk space and partition-table slots but are otherwise
harmless. To reclaim them:

Option A: re-run with ``force: true`` on the binding (wipes everything including
preserves):

.. code-block:: yaml

   armbian_local_disks:
     - device: /dev/nvme0n1
       force: true   # ← bypasses preserve idempotency
       layout: [ ... your new layout ... ]

Option B: SSH to the board and ``sfdisk --delete /dev/nvme0n1 <N>`` for each
orphan partition number.

For most operators: leave the orphans alone. They cost disk space but don't
affect boot or system behavior.

Common pitfalls
---------------

.. list-table::
   :header-rows: 1
   :widths: 34 32 34

   * - Symptom
     - Cause
     - Fix
   * - Playbook says "no hosts matched"
     - Inventory keys by FQDN, playbook ``hosts:`` default is short name
     - Pass ``-e target_hosts=<fqdn>``
   * - ``'armbian_local_disks' is undefined``
     - Inventory missing the var
     - Add it per the DSL above
   * - ``Failed to parse partition type: <foo>``
     - DSL type isn't a valid systemd-repart name
     - Use one of: esp, linux, root, var, home, srv, swap
   * - ``Error mounting ... vfat ... wrong fs type``
     - Kernel lacks CONFIG_VFAT_FS
     - Drop ESP from layout for this board
   * - ``blkid -L <label>`` retries exhausted on vfat
     - FAT label lowercase or >11 chars
     - Pre-flight validation catches this; use UPPERCASE ≤11 chars
   * - Sentinel disappeared from ``/var`` across reprovision
     - Either ``force: true`` set, or label changed (lost label-keyed preserve match)
     - Don't change ``armbi_var`` label between runs; don't set ``force: true``
   * - Local boot doesn't come up after reprovision
     - Most likely: pxelinux.cfg flip happened but kernel cmdline mismatches the
       new layout's labels
     - Auto-revert kicks in; check ``./diagnostics/<host>-*/`` for findmnt +
       journal
   * - ``systemd-repart: command not found``
     - Pre-Trixie Debian (Bookworm) where it's bundled in ``systemd``
     - ``_apply_repart.yml``'s ``failed_when: false`` apt install handles this;
       binary check still asserts

See also
--------

- DSL reference: ``roles/disk_provision/meta/argument_specs.yml``
- Lifecycle source: ``playbooks/reprovision_to_local.yml``
- Hardware E2E: ``playbooks/tests/test_reprovision_e2e.yml``
- Boot-mode override methods (inventory / -e / U-Boot env):
  :ref:`ansible_collections.david_igou.armbian.docsite.boot-mode-override`
