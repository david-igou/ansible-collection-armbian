# v3.0.0 Role Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose the `david_igou.armbian_netboot` v2 roles into seven single-purpose, single-host, transport-agnostic v3 roles; move all RouterOS-specific code into `playbooks/routeros/` reference playbooks; bump to 3.0.0.

**Architecture:** Six new roles added alongside v2 (image_extract, rootfs_clone, pxelinux_render, board_boot_wait, board_boot_verify, image_build [rename of armbian_build]); five v2 roles deleted (boot_mode, netboot_assets, routeros_pxe_config, routeros_poe, bootstrap_routeros_user); RouterOS calls move to reference playbooks under `playbooks/routeros/`; top-level playbooks compose roles + reference playbooks via transport-hook variables.

**Tech Stack:** Ansible 2.15+, community.routeros, ansible.netcommon, ansible.posix. Validation via `ansible-lint --profile=min` (existing `.ansible-lint`). No unit tests — argument_specs.yml is the role contract; integration via existing molecule scenario for `image_build` and `playbooks/test_hardware_e2e.yml` for end-to-end.

**Source spec:** `docs/superpowers/specs/2026-05-16-role-refactor-v3-design.md`

---

## Phase 0 — Setup

### Task 0: Branch + dependencies

**Files:** none

- [ ] **Step 0.1: Create a working branch off main**

```bash
git checkout main
git pull
git checkout -b v3-role-refactor
```

- [ ] **Step 0.2: Install collection dependencies (idempotent if already present)**

```bash
ansible-galaxy collection install -r requirements.yml
```

- [ ] **Step 0.3: Verify baseline lint is green before any change**

```bash
ansible-lint
```

Expected: no errors. If errors exist on `main`, stop and surface them — the refactor needs a green baseline.

### Testing scope for this plan

**Role-level only.** This plan exercises new roles in isolation against
synthetic inputs (template rendering, argument-spec validation, lint).
It does **not** SSH into the netboot server, push to RouterOS, or cycle
hardware. Playbook integration on real hosts is verified in a follow-up
plan after this branch merges.

Every smoke-test play in this plan sets `connection: local` to keep
inventory entries from routing through SSH (relevant because the
inventory's `localhost` entry under `armbian_builders` declares
`ansible_user=igou` and may otherwise attempt SSH).

### SSH agent caveat

If the SSH agent flakes mid-session (symptoms: `git push`, `gh`, or
`ansible-galaxy collection install` from a private source failing with
"Permission denied (publickey)"), the working key is at `~/.ssh/`.
Re-add with:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/<key-filename>
```

then retry the command. None of the steps in this plan require remote
SSH for verification — they only need it for `git push` at Task 29.

---

## Phase 1 — Add new roles alongside v2

Each role lands as its own commit. Old v2 roles stay untouched in this phase so the existing playbooks keep working until Phase 4.

Every new role follows the same skeleton:
```
roles/<name>/
  defaults/main.yml
  meta/argument_specs.yml
  meta/main.yml          (galaxy_info + dependencies: [])
  tasks/main.yml
```

`meta/main.yml` for every new role is identical except for `role_name`:

```yaml
---
galaxy_info:
  role_name: <name>
  author: david-igou
  description: <one-liner — pulled from argument_specs short_description>
  license: MIT
  min_ansible_version: "2.15"
  platforms:
    - name: Generic
      versions: [all]
dependencies: []
```

### Task 1: `image_extract` role

**Files:**
- Create: `roles/image_extract/defaults/main.yml`
- Create: `roles/image_extract/meta/argument_specs.yml`
- Create: `roles/image_extract/meta/main.yml`
- Create: `roles/image_extract/tasks/main.yml`
- Create: `roles/image_extract/tasks/_download_or_copy.yml`
- Create: `roles/image_extract/tasks/_extract_inner.yml`
- Create: `roles/image_extract/tasks/_copy_kernel_artifacts.yml`
- Create: `roles/image_extract/tasks/_cleanup.yml`

- [ ] **Step 1.1: Create `roles/image_extract/defaults/main.yml`**

```yaml
---
# image_extract role defaults.
# Inputs are documented in meta/argument_specs.yml — defaults here
# are only for optional knobs.

# When true, remove the template_dir, tftp_dir contents, and any
# cached .img/.img.xz before re-extracting. Default false so re-runs
# are idempotent no-ops when the template is already populated.
force_refresh: false

# Scratch directory on the target host for downloads and the
# decompressed .img file. The role creates it if missing.
image_cache_dir: "/var/lib/armbian_netboot/cache"

# Mount point used during extraction. The role creates and tears
# this down per-invocation.
image_mount_dir: "/var/lib/armbian_netboot/mnt"
```

- [ ] **Step 1.2: Create `roles/image_extract/meta/argument_specs.yml`**

```yaml
---
argument_specs:
  main:
    short_description: "Extract one Armbian .img.xz into a template rootfs and TFTP artifacts."
    description:
      - >-
        Decompresses an Armbian .img.xz, loop-mounts it, rsyncs the
        rootfs partition into template_dir, and copies vmlinuz / initrd
        / board.dtb into tftp_dir. The .img.xz source can be a local
        path on this host (already published) or a URL the role
        downloads.
      - >-
        Runs on a single host with sudo + losetup (typically the
        netboot server). Knows nothing about NFS, HTTP, or TFTP — the
        caller is responsible for placing template_dir and tftp_dir
        where downstream steps can read them.

    options:
      armbian_image_src:
        type: str
        required: true
        description: "Local filesystem path OR http(s):// URL to the .img.xz."
      model_name:
        type: str
        required: true
        description: "Identifier used in the image cache filename — typically the board model."
      template_dir:
        type: path
        required: true
        description: "Destination directory for the extracted rootfs template."
      tftp_dir:
        type: path
        required: true
        description: "Destination directory for vmlinuz / initrd.img / board.dtb."
      board_dtb:
        type: str
        required: true
        description: "Basename of the DTB to copy from the image's /boot tree (e.g. rk3588s-orangepi-5-pro.dtb)."
      force_refresh:
        type: bool
        default: false
        description: "When true, remove template_dir, tftp_dir, and the cached image before re-extracting."
      image_cache_dir:
        type: path
        default: "/var/lib/armbian_netboot/cache"
      image_mount_dir:
        type: path
        default: "/var/lib/armbian_netboot/mnt"
```

- [ ] **Step 1.3: Create `roles/image_extract/meta/main.yml`** using the skeleton at the top of Phase 1 with `role_name: image_extract` and a one-liner description matching `short_description`.

- [ ] **Step 1.4: Create `roles/image_extract/tasks/main.yml`**

```yaml
---
# image_extract — runs on a single host with sudo + losetup.
# Inputs documented in meta/argument_specs.yml.

- name: Compute per-invocation paths
  ansible.builtin.set_fact:
    _img_cache: "{{ image_cache_dir }}/{{ model_name }}.img.xz"
    _img_raw: "{{ image_cache_dir }}/{{ model_name }}.img"

- name: Force-refresh — remove stale state when requested
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - "{{ template_dir }}"
    - "{{ tftp_dir }}"
    - "{{ _img_cache }}"
    - "{{ _img_raw }}"
  when: force_refresh | bool

- name: Ensure working directories exist
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: "0755"
  loop:
    - "{{ image_cache_dir }}"
    - "{{ image_mount_dir }}"
    - "{{ template_dir }}"
    - "{{ tftp_dir }}"

- name: Check whether template + TFTP artifacts are already populated
  ansible.builtin.stat:
    path: "{{ item }}"
  register: _populated_stats
  loop:
    - "{{ template_dir }}/bin/bash"
    - "{{ tftp_dir }}/vmlinuz"

- name: Skip extraction when both template and TFTP are populated
  ansible.builtin.set_fact:
    _already_extracted: >-
      {{ _populated_stats.results | map(attribute='stat.exists') | min }}

- name: Extract image when needed
  when: not _already_extracted
  block:
    - name: Acquire .img.xz (download or copy)
      ansible.builtin.include_tasks: _download_or_copy.yml

    - name: Decompress, mount, rsync rootfs, copy kernel artifacts
      ansible.builtin.include_tasks: _extract_inner.yml

    - name: Copy vmlinuz / initrd / dtb to tftp_dir
      ansible.builtin.include_tasks: _copy_kernel_artifacts.yml

  always:
    - name: Tear down loop device and unmount (always)
      ansible.builtin.include_tasks: _cleanup.yml

- name: Strip /dev entries from template fstab (idempotent)
  ansible.builtin.lineinfile:
    path: "{{ template_dir }}/etc/fstab"
    regexp: "^/dev/"
    state: absent
  when: not _already_extracted
```

- [ ] **Step 1.5: Create `roles/image_extract/tasks/_download_or_copy.yml`**

```yaml
---
- name: Detect source flavour
  ansible.builtin.set_fact:
    _is_url: "{{ armbian_image_src is match('^https?://') }}"

- name: Download .img.xz from URL
  ansible.builtin.get_url:
    url: "{{ armbian_image_src }}"
    dest: "{{ _img_cache }}"
    mode: "0644"
    timeout: 600
  when: _is_url

- name: Copy .img.xz from local path
  ansible.builtin.copy:
    src: "{{ armbian_image_src }}"
    dest: "{{ _img_cache }}"
    remote_src: true
    mode: "0644"
  when: not _is_url
```

- [ ] **Step 1.6: Create `roles/image_extract/tasks/_extract_inner.yml`**

```yaml
---
- name: Decompress image (creates {{ _img_raw }})
  ansible.builtin.shell: |
    xz -dk "{{ _img_cache }}"
  args:
    creates: "{{ _img_raw }}"

- name: Attach .img to a loop device with partition scan
  ansible.builtin.shell: |
    losetup --find --show --partscan "{{ _img_raw }}"
  register: _loop_dev
  changed_when: true

- name: Mount the largest (rootfs) partition
  ansible.builtin.shell: |
    set -o pipefail
    PART=$(lsblk -ln -o NAME {{ _loop_dev.stdout }} | tail -1)
    mount "/dev/${PART}" "{{ image_mount_dir }}"
  args:
    executable: /bin/bash
  changed_when: true

- name: Rsync rootfs into template_dir
  ansible.builtin.shell: |
    rsync -aHAX \
      --exclude '/proc/*' --exclude '/sys/*' \
      --exclude '/dev/*' --exclude '/run/*' \
      "{{ image_mount_dir }}/" "{{ template_dir }}/"
  changed_when: true
```

- [ ] **Step 1.7: Create `roles/image_extract/tasks/_copy_kernel_artifacts.yml`**

```yaml
---
- name: Copy kernel and initrd to tftp_dir
  ansible.builtin.shell: |
    cp "{{ image_mount_dir }}"/boot/vmlinuz-* "{{ tftp_dir }}/vmlinuz"
    cp "{{ image_mount_dir }}"/boot/initrd.img-* "{{ tftp_dir }}/initrd.img"
  changed_when: true

# Armbian images place DTBs at one of several locations depending on
# the kernel package. Try each candidate; fail loudly if none match,
# because a missing DTB causes a kernel panic at PXE boot time which
# is much harder to diagnose than an Ansible failure here.
- name: Copy board DTB to tftp_dir
  ansible.builtin.shell: |
    set -e
    ROOT="{{ image_mount_dir }}"
    DTB="{{ board_dtb }}"
    for CANDIDATE in \
        "${ROOT}/boot/dtb/${DTB}" \
        "${ROOT}/boot/dtbs/${DTB}" \
        $(ls "${ROOT}"/boot/dtb-*/"${DTB}" 2>/dev/null) \
        $(ls "${ROOT}"/boot/dtbs/*/"${DTB}" 2>/dev/null); do
      if [ -f "${CANDIDATE}" ]; then
        cp "${CANDIDATE}" "{{ tftp_dir }}/board.dtb"
        echo "DTB copied from ${CANDIDATE}"
        exit 0
      fi
    done
    echo "ERROR: DTB ${DTB} not found under ${ROOT}/boot/{dtb,dtbs,dtb-*}" >&2
    exit 1
  args:
    executable: /bin/bash
  changed_when: true
```

- [ ] **Step 1.8: Create `roles/image_extract/tasks/_cleanup.yml`**

```yaml
---
- name: Unmount image
  ansible.builtin.shell: umount "{{ image_mount_dir }}"
  changed_when: true
  failed_when: false

- name: Detach loop device
  ansible.builtin.shell: losetup -d "{{ _loop_dev.stdout }}"
  when: _loop_dev is defined and _loop_dev.stdout is defined
  changed_when: true
  failed_when: false
```

- [ ] **Step 1.9: Lint the new role**

```bash
ansible-lint roles/image_extract/
```

Expected: no errors.

- [ ] **Step 1.10: Argument-spec smoke check — confirm the role refuses to run without required inputs**

```bash
cat > /tmp/imgex-smoke.yml <<'YAML'
---
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - include_role:
        name: david_igou.armbian_netboot.image_extract
YAML
ansible-playbook /tmp/imgex-smoke.yml 2>&1 | grep -i 'required'
rm /tmp/imgex-smoke.yml
```

Expected: output mentions `armbian_image_src`, `model_name`, `template_dir`, `tftp_dir`, `board_dtb` as required (the argument_specs validation message).

- [ ] **Step 1.11: Commit**

```bash
git add roles/image_extract/
git commit -m "feat(image_extract): single-host role to extract one Armbian image"
```

### Task 2: `rootfs_clone` role

**Files:**
- Create: `roles/rootfs_clone/defaults/main.yml`
- Create: `roles/rootfs_clone/meta/argument_specs.yml`
- Create: `roles/rootfs_clone/meta/main.yml`
- Create: `roles/rootfs_clone/tasks/main.yml`
- Create: `roles/rootfs_clone/tasks/_identity_reset.yml`

- [ ] **Step 2.1: Create `roles/rootfs_clone/defaults/main.yml`**

```yaml
---
# rootfs_clone has no optional knobs; defaults file kept for
# argument_specs symmetry with other roles.
```

- [ ] **Step 2.2: Create `roles/rootfs_clone/meta/argument_specs.yml`**

```yaml
---
argument_specs:
  main:
    short_description: "Reflink-clone a rootfs template and reset per-host identity."
    description:
      - >-
        Copies the contents of template_dir into target_dir using
        `cp -a --reflink=auto` (zero-cost CoW snapshot on XFS / btrfs /
        ZFS; full copy on ext4), then resets the host identity files
        (hostname, machine-id, ssh host keys) so multiple clones of
        the same template have independent identities on the wire.
      - >-
        Runs on a single host that owns the template and target paths.
        Knows nothing about NFS exports, hostnames in inventory, or
        how the rootfs is served.

    options:
      template_dir:
        type: path
        required: true
        description: "Source rootfs template directory."
      target_dir:
        type: path
        required: true
        description: "Destination per-host rootfs directory."
      hostname:
        type: str
        required: true
        description: "Hostname to set inside the cloned rootfs."
      force_refresh:
        type: bool
        default: false
        description: "When true, remove target_dir before cloning."
```

- [ ] **Step 2.3: Create `roles/rootfs_clone/meta/main.yml`** using the Phase 1 skeleton with `role_name: rootfs_clone`.

- [ ] **Step 2.4: Create `roles/rootfs_clone/tasks/main.yml`**

```yaml
---
- name: Verify template exists
  ansible.builtin.stat:
    path: "{{ template_dir }}/bin/bash"
  register: _template_stat

- name: Fail if template is not populated
  ansible.builtin.fail:
    msg: >-
      template_dir {{ template_dir }} is not populated (missing bin/bash).
      Run image_extract for this model before invoking rootfs_clone.
  when: not _template_stat.stat.exists

- name: Force-refresh — remove existing target_dir when requested
  ansible.builtin.file:
    path: "{{ target_dir }}"
    state: absent
  when: force_refresh | bool

- name: Check whether target_dir is already populated
  ansible.builtin.stat:
    path: "{{ target_dir }}/bin/bash"
  register: _target_stat

- name: Ensure target_dir exists
  ansible.builtin.file:
    path: "{{ target_dir }}"
    state: directory
    mode: "0755"
  when: not _target_stat.stat.exists

- name: Reflink-clone template into target_dir
  ansible.builtin.shell: |
    set -o pipefail
    cp -a --reflink=auto "{{ template_dir }}/." "{{ target_dir }}/"
  args:
    executable: /bin/bash
  when: not _target_stat.stat.exists
  changed_when: true

- name: Reset per-host identity (always — idempotent across re-runs)
  ansible.builtin.include_tasks: _identity_reset.yml
```

- [ ] **Step 2.5: Create `roles/rootfs_clone/tasks/_identity_reset.yml`**

```yaml
---
- name: Set per-host /etc/hostname
  ansible.builtin.copy:
    dest: "{{ target_dir }}/etc/hostname"
    content: "{{ hostname }}\n"
    mode: "0644"

- name: Set per-host /etc/hosts entry
  ansible.builtin.lineinfile:
    path: "{{ target_dir }}/etc/hosts"
    regexp: '^127\.0\.1\.1\s'
    line: "127.0.1.1\t{{ hostname }}"
    create: false
  failed_when: false  # not all base images ship /etc/hosts pre-populated

- name: Remove machine-id files (regenerated on first boot)
  ansible.builtin.file:
    path: "{{ target_dir }}/{{ item }}"
    state: absent
  loop:
    - etc/machine-id
    - var/lib/dbus/machine-id

- name: Remove SSH host keys (regenerated by ssh-keygen at first boot)
  ansible.builtin.shell: |
    rm -f "{{ target_dir }}"/etc/ssh/ssh_host_*
  args:
    executable: /bin/bash
  changed_when: true

# Suppress armbian-firstrun-config's interactive password-change prompt
# on first root login. Without this, the first SSH-as-root session
# triggers a passwd dialog which Ansible's non-interactive session
# cannot satisfy, and hardware E2E Phase 2's wait_for_connection hangs.
- name: Touch /root/.no_armbian_first_login to skip first-login prompt
  ansible.builtin.file:
    path: "{{ target_dir }}/root/.no_armbian_first_login"
    state: touch
    mode: "0644"
```

- [ ] **Step 2.6: Lint and commit**

```bash
ansible-lint roles/rootfs_clone/
git add roles/rootfs_clone/
git commit -m "feat(rootfs_clone): single-host role to reflink-clone a rootfs template"
```

### Task 3: `pxelinux_render` role

**Files:**
- Create: `roles/pxelinux_render/defaults/main.yml`
- Create: `roles/pxelinux_render/meta/argument_specs.yml`
- Create: `roles/pxelinux_render/meta/main.yml`
- Create: `roles/pxelinux_render/tasks/main.yml`
- Create: `roles/pxelinux_render/templates/pxelinux_cfg.j2`

- [ ] **Step 3.1: Create `roles/pxelinux_render/defaults/main.yml`**

```yaml
---
# Render-time knobs. All inputs that have inventory-level analogues
# default to undefined here and are validated as required in argspec.

# Per-board kernel command-line knob: which device specifier the
# kernel uses to find the root filesystem when booting from local SD.
# Default LABEL=armbi_root works for stock Armbian; per-host overrides
# (PARTUUID=, UUID=, PARTLABEL=) handle multi-drive boards.
sd_root: "LABEL=armbi_root"

# When true, append earlycon + verbose kernel params to both labels.
pxe_verbose: false

# TFTP-relative paths written verbatim into pxelinux.cfg. These are
# strings the netboot client passes to the TFTP server — not local FS
# paths on the rendering host. Defaults assume armbian/<model>/<file>.
tftp_kernel: "armbian/{{ model_name }}/vmlinuz"
tftp_initrd: "armbian/{{ model_name }}/initrd.img"
tftp_dtb:    "armbian/{{ model_name }}/board.dtb"
```

- [ ] **Step 3.2: Create `roles/pxelinux_render/meta/argument_specs.yml`**

```yaml
---
argument_specs:
  main:
    short_description: "Render one per-board pxelinux.cfg file to a local directory."
    description:
      - >-
        Renders an 01-<mac> pxelinux.cfg file using the supplied board
        identity and netboot parameters. Always writes — never uploads.
        The caller is responsible for moving the rendered file to the
        TFTP server.
      - >-
        Typically reached via `delegate_to: localhost` inside a
        `hosts: boards` play, so per-board hostvars are in scope and
        one invocation per board renders one file.

    options:
      board_mac:
        type: str
        required: true
        description: "Board MAC address; used to compute the 01-<mac> filename."
      boot_mode:
        type: str
        required: true
        choices: [nfs, sd]
        description: "Which label the rendered pxelinux.cfg's `default` directive points at."
      board_console:
        type: str
        required: true
        description: "console= kernel argument value (e.g. ttyS2,1500000)."
      model_name:
        type: str
        required: true
        description: "Board model identifier — used to compose default TFTP paths."
      nfs_server_ip:
        type: str
        required: true
        description: "Server IP written into nfsroot=."
      nfs_root_path:
        type: path
        required: true
        description: "NFS export root path (per-host directory is composed as <nfs_root_path>/<hostname>)."
      hostname:
        type: str
        required: true
        description: "Inventory hostname — used as both the per-host NFS subdir and the menu-label suffix."
      output_dir:
        type: path
        required: true
        description: "Local directory where 01-<mac> is written."
      sd_root:
        type: str
        default: "LABEL=armbi_root"
      pxe_verbose:
        type: bool
        default: false
      earlycon:
        type: str
        default: ""
        description: "Required when pxe_verbose=true. Format <driver>,<bus>,<mmio_addr>."
      tftp_kernel:
        type: str
        default: "armbian/{{ model_name }}/vmlinuz"
      tftp_initrd:
        type: str
        default: "armbian/{{ model_name }}/initrd.img"
      tftp_dtb:
        type: str
        default: "armbian/{{ model_name }}/board.dtb"
```

- [ ] **Step 3.3: Create `roles/pxelinux_render/meta/main.yml`** using the Phase 1 skeleton with `role_name: pxelinux_render`.

- [ ] **Step 3.4: Create `roles/pxelinux_render/templates/pxelinux_cfg.j2`**

```jinja
{% set _verbose_suffix = ' earlycon=' ~ earlycon ~ ' loglevel=8 ignore_loglevel initcall_debug printk.devkmsg=on systemd.log_level=debug systemd.log_target=console systemd.journald.forward_to_console=1' if pxe_verbose | bool else '' %}
# pxelinux.cfg for {{ hostname }} ({{ model_name }})
# MAC: {{ board_mac }}
# Active mode: {{ boot_mode }}
# Generated by Ansible — do not edit manually.

default {{ boot_mode }}
timeout 50
prompt  0

label nfs
  menu label Armbian NFS root ({{ hostname }})
  kernel {{ tftp_kernel }}
  initrd {{ tftp_initrd }}
  fdt    {{ tftp_dtb }}
  append root=/dev/nfs nfsroot={{ nfs_server_ip }}:{{ nfs_root_path }}/{{ hostname }},nfsvers=3,rw ip=dhcp console={{ board_console }} rootwait rw{{ _verbose_suffix }}

label sd
  menu label Armbian on SD ({{ hostname }})
  kernel {{ tftp_kernel }}
  initrd {{ tftp_initrd }}
  fdt    {{ tftp_dtb }}
  append root={{ sd_root }} rootfstype=ext4 rootwait rw console={{ board_console }}{{ _verbose_suffix }}
```

- [ ] **Step 3.5: Create `roles/pxelinux_render/tasks/main.yml`**

```yaml
---
- name: Validate earlycon is set when pxe_verbose is true
  ansible.builtin.assert:
    that:
      - earlycon | length > 0
    fail_msg: >-
      pxe_verbose=true was requested but earlycon was not supplied.
      Set earlycon to <driver>,<bus>,<mmio_addr> (e.g.
      uart8250,mmio32,0xfeb50000 for RK3588S UART2) or unset
      pxe_verbose.
  when: pxe_verbose | bool

- name: Compute pxelinux filename
  ansible.builtin.set_fact:
    _pxe_filename: "01-{{ board_mac | lower | replace(':', '-') }}"

- name: Ensure output_dir exists
  ansible.builtin.file:
    path: "{{ output_dir }}"
    state: directory
    mode: "0755"

- name: Render pxelinux.cfg for {{ hostname }}
  ansible.builtin.template:
    src: pxelinux_cfg.j2
    dest: "{{ output_dir }}/{{ _pxe_filename }}"
    mode: "0644"
```

- [ ] **Step 3.6: Render a golden fixture to verify template output**

```bash
mkdir -p /tmp/pxe-test
cat > /tmp/pxe-render-smoke.yml <<'YAML'
---
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - include_role:
        name: david_igou.armbian_netboot.pxelinux_render
      vars:
        board_mac: "AA:BB:CC:DD:EE:FF"
        boot_mode: nfs
        board_console: "ttyS2,1500000"
        model_name: orange-pi-5-pro
        nfs_server_ip: "10.0.0.10"
        nfs_root_path: /mnt/ssd/netboot/rootfs
        hostname: smoke-host
        output_dir: /tmp/pxe-test
YAML
ansible-playbook /tmp/pxe-render-smoke.yml
cat /tmp/pxe-test/01-aa-bb-cc-dd-ee-ff
```

Expected: file contains `default nfs`, `nfsroot=10.0.0.10:/mnt/ssd/netboot/rootfs/smoke-host`, `console=ttyS2,1500000`, `armbian/orange-pi-5-pro/vmlinuz`. If any of those are wrong, fix the template before committing.

- [ ] **Step 3.6b: Render the SD-mode variant against the same fixture and verify the `default` directive flips correctly**

```bash
sed -i 's/boot_mode: nfs/boot_mode: sd/' /tmp/pxe-render-smoke.yml
ansible-playbook /tmp/pxe-render-smoke.yml
grep -E '^default ' /tmp/pxe-test/01-aa-bb-cc-dd-ee-ff
```

Expected: `default sd`. Both labels (`label nfs` and `label sd`) still present in the file regardless of mode; only the `default` directive switches.

- [ ] **Step 3.7: Lint and commit**

```bash
rm -rf /tmp/pxe-test /tmp/pxe-render-smoke.yml
ansible-lint roles/pxelinux_render/
git add roles/pxelinux_render/
git commit -m "feat(pxelinux_render): render per-board pxelinux.cfg to a local directory"
```

### Task 4: `board_boot_wait` role

**Files:**
- Create: `roles/board_boot_wait/defaults/main.yml`
- Create: `roles/board_boot_wait/meta/argument_specs.yml`
- Create: `roles/board_boot_wait/meta/main.yml`
- Create: `roles/board_boot_wait/tasks/main.yml`

- [ ] **Step 4.1: Create `roles/board_boot_wait/defaults/main.yml`**

```yaml
---
# Mirror the names + defaults that lived on the v2 boot_mode role so
# inventory-level overrides continue to apply unchanged.
armbian_netboot_boot_retry_attempts: 0           # 0 = single attempt, no retries
armbian_netboot_boot_attempt_timeout: 180         # per-attempt TCP/22 wait, seconds
armbian_netboot_ssh_wait_timeout: 300             # per-attempt SSH ping wait
armbian_netboot_ssh_wait_retry_attempts: 0
armbian_netboot_post_boot_wait_timeout: 300       # final wait_for_connection
```

- [ ] **Step 4.2: Create `roles/board_boot_wait/meta/argument_specs.yml`**

```yaml
---
argument_specs:
  main:
    short_description: "Wait for a board to come up over TCP/22 + SSH."
    description:
      - >-
        Single-host role. Waits for the inventory host to accept TCP/22
        connections, then performs a wait_for_connection probe. No
        notion of how the board was powered — the caller cycles PoE
        (or the operator presses a button) before invoking this role.
      - >-
        Retry knobs match the v2 boot_mode role's names so inventory
        overrides keep working.

    options:
      armbian_netboot_boot_attempt_timeout:
        type: int
        default: 180
      armbian_netboot_post_boot_wait_timeout:
        type: int
        default: 300
```

- [ ] **Step 4.3: Create `roles/board_boot_wait/meta/main.yml`** using the Phase 1 skeleton with `role_name: board_boot_wait`.

- [ ] **Step 4.4: Create `roles/board_boot_wait/tasks/main.yml`**

```yaml
---
# board_boot_wait — runs on a board; waits for TCP/22 then SSH.
# Does NOT cycle power; the caller is responsible for that.

- name: Wait for TCP/22 to accept connections
  ansible.builtin.wait_for:
    host: "{{ ansible_host | default(inventory_hostname) }}"
    port: 22
    timeout: "{{ armbian_netboot_boot_attempt_timeout }}"
    state: started
  delegate_to: localhost
  become: false

- name: Wait for SSH to authenticate
  ansible.builtin.wait_for_connection:
    timeout: "{{ armbian_netboot_post_boot_wait_timeout }}"
    sleep: 5
```

- [ ] **Step 4.5: Lint and commit**

```bash
ansible-lint roles/board_boot_wait/
git add roles/board_boot_wait/
git commit -m "feat(board_boot_wait): wait for TCP/22 + SSH on a single board"
```

### Task 5: `board_boot_verify` role

**Files:**
- Create: `roles/board_boot_verify/defaults/main.yml`
- Create: `roles/board_boot_verify/meta/argument_specs.yml`
- Create: `roles/board_boot_verify/meta/main.yml`
- Create: `roles/board_boot_verify/tasks/main.yml`

- [ ] **Step 5.1: Create `roles/board_boot_verify/defaults/main.yml`**

```yaml
---
# No optional knobs; boot_mode is the only input.
```

- [ ] **Step 5.2: Create `roles/board_boot_verify/meta/argument_specs.yml`**

```yaml
---
argument_specs:
  main:
    short_description: "Assert a board's rootfs matches the declared boot mode."
    description:
      - >-
        Single-host role. Gathers facts, inspects ansible_mounts['/'],
        and asserts that the rootfs fstype matches the declared
        boot_mode (nfs|nfs4 for nfs; not nfs for sd).

    options:
      boot_mode:
        type: str
        required: true
        choices: [nfs, sd]
```

- [ ] **Step 5.3: Create `roles/board_boot_verify/meta/main.yml`** using the Phase 1 skeleton with `role_name: board_boot_verify`.

- [ ] **Step 5.4: Create `roles/board_boot_verify/tasks/main.yml`**

```yaml
---
- name: Gather facts
  ansible.builtin.setup:

- name: Capture root mount
  ansible.builtin.set_fact:
    _root_fstype: "{{ ansible_mounts | selectattr('mount', 'equalto', '/')
                                     | map(attribute='fstype') | first }}"
    _root_device: "{{ ansible_mounts | selectattr('mount', 'equalto', '/')
                                     | map(attribute='device') | first }}"

- name: Assert NFS rootfs when boot_mode=nfs
  ansible.builtin.assert:
    that:
      - _root_fstype in ['nfs', 'nfs4']
    fail_msg: >-
      boot_mode[nfs]: expected NFS rootfs but got
      {{ _root_device }} ({{ _root_fstype }}). The pxelinux.cfg upload
      step succeeded, so the board either skipped pxelinux.cfg or fell
      through to local boot. Check the TFTP server's request log.
  when: boot_mode == 'nfs'

- name: Assert local block-device rootfs when boot_mode=sd
  ansible.builtin.assert:
    that:
      - _root_fstype not in ['nfs', 'nfs4']
      - _root_device is match('^/dev/')
    fail_msg: >-
      boot_mode[sd]: expected local block device rootfs but got
      {{ _root_device }} ({{ _root_fstype }}). Default kernel cmdline
      is root=LABEL=armbi_root; override per-host with sd_root if the
      board has multiple drives carrying LABEL=armbi_root.
  when: boot_mode == 'sd'
```

- [ ] **Step 5.5: Lint and commit**

```bash
ansible-lint roles/board_boot_verify/
git add roles/board_boot_verify/
git commit -m "feat(board_boot_verify): assert rootfs matches declared boot mode"
```

### Task 6: `image_build` role (rename of `armbian_build`)

**Files:**
- Rename: `roles/armbian_build/` → `roles/image_build/` (preserve git history with `git mv`)
- Modify: `roles/image_build/meta/argument_specs.yml` (rename role + add optional publish var)
- Create: `roles/image_build/tasks/publish_scp.yml` (extracted from existing publish step inside `invoke_build.yml`, if any) or wrapping a new SCP push
- Modify: `roles/image_build/tasks/main.yml` (gate the publish step on `armbian_netboot_publish_target`)
- Update: `extensions/molecule/armbian_build/` → `extensions/molecule/image_build/`

- [ ] **Step 6.1: Rename the role directory preserving history**

```bash
git mv roles/armbian_build roles/image_build
git mv extensions/molecule/armbian_build extensions/molecule/image_build
```

- [ ] **Step 6.2: Inspect existing publish step**

```bash
grep -rn "publish\|scp" roles/image_build/tasks/ 2>/dev/null || true
grep -rn "publish\|scp" playbooks/build_image.yml 2>/dev/null || true
```

If the existing role/playbook already SCPs the built `.img.xz` to the netboot server, lift that block into a new `tasks/publish_scp.yml`. If publish is done in `playbooks/build_image.yml` today, move it into the role gated behind `armbian_netboot_publish_target`.

- [ ] **Step 6.3: Create `roles/image_build/tasks/publish_scp.yml`**

```yaml
---
# Optional publish: SCP the built .img.xz to a remote host.
# Gated by armbian_netboot_publish_target (host:path).
# Format: <ssh-host>:<absolute-path-on-remote>
#
# Example armbian_netboot_publish_target:
#   netboot-server.lan:/mnt/ssd/public/boot-files/images/orangepi5pro/

- name: Parse publish target
  ansible.builtin.set_fact:
    _publish_host: "{{ armbian_netboot_publish_target.split(':', 1)[0] }}"
    _publish_path: "{{ armbian_netboot_publish_target.split(':', 1)[1] }}"

- name: Ensure remote publish directory exists
  ansible.builtin.shell: |
    ssh "{{ _publish_host }}" \
      "mkdir -p '{{ _publish_path }}' && chmod 755 '{{ _publish_path }}'"
  delegate_to: "{{ inventory_hostname }}"
  changed_when: true

- name: SCP the built .img.xz to the publish target
  ansible.builtin.shell: |
    scp "{{ armbian_build_output_dir }}/{{ armbian_build_board }}/"*.img.xz \
        "{{ armbian_netboot_publish_target }}/"
  delegate_to: "{{ inventory_hostname }}"
  changed_when: true
```

- [ ] **Step 6.4: Update `roles/image_build/tasks/main.yml` to invoke publish**

Append to the end of `tasks/main.yml`:

```yaml
- name: Publish .img.xz to remote (opt-in)
  ansible.builtin.include_tasks: publish_scp.yml
  when: armbian_netboot_publish_target | default('') | length > 0
```

- [ ] **Step 6.5: Update `meta/argument_specs.yml`**

Change the role's `short_description` reference if it names `armbian_build`. Add a non-required option:

```yaml
      armbian_netboot_publish_target:
        type: str
        default: ""
        description:
          - "Optional `<ssh-host>:<abs-path>` to SCP the built .img.xz to."
          - "When empty (default), the role produces the artifact locally only."
```

- [ ] **Step 6.6: Update `meta/main.yml` `role_name: image_build`**.

- [ ] **Step 6.7: Update molecule scenario references**

```bash
grep -rn "armbian_build" extensions/molecule/image_build/ playbooks/build_image.yml 2>/dev/null
```

For each match: if it's the role name in `roles:` / `include_role:`, rename to `image_build`. If it's a variable like `armbian_build_board`, leave it (role var prefix is unchanged to minimize churn).

- [ ] **Step 6.8: Lint and commit**

```bash
ansible-lint roles/image_build/
git add roles/image_build/ extensions/molecule/image_build/ playbooks/build_image.yml
git commit -m "refactor(image_build): rename armbian_build, add opt-in publish target"
```

---

## Phase 2 — Reference playbooks

All RouterOS-specific code lives under `playbooks/routeros/`. Each reference playbook is composed of `community.routeros.command` + `ansible.netcommon.net_put` calls — no role wrappers.

### Task 7: `routeros/tasks/upload_file.yml` shared primitive

**Files:**
- Create: `playbooks/routeros/tasks/upload_file.yml`

- [ ] **Step 7.1: Create the file**

```yaml
---
# Shared primitive: upload a single file to RouterOS flash and register
# a matching /ip tftp row. Idempotent; size-gated; retry-tolerant.
#
# Required vars on include:
#   _upload_local_src   path on the controller to the file to push
#   _upload_remote_path flash:-relative destination (e.g. sbc/foo)
#   _upload_req_filename req-filename string for /ip tftp row
#   _upload_req_filename_is_regex bool (default false) — when true,
#                       the row is registered with a permissive ".*"
#                       prefix and a regex match (used for pxelinux.cfg)

- name: Stat local source
  ansible.builtin.stat:
    path: "{{ _upload_local_src }}"
  delegate_to: localhost
  become: false
  register: _upload_local_stat

- name: Assert local source exists
  ansible.builtin.assert:
    that:
      - _upload_local_stat.stat.exists
    fail_msg: "Local file {{ _upload_local_src }} is missing — upstream step did not run."

- name: Reset persistent connection before remote size check
  ansible.builtin.meta: reset_connection

- name: Count remote file matching local size
  community.routeros.command:
    commands:
      - >-
        /file print count-only where
        name="{{ _upload_remote_path }}"
        and size={{ _upload_local_stat.stat.size }}
  register: _upload_size_match
  retries: 3
  delay: 5
  until: _upload_size_match is succeeded
  changed_when: false

- name: Reset persistent connection before net_put
  ansible.builtin.meta: reset_connection
  when: (_upload_size_match.stdout[0] | trim | int) == 0

- name: Upload file when size differs or file missing
  ansible.netcommon.net_put:
    src: "{{ _upload_local_src }}"
    dest: "{{ _upload_remote_path }}"
  vars:
    ansible_command_timeout: 300
  register: _upload_net_put
  retries: 3
  delay: 5
  until: _upload_net_put is succeeded
  when: (_upload_size_match.stdout[0] | trim | int) == 0

- name: Reset persistent connection before /ip tftp count
  ansible.builtin.meta: reset_connection

- name: Build effective req-filename match
  ansible.builtin.set_fact:
    _upload_req_match: >-
      {{ ('.*' + _upload_req_filename) if (_upload_req_filename_is_regex | default(false) | bool)
         else _upload_req_filename }}

- name: Count /ip tftp rows for this file
  community.routeros.command:
    commands:
      - >-
        /ip tftp print count-only where
        req-filename="{{ _upload_req_match }}"
        and real-filename="{{ _upload_remote_path }}"
  register: _upload_tftp_count
  retries: 3
  delay: 5
  until: _upload_tftp_count is succeeded
  changed_when: false

- name: Reset persistent connection before /ip tftp add
  ansible.builtin.meta: reset_connection
  when: (_upload_tftp_count.stdout[0] | trim | int) == 0

- name: Add /ip tftp row when missing
  community.routeros.command:
    commands:
      - >-
        /ip tftp add
        req-filename="{{ _upload_req_match }}"
        real-filename="{{ _upload_remote_path }}"
        allow=yes read-only=yes
  register: _upload_tftp_add
  retries: 3
  delay: 5
  until: _upload_tftp_add is succeeded
  when: (_upload_tftp_count.stdout[0] | trim | int) == 0
  changed_when: true
```

- [ ] **Step 7.2: Commit**

```bash
git add playbooks/routeros/tasks/upload_file.yml
git commit -m "feat(routeros): shared upload_file primitive (net_put + /ip tftp row)"
```

### Task 8: `routeros/tasks/poe_cycle.yml` shared primitive

**Files:**
- Create: `playbooks/routeros/tasks/poe_cycle.yml`

- [ ] **Step 8.1: Create the file**

```yaml
---
# Shared primitive: PoE-cycle a single board's switch port.
# Delegated to the per-board switch (armbian_netboot_poe_switch).
#
# Required hostvars:
#   armbian_netboot_poe_switch
#   armbian_netboot_poe_port
# Optional:
#   armbian_netboot_poe_cycle_delay (default 5)

- name: PoE off
  community.routeros.command:
    commands:
      - '/interface ethernet poe set [find name="{{ armbian_netboot_poe_port }}"] poe-out=off'
  delegate_to: "{{ armbian_netboot_poe_switch }}"
  register: _poe_off
  retries: 3
  delay: 5
  until: _poe_off is succeeded

- name: Pause for capacitor drain
  ansible.builtin.pause:
    seconds: "{{ armbian_netboot_poe_cycle_delay | default(5) }}"

- name: PoE on
  community.routeros.command:
    commands:
      - '/interface ethernet poe set [find name="{{ armbian_netboot_poe_port }}"] poe-out=auto'
  delegate_to: "{{ armbian_netboot_poe_switch }}"
  register: _poe_on
  retries: 3
  delay: 5
  until: _poe_on is succeeded
```

- [ ] **Step 8.2: Commit**

```bash
git add playbooks/routeros/tasks/poe_cycle.yml
git commit -m "feat(routeros): shared poe_cycle primitive (off → pause → on)"
```

### Task 9: `routeros/upload_pxelinux_cfg.yml`

**Files:**
- Create: `playbooks/routeros/upload_pxelinux_cfg.yml`

- [ ] **Step 9.1: Create the playbook**

```yaml
---
# Upload per-board pxelinux.cfg files to the RouterOS router under
# flash:/{{ armbian_netboot_tftp_flash_dir }}/pxelinux.cfg/, registering
# regex-prefixed /ip tftp rows.
#
# Required vars on play invocation:
#   armbian_netboot_pxelinux_upload_boards: list of inventory hostnames
#                                           whose pxelinux files should be uploaded
#   armbian_netboot_tftp_cache_dir:         controller-side directory holding the
#                                           rendered 01-<mac> files (under pxelinux.cfg/)
#   armbian_netboot_tftp_flash_dir:         top-level dir on rb5009's flash (e.g. sbc)

- name: Upload pxelinux.cfg files to RouterOS
  hosts: routeros_routers
  gather_facts: false
  tasks:
    - name: Ensure pxelinux.cfg directory exists on router flash
      community.routeros.command:
        commands:
          - >-
            :if ([/file find name="{{ armbian_netboot_tftp_flash_dir }}/pxelinux.cfg" type=directory] = "")
            do={/file add name="{{ armbian_netboot_tftp_flash_dir }}/pxelinux.cfg" type=directory}
      register: _pxedir
      retries: 3
      delay: 5
      until: _pxedir is succeeded
      changed_when: false
      run_once: true

    - name: Upload one pxelinux.cfg per board
      ansible.builtin.include_tasks: tasks/upload_file.yml
      vars:
        _pxe_filename: "01-{{ hostvars[item].armbian_netboot_board_mac | lower | replace(':', '-') }}"
        _upload_local_src: "{{ armbian_netboot_tftp_cache_dir }}/pxelinux.cfg/{{ _pxe_filename }}"
        _upload_remote_path: "{{ armbian_netboot_tftp_flash_dir }}/pxelinux.cfg/{{ _pxe_filename }}"
        _upload_req_filename: "{{ _pxe_filename }}"
        _upload_req_filename_is_regex: true
      loop: "{{ armbian_netboot_pxelinux_upload_boards }}"
      run_once: true
```

- [ ] **Step 9.2: Commit**

```bash
git add playbooks/routeros/upload_pxelinux_cfg.yml
git commit -m "feat(routeros): reference playbook for pxelinux.cfg upload"
```

### Task 10: `routeros/upload_tftp_assets.yml`

**Files:**
- Create: `playbooks/routeros/upload_tftp_assets.yml`

- [ ] **Step 10.1: Create the playbook**

```yaml
---
# Upload kernel / initrd / dtb per model to flash:/<dir>/armbian/<model>/
# and register /ip tftp rows.
#
# Required vars:
#   armbian_netboot_tftp_upload_models: list of model strings
#   armbian_netboot_tftp_cache_dir:     controller cache holding per-model files
#   armbian_netboot_tftp_flash_dir:     top-level dir on rb5009 flash

- name: Upload SBC TFTP assets to RouterOS
  hosts: routeros_routers
  gather_facts: false
  vars:
    _assets: [vmlinuz, initrd.img, board.dtb]
  tasks:
    - name: Ensure base armbian dir exists on router flash
      community.routeros.command:
        commands:
          - >-
            :if ([/file find name="{{ armbian_netboot_tftp_flash_dir }}/armbian" type=directory] = "")
            do={/file add name="{{ armbian_netboot_tftp_flash_dir }}/armbian" type=directory}
      register: _basedir
      retries: 3
      delay: 5
      until: _basedir is succeeded
      changed_when: false
      run_once: true

    - name: Ensure per-model dirs exist
      community.routeros.command:
        commands:
          - >-
            :if ([/file find name="{{ armbian_netboot_tftp_flash_dir }}/armbian/{{ item }}" type=directory] = "")
            do={/file add name="{{ armbian_netboot_tftp_flash_dir }}/armbian/{{ item }}" type=directory}
      register: _modeldir
      retries: 3
      delay: 5
      until: _modeldir is succeeded
      changed_when: false
      loop: "{{ armbian_netboot_tftp_upload_models }}"
      run_once: true

    # Force-remove router-side files so net_put always pushes fresh
    # content — silently skipping by size has caused stale vmlinuz/
    # rootfs-modules mismatches (rb5009 served old kernel; initramfs
    # modprobe failed inside the new rootfs). Always-stage is ~6s/file
    # and removes the silent-mismatch class entirely.
    - name: Force-remove router-side asset
      community.routeros.command:
        commands:
          - >-
            /file remove
            [find name="{{ armbian_netboot_tftp_flash_dir }}/armbian/{{ item.0 }}/{{ item.1 }}"]
      register: _preremove
      retries: 3
      delay: 5
      until: _preremove is succeeded
      changed_when: false
      loop: "{{ armbian_netboot_tftp_upload_models | product(_assets) | list }}"
      loop_control:
        label: "{{ item.0 }}/{{ item.1 }}"
      run_once: true

    - name: Upload each (model, asset) pair via shared primitive
      ansible.builtin.include_tasks: tasks/upload_file.yml
      vars:
        _upload_local_src: "{{ armbian_netboot_tftp_cache_dir }}/{{ item.0 }}/{{ item.1 }}"
        _upload_remote_path: "{{ armbian_netboot_tftp_flash_dir }}/armbian/{{ item.0 }}/{{ item.1 }}"
        _upload_req_filename: "armbian/{{ item.0 }}/{{ item.1 }}"
        _upload_req_filename_is_regex: false
      loop: "{{ armbian_netboot_tftp_upload_models | product(_assets) | list }}"
      loop_control:
        label: "{{ item.0 }}/{{ item.1 }}"
      run_once: true

    - name: Reset network_cli connection after upload burst
      ansible.builtin.meta: reset_connection
```

- [ ] **Step 10.2: Commit**

```bash
git add playbooks/routeros/upload_tftp_assets.yml
git commit -m "feat(routeros): reference playbook for kernel/initrd/dtb upload"
```

### Task 11: `routeros/plumbing_check.yml`

**Files:**
- Create: `playbooks/routeros/plumbing_check.yml`

- [ ] **Step 11.1: Create the playbook**

```yaml
---
# Assert /ip tftp rows exist on RouterOS for each (model, asset) pair.
#
# Required var:
#   armbian_netboot_tftp_check_models: list of models to verify
#   armbian_netboot_tftp_flash_dir:    top-level dir on router flash

- name: Assert /ip tftp rows exist on RouterOS
  hosts: routeros_routers
  gather_facts: false
  vars:
    _assets: [vmlinuz, initrd.img, board.dtb]
  tasks:
    - name: Count /ip tftp rows per (model, asset) pair
      community.routeros.command:
        commands:
          - >-
            /ip tftp print count-only where
            req-filename="armbian/{{ item.0 }}/{{ item.1 }}"
      register: _row_count
      retries: 3
      delay: 5
      until: _row_count is succeeded
      changed_when: false
      loop: "{{ armbian_netboot_tftp_check_models | product(_assets) | list }}"
      loop_control:
        label: "{{ item.0 }}/{{ item.1 }}"
      run_once: true

    - name: Assert each pair has at least one row
      ansible.builtin.assert:
        that:
          - (item.stdout[0] | trim | int) >= 1
        fail_msg: >-
          RouterOS has no /ip tftp row for
          armbian/{{ item.item.0 }}/{{ item.item.1 }}.
          Run playbooks/stage_router.yml to populate TFTP assets
          before invoking converge_boot_mode.
      loop: "{{ _row_count.results }}"
      loop_control:
        label: "{{ item.item.0 }}/{{ item.item.1 }}"
      run_once: true
```

- [ ] **Step 11.2: Commit**

```bash
git add playbooks/routeros/plumbing_check.yml
git commit -m "feat(routeros): reference playbook for /ip tftp plumbing assertion"
```

### Task 12: `routeros/poe_control.yml`

**Files:**
- Create: `playbooks/routeros/poe_control.yml`

- [ ] **Step 12.1: Create the playbook**

```yaml
---
# Control PoE state on the switch port a board is plugged into.
# Required var:
#   armbian_netboot_poe_action: on | off | cycle
# Required hostvars:
#   armbian_netboot_poe_switch
#   armbian_netboot_poe_port

- name: Control PoE per board
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: Validate inputs
      ansible.builtin.assert:
        that:
          - armbian_netboot_poe_action in ['on', 'off', 'cycle']
          - armbian_netboot_poe_switch is defined and armbian_netboot_poe_switch | length > 0
          - armbian_netboot_poe_port   is defined and armbian_netboot_poe_port   | length > 0
        fail_msg: >-
          armbian_netboot_poe_action must be on|off|cycle; poe_switch
          and poe_port hostvars must be set on {{ inventory_hostname }}.

    - name: PoE on
      community.routeros.command:
        commands:
          - '/interface ethernet poe set [find name="{{ armbian_netboot_poe_port }}"] poe-out=auto'
      delegate_to: "{{ armbian_netboot_poe_switch }}"
      retries: 3
      delay: 5
      register: _poe_on
      until: _poe_on is succeeded
      when: armbian_netboot_poe_action == 'on'

    - name: PoE off
      community.routeros.command:
        commands:
          - '/interface ethernet poe set [find name="{{ armbian_netboot_poe_port }}"] poe-out=off'
      delegate_to: "{{ armbian_netboot_poe_switch }}"
      retries: 3
      delay: 5
      register: _poe_off
      until: _poe_off is succeeded
      when: armbian_netboot_poe_action == 'off'

    - name: PoE cycle
      ansible.builtin.include_tasks: tasks/poe_cycle.yml
      when: armbian_netboot_poe_action == 'cycle'
```

- [ ] **Step 12.2: Commit**

```bash
git add playbooks/routeros/poe_control.yml
git commit -m "feat(routeros): reference playbook for PoE control"
```

### Task 13: `routeros/bootstrap_user.yml`

**Files:**
- Create: `playbooks/routeros/bootstrap_user.yml`

- [ ] **Step 13.1: Lift logic from existing `roles/bootstrap_routeros_user/tasks/main.yml`**

Read the v2 role's task file and translate each task into the body of a single play:

```bash
cat roles/bootstrap_routeros_user/tasks/main.yml
```

Create `playbooks/routeros/bootstrap_user.yml`:

```yaml
---
# Provision the ansible-netboot user / group / SSH key on RouterOS hosts.
# Replaces the v2 bootstrap_routeros_user role.
#
# Usage:
#   ansible-playbook playbooks/routeros/bootstrap_user.yml \
#     -e ansible_user=<existing-admin>

- name: Bootstrap ansible-netboot user on RouterOS hosts
  hosts: routeros_netboot
  gather_facts: false
  tasks:
    # The body of each task here is lifted verbatim from
    # roles/bootstrap_routeros_user/tasks/main.yml — preserve task
    # names, retries, and var references exactly so behaviour is
    # bit-identical to the v2 role.
    <copy v2 task bodies here, in order>
```

- [ ] **Step 13.2: Commit**

```bash
git add playbooks/routeros/bootstrap_user.yml
git commit -m "feat(routeros): reference playbook for ansible-netboot user bootstrap"
```

---

## Phase 3 — Playbook-side helpers

These helpers replace the retry primitives that lived inside the v2 `boot_mode` role's task files. They live under `playbooks/tasks/` and are invoked via `include_tasks`.

### Task 14: `playbooks/tasks/cold_boot_with_retry.yml`

**Files:**
- Create: `playbooks/tasks/cold_boot_with_retry.yml`

- [ ] **Step 14.1: Translate `roles/boot_mode/tasks/cold_boot_with_retry.yml` + `cold_boot_single_attempt.yml`**

Read the v2 originals:

```bash
cat roles/boot_mode/tasks/cold_boot_with_retry.yml
cat roles/boot_mode/tasks/cold_boot_single_attempt.yml
```

Create `playbooks/tasks/cold_boot_with_retry.yml`:

```yaml
---
# Cold-boot a board with retry tolerance.
#
# Each attempt:
#   1. include the parameterised poe_cycle tasks file
#   2. wait_for TCP/22
#   3. sustained ssh-ping (until timeout)
#
# Required vars:
#   _phase_label:                   string used in task names
#   _boot_max_attempts:             int — total attempts (1 = no retry)
#   armbian_netboot_poe_cycle_tasks_file:
#     path to a tasks-file (default: routeros/tasks/poe_cycle.yml)
#     loaded via include_tasks; users override to swap transport.

- name: "{{ _phase_label }} — cold-boot attempts loop"
  block:
    - name: "{{ _phase_label }} — attempt {{ _attempt }} — PoE cycle"
      ansible.builtin.include_tasks: "{{ armbian_netboot_poe_cycle_tasks_file
                                          | default('routeros/tasks/poe_cycle.yml') }}"

    - name: "{{ _phase_label }} — attempt {{ _attempt }} — wait for TCP/22"
      ansible.builtin.wait_for:
        host: "{{ ansible_host | default(inventory_hostname) }}"
        port: 22
        timeout: "{{ armbian_netboot_boot_attempt_timeout | default(180) }}"
        state: started
      delegate_to: localhost
      become: false
  rescue:
    - name: "{{ _phase_label }} — retry exhausted"
      ansible.builtin.fail:
        msg: >-
          {{ _phase_label }}: TCP/22 never came up across
          {{ _boot_max_attempts }} cold-boot attempts.
      when: (_attempt | int) >= (_boot_max_attempts | int)

    - name: "{{ _phase_label }} — retry attempt {{ _attempt | int + 1 }}"
      ansible.builtin.include_tasks: cold_boot_with_retry.yml
      vars:
        _attempt: "{{ _attempt | int + 1 }}"

  vars:
    _attempt: "{{ _attempt | default(1) }}"
```

- [ ] **Step 14.2: Commit**

```bash
git add playbooks/tasks/cold_boot_with_retry.yml
git commit -m "feat(tasks): cold_boot_with_retry helper with parameterised cycle hook"
```

### Task 15: `playbooks/tasks/wait_for_ssh_with_cycle_retry.yml`

**Files:**
- Create: `playbooks/tasks/wait_for_ssh_with_cycle_retry.yml`

- [ ] **Step 15.1: Translate `roles/boot_mode/tasks/wait_for_ssh_with_cycle_retry.yml`**

```bash
cat roles/boot_mode/tasks/wait_for_ssh_with_cycle_retry.yml
```

Create `playbooks/tasks/wait_for_ssh_with_cycle_retry.yml`:

```yaml
---
# Post-boot wait_for_connection with optional one-cycle retry.
# Required vars:
#   _phase_label
#   _wait_timeout
#   armbian_netboot_poe_cycle_tasks_file (defaulted)

- name: "{{ _phase_label }} — wait for SSH (initial)"
  block:
    - ansible.builtin.wait_for_connection:
        timeout: "{{ _wait_timeout }}"
        sleep: 5
  rescue:
    - name: "{{ _phase_label }} — initial SSH wait failed; cycling and retrying"
      ansible.builtin.include_tasks: "{{ armbian_netboot_poe_cycle_tasks_file
                                          | default('routeros/tasks/poe_cycle.yml') }}"

    - name: "{{ _phase_label }} — wait for SSH (retry)"
      ansible.builtin.wait_for_connection:
        timeout: "{{ _wait_timeout }}"
        sleep: 5
```

- [ ] **Step 15.2: Commit**

```bash
git add playbooks/tasks/wait_for_ssh_with_cycle_retry.yml
git commit -m "feat(tasks): wait_for_ssh_with_cycle_retry helper"
```

### Task 16: `playbooks/tasks/auto_bootstrap_if_needed.yml`

**Files:**
- Create: `playbooks/tasks/auto_bootstrap_if_needed.yml`

- [ ] **Step 16.1: Extract the auto-bootstrap pattern from v2 `playbooks/test_hardware_e2e.yml` (used 3 times: Phase 1 pre-wait, Phase 2 pre-wait, Cleanup)**

Read the v2 pattern:

```bash
grep -n "auto-bootstrap" playbooks/test_hardware_e2e.yml | head -20
```

Create `playbooks/tasks/auto_bootstrap_if_needed.yml`:

```yaml
---
# Short SSH probe as the inventory user; if it fails, run
# bootstrap_armbian inline against the Armbian default root account.
# Used by test_hardware_e2e.yml at three points where a freshly-flashed
# board or fresh per-host NFS rootfs may not yet have the inventory user.
#
# Required vars:
#   _phase_label
#   armbian_netboot_default_password

- name: "{{ _phase_label }} — short SSH probe as inventory user"
  ansible.builtin.wait_for_connection:
    timeout: 30
    sleep: 5
    delay: 0
  register: _inv_probe
  ignore_errors: true # noqa: ignore-errors

- name: "{{ _phase_label }} — auto-bootstrap when inv user can't authenticate"
  when: _inv_probe is failed
  block:
    - ansible.builtin.debug:
        msg: >-
          {{ _phase_label }}: inventory user can't authenticate to
          {{ inventory_hostname }} but the board is reachable —
          running bootstrap_armbian inline.

    - ansible.builtin.include_role:
        name: david_igou.armbian_netboot.bootstrap_armbian
      vars:
        ansible_user: root
        ansible_password: "{{ armbian_netboot_default_password }}"
        ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        ansible_become: false

    - ansible.builtin.meta: reset_connection
```

- [ ] **Step 16.2: Commit**

```bash
git add playbooks/tasks/auto_bootstrap_if_needed.yml
git commit -m "feat(tasks): auto_bootstrap_if_needed helper extracted from e2e test"
```

---

## Phase 4 — Top-level playbook rewrites

Each top-level playbook is rewritten to compose new roles + reference playbooks. Old v2 roles are still in place until Phase 5, so any oversight in the rewrite can be spotted by comparing behaviour with the v2 playbook in parallel.

### Task 17: Rewrite `stage_netboot_assets.yml` (renamed from `stage_nfs_rootfs.yml`)

**Files:**
- Modify: `playbooks/stage_nfs_rootfs.yml` → `playbooks/stage_netboot_assets.yml` (`git mv`)

- [ ] **Step 17.1: Move the file**

```bash
git mv playbooks/stage_nfs_rootfs.yml playbooks/stage_netboot_assets.yml
```

- [ ] **Step 17.2: Replace its contents**

```yaml
---
# Stage netboot assets on the netboot server:
#   1. Extract one rootfs template + TFTP artifact set per unique board model
#   2. Reflink-clone the per-host rootfs for every board in inventory
#
# All artifacts land at known paths on the netboot server. The follow-up
# stage_router.yml playbook fetches the TFTP artifacts to the controller
# and pushes them to the router.

- name: Stage netboot assets on netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  vars:
    _unique_models: >-
      {{ groups['boards']
         | map('extract', hostvars, 'armbian_netboot_board_model')
         | list | unique }}
  tasks:
    - name: Load board configs from collection vars
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"

    - name: Extract per-model templates + TFTP artifacts
      ansible.builtin.include_role:
        name: david_igou.armbian_netboot.image_extract
      vars:
        armbian_image_src: "{{ armbian_netboot_image_urls[item] }}"
        model_name: "{{ item }}"
        template_dir: "{{ armbian_netboot_nfs_rootfs_path }}/_templates/{{ item }}"
        tftp_dir: "{{ armbian_netboot_image_cache }}/sbc-tftp/{{ item }}"
        board_dtb: "{{ armbian_netboot_board_configs[item].dtb }}"
        force_refresh: "{{ armbian_netboot_force_refresh | default(false) }}"
      loop: "{{ _unique_models }}"

    - name: Clone per-host rootfs for every board in inventory
      ansible.builtin.include_role:
        name: david_igou.armbian_netboot.rootfs_clone
      vars:
        template_dir: "{{ armbian_netboot_nfs_rootfs_path }}/_templates/{{ hostvars[item].armbian_netboot_board_model }}"
        target_dir: "{{ armbian_netboot_nfs_rootfs_path }}/{{ item }}"
        hostname: "{{ item }}"
        force_refresh: "{{ armbian_netboot_force_refresh | default(false) }}"
      loop: "{{ groups['boards'] }}"
```

- [ ] **Step 17.3: Syntax check, lint, commit**

```bash
ansible-playbook --syntax-check playbooks/stage_netboot_assets.yml
ansible-lint playbooks/stage_netboot_assets.yml
git add playbooks/stage_netboot_assets.yml
git commit -m "refactor(playbook): stage_netboot_assets composes image_extract + rootfs_clone"
```

### Task 18: Rewrite `stage_router.yml` (renamed from `stage_tftp_assets.yml`)

**Files:**
- Modify: `playbooks/stage_tftp_assets.yml` → `playbooks/stage_router.yml`

- [ ] **Step 18.1: Move and rewrite**

```bash
git mv playbooks/stage_tftp_assets.yml playbooks/stage_router.yml
```

Replace contents:

```yaml
---
# Pull TFTP artifacts from the netboot server's cache onto the
# controller, then push them to the router + register /ip tftp rows.
#
# Pre-condition: stage_netboot_assets.yml has been run so the
# kernel/initrd/dtb are populated under
# {{ armbian_netboot_image_cache }}/sbc-tftp/<model>/ on netboot_server.

- name: Fetch TFTP artifacts from netboot server to controller cache
  hosts: netboot_server
  become: true
  gather_facts: false
  vars:
    _unique_models: >-
      {{ groups['boards']
         | map('extract', hostvars, 'armbian_netboot_board_model')
         | list | unique }}
    _assets: [vmlinuz, initrd.img, board.dtb]
  tasks:
    - name: Ensure controller cache dir exists per model
      ansible.builtin.file:
        path: "{{ armbian_netboot_tftp_cache_dir }}/{{ item }}"
        state: directory
        mode: "0755"
      delegate_to: localhost
      become: false
      loop: "{{ _unique_models }}"

    - name: Fetch each (model, asset) from netboot server
      ansible.builtin.fetch:
        src: "{{ armbian_netboot_image_cache }}/sbc-tftp/{{ item.0 }}/{{ item.1 }}"
        dest: "{{ armbian_netboot_tftp_cache_dir }}/{{ item.0 }}/{{ item.1 }}"
        flat: true
      loop: "{{ _unique_models | product(_assets) | list }}"
      loop_control:
        label: "{{ item.0 }}/{{ item.1 }}"

- name: Upload TFTP assets to router (reference playbook)
  import_playbook: "{{ armbian_netboot_tftp_upload_playbook | default('routeros/upload_tftp_assets.yml') }}"
  vars:
    armbian_netboot_tftp_upload_models: >-
      {{ groups['boards']
         | map('extract', hostvars, 'armbian_netboot_board_model')
         | list | unique }}

- name: Plumbing check — verify /ip tftp rows landed
  import_playbook: "{{ armbian_netboot_plumbing_check_playbook | default('routeros/plumbing_check.yml') }}"
  vars:
    armbian_netboot_tftp_check_models: >-
      {{ groups['boards']
         | map('extract', hostvars, 'armbian_netboot_board_model')
         | list | unique }}
```

- [ ] **Step 18.2: Syntax check + lint + commit**

```bash
ansible-playbook --syntax-check playbooks/stage_router.yml
ansible-lint playbooks/stage_router.yml
git add playbooks/stage_router.yml
git commit -m "refactor(playbook): stage_router fetches + uploads TFTP assets"
```

### Task 19: Rewrite `converge_boot_mode.yml`

**Files:**
- Modify: `playbooks/converge_boot_mode.yml`

- [ ] **Step 19.1: Replace its contents**

```yaml
---
# Converge a board to its inventory-declared boot mode.
#
# Plays:
#   1. Pre-flight plumbing check (router has /ip tftp rows)
#   2. Render per-board pxelinux.cfg locally (delegate_to localhost)
#   3. Upload pxelinux.cfg to router (reference playbook)
#   4. PoE cycle + wait + verify on the board

- name: Pre-flight — assert router /ip tftp plumbing
  import_playbook: "{{ armbian_netboot_plumbing_check_playbook | default('routeros/plumbing_check.yml') }}"
  vars:
    armbian_netboot_tftp_check_models: >-
      {{ query('inventory_hostnames', target_hosts | default('boards'))
         | map('extract', hostvars, 'armbian_netboot_board_model')
         | list | unique }}

- name: Render per-board pxelinux.cfg locally
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: Load board configs
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"

    - name: Render pxelinux.cfg (delegated to localhost)
      ansible.builtin.include_role:
        name: david_igou.armbian_netboot.pxelinux_render
      vars:
        board_mac: "{{ armbian_netboot_board_mac }}"
        boot_mode: "{{ armbian_netboot_boot_mode }}"
        board_console: "{{ armbian_netboot_board_configs[armbian_netboot_board_model].console }}"
        model_name: "{{ armbian_netboot_board_model }}"
        nfs_server_ip: "{{ armbian_netboot_nfs_server_ip | default(armbian_netboot_server_ip) }}"
        nfs_root_path: "{{ armbian_netboot_nfs_rootfs_path }}"
        hostname: "{{ inventory_hostname }}"
        output_dir: "{{ armbian_netboot_tftp_cache_dir }}/pxelinux.cfg"
        sd_root: "{{ armbian_netboot_sd_root | default('LABEL=armbi_root') }}"
        pxe_verbose: "{{ armbian_netboot_pxe_verbose | default(false) }}"
        earlycon: "{{ armbian_netboot_board_configs[armbian_netboot_board_model].earlycon | default('') }}"
      delegate_to: localhost
      become: false

- name: Upload rendered pxelinux.cfg to router (reference playbook)
  import_playbook: "{{ armbian_netboot_pxelinux_upload_playbook | default('routeros/upload_pxelinux_cfg.yml') }}"
  vars:
    armbian_netboot_pxelinux_upload_boards: >-
      {{ query('inventory_hostnames', target_hosts | default('boards')) }}

- name: Cycle, wait, verify
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: Cycle PoE + cold-boot retry
      ansible.builtin.include_tasks: "{{ playbook_dir }}/tasks/cold_boot_with_retry.yml"
      vars:
        _phase_label: "converge[{{ armbian_netboot_boot_mode }}]"
        _boot_max_attempts: "{{ armbian_netboot_boot_retry_attempts | default(0) | int + 1 }}"
      when: armbian_netboot_cycle_board | default(true) | bool

    - name: Wait for SSH after cold boot
      ansible.builtin.include_tasks: "{{ playbook_dir }}/tasks/wait_for_ssh_with_cycle_retry.yml"
      vars:
        _phase_label: "converge[{{ armbian_netboot_boot_mode }}]"
        _wait_timeout: "{{ armbian_netboot_post_boot_wait_timeout | default(300) }}"
      when: armbian_netboot_cycle_board | default(true) | bool

    - name: Verify rootfs matches declared mode
      ansible.builtin.include_role:
        name: david_igou.armbian_netboot.board_boot_verify
      vars:
        boot_mode: "{{ armbian_netboot_boot_mode }}"
      when:
        - armbian_netboot_cycle_board | default(true) | bool
        - armbian_netboot_verify_state | default(true) | bool
```

- [ ] **Step 19.2: Syntax check + lint + commit**

```bash
ansible-playbook --syntax-check playbooks/converge_boot_mode.yml
ansible-lint playbooks/converge_boot_mode.yml
git add playbooks/converge_boot_mode.yml
git commit -m "refactor(playbook): converge_boot_mode composes new roles + reference playbooks"
```

### Task 20: Rewrite `set_boot_mode.yml`

**Files:**
- Modify: `playbooks/set_boot_mode.yml`

- [ ] **Step 20.1: Replace contents**

```yaml
---
# Ad-hoc boot-mode override: read armbian_netboot_boot_mode from `-e`
# instead of inventory. Wraps converge_boot_mode.yml unchanged.

- import_playbook: converge_boot_mode.yml
```

The `-e armbian_netboot_boot_mode=...` arg already overrides the inventory-declared value because Ansible `-e` is highest precedence. No further glue needed.

- [ ] **Step 20.2: Commit**

```bash
git add playbooks/set_boot_mode.yml
git commit -m "refactor(playbook): set_boot_mode is a thin wrapper around converge"
```

### Task 21: Rewrite top-level `poe_control.yml`

**Files:**
- Modify: `playbooks/poe_control.yml`

- [ ] **Step 21.1: Replace contents**

```yaml
---
# Top-level convenience wrapper around the routeros reference playbook.
# Users with non-RouterOS transport replace this with a parallel
# wrapper pointing at their own poe_control reference.

- import_playbook: "{{ armbian_netboot_poe_control_playbook | default('routeros/poe_control.yml') }}"
```

- [ ] **Step 21.2: Commit**

```bash
git add playbooks/poe_control.yml
git commit -m "refactor(playbook): poe_control wraps routeros reference"
```

### Task 22: Update `build_image.yml`

**Files:**
- Modify: `playbooks/build_image.yml`

- [ ] **Step 22.1: Inspect existing playbook**

```bash
cat playbooks/build_image.yml
```

- [ ] **Step 22.2: Update role references**

Find every `armbian_build` token and replace with `image_build`. If the playbook does a publish step outside the role (e.g. inline SCP after the build), remove that block — `image_build` now handles publishing via `armbian_netboot_publish_target`. Set the variable in the playbook's `vars:` to preserve current behaviour:

```yaml
  vars:
    armbian_netboot_publish_target: "{{ armbian_netboot_image_publish_target | default('') }}"
```

- [ ] **Step 22.3: Syntax check + lint + commit**

```bash
ansible-playbook --syntax-check playbooks/build_image.yml
ansible-lint playbooks/build_image.yml
git add playbooks/build_image.yml
git commit -m "refactor(playbook): build_image uses image_build with opt-in publish"
```

### Task 23: Rewrite `test_hardware_e2e.yml`

**Files:**
- Modify: `playbooks/test_hardware_e2e.yml`

This is the largest top-level rewrite. The three-phase structure (SD baseline → NFS → SD) stays; what changes is that each phase now composes the new roles + helpers instead of including v2 `boot_mode`'s tasks_from primitives.

- [ ] **Step 23.1: Read both inputs in parallel**

```bash
sed -n '1,200p' playbooks/test_hardware_e2e.yml
```

- [ ] **Step 23.2: Rewrite each phase**

For each of Phase 1, Phase 2, Phase 3, and Cleanup, replace:

| Old (v2) | New (v3) |
|---|---|
| `include_role: boot_mode tasks_from: cold_boot_with_retry.yml` | `include_tasks: tasks/cold_boot_with_retry.yml` |
| `include_role: boot_mode tasks_from: wait_for_ssh_with_cycle_retry.yml` | `include_tasks: tasks/wait_for_ssh_with_cycle_retry.yml` |
| `include_role: boot_mode tasks_from: converge.yml` | Render+upload via the converge_boot_mode shape: `include_role: pxelinux_render` (delegate_to localhost) then `include_tasks` the upload reference playbook tasks. For a single board this is cheap; alternatively, `import_playbook: converge_boot_mode.yml --limit <self> -e armbian_netboot_cycle_board=false` is equivalent but more plays. Prefer inline include_role + include_tasks. |
| Phase-1/Phase-2/Cleanup inline auto-bootstrap probe | `include_tasks: tasks/auto_bootstrap_if_needed.yml` (deduplicates the 3 copies) |

Manually inspect the `vars:` blocks at each phase — many of them set `armbian_netboot_boot_mode: nfs|sd` to drive the v2 `boot_mode` role. Under v3, pass `boot_mode:` to `pxelinux_render` and `board_boot_verify` directly.

- [ ] **Step 23.3: Preserve serial capture, diagnostic_bundle, leave_state, skip_baseline knobs**

The pre-flight (assert single board, assert PoE vars, assert default password), the serial capture block, the stale-known-hosts cleanup, and the `always:` cleanup block all stay structurally identical. Only the role/tasks include references change.

- [ ] **Step 23.4: Syntax check + lint + commit**

```bash
ansible-playbook --syntax-check playbooks/test_hardware_e2e.yml
ansible-lint playbooks/test_hardware_e2e.yml
git add playbooks/test_hardware_e2e.yml
git commit -m "refactor(playbook): test_hardware_e2e composes new roles + helpers"
```

---

## Phase 5 — Cleanup + release

### Task 24: Delete old roles

**Files:**
- Delete: `roles/boot_mode/`
- Delete: `roles/netboot_assets/`
- Delete: `roles/routeros_pxe_config/`
- Delete: `roles/routeros_poe/`
- Delete: `roles/bootstrap_routeros_user/`

- [ ] **Step 24.1: Grep for any remaining references to the old role names**

```bash
grep -rn --include='*.yml' --include='*.yaml' \
  -e 'name: boot_mode' \
  -e 'name: netboot_assets' \
  -e 'name: routeros_pxe_config' \
  -e 'name: routeros_poe' \
  -e 'name: bootstrap_routeros_user' \
  -e 'david_igou.armbian_netboot.boot_mode' \
  -e 'david_igou.armbian_netboot.netboot_assets' \
  -e 'david_igou.armbian_netboot.routeros_pxe_config' \
  -e 'david_igou.armbian_netboot.routeros_poe' \
  -e 'david_igou.armbian_netboot.bootstrap_routeros_user' \
  .
```

Expected: zero matches across the repo. Any match indicates Phase 4 missed an update — go back and fix it before deleting the old roles.

- [ ] **Step 24.2: Delete the role directories**

```bash
git rm -r roles/boot_mode roles/netboot_assets roles/routeros_pxe_config roles/routeros_poe roles/bootstrap_routeros_user
```

- [ ] **Step 24.3: Commit**

```bash
git commit -m "refactor(roles): delete v2 roles superseded by v3 decomposition"
```

### Task 25: Delete old playbooks superseded by renames

**Files:**
- Delete: `playbooks/bootstrap_routeros_user.yml` (replaced by `playbooks/routeros/bootstrap_user.yml`)
- Delete: `playbooks/persist_uboot_env.yml` ? → **No**, this stays per the spec's out-of-scope list.

- [ ] **Step 25.1: Check what still references `playbooks/bootstrap_routeros_user.yml`**

```bash
grep -rn 'bootstrap_routeros_user.yml' . | grep -v '^./docs/' | grep -v '^./.git/'
```

Update any remaining references (likely README and CLAUDE.md — Task 28 handles docs). Then:

- [ ] **Step 25.2: Delete the old top-level playbook**

```bash
git rm playbooks/bootstrap_routeros_user.yml
git commit -m "refactor(playbook): drop bootstrap_routeros_user.yml (replaced by routeros/bootstrap_user.yml)"
```

### Task 26: Bump `galaxy.yml` to 3.0.0

**Files:**
- Modify: `galaxy.yml`

- [ ] **Step 26.1: Edit version + description**

```yaml
version: 3.0.0
description: >-
  Ansible collection for end-to-end management of Armbian-based ARM SBCs:
  custom image build, per-host rootfs provisioning, netboot/SD boot-mode
  convergence, and PoE-driven hardware lifecycle. v3 decomposes roles into
  single-purpose, single-host, transport-agnostic units; networking-gear-
  specific code (e.g. RouterOS) lives in swappable reference playbooks
  under playbooks/<transport>/.
```

- [ ] **Step 26.2: Commit**

```bash
git add galaxy.yml
git commit -m "chore: bump collection to v3.0.0"
```

### Task 27: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 27.1: Update the "Collection structure" section** to reflect the new role list and the `playbooks/routeros/` directory.

- [ ] **Step 27.2: Update the "Running playbooks" section** with the renamed entry points: `stage_netboot_assets.yml` (was `stage_nfs_rootfs.yml`) and `stage_router.yml` (was `stage_tftp_assets.yml`); `routeros/bootstrap_user.yml` for the RouterOS user provisioning step.

- [ ] **Step 27.3: Update the "Status" header** to v3.0.0 with a one-line summary of the role refactor; keep the always-netboot model description but cross-reference both specs.

- [ ] **Step 27.4: Update the "Key files" list** to point at the new roles and helper task files.

- [ ] **Step 27.5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(CLAUDE.md): update for v3.0.0 role refactor"
```

### Task 28: Update README + cross-references in v2 specs

**Files:**
- Modify: `README.md` (if it documents roles/playbooks)
- Modify: `docs/superpowers/specs/2026-05-14-always-netboot-migration-design.md` (add header note pointing at the v3 spec)
- Modify: `docs/architecture.md` (if it diagrams the old role inventory)
- Modify: `docs/boot-mode-override.md` (any role name references)
- Modify: `docs/retry-configuration.md` (retry knobs now live in playbook-side helpers, not the boot_mode role)

- [ ] **Step 28.1: Audit doc references**

```bash
grep -rln --include='*.md' \
  -e 'boot_mode' \
  -e 'netboot_assets' \
  -e 'routeros_pxe_config' \
  -e 'routeros_poe' \
  -e 'bootstrap_routeros_user' \
  -e 'stage_nfs_rootfs.yml' \
  -e 'stage_tftp_assets.yml' \
  docs/ README.md
```

- [ ] **Step 28.2: Update each match.** Reference name changes are mechanical. For docs that explain *what* a role did (architecture, retry-configuration), rewrite the paragraph to describe the new shape: where the responsibility moved, which file holds it now, which helpers replace the v2 retry primitives.

- [ ] **Step 28.3: Commit**

```bash
git add docs/ README.md
git commit -m "docs: update cross-references for v3.0.0 role layout"
```

### Task 29: Final whole-repo lint + syntax sweep

- [ ] **Step 29.1: Run repo-wide lint**

```bash
ansible-lint
```

Expected: zero errors.

- [ ] **Step 29.2: Syntax-check every top-level playbook**

```bash
for p in playbooks/*.yml; do
  echo "==> $p"
  ansible-playbook --syntax-check "$p" || break
done
```

Expected: every playbook prints OK. `--syntax-check` parses YAML and resolves role/include references; it does not open SSH connections.

- [ ] **Step 29.3: Confirm argument_specs validation fires for every new role**

For each new role under `roles/`, run an `include_role` smoke check (using `hosts: localhost`, `connection: local`) with no vars and confirm the failure message lists the role's required inputs. The role-specific smoke checks earlier in the plan cover image_extract and pxelinux_render; repeat for `rootfs_clone`, `board_boot_wait`, `board_boot_verify`, and `image_build`.

- [ ] **Step 29.4: Verify v2 references are gone**

Re-run the grep from Step 24.1 over the whole repo. Expected: zero matches.

- [ ] **Step 29.5: Final commit (if anything was tidied) and push branch for review**

If the SSH agent isn't holding the GitHub key, `git push` will fail with "Permission denied (publickey)". Re-load the key per the Phase 0 SSH-agent note, then retry.

```bash
git status                        # expect clean
git push -u origin v3-role-refactor
gh pr create --title "v3.0.0: role refactor — single-purpose, transport-agnostic" --body "$(cat <<'EOF'
## Summary
- Decomposes v2 roles into seven single-purpose, single-host, transport-agnostic v3 roles.
- Moves all RouterOS-specific code to `playbooks/routeros/` reference playbooks reached via transport-hook variables.
- Bumps collection to 3.0.0.

Design spec: `docs/superpowers/specs/2026-05-16-role-refactor-v3-design.md`
Implementation plan: `docs/superpowers/plans/2026-05-16-role-refactor-v3.md`

## Test plan (this PR — role-level only)
- [ ] `ansible-lint` clean across the repo
- [ ] All top-level playbooks pass `--syntax-check`
- [ ] Every new role's argument_specs rejects missing-required-input invocations
- [ ] `pxelinux_render` produces correct output against a synthetic fixture (both `nfs` and `sd` modes)
- [ ] Grep finds zero references to v2 role names anywhere in the repo

## Deferred (follow-up plan)
End-to-end verification against real `netboot_server`, RouterOS, and hardware:
- [ ] `playbooks/stage_netboot_assets.yml` produces the same rootfs templates + per-host clones as v2
- [ ] `playbooks/stage_router.yml` lands the same TFTP files + `/ip tftp` rows on rb5009
- [ ] `playbooks/converge_boot_mode.yml --limit <host>` flips one board between NFS and SD modes
- [ ] `playbooks/test_hardware_e2e.yml --limit <host>` passes all three phases

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Implementation notes

- **Worktree.** Because this refactor touches dozens of files and lasts hours, consider using a git worktree (`superpowers:using-git-worktrees` skill) before starting Phase 1. Roll back is `git checkout main` if the experiment goes sideways.
- **TDD constraints.** Argument-spec smoke checks are the closest thing to unit tests for these roles. Where a role has behaviour that's testable in isolation (template rendering, identity reset on a synthetic tree), Phase 1 includes that check inline.
- **Hardware E2E gate.** Task 23's rewrite is verified at the end of Phase 5 via Task 29's pre-merge test plan. Run `test_hardware_e2e.yml` on real hardware before merging; the spec, the lint sweep, and syntax checks do not catch behaviour regressions in the retry helpers.
- **Backout.** Until Task 24 deletes the v2 roles, the rewrite can be reverted by `git revert` of the top-level playbook commits in Phase 4 — v2 roles still resolve. After Task 24, backout means reverting Tasks 24 + Phase 4 in order.
