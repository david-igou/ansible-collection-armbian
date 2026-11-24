.. _ansible_collections.david_igou.armbian.docsite.guide:

Overview
========

``david_igou.armbian`` is a set of roles for Armbian single-board computers
that netboot and get reimaged. It ships **roles only**: inventory,
orchestration and transport (TFTP upload, PoE or PDU control) belong in the
consuming repository.

.. note::

   Early-stage 0.0.x: role interfaces can change between releases. Pin a
   version in ``requirements.yml``.

Roles
-----

``board_config``
  Merges layered inventory into the ``board_config``, ``board_config_build`` and
  rootfs-source facts the other roles consume.
``image_build``
  Builds an Armbian image with ``armbian/build`` and the board's userpatches.
``rootfs_provision``
  Extracts an image into a per-host NFS root on the netboot server.
``pxelinux_render``
  Renders a board's ``01-<mac>`` pxelinux.cfg on the control node.
``board_boot_wait``
  Power-cycles a board through the caller's hook and waits for SSH.
``board_boot_verify``
  Asserts a board's root filesystem matches its boot mode.
``bootstrap_armbian``
  Creates an SSH-key automation user on a freshly flashed board.
``disk_image`` and ``disk_provision``
  Write an image, or a ``systemd-repart`` layout plus a copied root filesystem,
  to a board's local disk.

Boot modes
----------

Each board's pxelinux.cfg carries every label; its ``default`` line selects one.

.. list-table::
   :header-rows: 1

   * - Mode
     - Kernel from
     - Root filesystem
   * - ``nfs``
     - TFTP
     - NFS export ``<root path>/<hostname>``
   * - ``sd``
     - TFTP
     - ``root=LABEL=armbi_root`` on the SD card
   * - ``local``
     - TFTP
     - ``root=LABEL=armbi_root_local``, written by ``disk_provision``
   * - ``local_kernel``
     - the local disk (``localboot 0``)
     - the local disk

``board_boot_verify`` checks the same table from the booted board: an NFS root
for ``nfs``, a non-NFS ``/dev/*`` root for ``sd`` and ``local``, and
``/dev/nvme*`` for ``local_kernel`` unless the caller passes another regex.

The transport hook
------------------

The collection never talks to switches, routers or PDUs. The single place
transport plugs in is ``board_boot_wait_power_cycle_tasks``: a tasks file the
caller writes (PoE, PDU, hypervisor restart) that ``board_boot_wait`` includes
at the start of every attempt, in the board's host context. Uploading the
rendered pxelinux.cfg (``pxelinux_render_file``) to a TFTP server is likewise
the caller's own task.

Wiring the roles together
-------------------------

1. Layer board data in inventory: ``board_config_family`` on a SoC group,
   ``board_config_model`` on a model group, ``board_config_host`` in host vars,
   and the matching ``board_config_build_*`` layers. Run ``board_config``.
2. On a builder, feed ``board_config_build`` to ``image_build`` and publish
   ``<name>/{image, image.sha, manifest.json}`` under an HTTP assets tree.
3. Resolve each board's image with ``board_config`` ``tasks_from: rootfs_src``
   and run ``rootfs_provision`` on the netboot server.
4. Render the pxelinux.cfg with ``pxelinux_render`` and upload it.
5. Boot with ``board_boot_wait`` and confirm with ``board_boot_verify``.

.. code-block:: yaml

   - name: Boot a board from NFS
     hosts: boards
     gather_facts: false
     tasks:
       - name: Resolve hardware facts
         ansible.builtin.include_role:
           name: david_igou.armbian.board_config

       - name: Render the pxelinux.cfg
         ansible.builtin.include_role:
           name: david_igou.armbian.pxelinux_render
           apply:
             delegate_to: localhost
         vars:
           pxelinux_render_board_mac: "{{ board_mac }}"
           pxelinux_render_boot_mode: nfs
           pxelinux_render_console: "{{ board_config.console }}"
           pxelinux_render_nfs_server_ip: 192.0.2.10
           pxelinux_render_nfs_root_path: /srv/netboot/rootfs
           pxelinux_render_hostname: "{{ inventory_hostname }}"
           pxelinux_render_output_dir: "{{ playbook_dir }}/.cache/pxelinux.cfg"

       - name: Power-cycle and wait
         ansible.builtin.include_role:
           name: david_igou.armbian.board_boot_wait
         vars:
           board_boot_wait_power_cycle_tasks: "{{ playbook_dir }}/tasks/power_cycle.yml"
           board_boot_wait_attempts: 3

       - name: Check the board booted from NFS
         ansible.builtin.include_role:
           name: david_igou.armbian.board_boot_verify
         vars:
           board_boot_verify_mode: nfs

``playbooks/examples/`` in the collection source has one short call per role.
