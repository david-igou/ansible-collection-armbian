.. _ansible_collections.david_igou.armbian.docsite.netboot:

PXE netboot
===========

The netboot workflow boots boards over PXE → NFS from a central server and
falls back to local SD only on demand. The guiding invariant is
**always-netboot**: every onboarded board always has a ``pxelinux.cfg`` on
the RouterOS router, and a single ``default`` directive inside it selects
the active boot mode.

Three pieces of state need to be in place before a board can come up on NFS:

#. A **custom PXE-first Armbian image** — the U-Boot ``BOOT_TARGETS`` order
   is patched in at build time so the board reliably netboots from
   power-up.
#. A **per-host NFS rootfs** carved out of that image on the netboot
   server, with hostname / machine-id / SSH host keys reset.
#. **PXE assets on the router** — per-model kernel/initrd/dtb in
   ``/ip tftp``, and a per-board ``pxelinux.cfg`` whose ``default``
   directive selects ``nfs`` or ``sd``.

The sections below walk through each piece with the workflow playbooks the
collection ships and the file trees / rendered assets they produce. Every
example threads the same concrete board — ``orange-pi-5-pro-01`` with MAC
``aa:bb:cc:dd:ee:ff`` — so you can read the variables straight across.

.. note::

   Early-stage 0.0.x — expect breaking changes between releases. Pin a
   specific version in your ``requirements.yml``.

The setup
---------

Install the collection plus the RouterOS reference dependencies:

.. code-block:: bash

   ansible-galaxy collection install david_igou.armbian
   ansible-galaxy collection install -r playbooks/routeros/requirements.yml

The examples below assume this inventory shape. Replace the four hosts
(builder, netboot server, RouterOS router, board) with your own and adjust
addresses; everything else is verbatim:

.. code-block:: yaml

   # inventory/hosts.yml
   all:
     children:
       armbian_builders:
         hosts:
           builder-01:
             ansible_host: 192.0.2.5
       netboot_server:
         hosts:
           truenas-01:
             ansible_host: 192.0.2.10
             ansible_user: admin
             ansible_become: true
       routeros_router:
         hosts:
           rb5009:
             ansible_host: 192.0.2.1
             ansible_user: ansible-netboot
             ansible_port: 2222
       boards:
         children:
           orange_pi_5_pro:
             hosts:
               orange-pi-5-pro-01:
                 ansible_host: 192.0.2.111
                 ansible_user: armbian
                 armbian_board_mac: "aa:bb:cc:dd:ee:ff"
                 armbian_board_model: orange-pi-5-pro
                 armbian_boot_mode: nfs
                 armbian_poe_switch: rb5009
                 armbian_poe_port: ether3

   # inventory/group_vars/all.yml
   armbian_server_ip: 192.0.2.10
   armbian_nfs_rootfs_path: /srv/netboot/rootfs
   armbian_nfs_assets_export: /srv/netboot/boot-files
   armbian_tftp_flash_dir: sbc
   armbian_tftp_cache_dir: "{{ playbook_dir }}/../.cache/sbc-tftp"
   armbian_image_cache: /var/lib/armbian/cache
   armbian_router: rb5009

   # inventory/group_vars/orange_pi_5_pro.yml (model layer)
   armbian_board_config_model:
     armbian_board_name: orangepi5pro
     armbian_dl_dir: orangepi5pro
     armbian_support: standard
     dtb: rockchip/rk3588s-orangepi-5-pro.dtb
     console: ttyS2,1500000
     earlycon: uart8250,mmio32,0xfeb50000
   armbian_build_model:
     branch: current
     release: bookworm

The build
---------

Stock Armbian images don't boot PXE first; ``image_build`` produces a
custom ``.img.xz`` with the PXE-first ``BOOT_TARGETS`` order baked into
U-Boot at compile time, via an ``armbian/build`` userpatches overlay.

Drop the playbook below into ``playbooks/local/build.yml`` and run it. The
``vars`` block carries every value verbatim — no resolver primitives, no
inventory layering — so you can read what the role actually consumes:

.. code-block:: yaml

   ---
   - name: Build a PXE-first Armbian image for orange-pi-5-pro-01
     hosts: builder-01
     gather_facts: true
     tasks:
       - ansible.builtin.include_role:
           name: david_igou.armbian.image_build
         vars:
           armbian_build_board:   orangepi5pro
           armbian_build_host:    orange-pi-5-pro-01
           armbian_build_branch:  current
           armbian_build_release: bookworm
           armbian_build_userpatches:
             - dest: config/boards/orangepi5pro.conf
               content: |
                 function pre_config_uboot_target__orangepi5pro_pxe_first() {
                     declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
                     sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                         include/configs/rockchip-common.h
                 }

.. code-block:: bash

   ansible-playbook playbooks/local/build.yml

The output lands at ``$HOME/armbian_build/output/orange-pi-5-pro-01/`` on
the builder:

.. code-block:: text

   $HOME/armbian_build/output/
   └── orange-pi-5-pro-01/
       ├── Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz
       ├── Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz.sha
       └── manifest.json

The accompanying ``manifest.json`` records what was built; the role uses
it as its idempotency key on subsequent runs:

.. code-block:: json

   {
     "patch_hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
     "armbian_build_ref": "v26.2.0-trunk.844",
     "board":   "orangepi5pro",
     "branch":  "current",
     "release": "bookworm",
     "image_filename": "Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz",
     "built_at": "2026-05-30T12:34:56Z"
   }

For the fleet workflow that runs this per board and publishes the result
to the netboot server, use ``playbooks/build_and_publish_from_inventory.yml``.

The rootfs
----------

Each board gets its own NFS rootfs so two same-model boards have
independent identity on the wire. ``rootfs_provision`` runs on the
netboot server, downloads the ``.img.xz`` from the publish URL, extracts
the rootfs into a per-host directory, stages kernel/initrd/dtb to a TFTP
cache, and resets identity (hostname, machine-id, SSH host keys).

Drop this into ``playbooks/local/rootfs.yml``:

.. code-block:: yaml

   ---
   - name: Provision the NFS rootfs for orange-pi-5-pro-01
     hosts: truenas-01
     become: true
     gather_facts: false
     tasks:
       - ansible.builtin.include_role:
           name: david_igou.armbian.rootfs_provision
         vars:
           armbian_rootfs_src:  "https://192.0.2.10/boot-files/images/orange-pi-5-pro-01/Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz"
           armbian_rootfs_host: orange-pi-5-pro-01
           armbian_rootfs_dtb:  rockchip/rk3588s-orangepi-5-pro.dtb

.. code-block:: bash

   ansible-playbook playbooks/local/rootfs.yml

Afterwards the netboot server holds the per-host NFS rootfs and a
per-host TFTP staging cache:

.. code-block:: text

   /srv/netboot/rootfs/orange-pi-5-pro-01/         # armbian_rootfs_target_dir
   ├── etc/
   │   ├── hostname                                # → orange-pi-5-pro-01
   │   ├── machine-id                              # zeroed (first-boot trigger)
   │   └── ssh/
   │       ├── ssh_host_rsa_key(.pub)              # freshly regenerated
   │       ├── ssh_host_ecdsa_key(.pub)
   │       └── ssh_host_ed25519_key(.pub)
   ├── var/lib/dbus/machine-id                     # zeroed
   ├── ...                                         # rest of extracted rootfs
   └── .armbian_rootfs_provision_complete          # idempotency sentinel (JSON)

   /var/lib/armbian/cache/sbc-tftp/orange-pi-5-pro-01/   # armbian_rootfs_tftp_dir
   ├── vmlinuz
   ├── initrd.img
   └── board.dtb                                   # always staged under this fixed name

The sentinel records what the rootfs was provisioned from; re-running
``rootfs.yml`` is a no-op until ``src`` or ``host`` change (or you pass
``-e armbian_rootfs_force_refresh=true``):

.. code-block:: json

   {
     "host": "orange-pi-5-pro-01",
     "provisioned_at": "2026-05-30T12:34:56Z",
     "src": "https://192.0.2.10/boot-files/images/orange-pi-5-pro-01/Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz",
     "src_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
   }

The PXE assets
--------------

Two pieces of router-side state make a board actually boot over the
network: per-model TFTP assets registered in ``/ip tftp``, and a
per-board ``pxelinux.cfg`` keyed on the board's MAC.

Per-model TFTP assets
~~~~~~~~~~~~~~~~~~~~~

``stage_router.yml`` fetches the kernel/initrd/dtb staged by
``rootfs_provision`` down to a controller-side cache, then uploads them
to the router. To do that explicitly for the demo board, first sync the
three files from the netboot server:

.. code-block:: bash

   mkdir -p .cache/sbc-tftp/orange-pi-5-pro
   rsync -av \
     admin@192.0.2.10:/var/lib/armbian/cache/sbc-tftp/orange-pi-5-pro-01/{vmlinuz,initrd.img,board.dtb} \
     .cache/sbc-tftp/orange-pi-5-pro/

Then invoke the RouterOS reference playbook with the model list inline —
no inventory wiring required:

.. code-block:: bash

   ansible-playbook playbooks/routeros/upload_tftp_assets.yml \
     -e armbian_tftp_flash_dir=sbc \
     -e armbian_tftp_cache_dir=$PWD/.cache/sbc-tftp \
     -e '{"armbian_tftp_upload_models": ["orange-pi-5-pro"]}'

Afterwards the router's flash holds the per-model directory with three
``/ip tftp`` rows registered against it:

.. code-block:: text

   flash:/sbc/armbian/
   └── orange-pi-5-pro/
       ├── vmlinuz
       ├── initrd.img
       └── board.dtb

   /ip tftp> print
    # REQ-FILENAME                            REAL-FILENAME                                IP-ADDRESSES
    0 armbian/orange-pi-5-pro/vmlinuz         flash/sbc/armbian/orange-pi-5-pro/vmlinuz    0.0.0.0/0
    1 armbian/orange-pi-5-pro/initrd.img      flash/sbc/armbian/orange-pi-5-pro/initrd.img 0.0.0.0/0
    2 armbian/orange-pi-5-pro/board.dtb       flash/sbc/armbian/orange-pi-5-pro/board.dtb  0.0.0.0/0

Per-board pxelinux.cfg
~~~~~~~~~~~~~~~~~~~~~~

The per-board ``pxelinux.cfg`` is the file U-Boot fetches first; its
``default`` directive selects which label (and therefore which rootfs)
the board boots. Render it locally with ``pxelinux_render`` — the role
runs on ``localhost`` and writes one ``01-<mac>`` file per board.

Drop this into ``playbooks/local/pxelinux.yml``:

.. code-block:: yaml

   ---
   - name: Render the pxelinux.cfg for orange-pi-5-pro-01
     hosts: localhost
     gather_facts: false
     connection: local
     tasks:
       - ansible.builtin.include_role:
           name: david_igou.armbian.pxelinux_render
         vars:
           pxelinux_render_board_mac:     "aa:bb:cc:dd:ee:ff"
           pxelinux_render_boot_mode:     nfs
           pxelinux_render_nfs_server_ip: "192.0.2.10"
           pxelinux_render_nfs_root_path: /srv/netboot/rootfs
           pxelinux_render_hostname:      orange-pi-5-pro-01
           pxelinux_render_output_dir:    "{{ playbook_dir }}/../.cache/pxelinux.cfg"
           # pxelinux_render reads .console / .earlycon / .armbian_board_name
           # from armbian_board_config; supply it inline here so the template
           # has what it needs without a resolver step.
           armbian_board_config:
             armbian_board_name: orangepi5pro
             console:  "ttyS2,1500000"
             earlycon: "uart8250,mmio32,0xfeb50000"

.. code-block:: bash

   ansible-playbook playbooks/local/pxelinux.yml

The role writes one file:

.. code-block:: text

   .cache/pxelinux.cfg/
   └── 01-aa-bb-cc-dd-ee-ff     # default → nfs

The full rendered content of ``01-aa-bb-cc-dd-ee-ff`` — every label
that exists for this board, with ``default`` pointed at ``nfs``:

.. code-block:: text

   # Ansible managed
   # pxelinux.cfg for orange-pi-5-pro-01 (Orange Pi 5 Pro)
   # MAC: aa:bb:cc:dd:ee:ff
   # Active mode: nfs

   default nfs
   timeout 50
   prompt  0

   label nfs
     menu label Armbian NFS root (orange-pi-5-pro-01)
     kernel armbian/orange-pi-5-pro-01/vmlinuz
     initrd armbian/orange-pi-5-pro-01/initrd.img
     fdt    armbian/orange-pi-5-pro-01/board.dtb
     append root=/dev/nfs nfsroot=192.0.2.10:/srv/netboot/rootfs/orange-pi-5-pro-01,nfsvers=3,rw ip=dhcp console=ttyS2,1500000 rootwait rw

   label sd
     menu label Armbian on SD (orange-pi-5-pro-01)
     kernel armbian/orange-pi-5-pro-01/vmlinuz
     initrd armbian/orange-pi-5-pro-01/initrd.img
     fdt    armbian/orange-pi-5-pro-01/board.dtb
     append root=LABEL=armbi_root rootfstype=ext4 rootwait rw console=ttyS2,1500000

   label local
     menu label Armbian on local disk (orange-pi-5-pro-01)
     kernel armbian/orange-pi-5-pro-01/vmlinuz
     initrd armbian/orange-pi-5-pro-01/initrd.img
     fdt    armbian/orange-pi-5-pro-01/board.dtb
     append root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console=ttyS2,1500000

   label local_kernel
     menu label Boot local kernel from NVMe (orange-pi-5-pro-01)
     localboot 0

Switching ``pxelinux_render_boot_mode`` to ``sd`` re-renders the same
file with ``default sd`` — the label blocks themselves are unchanged.

Upload it to the router with the RouterOS reference playbook. The
playbook reads each board's MAC from ``hostvars[item].armbian_board_mac``,
so the board must be in inventory:

.. code-block:: bash

   ansible-playbook playbooks/routeros/upload_pxelinux_cfg.yml \
     -e armbian_tftp_flash_dir=sbc \
     -e armbian_tftp_cache_dir=$PWD/.cache \
     -e '{"armbian_pxelinux_upload_boards": ["orange-pi-5-pro-01"]}'

Router-side, the pxelinux.cfg directory now holds one file per board,
registered under a regex ``/ip tftp`` row so U-Boot's MAC-prefixed
request resolves to it:

.. code-block:: text

   flash:/sbc/pxelinux.cfg/
   └── 01-aa-bb-cc-dd-ee-ff

   /ip tftp> print where req-filename~"01-"
    # REQ-FILENAME                  REAL-FILENAME                              IP-ADDRESSES
    3 01-aa-bb-cc-dd-ee-ff          flash/sbc/pxelinux.cfg/01-aa-bb-cc-dd-ee-ff 0.0.0.0/0

Converge and verify
~~~~~~~~~~~~~~~~~~~

The workhorse playbook ``converge_boot_mode.yml`` composes everything
above (plumbing check → render → upload → PoE cycle → wait → verify
rootfs matches declared mode):

.. code-block:: bash

   ansible-playbook playbooks/converge_boot_mode.yml \
     -e target_hosts=orange-pi-5-pro-01

To flip a board's boot mode ad hoc without editing inventory:

.. code-block:: bash

   ansible-playbook playbooks/set_boot_mode.yml \
     --limit orange-pi-5-pro-01 \
     -e armbian_boot_mode=sd

See the per-role reference (linked from the sidebar) for the full set of
inputs each role accepts.
