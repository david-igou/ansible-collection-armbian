---
name: Bug report
about: Something in this collection isn't behaving as documented
title: '[bug] '
labels: bug
---

## What happened

<!-- One or two sentences. What did you expect? What actually happened? -->

## Reproducer

<!-- Minimal commands + inventory excerpt + relevant role/playbook vars.
     Trim the inventory to just what's needed to reproduce. -->

```yaml
# inventory excerpt
```

```bash
# command
ansible-playbook playbooks/... -e ...
```

## Versions

- Collection version: <!-- ansible-galaxy collection list david_igou.armbian -->
- Ansible: <!-- ansible --version -->
- Python: <!-- python3 --version -->
- Control-node OS:
- Target board model + SoC: <!-- e.g. orange-pi-5-pro / rk3588s -->
- Armbian image source: <!-- URL or build command -->

## Logs

<!-- Run with -vv. Trim to the failing task + 10–20 lines of context.
     If a diagnostic bundle was produced, paste its path and the
     contents of relevant files (findmnt, cmdline, journal tail). -->

```text
```

## Anything you've already tried

<!-- Optional. Workarounds attempted, dead-ends ruled out. -->
