.. _ansible_collections.david_igou.armbian.docsite.board_boot_wait_role:

david_igou.armbian.board_boot_wait role
=======================================

Runs on a board. Waits for the board to come up — TCP/22 reachable plus a
sustained SSH probe — with no knowledge of power state. The retry/timeout knobs
it reads are shared with the cold-boot orchestration primitives.

See the :ansplugin:`full role reference <david_igou.armbian.board_boot_wait#role>`
for all parameters and defaults.
