.. _ansible_collections.david_igou.armbian.docsite.pxelinux_render_role:

david_igou.armbian.pxelinux_render role
=======================================

Runs on ``localhost`` (typically via ``delegate_to``). Renders one per-board
``01-<mac>`` pxelinux.cfg into a local directory, with a ``default`` directive
selecting the active boot mode (nfs, sd, local, or local_kernel).

See the :ansplugin:`full role reference <david_igou.armbian.pxelinux_render#role>`
for all parameters and defaults.
