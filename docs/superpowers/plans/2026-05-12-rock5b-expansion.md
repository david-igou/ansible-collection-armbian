# rock-5b Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add rock-5b as a second v1-supported board alongside orange-pi-5-pro, exercising the existing expansion seams stage-by-stage and capturing friction observations as a v1-spec amendment.

**Architecture:** Three sequential phases — image build → inventory + staging → hardware E2E. Between Phase 1 and Phase 2 the operator performs a manual hardware bring-up (flash SD, capture MAC, pin static DHCP lease on rb5009 via a separate repo). No refactoring of expansion seams during this work; each friction point is logged and deferred. After Phase 3, a consolidation pass writes a v1-spec amendment and minimal doc updates.

**Tech Stack:** Ansible 2.15+, `community.routeros`, `ansible.posix`, `ansible.netcommon`, armbian/build (Docker-based image builder), MikroTik RouterOS (rb5009), TrueNAS (NFS exports + nginx HTTP), yamllint, ansible-lint.

**Branch:** Continue on `design/rock5b-expansion` (the spec is already committed there). One PR at the end of Phase 4.

**Spec:** [`docs/superpowers/specs/2026-05-12-rock5b-expansion-design.md`](../specs/2026-05-12-rock5b-expansion-design.md)

---

## File Structure

**Files to modify:**

| Path | Phase | Purpose |
|---|---|---|
| `vars/boards.yml` | 1 | Add `rock-5b` block (6 fields) |
| `playbooks/build_image.yml` | 1 | Add `rock-5b` userpatches entry |
| `inventory/group_vars/all.yml` | 1 | `armbian_image_urls[rock-5b]` (placeholder, then real) |
| `.inventory/hosts.yml` (real, gitignored) | 1 (placeholder values) + 1.5 (real values) | Add `rock_5b` subgroup |
| `inventory/hosts.yml` (doc-only) | 4 | Add `rock_5b` subgroup with placeholder IP/MAC |
| `docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md` | 4 | Append rock-5b expansion amendment |
| `README.md` | 4 | Update v1 status header |
| `CLAUDE.md` | 4 | Update v1 status header + fix `earlycon` field drift in "Adding a new board" section |

**Files to create:**

| Path | Phase | Purpose |
|---|---|---|
| `docs/superpowers/specs/.rock5b-friction-notes.md` | 1 (initialize) | Working notes during the work; deleted at end of Phase 4 |
| `host_vars/rock-5b-01.yml` OR `group_vars/rock_5b.yml` | 3 (conditional) | Only if E2E retry knobs need rock-5b-specific overrides |

**Verification surface:** No new test files. Verification commands run against real hardware/state (yamllint, `ansible-playbook --syntax-check`, hardware playbook runs, SSH probes, RouterOS `/ip tftp print`, TrueNAS filesystem checks).

---

## Phase 1 — Image build

Goal: produce a custom Armbian `.img.xz` for rock-5b on the build host and publish it alongside the orange-pi-5-pro image.

### Task 1.1: Verify armbian/build hook-name convention for dashed boards

The spec hypothesises that the userpatches function name uses underscores (`rock_5b`) even though the userpatches key and `.conf` filename use dashes (`rock-5b`). Confirm this against armbian/build's source before writing the userpatches entry.

**Files:** none (research only)

- [ ] **Step 1: Locate the pre_config_uboot_target hook in armbian/build**

Run:
```bash
gh api repos/armbian/build/contents/lib/functions/compilation/uboot.sh \
  --jq '.content' | base64 -d | grep -n 'pre_config_uboot_target'
```

Or browse: `https://github.com/armbian/build/blob/main/lib/functions/compilation/uboot.sh` and search for `pre_config_uboot_target`.

Expected: a `call_extension_method` invocation like
`call_extension_method "pre_config_uboot_target__${BOARD//-/_}" <<-'PRE_CONFIG_UBOOT_TARGET'`
or similar, where `BOARD//-/_` substitutes underscores for dashes in the board name.

- [ ] **Step 2: Decide function-name form for rock-5b**

If the hook resolves the board name with `${BOARD//-/_}`, the function name MUST be `pre_config_uboot_target__rock_5b_pxe_first` (underscored). If the convention is different (rare), match what armbian/build expects.

Capture the finding in `docs/superpowers/specs/.rock5b-friction-notes.md` under Phase 1 (initialize the file with this first note):

```bash
mkdir -p docs/superpowers/specs
cat > docs/superpowers/specs/.rock5b-friction-notes.md <<'EOF'
# rock-5b friction working notes (deleted at end of Phase 4)

## Phase 1 (image build)

- **What hurt:** userpatches function-name convention vs. file/key name divergence
  **Where:** playbooks/build_image.yml build_userpatches dict
  **Root cause:** armbian/build hook resolution does `${BOARD//-/_}`, so dashed board names need underscored function names — the file/key/function trio uses two different conventions
  **Deferred-refactor candidate:** yes — encode the convention as a Jinja transform in vars/boards.yml so adding a board doesn't require remembering the rule

EOF
```

- [ ] **Step 3: Commit research note**

```bash
git add docs/superpowers/specs/.rock5b-friction-notes.md
git commit -m "wip: initialize rock-5b friction notes with Phase 1 finding on hook naming"
```

### Task 1.2: Add rock-5b entry to vars/boards.yml

**Files:**
- Modify: `vars/boards.yml`

- [ ] **Step 1: Read current state**

`vars/boards.yml` currently has one entry under `board_configs:` for `orange-pi-5-pro`. Confirm by:

Run:
```bash
yq '.board_configs | keys' vars/boards.yml
```
Expected: `["orange-pi-5-pro"]`

- [ ] **Step 2: Append the rock-5b block**

Add this block as a sibling of `orange-pi-5-pro:` under `board_configs:`:

```yaml
  rock-5b:
    armbian_dl_dir: rock-5b
    armbian_board_name: rock-5b
    armbian_support: standard
    dtb: rockchip/rk3588-rock-5b.dtb
    console: ttyS2,1500000n8
    earlycon: uart8250,mmio32,0xfeb50000
```

Use the Edit tool with `old_string` set to the end of the orange-pi-5-pro block and `new_string` appending the rock-5b block.

- [ ] **Step 3: Verify yamllint passes**

Run:
```bash
yamllint vars/boards.yml
```
Expected: no output (exit 0).

- [ ] **Step 4: Verify yq parses both entries**

Run:
```bash
yq '.board_configs | keys' vars/boards.yml
```
Expected: `["orange-pi-5-pro", "rock-5b"]`

- [ ] **Step 5: Commit**

```bash
git add vars/boards.yml
git commit -m "feat: add rock-5b entry to vars/boards.yml"
```

### Task 1.3: Add rock-5b userpatches entry to playbooks/build_image.yml

**Files:**
- Modify: `playbooks/build_image.yml` (lines 34-51, the `build_userpatches` vars block)

- [ ] **Step 1: Read current state**

The `build_userpatches:` dict at lines 35-51 of `playbooks/build_image.yml` has two entries: `orangepi5` and `orangepi5pro`. Confirm by reading lines 34-52.

- [ ] **Step 2: Append rock-5b entry**

Use Edit to add this entry as a sibling of `orangepi5pro:` inside `build_userpatches:`:

```yaml
      rock-5b:
        - dest: "config/boards/rock-5b.conf"
          content: |
            function pre_config_uboot_target__rock_5b_pxe_first() {
                declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
                sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                    include/configs/rockchip-common.h
            }
```

Note: dashed key (`rock-5b:`), dashed `.conf` filename (`rock-5b.conf`), underscored function name (`rock_5b`). This is the divergence confirmed in Task 1.1.

- [ ] **Step 3: Verify yamllint passes**

Run:
```bash
yamllint playbooks/build_image.yml
```
Expected: no output (exit 0).

- [ ] **Step 4: Verify ansible-playbook --syntax-check passes**

Run:
```bash
ansible-playbook --syntax-check playbooks/build_image.yml
```
Expected: `playbook: playbooks/build_image.yml` and no errors.

- [ ] **Step 5: Commit**

```bash
git add playbooks/build_image.yml
git commit -m "feat: add rock-5b to build_userpatches with PXE-first BOOT_TARGETS"
```

### Task 1.4: Add placeholder armbian_image_urls entry

This is the placeholder URL that Phase 1's build will overwrite with the real filename in Task 1.6.

**Files:**
- Modify: `inventory/group_vars/all.yml` (lines 42-43, the `armbian_image_urls:` block) — note: this is the doc-only sample. The REAL inventory is at `.inventory/group_vars/all.yml` (gitignored). Update both.

- [ ] **Step 1: Verify ANSIBLE_INVENTORY points at the real inventory**

Per CLAUDE.md's agent requirement:

Run:
```bash
echo "$ANSIBLE_INVENTORY"
ls -la "$ANSIBLE_INVENTORY"
```
Expected: path ends in `.inventory/` and the directory exists.

If either check fails, stop and ask the user where the real inventory lives.

- [ ] **Step 2: Add placeholder URL to the real inventory**

Edit `.inventory/group_vars/all.yml`:

Add this line as a sibling under `armbian_image_urls:`:

```yaml
  rock-5b: "https://public.igou.systems/boot-files/images/rock-5b/PLACEHOLDER_UPDATE_AFTER_BUILD.img.xz"
```

- [ ] **Step 3: Add the same placeholder to the doc inventory**

Edit `inventory/group_vars/all.yml` (the sample), adding the rock-5b entry under `armbian_image_urls:` so the documentation matches.

- [ ] **Step 4: Verify yamllint passes**

Run:
```bash
yamllint inventory/group_vars/all.yml
```
Expected: no output.

- [ ] **Step 5: Commit (real inventory is gitignored, only doc inventory committed)**

```bash
git add inventory/group_vars/all.yml
git commit -m "feat: add rock-5b placeholder URL to armbian_image_urls"
```

### Task 1.5: Add rock-5b to inventory with placeholder values

The build playbook discovers boards from `groups['boards']` via `set_fact`. To build rock-5b, it has to be in inventory BEFORE we have its real MAC/IP. We use placeholders that Phase 1.5 fills in with real values.

**This is itself a friction-writeup point** — capture it in the notes file at the end of this task.

**Files:**
- Modify: `.inventory/hosts.yml` (real, gitignored)

- [ ] **Step 1: Verify ANSIBLE_INVENTORY**

Run:
```bash
echo "$ANSIBLE_INVENTORY"
test -f "$ANSIBLE_INVENTORY/hosts.yml" && echo OK
```
Expected: `OK`. If not, stop and ask the user.

- [ ] **Step 2: Add the rock_5b subgroup with placeholders**

Edit `.inventory/hosts.yml`. Add this as a sibling of the existing `orange_pi_5_pro:` subgroup under `boards.children:`:

```yaml
        # PLACEHOLDERS — filled in with real values during Phase 1.5
        # (manual hardware bring-up). build_image.yml only reads
        # board_model from these entries, so placeholder MAC/IP are
        # safe until Phase 1.5 completes.
        rock_5b:
          hosts:
            rock-5b-01:
              ansible_host: 0.0.0.0
              board_mac: "00:00:00:00:00:00"
              board_model: rock-5b
              poe_switch: <your switch hostname>
              poe_port: <ether N>
```

Fill in `poe_switch` and `poe_port` with the real values (you know these before the board boots — they're physical wiring decisions, not DHCP-derived).

- [ ] **Step 3: Verify ansible-inventory parses it**

Run:
```bash
ansible-inventory --graph boards
```
Expected:
```
@boards:
  |--@orange_pi_5_pro:
  |  |--orange-pi-5-pro-01
  |--@rock_5b:
  |  |--rock-5b-01
```

- [ ] **Step 4: Append friction note**

Edit `docs/superpowers/specs/.rock5b-friction-notes.md` Phase 1 section:

```
- **What hurt:** rock-5b had to be added to inventory with placeholder MAC/IP before the build playbook would discover it, because build_image.yml derives _board_models from groups['boards'] via set_fact
  **Where:** playbooks/build_image.yml lines 57-63
  **Root cause:** the playbook's "what to build" question is answered by inventory, but inventory wants a real board (with MAC/IP) — chicken-and-egg
  **Deferred-refactor candidate:** yes — accept _board_models override at the play level, or move "what to build" into a separate config (e.g. a build_targets var keyed by board_model) so building doesn't require inventory pre-population
```

- [ ] **Step 5: Commit (friction notes only; .inventory/ is gitignored)**

```bash
git add docs/superpowers/specs/.rock5b-friction-notes.md
git commit -m "wip: Phase 1 friction note on inventory-driven build discovery"
```

### Task 1.6: Run the build playbook

**Files:** none (operator step)

- [ ] **Step 1: Confirm pre-run state**

Run:
```bash
ansible-playbook --syntax-check playbooks/build_image.yml
ansible-inventory --graph boards
```
Expected: no syntax errors; `boards` group shows both `orange-pi-5-pro` and `rock-5b` hosts. The build playbook's `_board_models` resolution will produce `["orange-pi-5-pro", "rock-5b"]`.

- [ ] **Step 2: Run the build**

Run:
```bash
ansible-playbook playbooks/build_image.yml
```

Expected output: the play prints `Will build images for: ['orangepi5pro', 'rock-5b']`, then armbian/build runs for each. Build time is typically 30-90 minutes per board on a Docker-capable host with a warm cache.

- [ ] **Step 3: Verify both images published**

Run on the netboot server (or via ssh):
```bash
ls -la /mnt/ssd/public/boot-files/images/orangepi5pro/
ls -la /mnt/ssd/public/boot-files/images/rock-5b/
```

Expected: each directory contains a recent `Armbian-unofficial_*_minimal.img.xz` file.

If either directory is missing or empty, the build failed — capture the failure mode in friction notes and diagnose before proceeding.

- [ ] **Step 4: Capture the rock-5b image filename**

Run:
```bash
ssh netboot-server ls /mnt/ssd/public/boot-files/images/rock-5b/Armbian-unofficial_*_minimal.img.xz
```

Note the exact filename. It will look like `Armbian-unofficial_25.11.0-trunk_Rock-5b_trixie_current_6.16.7_minimal.img.xz` — capture the casing (`Rock-5b`) and the version segments.

### Task 1.7: Update armbian_image_urls with the real filename

**Files:**
- Modify: `inventory/group_vars/all.yml`
- Modify: `.inventory/group_vars/all.yml`

- [ ] **Step 1: Replace the placeholder URL in both inventories**

Edit both files; replace the placeholder with the real published path. For example:

```yaml
  rock-5b: "https://public.igou.systems/boot-files/images/rock-5b/Armbian-unofficial_25.11.0-trunk_Rock-5b_trixie_current_6.16.7_minimal.img.xz"
```

Use the exact filename from Task 1.6 Step 4.

- [ ] **Step 2: Verify HEAD-check passes**

Run:
```bash
curl -sIo /dev/null -w '%{http_code}\n' \
  "https://public.igou.systems/boot-files/images/rock-5b/Armbian-unofficial_<…>.img.xz"
```
Expected: `200`.

- [ ] **Step 3: Verify yamllint**

Run:
```bash
yamllint inventory/group_vars/all.yml
```
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add inventory/group_vars/all.yml
git commit -m "feat: pin rock-5b image URL to first successful build"
```

### Task 1.8: Capture remaining Phase 1 friction

- [ ] **Step 1: Append observations to friction notes**

Open `docs/superpowers/specs/.rock5b-friction-notes.md` and append everything that hurt during Phase 1 beyond the hook-naming finding (Task 1.1) and the inventory-driven discovery finding (Task 1.5). Common items to think through:

- Did the image filename casing (`Rock-5b` vs `rock-5b`) cause confusion when filling in the URL?
- Did the `build_userpatches` dict feel like it's growing toward "this should be in vars/boards.yml"?
- Were there any build failures or surprises that the friction notes should capture?

Use the note shape from the spec:
```
- **What hurt:** <one-line description>
  **Where:** <file:line or playbook stage>
  **Root cause:** <why it hurt>
  **Deferred-refactor candidate:** <yes/no — if yes, what would fix it>
```

- [ ] **Step 2: Commit friction notes**

```bash
git add docs/superpowers/specs/.rock5b-friction-notes.md
git commit -m "wip: Phase 1 friction notes"
```

---

## Phase 1.5 — Manual hardware bring-up (operator only)

Goal: physically prepare the rock-5b so Phase 2 can target it by hostname.

**No code changes. This phase is operator action plus an external-repo step.**

### Task 1.5.1: Flash and boot the rock-5b

- [ ] **Step 1: Download the image to the operator's workstation**

The image is at the URL pinned in Task 1.6. Download it locally or copy from the netboot server.

- [ ] **Step 2: Flash an SD card**

Use `xzcat | dd`, etcher, or equivalent. Example:
```bash
xzcat Armbian-unofficial_<…>.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

- [ ] **Step 3: Insert SD into rock-5b, wire PoE-HAT or PoE-splitter ethernet, power on**

Physical setup.

### Task 1.5.2: Capture MAC and pin static DHCP reservation

- [ ] **Step 1: Capture the DHCP-leased MAC and IP from rb5009**

On rb5009 (or via Ansible):
```bash
ssh ansible-netboot@rb5009 '/ip dhcp-server lease print where dynamic'
```
Expected: a lease appears for an as-yet-unknown MAC (rock-5b's). Note the MAC and assigned IP.

If multiple unknown leases exist, distinguish rock-5b by checking the `host-name` field (Armbian's default hostname) or by powering only rock-5b on while watching for the new lease.

- [ ] **Step 2: Pin the MAC to a static reservation on rb5009**

**This step is owned by the separate routeros-config repo** (e.g. igou-ansible's `deploy_netboot_binaries.yml`), NOT this collection. Add a static lease entry there for rock-5b's MAC → desired IP, then run that repo's deploy to apply it.

This is the same external-state pattern as `next-server`. Capture as a friction-writeup point: "every new board adds external RouterOS state."

- [ ] **Step 3: Verify the lease is now static and on the desired IP**

```bash
ssh ansible-netboot@rb5009 '/ip dhcp-server lease print where mac-address="<rock-5b mac>"'
```
Expected: lease shows as static (`D` flag absent or `B` only), bound to the desired IP.

- [ ] **Step 4: Confirm SSH reachability with default Armbian creds**

```bash
ssh -o StrictHostKeyChecking=no root@<rock-5b ip>
# Password: 1234 (armbian_default_password)
```
Expected: login succeeds; Armbian first-boot TUI may appear (Ctrl+C is fine — `bootstrap_armbian.yml` handles dismissing it).

- [ ] **Step 5: Replace placeholders in `.inventory/hosts.yml` with real values**

Edit `.inventory/hosts.yml`. Find the `rock_5b` subgroup added in Task 1.5 and replace:

- `ansible_host: 0.0.0.0` → the pinned IP from Step 2
- `board_mac: "00:00:00:00:00:00"` → the captured MAC from Step 1 (lowercase, colon-separated)

`poe_switch` and `poe_port` should already be set correctly from Task 1.5; leave them alone.

Verify:
```bash
ansible-inventory --host rock-5b-01
```
Expected: output shows the real `ansible_host` and `board_mac` values, not the placeholders.

- [ ] **Step 6: Capture Phase 1.5 friction notes**

Open `docs/superpowers/specs/.rock5b-friction-notes.md`, add a `## Phase 1.5 (manual hardware bring-up)` section, and note what hurt:

- How long did the chicken-and-egg between rb5009 lease capture and static-reservation pinning feel? Did it need a runbook entry in this collection's docs?
- Did the cross-repo handoff (this collection → routeros-config repo) feel like a barrier?

Then commit:
```bash
git add docs/superpowers/specs/.rock5b-friction-notes.md
git commit -m "wip: Phase 1.5 friction notes"
```

---

## Phase 2 — Bootstrap + staging

Goal: rock-5b's SSH-key user is provisioned, has a per-host NFS rootfs on TrueNAS, and rb5009 holds per-model TFTP assets.

(Inventory entry was added in Task 1.5 with placeholders and updated to real values in Task 1.5.2 Step 5. Nothing new to add here.)

### Task 2.1: Bootstrap the rock-5b SSH user

**Files:** none

- [ ] **Step 1: Run bootstrap_armbian.yml**

Run:
```bash
ansible-playbook playbooks/bootstrap_armbian.yml --limit rock-5b-01
```
Expected: play targets rock-5b-01, creates the inventory's `ansible_user` (typically `igou` or similar — check `inventory/group_vars/boards.yml` or `host_vars/`) with passwordless sudo + SSH-key auth, drops Armbian's first-login TUI, disables sshd password auth. Reports `ok=N changed=M failed=0`.

- [ ] **Step 2: Verify the new user works without password**

Run:
```bash
ansible rock-5b-01 -m command -a 'whoami'
ansible rock-5b-01 -m command -a 'sudo -n true'
```
Expected: first command returns the configured `ansible_user`; second returns nothing (success — `sudo -n true` is silent on success).

### Task 2.2: Run stage_netboot_assets.yml

**Files:** none

- [ ] **Step 1: Run preflight in --check mode first to catch URL issues**

Run:
```bash
ansible-playbook playbooks/stage_netboot_assets.yml --check --start-at-task='preflight'
```
Expected: HEAD-checks succeed for both `orange-pi-5-pro` and `rock-5b` URLs. If `rock-5b` HEAD-check fails, the URL pinned in Task 1.6 is wrong — fix it before continuing.

- [ ] **Step 2: Run the full stage**

Run:
```bash
ansible-playbook playbooks/stage_netboot_assets.yml
```
Expected output: per-model template extraction for `rock-5b` (download + xz decompression + rootfs extraction), per-host clone for `rock-5b-01`, kernel/initrd/dtb fetched to control-node cache, then net_put to rb5009 + `/ip tftp` row creation. Reports `failed=0`.

This task does a lot — expect 5-15 minutes depending on disk speed and image size.

### Task 2.3: Verify staging on TrueNAS

**Files:** none

- [ ] **Step 1: Verify per-model template**

Run on the netboot server (or via ssh):
```bash
ssh netboot-server 'sudo ls -la /mnt/ssd/netboot/rootfs/_templates/rock-5b/'
```
Expected: a populated rootfs with `bin/ boot/ etc/ lib/ root/ sbin/ usr/ var/` etc. visible.

- [ ] **Step 2: Verify DTB path matches `vars/boards.yml` hypothesis**

Run:
```bash
ssh netboot-server 'sudo find /mnt/ssd/netboot/rootfs/_templates/rock-5b/boot/dtb -name "*rock-5b*"'
```
Expected: a file at `/mnt/ssd/netboot/rootfs/_templates/rock-5b/boot/dtb/rockchip/rk3588-rock-5b.dtb`.

**If the DTB path is different** (e.g. lives under `/boot/dtbs/<kver>/rockchip/` instead of `/boot/dtb/`, or has a slightly different filename):
1. Update `vars/boards.yml` rock-5b's `dtb:` field to match reality.
2. Re-run `stage_netboot_assets.yml` so the role picks up the correct DTB for rb5009.
3. Capture in friction notes (this is exactly the "Armbian renames between releases" friction the spec anticipated).
4. Commit the vars/boards.yml correction with message `fix: correct rock-5b dtb path to match Armbian release`.

- [ ] **Step 3: Verify per-host clone has reset identity**

```bash
ssh netboot-server 'sudo cat /mnt/ssd/netboot/rootfs/rock-5b-01/etc/hostname'
ssh netboot-server 'sudo cat /mnt/ssd/netboot/rootfs/rock-5b-01/etc/machine-id'
```
Expected: hostname is `rock-5b-01`; machine-id is non-empty and differs from the template's. SSH host keys under `/etc/ssh/ssh_host_*_key` should also differ between template and clone.

### Task 2.4: Verify staging on rb5009

**Files:** none

- [ ] **Step 1: Verify TFTP files on flash**

Run:
```bash
ssh ansible-netboot@rb5009 '/file print where name~"sbc/armbian/rock-5b/"'
```
Expected: three rows — `sbc/armbian/rock-5b/vmlinuz`, `sbc/armbian/rock-5b/initrd.img`, `sbc/armbian/rock-5b/board.dtb` — each with non-zero size.

- [ ] **Step 2: Verify /ip tftp rows**

Run:
```bash
ssh ansible-netboot@rb5009 '/ip tftp print where real-filename~"sbc/armbian/rock-5b/"'
```
Expected: three rows matching the files above, with `req-filename` set to `armbian/rock-5b/<basename>` (no `sbc/` prefix).

### Task 2.5: Capture Phase 2 friction and commit

- [ ] **Step 1: Append observations to friction notes**

Open `docs/superpowers/specs/.rock5b-friction-notes.md`. Add a `## Phase 2 (staging)` section. Common items:

- DTB path hypothesis vs. reality (covered above if it differed)
- How obvious was it that `stage_netboot_assets.yml` auto-picks-up new boards from inventory vs. needs a CLI flag?
- Did the per-host clone time (first time vs. reflink-shared subsequent) feel reasonable, or were you surprised?
- Was anything about the doc-inventory vs real-inventory split awkward?

- [ ] **Step 2: Commit Phase 2 changes (inventory + friction notes only; vars/boards.yml correction if any was already committed)**

The real `.inventory/` is gitignored, so nothing to commit there. Doc inventory (`inventory/hosts.yml`) is updated in Phase 4. Only the friction notes get committed now:

```bash
git add docs/superpowers/specs/.rock5b-friction-notes.md
git commit -m "wip: Phase 2 friction notes"
```

---

## Phase 3 — Hardware E2E

Goal: rock-5b passes the SD→NFS→SD cycle via the existing harness with no harness code changes.

### Task 3.1: Pre-E2E smoke — enable_netboot

**Files:** none

- [ ] **Step 1: Toggle rock-5b into NFS root**

Run:
```bash
ansible-playbook playbooks/enable_netboot.yml --limit rock-5b-01
```
Expected: renders pxelinux.cfg locally, net_puts to rb5009, registers `/ip tftp` row, reboots board. Reports `failed=0`.

- [ ] **Step 2: Verify the board came up on NFS**

Wait for the board to come back (up to 2 minutes), then:

```bash
ansible rock-5b-01 -m command -a 'findmnt /'
```
Expected: `SOURCE` column shows `<truenas-ip>:/mnt/ssd/netboot/rootfs/rock-5b-01` (or whatever the NFS export path is); `FSTYPE` is `nfs` or `nfs4`.

- [ ] **Step 3: Verify console hypothesis via /proc/cmdline (no UART needed)**

Run:
```bash
ansible rock-5b-01 -m command -a 'cat /proc/cmdline'
```
Expected: cmdline contains `console=ttyS2,1500000n8` (the value from `vars/boards.yml`). If it differs, update `vars/boards.yml` and re-run `enable_netboot.yml`.

### Task 3.2: Pre-E2E smoke — disable_netboot

**Files:** none

- [ ] **Step 1: Toggle rock-5b back to SD**

Run:
```bash
ansible-playbook playbooks/disable_netboot.yml --limit rock-5b-01
```
Expected: removes `/ip tftp` row, removes flash file, reboots board. Reports `failed=0`.

- [ ] **Step 2: Verify the board came up on SD**

Wait for the board to come back, then:

```bash
ansible rock-5b-01 -m command -a 'findmnt /'
```
Expected: `SOURCE` shows a local mmc device (e.g. `/dev/mmcblk1p1` or similar); `FSTYPE` is `ext4`.

### Task 3.3: Run the full E2E harness

**Files:** none

- [ ] **Step 1: Run E2E without serial capture**

Run:
```bash
ansible-playbook playbooks/test_hardware_e2e.yml --limit rock-5b-01
```
(Note: NO `-e capture_serial=true` per the spec — rock-5b has no UART wired.)

Expected: SD → NFS → SD cycle with `findmnt /` assertions at each transition. Each phase logs diagnostic bundle output (cmdline, route, lsblk). Final report: all phases pass, `failed=0`.

- [ ] **Step 2: If E2E flakes intermittently, tune retry knobs (NOT harness code)**

If the E2E fails because of timing (board not ready in time, post-cycle SSH stability window too short, etc.), create per-board overrides at:

`group_vars/rock_5b.yml` (preferred — applies to all rock-5b hosts) OR
`host_vars/rock-5b-01.yml` (single-host scope)

Example contents (only override knobs that need tuning — leave defaults alone otherwise):

```yaml
---
# rock-5b-specific retry-stack tuning. See docs/retry-configuration.md.
boot_retry_attempts: 3
cold_boot_wait: 90
```

Touching `playbooks/test_hardware_e2e.yml` or anything under `roles/board_boot_state/` is **disqualifying** (acceptance criterion 3).

Re-run the E2E after creating the override file. If it now passes, commit the override:

```bash
git add group_vars/rock_5b.yml  # or host_vars/rock-5b-01.yml
git commit -m "feat: per-board retry tuning for rock-5b"
```

If no tuning was needed, skip this step entirely.

### Task 3.4: Capture Phase 3 friction

- [ ] **Step 1: Append observations to friction notes**

Open `docs/superpowers/specs/.rock5b-friction-notes.md`. Add a `## Phase 3 (hardware E2E)` section. Common items:

- Did retry-knob defaults work, or need tuning? (If tuning, what values, why?)
- Was the no-serial diagnostic surface adequate, or did you wish for UART output at any point?
- How did rock-5b's PoE-cycle → reachable timing compare to OPi5Pro?
- Any surprises during the toggle (pxelinux.cfg rendered, board didn't pick it up, etc.)?

- [ ] **Step 2: Commit friction notes**

```bash
git add docs/superpowers/specs/.rock5b-friction-notes.md
git commit -m "wip: Phase 3 friction notes"
```

---

## Phase 4 — Spec amendment + doc updates + PR

Goal: rescope v1 to two boards in the published artefacts, consolidate friction notes into a spec amendment, open the PR.

### Task 4.1: Consolidate friction notes into v1-spec amendment

**Files:**
- Modify: `docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md` (append a new amendment section)

- [ ] **Step 1: Read the existing amendment section**

The spec already has an `## Amendments (2026-05-12)` section near the end. Read lines 209-296 to understand the existing pattern.

- [ ] **Step 2: Append a new amendment section**

Add a new section at the end of the file (after the existing amendments) following this structure — fill `<…>` placeholders from `.rock5b-friction-notes.md`:

```markdown
## Amendments (YYYY-MM-DD) — rock-5b expansion

### v1 rescope

v1 now ships two-board netboot capability: `orange-pi-5-pro` AND
`rock-5b`. The original spec's acceptance criterion "vars/boards.yml
contains exactly one entry (orangepi5pro)" is voided. Replacement
criterion: vars/boards.yml contains entries for both v1-supported
boards. The original spec's "Adding a new board (post-v1)" section is
no longer post-v1 framing — it documents the path to board 3+.

### Per-phase friction observations

**Phase 1 (image build):**
<distilled bullets from .rock5b-friction-notes.md Phase 1 section>

**Phase 1.5 (manual hardware bring-up):**
<distilled bullets from notes — emphasis on cross-repo/external-state
gaps>

**Phase 2 (staging):**
<distilled bullets from notes>

**Phase 3 (hardware E2E):**
<distilled bullets from notes>

**External-state callout:** every new board adds external RouterOS
state (static DHCP reservation, owned by the operator's separate
routeros-config repo) that this collection does not manage, in the
same way `next-server` is externally owned. This is not a bug — it's
a deliberate scope boundary — but it's worth documenting so the
third-board operator isn't surprised.

### Deferred refactors (post-v1)

<bullet list of every "Deferred-refactor candidate: yes" item from
the friction notes, each with a one-line description and the
codebase location the refactor would touch>
```

Use today's date in the section header (e.g. `## Amendments (2026-05-12) — rock-5b expansion`).

- [ ] **Step 3: Verify yamllint and markdown sanity**

Run:
```bash
yamllint docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md 2>&1 || true
```
(yamllint may complain about non-YAML content — that's fine for `.md` files. The frontmatter at the top is the only YAML.)

Manually skim the amendment to confirm no `<placeholder>` markers remain.

- [ ] **Step 4: Commit the amendment**

```bash
git add docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md
git commit -m "docs: amend v1 spec to rescope for two-board capability + rock-5b friction"
```

### Task 4.2: Update README.md status header

**Files:**
- Modify: `README.md` (lines 16-31, the "Status" section)

- [ ] **Step 1: Read current header**

Read README.md lines 14-32.

- [ ] **Step 2: Update the status text**

Use Edit to change:
- Line 16: `## Status: v1 = orange-pi-5-pro netboot capability only` → `## Status: v1 = orange-pi-5-pro + rock-5b netboot capability`
- Lines 19-23 (the paragraph that says "for orange-pi-5-pro" / "Orange Pi 5 Pro only") — rewrite to describe two boards. Suggested replacement paragraph:

> This collection delivers two-board netboot capability for v1: a custom Armbian SD image for `orange-pi-5-pro` and `rock-5b` whose U-Boot tries PXE first, so adding or removing a per-board `pxelinux.cfg/01-<MAC>` file on rb5009's TFTP server switches each board between an NFS rootfs and the local SD rootfs. v1 explicitly does not include reprovisioning, on-host bootloader flashing, or any board beyond these two. Reprovisioning and on-host bootloader flashing have been **deleted from the repo, not deferred-in-place**; they will be re-introduced post-v1 against the slimmer model.

- [ ] **Step 3: Update the "Included content" intro line**

Line 9-14: change "an `orange-pi-5-pro` board can be flipped …" to "two boards (`orange-pi-5-pro` and `rock-5b`) can each be flipped …".

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README status header reflects two-board v1"
```

### Task 4.3: Update CLAUDE.md status header + fix earlycon drift

**Files:**
- Modify: `CLAUDE.md` (the status section near the top + the "Adding a new board" section at line 335)

- [ ] **Step 1: Update the status section near the top of CLAUDE.md**

Find the section that starts with `## ✅ Status: v1 = orangepi5pro netboot capability only` and rewrite to reflect two boards. Mirror the wording chosen in Task 4.2's README update for consistency.

- [ ] **Step 2: Fix the earlycon drift in "Adding a new board"**

Read CLAUDE.md lines 335-350. The current step 2 lists 5 fields:

```
2. Add an entry to `vars/boards.yml` with `armbian_dl_dir`,
   `armbian_board_name`, `armbian_support`, `dtb`, `console`.
```

Update to 6 fields:

```
2. Add an entry to `vars/boards.yml` with `armbian_dl_dir`,
   `armbian_board_name`, `armbian_support`, `dtb`, `console`, `earlycon`.
```

- [ ] **Step 3: Update the section header from "(post-v1)" framing if appropriate**

The section header is `## Adding a new board (post-v1)`. Since v1 now contains two boards, this section documents adding board 3+. Consider changing to `## Adding a new board (board 3+)` or leaving "post-v1" if you want to preserve the historical naming. Pick one and apply consistently.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md two-board v1 + earlycon drift fix in 'Adding a new board'"
```

### Task 4.4: Update sample inventory to include rock_5b

**Files:**
- Modify: `inventory/hosts.yml` (the doc-only sample)

- [ ] **Step 1: Read the current sample inventory boards section**

Read `inventory/hosts.yml` lines 81-96.

- [ ] **Step 2: Add a rock_5b subgroup with placeholder values**

Add this as a sibling of `orange_pi_5_pro:` under `boards.children:`:

```yaml
        # Rock 5B: PoE via HAT or external splitter. PoE cycling via the
        # upstream RouterOS switch is the available power-control surface.
        rock_5b:
          hosts:
            rock-5b-01:
              ansible_host: 192.168.1.112
              board_mac: "aa:bb:cc:dd:ee:22"
              board_model: rock-5b
              poe_switch: switch
              poe_port: ether5
```

Keep IPs/MACs as placeholders matching the sample-inventory convention (the existing `192.168.1.111` / `aa:bb:cc:dd:ee:11` for OPi5Pro is illustrative; mirror that style).

- [ ] **Step 3: Verify yamllint**

Run:
```bash
yamllint inventory/hosts.yml
```
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add inventory/hosts.yml
git commit -m "docs: sample inventory documents rock_5b subgroup"
```

### Task 4.5: Delete the working friction notes file

**Files:**
- Delete: `docs/superpowers/specs/.rock5b-friction-notes.md`

- [ ] **Step 1: Confirm content has migrated into the amendment**

Open the file and the v1-spec amendment side-by-side. Confirm every observation has been distilled into the amendment. Anything that didn't make it is either (a) too low-signal to keep or (b) needs to be added to the amendment now.

- [ ] **Step 2: Delete the notes file**

```bash
git rm docs/superpowers/specs/.rock5b-friction-notes.md
git commit -m "docs: drop working friction notes (migrated into v1 spec amendment)"
```

### Task 4.6: Final lint pass

**Files:** none

- [ ] **Step 1: Run yamllint across the changed areas**

Run:
```bash
make yamllint
```
Expected: no output.

- [ ] **Step 2: Run ansible-lint across roles and playbooks**

Run:
```bash
make ansible-lint
```
Expected: no errors. Warnings about pre-existing issues are OK if they're unchanged from main; new issues introduced by this work need to be fixed before opening the PR.

### Task 4.7: Open the PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin design/rock5b-expansion
```

- [ ] **Step 2: Create the PR**

Run:
```bash
gh pr create --title "Add rock-5b as second v1 board" --body "$(cat <<'EOF'
## Summary

- Adds `rock-5b` as a second v1-supported board alongside `orange-pi-5-pro`, rescoping v1 to two-board netboot capability.
- Stage-by-stage expansion (image build → staging → hardware E2E) with no refactoring of expansion seams; friction observations consolidated into an amendment on the v1 scope-narrowing spec.
- Minimal doc updates: README/CLAUDE.md status headers reflect the rescope, CLAUDE.md "Adding a new board" section's `earlycon` field drift fixed, sample inventory documents `rock_5b` subgroup.

Spec: `docs/superpowers/specs/2026-05-12-rock5b-expansion-design.md`
Amendment: appended to `docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`

## Test plan

- [x] `playbooks/build_image.yml` produces both `orange-pi-5-pro` and `rock-5b` `.img.xz` files
- [x] `playbooks/stage_netboot_assets.yml` populates `_templates/rock-5b/` + `rock-5b-01/` on TrueNAS, stages rb5009 TFTP
- [x] `playbooks/test_hardware_e2e.yml --limit rock-5b-01` passes SD → NFS → SD without harness code changes
- [x] `make yamllint` and `make ansible-lint` pass

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Capture the returned PR URL.

---

## Self-Review Checklist (run before declaring this plan complete)

- **Spec coverage:** Each spec section maps to one or more tasks?
  - Goal / rescope → Phase 4 Task 4.1, 4.2, 4.3
  - Acceptance criterion 1 (build) → Phase 1 (all tasks)
  - Acceptance criterion 2 (stage) → Phase 2 Tasks 2.2–2.4
  - Acceptance criterion 3 (E2E, no harness changes) → Phase 3 Task 3.3 (+ disqualifying-changes note)
  - Acceptance criterion 4 (friction writeup amendment) → Phase 4 Task 4.1
  - Open data items table → Phase 1 Tasks 1.1, 1.6 (hook naming, image filename) + Phase 2 Task 2.3 Step 2 (DTB path) + Phase 3 Task 3.1 Step 3 (console verification)
  - Chicken-and-egg URL → Phase 1 Tasks 1.4 (placeholder) + 1.7 (real)
  - Inventory-before-build chicken-and-egg → Phase 1 Task 1.5 (placeholder inventory) + Phase 1.5 Step 5 (update to real values)
  - Phase 1.5 manual hardware bring-up → Phase 1.5 section
  - Friction capture mechanics → initialized in Task 1.1, appended each phase, consolidated in 4.1
  - Doc updates → Tasks 4.2, 4.3, 4.4
  - Deferred refactors callout → Task 4.1 Step 2 (in amendment template)

- **Placeholder scan:** Any "TBD", "TODO", or "fill in details" outside of template body text? Operator-fill placeholders (`<MAC from Phase 1.5>`, `<rock-5b ip>`) are intentional and clearly bounded.

- **Type consistency:** `board_model: rock-5b` (dashed) used consistently. Userpatches key `rock-5b` and function name `rock_5b` divergence is explicitly noted in Task 1.3 and traced to Task 1.1's research finding. Inventory subgroup `rock_5b` (underscored, per Ansible group naming rules — dashes aren't valid in YAML mapping keys without quoting). The four-string-form naming is exactly the friction this plan exercises.
