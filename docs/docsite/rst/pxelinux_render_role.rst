.. _ansible_collections.david_igou.armbian.docsite.pxelinux_render_role:

david_igou.armbian.pxelinux_render role
=======================================

Runs on the control node, usually delegated from a play on the boards. Renders
one ``01-<mac>`` pxelinux.cfg with a label per boot mode and a ``default`` line
selecting the active one, and sets ``pxelinux_render_file`` for the caller's upload.

See the :ansplugin:`full role reference <david_igou.armbian.pxelinux_render#role>`
for all parameters and defaults.
