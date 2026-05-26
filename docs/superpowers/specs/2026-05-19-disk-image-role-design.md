# `disk_image` role — design

**Date**: 2026-05-19
**Status**: Approved (brainstorming complete; implementation plan TBD)
**Supersedes**: nothing
**Motivating context**: cross-iteration SD-card state drift surfaced during
fleet-e2e validation runs (see `docs/end-to-end-fleet-test.html` §
"Open: dd a known image to SD as a pre-flight (full state reset)").
The fleet test ran 5×5 phases against the same SD cards repeatedly;
machine-id, host keys, and leftover state from prior runs accumulated.
A canonical pre-flight `dd` is the deterministic answer.

## Goal

Add a single-purpose, transport-agnostic role that writes a defined
image to a defined block device. Reuse cases include "reimage the SD
card from an NFS-booted board" (the immediate use case in
`test_fleet_e2e.yml`) and "reimage an NVMe device" (no current caller,
but the role doesn't care).

Out of scope: identity reset, filesystem expansion, supply-chain
verification, retry on transient network failure. Caller's job, or
left to a downstream role.

## Role placement

- **Name**: `disk_image` (sits next to `disk_provision`, `image_extract`,
  `image_build` — the verb-then-noun naming the collection already uses).
- **Runs on**: a board (whatever host is in the play). The role assumes
  root or `become: true`, and that the running rootfs is *not* on the
  target device.
- **Transport agnostic**: takes a source URL/path and a device path.
  Knowing about NFS vs SD vs NVMe is the caller's job. Same separation
  v3 put between `pxelinux_render` and `converge_boot_mode.yml`.

## Runtime prerequisites on the running rootfs

- `curl`, `xz`, `dd`, `sync`, `partprobe` (from `parted`).
- All present in stock Armbian; the role does not install them.

## Inputs (`meta/argument_specs.yml`)

```yaml
argument_specs:
  main:
    short_description: Write a defined image to a defined block device.
    options:
      image_source:
        description:
          - Either an http(s):// URL or an absolute path on the running host.
          - Auto-dispatch by extension: .img.xz → xzcat | dd; .img → dd direct.
          - Mismatched extension is a hard failure (no content sniffing).
        type: str
        required: true
      target_device:
        description:
          - Absolute path to a block device (e.g. /dev/mmcblk0, /dev/nvme0n1).
          - Must be a real block device (stat → S_ISBLK), not a partition.
          - Role refuses if this device, or any of its partitions, backs
            a currently-mounted filesystem.
        type: str
        required: true
      dd_bs:
        description: dd block size. Default tuned for SD/NVMe throughput.
        type: str
        default: "4M"
```

Three options. No retry knobs, no confirm flag, no idempotency cache,
no scratch-dir option (streaming-only fetch).

Deliberately **not** exposed:
- `image_sha256` — streaming-only means we can't verify before writing.
  Easy to add later if the supply-chain story changes.
- `force` / `confirm` — out-of-scope per design discussion; the
  mount-aware guard is the only safety check.

## Behavior — task flow

Three blocks, in order. Failure from any aborts the role.

### Block A — Validate (no side effects)

1. `stat` `target_device` → assert it exists and is a block device.
   Then check `/sys/class/block/<basename>/partition` — must NOT exist
   (its existence is what distinguishes a partition node from a whole
   disk node, independent of naming conventions).
2. Enumerate `target_device` + all its partitions via
   `lsblk -nro NAME <target_device>` (yields `mmcblk0`, `mmcblk0p1`,
   `mmcblk0p2`, ...). For each, scan `/proc/mounts` for an exact
   match in the source field. Fail with the offending mount line.
   Exact-match (not prefix-match) avoids the `/dev/sda` vs `/dev/sdaa1`
   false positive.
3. Classify `image_source`:
   - matches `^https?://` → URL branch
   - matches `^/` → local path; `stat` → assert exists, regular file
   - anything else → fail fast with a clear message
4. From the last segment of the path/URL, derive the format:
   - ends in `.img.xz` → `xz` branch
   - ends in `.img` → `raw` branch
   - anything else → fail fast

### Block B — Stream and write

One `ansible.builtin.shell` task per source-classify × format-classify
combination, gated by `when:`. All run `set -o pipefail` so a curl 404
or xz CRC failure in the pipe is not swallowed:

- URL + xz: `set -o pipefail; curl -fsSL <url> | xz -dc | dd of=<target> bs=<dd_bs> conv=fsync status=progress`
- URL + raw: `set -o pipefail; curl -fsSL <url> | dd of=<target> bs=<dd_bs> conv=fsync status=progress`
- Path + xz: `set -o pipefail; xz -dc <path> | dd of=<target> bs=<dd_bs> conv=fsync status=progress`
- Path + raw: `dd if=<path> of=<target> bs=<dd_bs> conv=fsync status=progress`

`conv=fsync` makes dd itself fsync at end. Stderr is captured into the
task's `register:` for evidence. `status=progress` writes ~1 line/sec
of throughput to stderr.

### Block C — Settle the kernel's view of the new partition table

1. `sync` — defensive, on top of `conv=fsync`.
2. `partprobe <target_device>` — kernel re-reads partition table so the
   next role can mount a partition without a reboot.
3. `sleep 1` then re-stat partition nodes (best-effort, not asserted) —
   give udev time to materialise `<target>p1`, `p2`, ... before the
   next play in the caller's playbook fires.

## Failure modes

| Failure | Where it surfaces | Symptom |
|---|---|---|
| `target_device` doesn't exist | Block A step 1 | assert: `not a block device: <path>` |
| `target_device` is a partition node (e.g. `/dev/mmcblk0p1`) | Block A step 1 | assert: `target_device is a partition, not a whole disk: <path>` |
| Target or one of its partitions is mounted (e.g. ran while booted on SD against `/dev/mmcblk0`) | Block A step 2 | assert: `target device <dev> backs a mounted filesystem: <mount line>` |
| `image_source` gibberish (not URL, not abs path) | Block A step 3 | fail: `image_source must be http(s):// URL or absolute path` |
| Wrong extension (`.iso`, `.img.gz`) | Block A step 4 | fail: `unsupported format; only .img and .img.xz` |
| URL 404 / DNS failure / connection refused | Block B | curl exits non-zero; pipefail propagates; task fails |
| `.img.xz` corrupt (CRC mismatch) | Block B | xz exits non-zero; pipefail propagates; **partial write on target** |
| Network blip mid-stream | Block B | curl exits non-zero; **partial write on target** |
| dd write error (bad sector, device full) | Block B | dd exits non-zero; **partial write on target** |
| `partprobe` not installed | Block C | command-not-found; role assumes `parted` package present (Armbian default) |

**Acknowledgement**: a mid-stream failure leaves the target with a
partial image. By design (stream over staged). Recovery: re-invoke the
role (always-write contract).

## Caller wiring — `test_fleet_e2e.yml` Phase 0

New phase inserted before Phase A. Skip-flag `skip_dd_sd` defaults to
`false` (new behaviour is opt-out):

```yaml
- name: "Phase 0 — dd canonical image to SD (state reset, parallel)"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    skip_dd_sd: false
    fleet_artifact_dir: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/0-dd-sd"
  tasks:
    - name: "Phase 0 — block"
      when: not (skip_dd_sd | bool)
      block:
        - name: "Phase 0 — pre-flight: ensure we're booted on NFS"
          # board_boot_verify with target=nfs; if not on NFS, abort.
          # disk_image's own mount-aware guard would also catch this,
          # but a play-level guard surfaces the cause earlier.

        - name: "Phase 0 — dd canonical SD image"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "{{ armbian_image_urls[armbian_board_model] }}"
            target_device: "{{ armbian_sd_device | default('/dev/mmcblk0') }}"

        - name: "Phase 0 — record timing + evidence"
          # same pattern as Phase A timing block.
```

Notes on the wiring:

1. **Phase 0 only runs when the board is already on NFS.** Cold-start
   scenarios (board on stale SD) need the fleet test's `Pre-flight` play
   to converge to NFS first; the existing pre-flight already injects
   the igou user into the per-host NFS rootfs, so adding a "set boot
   mode to nfs + cycle" step is straightforward and orthogonal to this
   role's design.

2. **`skip_dd_sd: false` default**: opt-out matches the framing that
   this fixes a known drift problem. Operators can `-e skip_dd_sd=true`
   for runs where state isn't a concern.

3. **No Phase 0b for NVMe** in this design. The role itself works for
   NVMe fine, but fleet test's NVMe interaction is Phase C
   (`disk_provision`/`reprovision_to_local`), which already wipes NVMe
   via `blkdiscard` + `systemd-repart`. Adding a "dd canonical image
   to NVMe" Phase 0b doesn't have a current use case.

4. **`armbian_sd_device`**: new inventory var, default
   `/dev/mmcblk0`. Per CLAUDE.md ("MMC controller index varies per
   board"), a future board may enumerate differently; per-host
   override in inventory covers it.

5. **What Phase 0 does NOT do**: identity reset, partition resize,
   kernel-side anything. Armbian-firstrun handles machine-id and ssh
   host keys on first boot; `bootstrap_armbian` re-runs from Phase A
   handles the inventory user. If post-Phase-0 drift still surfaces in
   later runs, that's a separate fix.

## File layout

```
roles/disk_image/
├── README.md
├── defaults/main.yml          # dd_bs: "4M"
├── meta/
│   ├── argument_specs.yml
│   └── main.yml               # min_ansible_version: "2.15"
└── tasks/
    ├── main.yml               # orchestrates Block A / B / C
    ├── _validate.yml          # Block A
    ├── _write.yml             # Block B (one task per branch)
    └── _settle.yml            # Block C
```

Split into sub-files mirrors `image_extract/tasks/` (already uses
`_download_or_copy.yml`, `_extract_inner.yml`, `_copy_kernel_artifacts.yml`).
Keeps `main.yml` to ~20 lines of orchestration.

## Verification

After implementation, three ground-truth tests:

1. **Unit-style**: `ansible-playbook` against a board booted on NFS,
   target `/dev/mmcblk0`. Expect: dd writes ~3 GB, `lsblk` shows the
   new partition table, board reboots into the freshly-imaged SD.

2. **Negative**: invoke the role against a board booted on SD with
   target `/dev/mmcblk0`. Expect: Block A step 2 fails with a clear
   "target backs a mounted filesystem" error, no bytes written.

3. **Fleet integration**: run `test_fleet_e2e.yml` with Phase 0 active
   on a single board. Expect: drift symptoms (stale host keys, stale
   machine-id) gone on subsequent runs.

## Future enhancements (deliberately not in v1)

- `image_sha256` option — supply-chain verification (would force staged
  download).
- Stage-then-dd mode with sha256 gate (Q5 option B, not chosen for v1).
- Identity reset (mount root partition, blank machine-id, rm ssh host
  keys) — would mirror `rootfs_clone`'s identity reset, but for SD/NVMe.
- `growpart` last partition post-dd.
- `image_source: extracted_template` mode — rsync from
  `armbian_nfs_rootfs_path/_templates/<model>/` instead of
  re-decompressing the upstream `.img.xz`. Faster for fleet runs (no
  re-decompress, no HTTP) but couples this role to the netboot server's
  on-disk layout.
