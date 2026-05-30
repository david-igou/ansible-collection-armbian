.. _ansible_collections.david_igou.armbian.docsite.guide:

Getting started
===============

``david_igou.armbian`` manages Armbian-based ARM SBCs end to end: building a
custom Armbian image, writing it to a board, and provisioning a regular
login user — all with single-purpose, parameter-driven roles composed by
workflow playbooks. This page walks through the simplest end-to-end use:
build a custom image and boot a single board from its SD card.

For the PXE-netboot workflow (custom PXE-first image, NFS rootfs, and
RouterOS-driven boot-mode convergence), see
:ref:`ansible_collections.david_igou.armbian.docsite.netboot`. Per-role
inputs and outputs are documented in the role reference.

.. note::

   Early-stage 0.0.x — expect breaking changes between releases. Pin a
   specific version in your ``requirements.yml``.

Install
-------

.. code-block:: bash

   ansible-galaxy collection install david_igou.armbian

Inventory
---------

You need two hosts: a Docker-capable **builder** that runs
``armbian/build``, and the **board** that will be booted.

.. code-block:: yaml

   # inventory/hosts.yml
   all:
     children:
       armbian_builders:
         hosts:
           builder-01:
             ansible_host: 192.168.1.10
       boards:
         hosts:
           my-board:
             ansible_host: 192.168.1.50
             armbian_build_board: orangepi5pro    # armbian/build BOARD= value
             armbian_build_branch: current        # current | edge | legacy | vendor
             armbian_build_release: bookworm

   # inventory/group_vars/all.yml
   armbian_bootstrap_ssh_keys:
     - "ssh-ed25519 AAAA... you@workstation"

Build a custom image
--------------------

The ``image_build`` role builds one ``.img.xz`` per board on a builder host
using ``armbian/build`` in Docker mode. The output (``.img.xz`` + a
``manifest.json``) lands at
``{{ armbian_build_output_dir }}/{{ armbian_build_host }}/`` on the builder.
For a regular SD-bootable image, no userpatches are required.

A minimal demo playbook lives at ``playbooks/examples/image_build.yml``:

.. code-block:: bash

   ansible-playbook playbooks/examples/image_build.yml --limit builder-01

See the :ansplugin:`image_build role reference <david_igou.armbian.image_build#role>`
for the full parameter list.

Flash the SD card
-----------------

``image_build``'s output is a regular Armbian ``.img.xz``. Copy it off the
builder and write it to an SD card with whatever flashing tool you prefer
(``balenaEtcher``, ``dd``, or Armbian's own writer):

.. code-block:: bash

   scp builder-01:/path/to/output/my-board/Armbian_*.img.xz .
   xz -dc Armbian_*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync

Insert the SD card in the board and power it on.

Bootstrap the board
-------------------

``bootstrap_armbian`` connects as ``root`` with Armbian's default password
and replaces it with your inventory user — passwordless sudo, SSH-key auth
only, password login disabled. The play is idempotent.

.. code-block:: bash

   ansible-playbook playbooks/bootstrap_armbian.yml --limit my-board

From here the board is a normal Ansible target. Other roles work standalone
too — ``disk_image`` streams an ``.img.xz`` onto a block device,
``disk_provision`` applies a declarative GPT layout to a local disk, and
the netboot playbooks compose the whole fleet (see the netboot guide).
