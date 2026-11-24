.. _ansible_collections.david_igou.armbian.docsite.board_boot_wait_role:

david_igou.armbian.board_boot_wait role
=======================================

Runs on a board. Each attempt includes the caller's power-cycle tasks file (the
collection's only transport hook), waits for the SSH banner and optionally an SSH
login, and retries; the final failure names the stage that timed out.

See the :ansplugin:`full role reference <david_igou.armbian.board_boot_wait#role>`
for all parameters and defaults.
