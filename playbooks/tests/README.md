# `playbooks/tests/`

> **Disclaimer.** These playbooks are what the author runs to test the
> collection in their own environment. They are provided as-is, with
> **no guarantee of functionality, stability, or fitness** for any other setup.
> Expect to read and adapt them before relying on them.

Two kinds of tests live here:

- **Localhost var-contract tests** — fast, hardware-free. They build synthetic
  inventory and assert the resolver/contract primitives in `../tasks/` produce
  the expected facts. Safe to run anywhere; the build/publish contract test is
  wired into the Makefile + CI (`make test-build-and-publish-vars`).
- **Hardware E2E harnesses** — exercise real boards (PoE cycles, NFS↔SD↔local
  transitions, reprovision). They require the real `.inventory/`, reachable
  hardware, and the RouterOS optional deps. **Not** for CI.

Run by path (not FQCN-addressable):

```bash
ansible-playbook playbooks/tests/<name>.yml
```

## Localhost var-contract tests (hardware-free)

| Test | Asserts |
|---|---|
| `test_resolve_board_config.yml` | `../tasks/_resolve_board_config.yml` family/model/host merge |
| `test_resolve_build_profile.yml` | `../tasks/_resolve_build_profile.yml` build-layer merge |
| `test_resolve_rootfs_src.yml` | `../tasks/_resolve_rootfs_src.yml` src resolution (host_vars → manifest → fail) |
| `test_build_and_publish_vars.yml` | `../build_and_publish_from_inventory.yml` per-host resolver contract |

The `test_resolve_*.yml` tests are run by path; `test_build_and_publish_vars.yml`
also has the Makefile/CI target noted above.

## Hardware E2E harnesses (real boards required)

| Harness | Scope |
|---|---|
| `test_fleet_e2e.yml` | Deterministic six-phase whole-fleet harness |
| `test_hardware_e2e.yml` | Single-board SD → NFS → SD assertion harness |
| `test_manual_psu_cold_boot.yml` | NFS converge for USB-C / manual-PSU boards (operator-driven power) |
| `test_reprovision_e2e.yml` | Single-board reprovision regression (wraps `../reprovision_to_local.yml`) |

The `running-fleet-e2e-test` skill (`.claude/skills/`) drives `test_fleet_e2e.yml`
with a wrapper script and per-phase recovery guidance.
