.. _ansible_collections.david_igou.armbian.docsite.netboot:

PXE netboot
===========

The netboot workflow boots boards over PXE → NFS from a central server and
falls back to local SD only on demand. The guiding invariant is
**always-netboot**: every onboarded board always has a ``pxelinux.cfg`` on
the RouterOS router, and a single ``default`` directive inside it selects
the active boot mode.

Three pieces of state need to be in place on a per-board basis before a
board can come up on NFS:

#. A **custom PXE-first Armbian image** (the U-Boot ``BOOT_TARGETS`` order
   is patched in at build time so the board reliably netboots from
   power-up).
#. A **per-host NFS rootfs** carved out of that image on the netboot
   server, with hostname / machine-id / SSH host keys reset.
#. **PXE assets on the router** — per-model kernel/initrd/dtb in
   ``/ip tftp``, and a per-board ``pxelinux.cfg`` whose ``default``
   directive selects ``nfs`` or ``sd``.

The sections below cover each piece in turn. Once all three are in place,
``converge_boot_mode.yml`` flips the ``default`` directive, power-cycles
the board, and verifies it came up on the expected rootfs.

.. note::

   Early-stage 0.0.x — expect breaking changes between releases. Pin a
   specific version in your ``requirements.yml``.

Install
-------

The netboot workflow drives RouterOS, so install both the collection and
the RouterOS reference dependencies:

.. code-block:: bash

   ansible-galaxy collection install david_igou.armbian
   ansible-galaxy collection install -r playbooks/routeros/requirements.yml

Each board in inventory needs at least ``armbian_board_mac``,
``armbian_board_model``, ``armbian_boot_mode``, plus PoE coordinates
(``armbian_poe_switch``, ``armbian_poe_port``) when the switch controls
power. See the role reference for the full set of variables.

The build
---------

Stock Armbian images don't boot PXE first. The ``image_build`` role
produces a custom ``.img.xz`` with the PXE-first ``BOOT_TARGETS`` order
baked into U-Boot at compile time, via an ``armbian/build`` userpatches
overlay. The
``build_and_publish_from_inventory.yml`` workflow loops the role over
every board in inventory, resolves the per-host build profile (family →
model → host layers), and publishes the resulting ``.img.xz`` plus a
``manifest.json`` to the netboot server's HTTP assets directory:

.. code-block:: bash

   ansible-playbook playbooks/build_and_publish_from_inventory.yml

Per-board build profile lives in inventory under
``armbian_build_family`` / ``armbian_build_model`` / ``armbian_build_host``;
the resolver primitive in ``playbooks/tasks/_resolve_build_profile.yml``
merges them and feeds the result into ``image_build``. See the
:ansplugin:`image_build role reference <david_igou.armbian.image_build#role>`.

The rootfs
----------

Each board gets its own NFS rootfs so two same-model boards have
independent identity on the wire. ``stage_netboot_assets.yml`` invokes
the ``rootfs_provision`` role once per board against the netboot server:

#. Resolve the per-host ``.img.xz`` source (host_vars
   ``armbian_rootfs_src``, falling back to the published manifest from
   the previous step).
#. Extract the rootfs into a per-model template (``_templates/<model>/``).
#. Reflink-clone the template into a per-host directory
   (``<inventory_hostname>/``) — a zero-cost CoW snapshot on XFS, btrfs,
   or ZFS.
#. Reset identity inside the clone: hostname, machine-id, SSH host keys.

.. code-block:: bash

   ansible-playbook playbooks/stage_netboot_assets.yml

The NFS export root (``armbian_nfs_rootfs_path``, default
``/srv/netboot/rootfs``) must already exist on the netboot server and be
exported. See the
:ansplugin:`rootfs_provision role reference <david_igou.armbian.rootfs_provision#role>`.

The PXE assets
--------------

Two pieces of router-side state make a board actually boot over the
network: per-model TFTP assets (kernel, initrd, dtb) registered in
``/ip tftp``, and a per-board ``pxelinux.cfg`` keyed on the board's MAC.

**Per-model TFTP assets** — ``stage_router.yml`` fetches the
kernel/initrd/dtb from the netboot server to a controller cache, then
uploads them to the router and registers the ``/ip tftp`` rows:

.. code-block:: bash

   ansible-playbook playbooks/stage_router.yml

This is a one-time step per model; assets persist across boot-mode
changes.

**Per-board pxelinux.cfg + boot-mode convergence** —
``converge_boot_mode.yml`` is the workhorse that renders one
``01-<mac>`` pxelinux.cfg via the ``pxelinux_render`` role, uploads it
to the router, PoE-cycles the board, and verifies it came up on the
expected rootfs:

.. code-block:: bash

   ansible-playbook playbooks/converge_boot_mode.yml \
     -e target_hosts=orange-pi-5-pro-01

The ``default`` directive inside the pxelinux.cfg is driven by each
board's ``armbian_boot_mode`` inventory variable (``nfs`` or ``sd``).
To flip a board ad hoc without editing inventory:

.. code-block:: bash

   ansible-playbook playbooks/set_boot_mode.yml \
     --limit orange-pi-5-pro-01 \
     -e armbian_boot_mode=sd

See the
:ansplugin:`pxelinux_render role reference <david_igou.armbian.pxelinux_render#role>`
and the RouterOS reference playbooks under ``playbooks/routeros/`` for
the swappable transport layer.
