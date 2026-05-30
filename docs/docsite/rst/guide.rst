.. _ansible_collections.david_igou.armbian.docsite.guide:

Getting started
===============

``david_igou.armbian`` manages Armbian-based ARM SBCs end to end: building
a custom Armbian image, writing it to a board, and provisioning a regular
login user — all with single-purpose, parameter-driven roles composed by
workflow playbooks. This page walks through the simplest use: build a
regular Armbian image, flash it to an SD card, and bootstrap a login user.
No netboot server, no router, no PXE patches.

For the PXE-netboot workflow (custom PXE-first image, NFS rootfs, and
RouterOS-driven boot-mode convergence), see
:ref:`ansible_collections.david_igou.armbian.docsite.netboot`. Per-role
inputs and outputs are documented in the role reference.

Every example threads the same concrete board — ``orange-pi-5-pro-01`` —
so the variables read straight across.

.. note::

   Early-stage 0.0.x — expect breaking changes between releases. Pin a
   specific version in your ``requirements.yml``.

The setup
---------

Install the collection:

.. code-block:: bash

   ansible-galaxy collection install david_igou.armbian

The examples below assume this inventory shape: a Docker-capable
**builder** that runs ``armbian/build``, and the **board** itself.
Replace the two hosts with your own and adjust addresses; everything
else is verbatim:

.. code-block:: yaml

   # inventory/hosts.yml
   all:
     children:
       armbian_builders:
         hosts:
           builder-01:
             ansible_host: 192.0.2.5
       boards:
         hosts:
           orange-pi-5-pro-01:
             ansible_host: 192.0.2.111
             ansible_user: armbian

   # inventory/group_vars/all.yml
   armbian_default_password: "1234"

The build
---------

``image_build`` runs ``armbian/build`` in Docker mode on the builder
host and writes a ``.img.xz`` plus a ``manifest.json`` to
``$HOME/armbian_build/output/<host>/``. A regular SD-bootable image
needs no userpatches — board, branch, and release are the only inputs.

Drop this into ``playbooks/local/build.yml``:

.. code-block:: yaml

   ---
   - name: Build a regular Armbian image for orange-pi-5-pro-01
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

.. code-block:: bash

   ansible-playbook playbooks/local/build.yml

The output on the builder:

.. code-block:: text

   $HOME/armbian_build/output/
   └── orange-pi-5-pro-01/
       ├── Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz
       ├── Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz.sha
       └── manifest.json

The accompanying ``manifest.json`` records what was built; the role uses
it as its idempotency key on subsequent runs (re-running ``build.yml``
is a no-op until ``board``, ``branch``, ``release``, ``armbian_build_ref``,
or ``armbian_build_userpatches`` change):

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

Flash the SD card
-----------------

The ``image_build`` role only produces the ``.img.xz``; flashing is a
manual step because ``disk_image`` can't write to a board's own boot
disk. Copy the image off the builder and write it to an SD card on your
workstation:

.. code-block:: bash

   scp builder-01:armbian_build/output/orange-pi-5-pro-01/Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz .

   # Identify the SD card; double-check before running dd.
   lsblk

   xz -dc Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz \
     | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync

Insert the SD card in the board, power it on, and confirm it's reachable
on the address you set in inventory:

.. code-block:: bash

   ssh root@192.0.2.111   # password: 1234

Bootstrap the board
-------------------

A freshly flashed Armbian image only has the ``root`` user with the
default password (``"1234"``). ``bootstrap_armbian`` connects as ``root``,
provisions your inventory user with passwordless sudo + SSH-key login,
drops Armbian's first-login TUI, and disables password authentication.

Drop this into ``playbooks/local/bootstrap.yml``:

.. code-block:: yaml

   ---
   - name: Bootstrap orange-pi-5-pro-01 with an SSH-key login user
     hosts: orange-pi-5-pro-01
     gather_facts: false
     vars:
       # Connect as root with the default Armbian password — this is the
       # only user that exists before bootstrap runs. After this playbook
       # succeeds, subsequent plays connect as `armbian` (ansible_user in
       # inventory) using key auth.
       ansible_user: root
       ansible_password: "1234"
       ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
       ansible_become: false
     roles:
       - role: david_igou.armbian.bootstrap_armbian
         vars:
           armbian_bootstrap_user: armbian
           armbian_bootstrap_ssh_keys:
             - "ssh-ed25519 AAAA...your-public-key... you@workstation"

.. code-block:: bash

   ansible-playbook playbooks/local/bootstrap.yml

The role leaves the board in this state — a regular ``armbian`` user
with key-only login and passwordless sudo:

.. code-block:: text

   /home/armbian/.ssh/authorized_keys     # the supplied public key(s)
   /etc/sudoers.d/armbian                  # mode 0440, visudo-validated

   # /etc/sudoers.d/armbian
   armbian ALL=(ALL) NOPASSWD: ALL

It also removes ``/root/.not_logged_in_yet`` (Armbian's first-login TUI)
and sets ``PasswordAuthentication no`` in ``/etc/ssh/sshd_config`` so the
next reboot is key-only. Verify with key auth:

.. code-block:: bash

   ssh armbian@192.0.2.111

From here the board is a regular Ansible target. Re-running
``bootstrap.yml`` reconciles ``authorized_keys`` and is otherwise a no-op.

Where to next
-------------

Other roles work standalone too — ``disk_image`` streams an ``.img.xz``
onto a block device (run from a board booted from a different device),
and ``disk_provision`` applies a declarative GPT layout to a local disk.

For the full PXE-netboot workflow that builds a PXE-first image, carves
out per-host NFS rootfs on a netboot server, and drives boot-mode
convergence via RouterOS, see
:ref:`ansible_collections.david_igou.armbian.docsite.netboot`.
