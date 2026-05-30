.. _ansible_collections.david_igou.armbian.docsite.bootstrap_armbian_role:

david_igou.armbian.bootstrap_armbian role
=========================================

Runs on a board. Connects as ``root`` with the Armbian default password and
provisions an unprivileged SSH-key user with passwordless sudo, drops Armbian's
first-login prompt, and disables sshd password authentication. Idempotent.

See the :ansplugin:`full role reference <david_igou.armbian.bootstrap_armbian#role>`
for all parameters and defaults.
