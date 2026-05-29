.. _ansible_collections.david_igou.armbian.docsite.architecture:

Architecture and data flow
==========================

How the collection's roles and playbooks fit together. For the onboarding
walkthrough see :ref:`ansible_collections.david_igou.armbian.docsite.lifecycle`;
for day-to-day operations see
:ref:`ansible_collections.david_igou.armbian.docsite.daily-operations`.

Mental model
------------

**Roles are single-purpose, parameter-driven state enforcers. Playbooks compose
them into workflows.** A role asks: *given these inputs, is the world in the
desired state, and if not, make it so.* It does not decide intent — callers do.
A playbook decides which roles to invoke, against which inventory, with which
parameters, in what order.

Roles are transport-agnostic. Switch-ecosystem-specific tasks (RouterOS upload,
PoE control) live as swappable reference playbooks under ``playbooks/routeros/``,
selected via ``armbian_*_playbook`` variables. The rule of thumb:

- Adding a new external system → add a role.
- Adding a new operation that combines existing primitives → add a playbook, no
  role changes.
- Swapping to a different switch ecosystem → write a parallel
  ``playbooks/<vendor>/`` directory and point the transport-hook variables at it.

Always-netboot invariant
-------------------------

Every onboarded board always has ``pxelinux.cfg/01-<MAC>`` on the RouterOS
router. Boot mode is controlled by the ``default`` directive inside it; the
``sd`` label defaults to ``root=LABEL=armbi_root`` (override per-host via
``armbian_sd_root``). Nothing is added or removed to flip modes — convergence
rewrites the same file.

The roles
---------

Each role runs on a specific host class, takes a small input set, and produces
one output. Most roles are independent — they consume inventory metadata or
live-board state, not artefacts from other roles. The only direct role-to-role
chain is **image production**: ``image_build`` produces a ``.img.xz`` that
``rootfs_provision`` consumes.

.. list-table::
   :header-rows: 1
   :widths: 22 22 56

   * - Role
     - Runs on
     - Input → output
   * - ``image_build``
     - ``armbian_builders``
     - board, branch, userpatches → ``<board>.img.xz`` (PXE-first U-Boot baked in)
   * - ``rootfs_provision``
     - netboot server
     - per-host ``armbian_rootfs_src`` → per-model rootfs template + per-host
       clone (reflink + hostname / machine-id / SSH host keys reset) +
       vmlinuz/initrd/dtb TFTP artefacts
   * - ``pxelinux_render``
     - controller (localhost)
     - MAC, model, boot_mode, NFS server + path, cmdline knobs →
       per-board ``pxelinux.cfg/01-<MAC>`` file
   * - ``bootstrap_armbian``
     - a board
     - ``ansible_user``, SSH key list (connects as root + default password) →
       SSH-key user + passwordless sudo on the running rootfs
   * - ``board_boot_wait``
     - a board
     - TCP/22 + SSH probe timeout → assertion the board is reachable
   * - ``board_boot_verify``
     - a board
     - declared boot_mode → assertion ``ansible_mounts['/']`` matches the mode
       (NFS vs block device)
   * - ``disk_image``
     - a board
     - ``.img.xz``/``.img`` source, target block device → whole-disk image
       streamed via ``curl | xz | dd``, mount-aware refusal
   * - ``disk_provision``
     - a board
     - declarative GPT layout, rsync source rootfs, target block device →
       partitions applied via ``systemd-repart``, fstab rewritten by LABEL,
       idempotent

The image-production chain is the only inter-role edge::

    image_build  ──(.img.xz)──▶  rootfs_provision

``rootfs_provision``'s TFTP artefacts and ``pxelinux_render``'s pxelinux.cfg
both leave the role boundary via orchestration playbooks (``stage_router.yml``,
``routeros/upload_pxelinux_cfg.yml``) that ``net_put`` them to the router.
``rootfs_provision``'s per-host clone is read directly by the netboot server's
NFS export — no further copy. The board-side roles are parameterised by
inventory and the live board's state; they don't participate in the dependency
chain.

Playbooks
---------

Every user-facing playbook composes roles and/or imports reference playbooks.
The lifecycle ordering is the order they're typically run in (see
:ref:`ansible_collections.david_igou.armbian.docsite.lifecycle`); this table is
the dependency graph.

.. list-table::
   :header-rows: 1
   :widths: 4 30 30 36

   * - #
     - Playbook
     - ``hosts:``
     - Composes / imports
   * - 0
     - ``build_and_publish_from_inventory.yml``
     - ``armbian_builders``
     - role: ``image_build``
   * - 1
     - ``bootstrap_armbian.yml``
     - ``boards`` (as root)
     - role: ``bootstrap_armbian``
   * - 2
     - ``routeros/bootstrap_user.yml``
     - ``routeros_netboot``
     - uses ``community.routeros.command``
   * - 3
     - ``stage_netboot_assets.yml``
     - ``netboot_server``
     - role: ``rootfs_provision`` (per host)
   * - 4
     - ``stage_router.yml``
     - ``netboot_server`` (fetch) → ``routeros_router`` (push)
     - imports ``routeros/upload_tftp_assets.yml``, ``routeros/plumbing_check.yml``
   * - 5
     - ``converge_boot_mode.yml``
     - ``routeros_router`` → ``boards``
     - roles ``pxelinux_render``, ``board_boot_wait``, ``board_boot_verify``;
       imports ``routeros/plumbing_check.yml``, ``routeros/upload_pxelinux_cfg.yml``
   * - 6
     - ``set_boot_mode.yml``
     - (import wrapper)
     - imports ``converge_boot_mode.yml``
   * - 7
     - ``routeros/poe_control.yml``
     - ``boards`` → ``routeros_switch`` (delegated)
     - run directly
   * - 8
     - ``persist_uboot_env.yml``
     - rock-5b boards → switch (delegated)
     - uses ``routeros/tasks/poe_cycle.yml``
   * - 9
     - ``provision_local_disk.yml``
     - one board
     - role: ``disk_provision``
   * - 10
     - ``reprovision_to_local.yml``
     - one board (+ router delegated)
     - roles ``pxelinux_render``, ``disk_provision``, ``board_boot_verify``;
       imports ``routeros/upload_pxelinux_cfg.yml``

Test and cleanup harnesses (``tests/test_hardware_e2e.yml``,
``tests/test_fleet_e2e.yml``, ``tests/test_manual_psu_cold_boot.yml``,
``tests/test_reprovision_e2e.yml``, ``cleanup_boot_files.yml``) sit outside the
standard lifecycle and exercise the roles / reference playbooks transitively.

RouterOS reference playbooks (swappable)
----------------------------------------

Every RouterOS-specific behaviour lives in ``playbooks/routeros/`` and is
selected by the orchestration playbook via an ``armbian_*_playbook`` variable.
Point that variable at a parallel ``playbooks/<vendor>/`` directory to swap
transports.

.. list-table::
   :header-rows: 1
   :widths: 40 30 30

   * - Playbook
     - Default consumer
     - Variable to override
   * - ``routeros/bootstrap_user.yml``
     - manual one-time
     - — (run directly)
   * - ``routeros/upload_pxelinux_cfg.yml``
     - ``converge_boot_mode.yml``
     - ``armbian_pxelinux_upload_playbook``
   * - ``routeros/upload_tftp_assets.yml``
     - ``stage_router.yml``
     - ``armbian_tftp_upload_playbook``
   * - ``routeros/plumbing_check.yml``
     - ``stage_router.yml``, ``converge_boot_mode.yml``
     - ``armbian_plumbing_check_playbook``
   * - ``routeros/poe_control.yml``
     - manual ad-hoc
     - — (run directly)
