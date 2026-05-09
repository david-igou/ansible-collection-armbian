# Post-Rebuild Followups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the small, concrete gaps surfaced by the 2026-05-07 hardware debugging session that produced a working `BOARD=orangepi5pro` image: pin `armbian_image_urls` to the new build, document the orangepi5→orangepi5pro MMC index change, and clear stale build artefacts from the builder and the netboot server. Each task is independent and could be a standalone PR.

**Architecture:** No code restructuring. Mostly inventory pins, doc additions, and `rm` of known-stale files.

**Tech Stack:** Ansible collection, `armbian/build` outputs on the builder host, rsync to TrueNAS NFS export.

**Background context:** During the 2026-05-07 debugging session we discovered that the SD card on `opi5pro-01` had been flashed with a `BOARD=orangepi5` (not `orangepi5pro`) Armbian image whose U-Boot's compile-time `fdtfile` env (`rockchip/rk3588s-orangepi-5.dtb`) didn't match the kernel-side DTB filename present on disk (`...orangepi-5-pro.dtb`). `boot.scr`'s DTB load failed silently, `booti` ran with garbage at `fdt_addr_r`, kernel never started, BL31 watchdog reset the board — yielding the visible "U-Boot loop" symptom. A fresh `playbooks/build_image.yml` run with current `vars/boards.yml` produced a correct `Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.27_minimal.img.xz`. After flashing and bootstrap, `bootstrap_armbian` succeeded as designed.

**Out of scope — needs separate design spec before any implementation plan:**
The `bootcmd=bootflow scan -lb` modern bootmeth framework (mainline U-Boot v2025.10) does not consume the legacy `boot_targets` env var that our `pre_config_uboot_target__orangepi5pro_pxe_first` userpatch modifies. With our patch, `boot_targets` is correctly `pxe dhcp mmc1 mmc0 nvme scsi usb spi`, but `bootflow scan` iterates bootdevs in DT order (Ethernet first on this board) and the bootmeth ordering is independently `extlinux script efi_mgr efi pxe vbe_simple`. When `enable_netboot` is *not* in effect, RouterOS DHCP still hands out `next-server=10.10.9.1` (the gateway) by default, U-Boot tries TFTP from the gateway, retries cycle through `pxelinux.cfg/01-MAC`, `pxelinux.cfg/0A0A0919`, etc., and the chain takes minutes to fail before the next bootdev is scanned — long enough that the BL31 hardware watchdog resets the board. The v1 invariant claimed by `CLAUDE.md` and `docs/architecture.md` ("U-Boot tries PXE first and falls through to disk when DHCP provides no `next-server`") is therefore not delivered by the current image. Author a design spec at `docs/superpowers/specs/2026-05-XX-bootflow-pxe-first-design.md` evaluating: (a) `bootmeth_order` env or compile-time `CONFIG_BOOTMETH_ORDER`, (b) reverting `bootcmd` to legacy `run distro_bootcmd` (which honours `boot_targets`), (c) RouterOS-side fix that explicitly clears `next-server` on disabled-netboot leases, (d) shortening TFTP `tftptimeout` so fall-through happens faster, or (e) some combination. Do this before continuing the present plan only if the user wants the v1 invariant restored before next hardware test.

---

## File Structure

**Modify:**
- `.inventory/group_vars/all.yml` (real inventory, gitignored — user action) — pin `armbian_image_urls[orange-pi-5-pro]` to the new 6.18.27 image filename.
- `inventory/group_vars/all.yml` (sample inventory) — update the commented example URL to match the new naming so future onboardings don't copy a stale filename.
- `CLAUDE.md` — add a one-paragraph note under "Adding a new board (post-v1)" documenting that the U-Boot DTB enumerates **three** MMC controllers on `orangepi5pro` (eMMC slot, SDIO/WiFi, SDcard) where the SD card lands at `mmc 1`, not `mmc 0` — relevant for any future per-board boot-script that hard-codes an `mmc dev N`.

**Delete (filesystem cleanup, no code):**
- `/workspace/armbian_build/output/images/Armbian-unofficial_26.05.0-trunk_Orangepi5_bookworm_current_6.18.26_minimal.img.xz` (+ `.txt`) on the builder host — stale `BOARD=orangepi5` build that produced the broken SD image.
- `/workspace/armbian_build/output/debs/linux-u-boot-orangepi5-current_*.deb`, `armbian-bsp-cli-orangepi5_*.deb`, `armbian-bsp-cli-orangepi5-current_*.deb` on the builder host — same lineage.
- `/workspace/armbian_build/build/cache/sources/u-boot-worktree/u-boot-orangepi5/` on the builder host — orphan U-Boot v2026.04 source worktree from the orangepi5 build (the `orangepi5pro` build uses `u-boot-orangepi5pro/v2025.10/`).
- `truenas:/mnt/ssd/containers/netbootxyz/assets/images/orangepi5pro/Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.26_minimal.img.xz` (+ `.sha`) — older, currently-unreferenced image; orangepi5pro filename means it's not the same broken build as the on-disk SD content but is still stale relative to the 6.18.27 we just published.

**Verification approach:** No formal test suite. After each task: `yamllint -c .yamllint.yml <changed.yml>`, `ansible-lint <changed.yml>` if applicable, and a `netboot_assets/preflight.yml` HEAD-check against the pinned URL (run as part of `stage_netboot_assets.yml`) to confirm the URL resolves 200. Cleanup tasks are verified by `ls` confirming the stale files are gone and the new files remain.

---

### Task 1: Pin sample-inventory `armbian_image_urls` example to the 6.18.27 filename

**Why first:** The sample inventory is documentation; correcting it costs nothing and prevents the next person reading the repo from copying a stale filename. The .inventory edit (Task 2) is user-action and the user needs the canonical filename to copy from somewhere.

**Files:**
- Modify: `inventory/group_vars/all.yml`

**Current state** (verified 2026-05-07):
```yaml
# armbian_image_urls:
#   orange-pi-5-pro: "{{ image_server_url }}/images/orangepi5pro/Armbian_<version>_orangepi5pro_bookworm_current_<kernel>.img.xz"

armbian_image_urls: {}
```

The commented placeholder uses `Armbian_<version>_orangepi5pro_…` (lower-case `o`, no `-unofficial` suffix), which doesn't match what `armbian/build` actually produces. The real artefact name from this collection's build pipeline is `Armbian-unofficial_<armbian-build-tag>_Orangepi5pro_bookworm_current_<kernel>_minimal.img.xz` — note the leading capital `O` (Armbian capitalises the first letter of `BOARD` in image filenames) and the `-unofficial` suffix that armbian/build adds when building from a non-tagged commit.

- [ ] **Step 1: Update the commented example URL**

Replace the commented line with the actual produced filename pattern:

```yaml
# armbian_image_urls:
#   orange-pi-5-pro: "{{ image_server_url }}/images/orangepi5pro/Armbian-unofficial_<armbian-build-tag>_Orangepi5pro_bookworm_current_<kernel>_minimal.img.xz"

armbian_image_urls: {}
```

- [ ] **Step 2: Lint the file**

Run: `yamllint -c .yamllint.yml inventory/group_vars/all.yml`
Expected: clean (no warnings).

- [ ] **Step 3: Commit**

```bash
git add inventory/group_vars/all.yml
git commit -m "Match armbian_image_urls example filename to actual build output

armbian/build produces 'Armbian-unofficial_<tag>_Orangepi5pro_<release>_<branch>_<kernel>_minimal.img.xz'
(capital O, -unofficial suffix, _minimal segment) when invoked from this
collection's build pipeline. The sample inventory's placeholder used a
lower-case 'orangepi5pro' segment and omitted both the -unofficial suffix
and the _minimal suffix, so anyone copying it would write a URL that
404s against the real publish location.

Closes #<TBD-issue>
"
```

---

### Task 2: User action — pin real inventory `armbian_image_urls` to 6.18.27

**Why this is a user action:** `.inventory/` is gitignored. This plan documents the fix; only the user can apply it locally.

**Current value** (verified 2026-05-07 in user's `.inventory/group_vars/all.yml:62`):
```yaml
armbian_image_urls:
  orange-pi-5-pro: "http://10.10.45.242/images/orangepi5pro/Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.26_minimal.img.xz"
```

**Required value:**
```yaml
armbian_image_urls:
  orange-pi-5-pro: "http://10.10.45.242/images/orangepi5pro/Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.27_minimal.img.xz"
```

(Single character change: `6.18.26` → `6.18.27`.)

- [ ] **Step 1: Update the URL**

Tell the user to run, on the host:

```bash
sed -i 's|_6\.18\.26_|_6.18.27_|' /workspace/ansible-collection-armbian_netboot/.inventory/group_vars/all.yml
```

- [ ] **Step 2: Verify the URL HEAD-checks 200**

Run: `curl -ILs http://10.10.45.242/images/orangepi5pro/Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.27_minimal.img.xz | head -1`
Expected: `HTTP/1.1 200 OK` (or `301`/`302`).

- [ ] **Step 3: Run the netboot_assets preflight to confirm the playbook agrees**

Run: `ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/stage_netboot_assets.yml --check --tags preflight`
Expected: PoE roles + netboot_assets preflight report `ok` for the orange-pi-5-pro URL HEAD task.

This step touches only the user's private inventory; no commit.

---

### Task 3: Add `armbian_default_password` to user inventory (user action)

**Why:** During the debugging session, `bootstrap_armbian.yml` failed with `'armbian_default_password' is undefined` because the user's `.inventory/group_vars/all.yml` doesn't define it. The sample `inventory/group_vars/all.yml:62` has `armbian_default_password: "1234"`. The user's private inventory needs the same key (vault-encrypted is recommended but not required for the literal `"1234"` Armbian default).

- [ ] **Step 1: Append the variable to .inventory/group_vars/all.yml**

Tell the user to run, on the host:

```bash
cat >> /workspace/ansible-collection-armbian_netboot/.inventory/group_vars/all.yml <<'EOF'

# Armbian default root password used by bootstrap_armbian.yml during
# the one-shot bootstrap login. Stock Armbian images ship with "1234".
# Override per-board if you've set something different at flash time.
armbian_default_password: "1234"
EOF
```

(If the user prefers vault encryption: `ansible-vault encrypt_string '1234' --name 'armbian_default_password' >> .inventory/group_vars/all.yml` — not required for stock Armbian since the password is a public default.)

- [ ] **Step 2: Verify bootstrap_armbian no longer needs `-e` override**

Run: `ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/bootstrap_armbian.yml --limit opi5pro-01.igou.systems --check`
Expected: validate-keys task passes (assertion mode); the rest is skipped in `--check` against an already-bootstrapped host but no "armbian_default_password is undefined" error.

This step touches only the user's private inventory; no commit.

---

### Task 4: Document MMC controller index per `BOARD` in CLAUDE.md

**Why:** During triage we discovered that the SD card lands at `mmc 0` in the `BOARD=orangepi5` U-Boot DTB but at `mmc 1` in the `BOARD=orangepi5pro` U-Boot DTB (because the orangepi5pro DT exposes all three RK3588 MMC controllers — eMMC at `mmc@fe2e0000` taking index 0, SDIO/WiFi at `mmc@fe2d0000`, SD card at `mmc@fe2c0000`). This doesn't break anything today (no current code does `mmc dev <hardcoded>`), but it's the kind of variation that bites the next person adding a board. The collection's `CLAUDE.md` already has a "SBC ecosystem reality: variation is the rule" section that lists per-board variation points — this is one more.

**Files:**
- Modify: `CLAUDE.md` (insert under the existing "SBC ecosystem reality" bullet list)

- [ ] **Step 1: Read the current section**

```bash
grep -n "ecosystem reality\|dimensions that vary" CLAUDE.md
```

Expected: locates the "SBC ecosystem reality: variation is the rule" header and the bullet list under it (currently covers naming, console UART, DTB layout, support tier, U-Boot deb naming).

- [ ] **Step 2: Add a new bullet to that list**

Append the following bullet to the existing list (alongside "U-Boot deb naming"). Note: the bullet deliberately does NOT pin specific U-Boot versions (`v2025.10` / `v2026.04`) — those are tracked in `armbian/build`'s upstream board configs and would age silently if mainline ships newer releases. The principle (per-DTB-declaration drives MMC index) is timeless; the version numbers are transient.

```markdown
- **MMC controller index in U-Boot**: which `mmc dev N` enumerates the
  SD card slot is per-board, depending on what the U-Boot DTB declares.
  On `orangepi5` the U-Boot DT exposes only the SD controller and the
  SD card is `mmc 0`; on `orangepi5pro` the U-Boot DT exposes eMMC slot
  + SDIO + SD and the SD card is `mmc 1`. `boot.scr` reads `${devnum}`
  from the bootflow framework so most boots don't care, but anything
  that hard-codes `mmc dev N` (manual U-Boot scripts, recovery aids,
  future per-board hooks) must consult `mmc list` on the actual board.
```

- [ ] **Step 3: Lint**

Run: `markdownlint CLAUDE.md` (if available) or visually verify the list renders cleanly.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Note MMC controller index varies between board U-Boot DTBs

The 2026-05-07 debugging session uncovered that 'mmc dev 0' selects
the SD card on orangepi5's U-Boot but '... -110: Card did not respond'
on orangepi5pro's U-Boot, where the SD is exposed as mmc 1 because the
DT also declares eMMC and SDIO controllers. List this alongside the
other per-board variation points already documented in the
'SBC ecosystem reality' section.
"
```

---

### Task 5: Remove stale `BOARD=orangepi5` build artefacts on the builder

**Why:** `/workspace/armbian_build/output/` retains the broken-SD-producing build from before `vars/boards.yml` was added. Output files are large (~366 MiB image + several MiB of debs) and the U-Boot worktree is ~1 GB. They are no longer reachable from any current playbook input — the orangepi5pro build uses `BOOTBRANCH=tag:v2025.10`, `BOARDFAMILY=rockchip-rk3588`, and a different `BOOTDIR=u-boot-orangepi5pro` path. Keeping them around invites future-Claude to grep them up and get confused about which artefact is canonical.

**Files (to delete on the host, not in the repo):**
- `/workspace/armbian_build/output/images/Armbian-unofficial_26.05.0-trunk_Orangepi5_bookworm_current_6.18.26_minimal.img.xz` (and matching `.txt`)
- `/workspace/armbian_build/output/debs/linux-u-boot-orangepi5-current_*.deb`
- `/workspace/armbian_build/output/debs/armbian-bsp-cli-orangepi5_*.deb`
- `/workspace/armbian_build/output/debs/armbian-bsp-cli-orangepi5-current_*.deb`
- `/workspace/armbian_build/build/cache/sources/u-boot-worktree/u-boot-orangepi5/` (entire directory)

- [ ] **Step 1: Confirm what's slated for deletion**

```bash
ssh igou@localhost 'ls -la /workspace/armbian_build/output/images/Armbian-unofficial_*Orangepi5_*.img.xz /workspace/armbian_build/output/debs/{linux-u-boot-orangepi5-current,armbian-bsp-cli-orangepi5,armbian-bsp-cli-orangepi5-current}_*.deb 2>&1; ls -ld /workspace/armbian_build/build/cache/sources/u-boot-worktree/u-boot-orangepi5'
```

Expected: lists the four image/deb file groups + the orphan worktree directory. If any pattern matches more than expected, abort and hand-pick.

- [ ] **Step 2: Delete the artefacts**

```bash
ssh igou@localhost '
  rm -v /workspace/armbian_build/output/images/Armbian-unofficial_*Orangepi5_*.img.xz
  rm -v /workspace/armbian_build/output/images/Armbian-unofficial_*Orangepi5_*.img.txt
  rm -v /workspace/armbian_build/output/debs/linux-u-boot-orangepi5-current_*.deb
  rm -v /workspace/armbian_build/output/debs/armbian-bsp-cli-orangepi5_*.deb
  rm -v /workspace/armbian_build/output/debs/armbian-bsp-cli-orangepi5-current_*.deb
  rm -rfv /workspace/armbian_build/build/cache/sources/u-boot-worktree/u-boot-orangepi5
'
```

Expected: each `rm -v` prints the deleted file, no errors.

- [ ] **Step 3: Verify the orangepi5pro artefacts are still intact**

```bash
ssh igou@localhost 'ls -la /workspace/armbian_build/output/orangepi5pro/ /workspace/armbian_build/build/cache/sources/u-boot-worktree/u-boot-orangepi5pro/'
```

Expected: shows the `_Orangepi5pro_..._6.18.27_minimal.img.xz` + `manifest.json` and the `u-boot-orangepi5pro/v2025.10/` source worktree.

This step modifies only host filesystem state; no commit.

---

### Task 6: Remove stale `_6.18.26_` image on TrueNAS

**Why:** `truenas:/mnt/ssd/containers/netbootxyz/assets/images/orangepi5pro/` contains both the new `_6.18.27_minimal.img.xz` (from this morning's publish) and an older `_6.18.26_minimal.img.xz` from the day before. The 6.18.26 version is an `Orangepi5pro`-named build, so it's not the *same* broken image that was on the SD card (that one was `Orangepi5`-named), but it predates `vars/boards.yml` and we have no manifest for it. Anything that globs `*.img.xz` would pick the lexically smaller filename. The publish play uses `delete: false` (intentional, so concurrent boards don't lose each other's images), so housekeeping has to happen out-of-band.

**Files (to delete on TrueNAS):**
- `/mnt/ssd/containers/netbootxyz/assets/images/orangepi5pro/Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.26_minimal.img.xz`
- `/mnt/ssd/containers/netbootxyz/assets/images/orangepi5pro/Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.26_minimal.img.xz.sha`

- [ ] **Step 1: Confirm what's there**

```bash
ssh truenas_admin@truenas.igou.systems 'ls -la /mnt/ssd/containers/netbootxyz/assets/images/orangepi5pro/'
```

Expected: lists both `_6.18.26_` and `_6.18.27_` `.img.xz` (+ `.sha`) and the `manifest.json`.

- [ ] **Step 2: Confirm the live `armbian_image_urls` pin is the 6.18.27 (not the 6.18.26 we're about to delete)**

```bash
grep "armbian_image_urls" -A 2 .inventory/group_vars/all.yml | grep -o '6\.18\.[0-9]*'
```

Expected: prints `6.18.27`. **If this prints `6.18.26`, STOP — Task 2 has not been done; doing Task 6 first will break the active boot path.**

- [ ] **Step 3: Delete the stale image and its sidecar**

```bash
ssh truenas_admin@truenas.igou.systems 'sudo rm -v /mnt/ssd/containers/netbootxyz/assets/images/orangepi5pro/Armbian-unofficial_26.05.0-trunk_Orangepi5pro_bookworm_current_6.18.26_minimal.img.xz{,.sha}'
```

Expected: two `removed '...'` lines, no errors.

- [ ] **Step 4: Re-run preflight to confirm the 6.18.27 URL still resolves**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/stage_netboot_assets.yml --check --tags preflight
```

Expected: orange-pi-5-pro URL HEAD task `ok`.

This step modifies only TrueNAS filesystem state; no commit.

---

### Task 7: Reconcile builder cache_dir between inventory and reality (user decision + optional inventory edit)

**Why:** During the rebuild we found the host has *two* parallel armbian/build caches: `/var/lib/armbian_build/build/` (~2.3 GB, what the inventory at `.inventory/inventory.yaml:69-70` declares) and `/workspace/armbian_build/build/` (~2.2 GB, what I overrode the rebuild to write into via `-e armbian_build_cache_dir=...`). Both are populated. Going forward, builds should use one. Pick one and delete the other to free disk and prevent split-brain. The `armbian_build` role is intentionally agnostic — it'll work with either path — so this is an inventory-level decision, not a code change.

**The user's call to make:**
- **Option A** (recommended): keep `/var/lib/armbian_build` (what inventory declares), delete `/workspace/armbian_build`. Rationale: the inventory is the source of truth, and `/var/lib/armbian_build` is on the same filesystem (`455 GB`, `181 GB free`) so no space-savings difference. Anyone running the playbook without `-e` overrides "just works."
- **Option B**: standardise on `/workspace/armbian_build`, edit `.inventory/inventory.yaml` to match, delete `/var/lib/armbian_build`. Rationale: the workspace dir is visible from inside the dev container so future debugging from container has direct read access. Cost: every `armbian-build` run requires the inventory edit to stay in place.

- [ ] **Step 1: User picks A or B**

(No action by an executing agent — pause for user input.)

- [ ] **Step 2 (option A): Delete `/workspace/armbian_build` and re-publish from `/var/lib/armbian_build`**

```bash
# Pre-warm /var/lib/armbian_build/output/orangepi5pro/ FIRST, before
# anything destructive. The cp must succeed before the rm — otherwise
# the new build's manifest+image is gone with the source dir.
ssh igou@localhost '
  mkdir -p /var/lib/armbian_build/output/orangepi5pro
  cp -p /workspace/armbian_build/output/orangepi5pro/* /var/lib/armbian_build/output/orangepi5pro/
'
# Verify the pre-warm landed before the rm.
ssh igou@localhost 'ls /var/lib/armbian_build/output/orangepi5pro/'

# Now safe to delete /workspace/armbian_build. The next playbook run
# uses the inventory's declared cache_dir (/var/lib/armbian_build) and
# the role's manifest-skip logic will hit the pre-warmed manifest and
# skip the rebuild.
ssh igou@localhost 'sudo rm -rf /workspace/armbian_build'
```

Expected: `/workspace/armbian_build` is gone; `/var/lib/armbian_build/output/orangepi5pro/` contains the 6.18.27 image + manifest.json.

- [ ] **Step 2 (option B): Edit inventory + delete `/var/lib/armbian_build`**

Edit `.inventory/inventory.yaml:69-70`:
```yaml
        armbian_build_cache_dir: "/workspace/armbian_build"
        armbian_build_output_dir: "/workspace/armbian_build/output"
```

Then:
```bash
ssh igou@localhost 'sudo rm -rf /var/lib/armbian_build'
```

- [ ] **Step 3: Run a no-op playbook to confirm the role's manifest-skip path is happy with the chosen location**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/build_image.yml
```

Expected (no `-e armbian_build_force=true`): role detects existing matching manifest and **skips** `Build Armbian image with userpatches applied`. The publish play still runs and reports `ok=0 changed=0` against TrueNAS (no source changes since last publish).

This step is configuration; no commit unless option B was chosen and the inventory file is committed (note: `.inventory/` is gitignored, so even option B doesn't produce a commit).

---

## Self-Review

**Spec coverage** (this plan vs the listed scope):
- Task 1 covers the sample-inventory placeholder fix.
- Task 2 covers the real-inventory pin (user action).
- Task 3 covers the `armbian_default_password` gap.
- Task 4 covers the MMC controller index documentation.
- Task 5 + Task 6 cover stale-artefact cleanup on builder + TrueNAS.
- Task 7 covers the dual-cache-dir mismatch.
- The bootflow PXE-first invariant issue is **explicitly out of scope** and routed to a future design spec — this is intentional.

**Placeholder scan:** No "TBD" outside of the issue-number placeholder in Task 1's commit message. Every step has the actual command.

**Type consistency:** Filenames and paths used in Task 5 (delete) match the artefact names verified in the 2026-05-07 session and shown in earlier tasks. Task 6's `_6.18.26_minimal.img.xz` deletion is safe because Task 2 pins `armbian_image_urls` to `_6.18.27_` first (Task 2 is gated as a prerequisite for Task 6 in Step 2 of Task 6).

**Risk note:** Task 6 (delete on TrueNAS) and Task 7 option A (delete `/workspace/armbian_build`) are destructive. Both have explicit verification steps preceding the `rm`. If anyone runs Task 6 before Task 2, `stage_netboot_assets.yml`'s preflight will fail loudly (HEAD-check 404), so the breakage is loud, not silent. Acceptable.
