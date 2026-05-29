.. _ansible_collections.david_igou.armbian.docsite.guide:

Getting started
===============

``david_igou.armbian`` manages Armbian-based ARM SBCs end to end: building a
custom PXE-first Armbian image, provisioning per-host NFS rootfs, converging
boards between netboot and SD/local boot, and driving the hardware lifecycle
over PoE.

The collection is built from **single-purpose, parameter-driven roles** —
each one enforces one piece of desired state on one host class — composed by
**workflow playbooks** that decide which roles to run, where, and in what order.
The guiding invariant is *always-netboot*: every onboarded board always has a
``pxelinux.cfg`` on the router, and a single ``default`` directive inside it
selects the active boot mode. Per-role inputs and outputs are documented in the
role reference (see the Role Index below); networking-gear specifics (RouterOS
upload, PoE) live as swappable reference playbooks under ``playbooks/routeros/``.

.. note::

   Early-stage 0.0.x — expect breaking changes between releases. Pin a specific
   version in your ``requirements.yml``.

Example usage
-------------

A minimal end-to-end path from nothing to a board booting over NFS on demand.
Each board needs an inventory entry with at least ``armbian_board_mac``,
``armbian_board_model``, and ``armbian_boot_mode``; see the role reference for
the full set of variables.

**1. Install the collection.**

.. code-block:: bash

   ansible-galaxy collection install david_igou.armbian

   # Only if you orchestrate RouterOS (boot-mode convergence, TFTP staging):
   ansible-galaxy collection install -r playbooks/routeros/requirements.yml

**2. Build and publish the custom PXE-first image.**

Stock Armbian images don't boot PXE-first; this builds one that does and
publishes the ``.img.xz`` to the netboot server.

.. code-block:: bash

   ansible-playbook playbooks/build_and_publish_from_inventory.yml

**3. Bootstrap a freshly flashed board.**

Flash the image to an SD card and power the board on, then create the SSH-key
user with passwordless sudo:

.. code-block:: bash

   ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01

**4. Stage the netboot assets.**

Provision the per-host NFS rootfs on the netboot server, then push the
kernel/initrd/dtb and TFTP rows to the router:

.. code-block:: bash

   ansible-playbook playbooks/stage_netboot_assets.yml
   ansible-playbook playbooks/stage_router.yml

**5. Converge the board to its declared boot mode.**

Renders the per-board ``pxelinux.cfg``, uploads it, power-cycles the board, and
verifies it comes up on the expected rootfs:

.. code-block:: bash

   ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01

**6. Toggle boot mode ad hoc** (no inventory edit), e.g. to fall back to SD:

.. code-block:: bash

   ansible-playbook playbooks/set_boot_mode.yml \
     --limit orange-pi-5-pro-01 \
     -e armbian_boot_mode=sd
