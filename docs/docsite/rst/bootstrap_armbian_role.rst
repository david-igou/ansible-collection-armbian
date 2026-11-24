.. _ansible_collections.david_igou.armbian.docsite.bootstrap_armbian_role:

david_igou.armbian.bootstrap_armbian role
=========================================

Runs on a freshly flashed board as ``root``. Creates an SSH-key automation user with
passwordless sudo, removes Armbian's first-login prompt, and writes a validated sshd
drop-in that disables password authentication (and, optionally, root login).

See the :ansplugin:`full role reference <david_igou.armbian.bootstrap_armbian#role>`
for all parameters and defaults.
