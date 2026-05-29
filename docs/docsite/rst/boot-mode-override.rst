.. _ansible_collections.david_igou.armbian.docsite.boot-mode-override:

Boot mode override methods
==========================

Three ways to change a board's boot mode, ranked by durability.

**Available boot modes** (rendered as labels in every pxelinux.cfg; the
inventory's ``armbian_boot_mode`` selects which becomes ``default``):

.. list-table::
   :header-rows: 1
   :widths: 14 26 26 34

   * - Mode
     - Kernel/initrd/dtb source
     - Rootfs source
     - Notes
   * - ``nfs``
     - TFTP (router)
     - NFS export ``/<host>/``
     - Default. Stateless rebuild via ``stage_netboot_assets``.
   * - ``sd``
     - TFTP (router)
     - SD card ``LABEL=armbi_root``
     - Survives router outage on SD-resident rootfs.
   * - ``local``
     - TFTP (router)
     - Local disk ``LABEL=armbi_root_local``
     - Passthrough: kernel still central; rootfs local (e.g. NVMe via
       ``provision_local_disk.yml``).
   * - ``local_kernel``
     - **NVMe** ``/boot/extlinux/extlinux.conf``
     - NVMe (whatever extlinux.conf declares)
     - Hands off via ``localboot 0`` → U-Boot ``localcmd``. Decouples kernel
       updates from the router's TFTP.

Comparison
----------

.. list-table::
   :header-rows: 1
   :widths: 30 28 18 24

   * - Method
     - Durability
     - Touches the router?
     - Use case
   * - Inventory (``armbian_boot_mode``)
     - Permanent
     - Yes (on converge)
     - Fleet-level default
   * - Ansible ``-e`` (``set_boot_mode.yml``)
     - Until next converge
     - Yes
     - Ad-hoc testing, one-off flip
   * - U-Boot env (``pxe_label_override``)
     - Single boot (non-SPI) or until cleared (SPI)
     - No
     - Serial console triage

Method 1: Inventory (permanent)
-------------------------------

Set ``armbian_boot_mode`` on the host in your inventory, then run
``converge_boot_mode.yml``:

.. code-block:: yaml

   # inventory/host_vars/orange-pi-5-pro-01.yml  (or inline in hosts.yml)
   armbian_boot_mode: sd

.. code-block:: bash

   ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01

The rendered pxelinux.cfg on the router is updated to ``default sd``. Every
subsequent ``converge_boot_mode.yml`` run re-reads the inventory value, so the
change persists across automation runs.

To revert, change the inventory back and re-converge:

.. code-block:: yaml

   armbian_boot_mode: nfs

.. code-block:: bash

   ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01

Method 2: Ansible ``-e`` override (ad-hoc)
------------------------------------------

Use ``set_boot_mode.yml`` with an extra-var — no inventory edit needed:

.. code-block:: bash

   # Flip to sd boot temporarily
   ansible-playbook playbooks/set_boot_mode.yml \
     --limit orange-pi-5-pro-01 \
     -e armbian_boot_mode=sd

   # Flip back to nfs
   ansible-playbook playbooks/set_boot_mode.yml \
     --limit orange-pi-5-pro-01 \
     -e armbian_boot_mode=nfs

The ``-e`` value wins over inventory for this run. The pxelinux.cfg on the
router is re-rendered with the override. On the *next* run of
``converge_boot_mode.yml`` (which reads from inventory), the inventory value
takes effect again.

To write router state without cycling the board:

.. code-block:: bash

   ansible-playbook playbooks/set_boot_mode.yml \
     --limit orange-pi-5-pro-01 \
     -e armbian_boot_mode=sd \
     -e armbian_cycle_board=false

Method 3: U-Boot environment variable (single boot)
---------------------------------------------------

At the board's serial console (or via ``fw_setenv`` from Linux), set
``pxe_label_override``:

.. code-block:: text

   # At U-Boot prompt:
   setenv pxe_label_override sd
   boot

   # Or from Linux (persists in env storage):
   sudo fw_setenv pxe_label_override sd

This requires the pxelinux.cfg template to check for ``pxe_label_override`` (a
future enhancement — the current template does not implement this). When
implemented, U-Boot's ``pxe boot`` command would read the env var and select the
matching label instead of the ``default`` directive.

SPI vs non-SPI boards
~~~~~~~~~~~~~~~~~~~~~~

- **Non-SPI boards** (e.g. Orange Pi 5 Pro): U-Boot env lives in RAM.
  ``setenv`` at the console is volatile — lost on the next power cycle.
  Effective as a single-boot override.
- **SPI boards** (e.g. Rock 5B): U-Boot env persists in SPI flash. ``fw_setenv``
  (or ``saveenv`` at the console) survives reboots. Clear with ``fw_setenv
  pxe_label_override`` (empty value) or re-run ``persist_uboot_env.yml``.
