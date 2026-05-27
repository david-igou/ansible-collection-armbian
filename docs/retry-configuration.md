# Boot-retry configuration matrix

The retry/timeout knobs documented here are inputs to the cold-boot
primitives that live as task files under `playbooks/tasks/`:

- `playbooks/tasks/cold_boot_with_retry.yml` — outer retry loop (PoE
  cycle → `wait_for` TCP/22 → sustained ssh-ping).
- `playbooks/tasks/cold_boot_single_attempt.yml` — inner
  `block:`/`rescue:` for one attempt, included by the outer loop.
- `playbooks/tasks/wait_for_ssh_with_cycle_retry.yml` — second-layer
  retry around the post-boot SSH wait.

These primitives are composed by the orchestration playbooks
(`converge_boot_mode.yml`, `set_boot_mode.yml`, `test_hardware_e2e.yml`,
`test_fleet_e2e.yml`). The inventory variables
(`armbian_boot_retry_attempts`, `armbian_boot_attempt_timeout`, etc.)
are read directly by the task files. This doc maps scenarios to
recommended settings.

For why the retry stack exists at all, see issue [#38] and the
discussion of PoE-HAT brown-out behavior. Short version: on flaky
PoE-HAT power delivery the dominant failure mode is "board fails to
cold-boot or boots then falls off the network for a few minutes."
The retry stack converts this into eventually-consistent automation:
the play PoE-cycles the board again instead of hard-failing.

[#38]: https://github.com/david-igou/ansible-collection-armbian/issues/38

## Knobs

| Variable | Default | What it does |
|---|---|---|
| `armbian_boot_retry_attempts` | `0` | Number of additional cold-boot attempts after a failed PoE cycle / TCP/22 wait. `0` = single attempt (no retry); `2` = up to 3 total attempts per phase. |
| `armbian_boot_attempt_timeout` | `180` | Seconds to wait for TCP/22 within a single attempt before declaring it failed and either retrying or giving up. |
| `armbian_ssh_wait_timeout` | `90` | Seconds to wait for sustained ssh-ping inside the retry block (the "is the board *stably* up?" check). |
| `armbian_ssh_wait_retry_attempts` | (= `armbian_boot_retry_attempts`) | Retry depth for the **second-layer** retry around the post-boot SSH wait. Override only if you need different depths for the two layers. |
| `armbian_post_boot_wait_timeout` | `300` | Seconds for the post-retry wait_for_connection (the long ssh wait after the retry has reported success). |
| `armbian_poe_cycle_delay` | `5` | Seconds the PoE port stays off during a `cycle` action (capacitor drain time). |

Plus the existing flow-control knobs:

| Variable | Default | What it does |
|---|---|---|
| `capture_serial` | `false` | Start a background socat capture on the serial host. |
| `skip_baseline` | `false` | Skip Phase 1 (the disk-boot baseline + assertion). Useful when SD-side boot is broken and you only want to validate the PXE path. |
| `leave_state` | `false` | Skip Phase 3 / Cleanup. Board left in whatever state Phase 2 / current phase ended in. |
| `armbian_cycle_board` | `true` (defaults when using `playbooks/converge_boot_mode.yml` / `playbooks/set_boot_mode.yml`) | When `false`, skips the PoE cycle + verify in `playbooks/converge_boot_mode.yml` / `playbooks/set_boot_mode.yml`. Use when the board is currently powered off and you just want to write the router config. |

## Recommended combinations

### Healthy hardware (production toggle on a known-good PoE setup)

Defaults — no retries needed, all timeouts at full budget.

```
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=<board>
```

Behavior: single attempt at PoE cycle + boot wait. Fails fast if the
board doesn't come up; you'll want to investigate rather than retry.

### Flaky PoE HAT (production toggle on hardware with known brown-out behavior)

```
ansible-playbook playbooks/converge_boot_mode.yml \
  --limit <board> \
  -e armbian_boot_retry_attempts=2 \
  -e armbian_poe_cycle_delay=60
```

Behavior: up to 3 cold-boot attempts (initial + 2 retries), each
allowing the board's full ~80 s normal boot time plus margin. The
60 s drain ensures the board's bulk capacitors have fully discharged
before re-energizing. Hits ~80 % on the 4 A HAT topology in #38.

### Maximum eventual consistency (slow but reliable)

```
ansible-playbook playbooks/test_hardware_e2e.yml \
  --limit <board> \
  -e armbian_boot_retry_attempts=3 \
  -e armbian_poe_cycle_delay=60 \
  -e armbian_ssh_wait_timeout=90 \
  -e armbian_post_boot_wait_timeout=300
```

Behavior: full e2e with deep retries. Each attempt gets the full
default timeouts. Slow per-iter (~10 min average) but the highest
green rate. Use when you don't care about iter time and the board
needs every chance to recover.

### Fast iter loop (for characterization, not production)

```
ansible-playbook playbooks/test_hardware_e2e.yml \
  --limit <board> \
  -e skip_baseline=true \
  -e leave_state=true \
  -e armbian_boot_attempt_timeout=90 \
  -e armbian_ssh_wait_timeout=45 \
  -e armbian_boot_retry_attempts=3 \
  -e armbian_post_boot_wait_timeout=60 \
  -e armbian_poe_cycle_delay=60
```

Behavior: skips Phase 1 baseline and Phase 3 cleanup, leaving the
board in NFS-rooted state. Each iter is ~4 min on greens, ~8 min on
rescues. ~12 iters/hour. Use for running many iters quickly to
characterize failure rates or stress-test the retry stack.
**Do not use this combo for production** — leave_state means the
board is left in NFS mode after each run; you'll need to manually
toggle back.

### Fresh-rootfs reflash (auto-bootstrap needed)

```
ansible-playbook playbooks/test_hardware_e2e.yml \
  --limit <board> \
  -e armbian_boot_retry_attempts=0
```

Behavior: explicitly no retries. Required for the fresh-rootfs
auto-bootstrap path: the retry's internal sustained-ssh-ping uses
the inventory user, which doesn't exist on a freshly-flashed rootfs.
With `armbian_boot_retry_attempts > 0`, every attempt would fail auth and
the play would error out before the downstream auto-bootstrap chain
could run.

## How the two retry layers interact

Each phase that drives a cold boot now has two retry layers:

```
Phase N:
  Layer 1 (cold_boot_with_retry.yml):
    repeat up to armbian_boot_retry_attempts+1 times:
      - PoE cycle (off → armbian_poe_cycle_delay drain → on)
      - wait_for TCP/22 (armbian_boot_attempt_timeout)
      - wait_for_connection sustained ssh-ping (armbian_ssh_wait_timeout)
    assert at least one attempt succeeded.

  ... (auto-bootstrap probe, other intermediate tasks) ...

  Layer 2 (wait_for_ssh_with_cycle_retry.yml):
    initial wait_for_connection (delay=30, timeout=armbian_post_boot_wait_timeout)
    on failure → rescue:
      - cold_boot_with_retry (another full Layer 1 loop)
      - second wait_for_connection
    if second wait also fails → play fails
```

**Layer 1** catches "board never came up" and "board came up briefly
then died within ~90 s." It's bounded by `armbian_boot_retry_attempts`.

**Layer 2** catches "board passed Layer 1's check, then died during
the longer post-retry SSH wait." It triggers another full Layer 1
loop when it fires, then tries the SSH wait once more. Bounded by
`armbian_ssh_wait_retry_attempts` (defaults to the same value as
`armbian_boot_retry_attempts`).

The two layers cover different failure-window sizes:

- A board that's hung in early boot fails Layer 1 quickly (within
  `armbian_boot_attempt_timeout`).
- A board that comes up briefly, ACKs SYN to port 22, then falls off
  during the next ~90 s passes Layer 1 (since the sustained ssh-ping
  saw it) but fails Layer 2 (the longer wait sees it gone).
- Both modes are rescued by a fresh PoE cycle in their respective
  layer's retry loop.

## Failure modes the retry stack does *not* cover

- **Wrong rootfs after successful boot** — board PXE-bootflow falls
  through to local SD instead of pulling pxelinux.cfg, the rootfs
  assertion fails. This is a "successful boot to the wrong place"
  rather than a cold-boot failure; the retry stack doesn't trigger.
  Would need a third retry layer around Phase 2's verify step
  (re-write pxelinux.cfg + re-cycle on assertion failure).
- **Router configuration drift** — e.g. the per-board `/ip tftp` row
  isn't where the playbook expects. Surfaced by the pre-flight
  plumbing-check, fails the play immediately.
- **Network-layer issues outside the board** — switch port disabled,
  cable unplugged, VLAN misconfiguration. The retry will fire but
  every cycle fails the same way.
- **Hard hardware failure** — SD card dead, PoE HAT shorted, board
  itself non-functional. Same as network-layer: every retry fails.
  The assert at the end of Layer 1 fails loud after exhausting attempts.

## Tuning intuition

When choosing values:

- **`armbian_boot_attempt_timeout`** should be ≥ the board's normal cold-boot
  time (this hardware is ~60–80 s for the Orange Pi 5 Pro). Too
  short → false-fails on healthy boots, wasting cycles on retries.
  Too long → slow failure detection when the board's genuinely hung.
  `90` is a comfortable margin.
- **`armbian_ssh_wait_timeout`** is the "is the board stably up?" check. A
  healthy board ssh-pings successfully within 5–10 s; `90` gives the
  retry's check enough time to also catch "briefly responsive then
  dead" patterns. Lowering below ~30 s starts false-failing.
- **`armbian_post_boot_wait_timeout`** caps the post-retry SSH wait. Originally 300 s
  (the historical default); 60 s is sufficient now that Layer 1's
  sustained ssh-ping has already established stability. Lower only
  if you're willing to false-fail in exchange for faster iteration.
- **`armbian_poe_cycle_delay`** matters more on flaky HATs — bigger
  capacitor banks need more time to drain. 30 s works on healthy
  HATs; 60 s tends to recover marginal HATs that the shorter delay
  doesn't.
- **`armbian_boot_retry_attempts`** scales the failure-rescue rate
  multiplicatively at the cost of worst-case iter time. At an
  observed 60 % per-attempt success rate, `armbian_boot_retry_attempts=2`
  (3 attempts) compounds to 93.6 % per-phase. With three phases
  in a full e2e, that's about 82 % whole-iter. `armbian_boot_retry_attempts=3`
  pushes the per-phase to 97.4 % and whole-iter to about 92 %.
