# Molecule + KubeVirt Implementation Plan

> Spec: [`2026-05-05-molecule-kubevirt-design.md`](../specs/2026-05-05-molecule-kubevirt-design.md)

**Goal:** Land a Molecule scenario for `armbian_build` that runs a real
Armbian build on a KubeVirt VM, plus the reusable KubeVirt provisioner.

**Architecture:** `extensions/molecule/provisioners/kubevirt/` (lifecycle
playbooks + tasks) is shared infrastructure. `extensions/molecule/armbian_build/`
is the scenario. A `Makefile` target wraps the invocation.

**Tech stack:** Molecule (ansible driver), `kubernetes.core`, `community.crypto`,
KubeVirt v1, OCP hub cluster.

---

## Task 1: KubeVirt provisioner — requirements + group_vars

**Files:**
- Create: `extensions/molecule/provisioners/kubevirt/requirements.yml`
- Create: `extensions/molecule/provisioners/kubevirt/group_vars/all.yml`

**Step 1: Write `requirements.yml`**

```yaml
---
collections:
  - name: kubernetes.core
  - name: community.crypto
```

**Step 2: Write `group_vars/all.yml`**

```yaml
---
ansible_connection: ssh
```

---

## Task 2: KubeVirt provisioner — `tasks/create_vm_dictionary.yml`

**Files:**
- Create: `extensions/molecule/provisioners/kubevirt/tasks/create_vm_dictionary.yml`

**Step 1: Write the task**

Direct copy from devhost. Builds the per-VM connection-info dict that
`create.yml` later writes to molecule's inventory.

```yaml
---
- name: Create VM dictionary
  vars:
    __kubevirt_ssh_service_port: >-
      {%- set svc_type = vm.kubevirt.ssh_service.type | default(None) -%}
      {%- if svc_type == 'NodePort' -%}
        {{ (__kubevirt_node_port_services.results
            | selectattr('vm.name', '==', vm.name)
            | first)['resources'][0]['spec']['ports'][0]['nodePort'] }}
      {%- endif -%}
  ansible.builtin.set_fact:
    __kubevirt_molecule_systems: >-
      {{
        __kubevirt_molecule_systems | default({}) | combine({
          vm.name: {
            'ansible_user': vm.kubevirt.ansible_user,
            'ansible_host': __kubevirt_nodeport_host,
            'ansible_ssh_port': __kubevirt_ssh_service_port,
            'ansible_ssh_private_key_file': __kubevirt_ssh_key_path
          }
        })
      }}
```

---

## Task 3: KubeVirt provisioner — `tasks/create_vm.yml`

**Files:**
- Create: `extensions/molecule/provisioners/kubevirt/tasks/create_vm.yml`

This is the file with our three adaptations vs. devhost:

1. **No DataVolume branch** (cluster perms forbid it).
2. **`cpu_cores`** support (KubeVirt default of 1 vCPU is unusable).
3. **`scratch_disk_size`** support — when set, attach an `emptyDisk` and
   emit cloud-init `disk_setup`/`fs_setup`/`mounts` so it lands at
   `scratch_mount`.

**Step 1: Write the task**

```yaml
---
# Creates a KubeVirt VM using a containerDisk root.
#
# When `vm.kubevirt.scratch_disk_size` is set, an additional `emptyDisk`
# is attached as `/dev/vdb` and cloud-init formats and mounts it at
# `vm.kubevirt.scratch_mount` (xfs). Used for build scratch space when
# the cluster does not grant DataVolume/PVC create perms in the molecule
# namespace.
#
# Example platform entry:
#
#   kubevirt:
#     image: quay.io/containerdisks/centos-stream:10
#     namespace: molecule
#     ssh_service: { type: NodePort }
#     ansible_user: cloud-user
#     memory: 16Gi
#     cpu_cores: 8
#     scratch_disk_size: 100Gi
#     scratch_mount: /var/lib/armbian_build

- name: Create VM in KubeVirt
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: kubevirt.io/v1
      kind: VirtualMachine
      metadata:
        labels:
          kubevirt.io/domain: "{{ vm.name }}"
        name: "{{ vm.name }}"
        namespace: "{{ vm.kubevirt.namespace }}"
      spec:
        running: true
        template:
          metadata:
            labels:
              kubevirt.io/domain: "{{ vm.name }}"
          spec:
            domain:
              cpu:
                cores: "{{ vm.kubevirt.cpu_cores | default(1) | int }}"
              devices:
                disks:
                  - disk: { bus: virtio }
                    name: containerdisk
                  - "{{ {'disk': {'bus': 'virtio'}, 'name': 'scratchdisk'}
                        if vm.kubevirt.scratch_disk_size is defined else None }}"
                  - disk: { bus: virtio }
                    name: cloudinitdisk
              resources:
                requests:
                  memory: "{{ vm.kubevirt.memory | default('1Gi') }}"
            volumes:
              - name: containerdisk
                containerDisk:
                  image: "{{ vm.kubevirt.image }}"
              - "{{ {'name': 'scratchdisk',
                     'emptyDisk': {'capacity': vm.kubevirt.scratch_disk_size}}
                    if vm.kubevirt.scratch_disk_size is defined else None }}"
              - name: cloudinitdisk
                cloudInitNoCloud:
                  userData: |
                    #cloud-config
                    preserve_hostname: true
                    hostname: "{{ vm.name }}"
                    fqdn: "{{ vm.name }}"
                    prefer_fqdn_over_hostname: true
                    users:
                      - default
                      - name: {{ vm.kubevirt.ansible_user }}
                        lock_passwd: true
                        sudo: ALL=(ALL) NOPASSWD:ALL
                        ssh_authorized_keys:
                          - "{{ temporary_ssh_public_key }}"
                    packages:
                      - qemu-guest-agent
                    {% if vm.kubevirt.scratch_disk_size is defined %}
                    disk_setup:
                      /dev/vdb:
                        table_type: gpt
                        layout: true
                        overwrite: true
                    fs_setup:
                      - device: /dev/vdb
                        partition: 1
                        filesystem: xfs
                        label: scratch
                        overwrite: true
                    mounts:
                      - [LABEL=scratch, "{{ vm.kubevirt.scratch_mount | default('/var/lib/molecule-scratch') }}", xfs, "defaults,nofail", "0", "0"]
                    {% endif %}
                    runcmd:
                      - ["hostnamectl", "set-hostname", "{{ vm.name }}"]
                      - ["systemctl", "enable", "--now", "qemu-guest-agent"]

- name: Fetch VM pod info
  kubernetes.core.k8s_info:
    api_version: v1
    kind: Pod
    label_selectors:
      - "vm.kubevirt.io/name={{ vm.name }}"
    namespace: "{{ vm.kubevirt.namespace }}"
  register: __kubevirt_vm_pod_info
  until:
    - __kubevirt_vm_pod_info.resources | default([]) | length > 0
    - __kubevirt_vm_pod_info.resources[0].spec.nodeName is defined
  retries: 30
  delay: 5

- name: Extract the node name from the VM pod info
  ansible.builtin.set_fact:
    __kubevirt_nodeport_host: >-
      {{ __kubevirt_vm_pod_info.resources | map(attribute='spec.nodeName') | list | first }}
```

**Note on the `None`-filter trick**: KubeVirt's API server quietly drops
list elements that are `null`, so the conditional disk/volume entries
disappear when `scratch_disk_size` is unset without us needing to template
two separate VM specs. **Verify in Step 2** that this actually works
against the OCP API — if the API rejects `null` list entries, fall back
to two separate `kubernetes.core.k8s` tasks gated by `when:`.

**Step 2: Smoke-validate the spec template**

```bash
# Render in-place via ansible-inventory or a one-off ad-hoc run; also
# inspect the resulting VirtualMachine yaml with `kubectl get vm <name> -o yaml`
# after first scenario run.
```

If `null` entries fail, refactor `create_vm.yml` into two `kubernetes.core.k8s`
tasks, one with `when: vm.kubevirt.scratch_disk_size is defined` and one
without. Commit the refactor.

---

## Task 4: KubeVirt provisioner — `create.yml`

**Files:**
- Create: `extensions/molecule/provisioners/kubevirt/create.yml`

Adapted from devhost: drops the DataVolume readiness wait (we never use
DV); otherwise structurally identical (SSH keypair, loop create_vm,
NodePort services, build inventory dict, write inventory, refresh).

**Step 1: Write the playbook**

```yaml
---
- name: Create
  hosts: localhost
  connection: local
  gather_facts: false

  tasks:
    - name: Set default SSH key path
      ansible.builtin.set_fact:
        __kubevirt_ssh_key_path: "{{ molecule_ephemeral_directory }}/identity_file"

    - name: Generate SSH key pair
      community.crypto.openssh_keypair:
        path: "{{ __kubevirt_ssh_key_path }}"
        size: 2048
      register: __kubevirt_ssh_keypair

    - name: Set SSH public key
      ansible.builtin.set_fact:
        temporary_ssh_public_key: "{{ __kubevirt_ssh_keypair.public_key }}"

    - name: Create VM in KubeVirt
      ansible.builtin.include_tasks: tasks/create_vm.yml
      loop: "{{ molecule_yml.platforms }}"
      loop_control:
        loop_var: vm

    - name: Create NodePort services
      when: "vm.kubevirt.ssh_service.type | default('') == 'NodePort'"
      block:
        - name: Create SSH NodePort Kubernetes service
          kubernetes.core.k8s:
            state: present
            definition:
              apiVersion: v1
              kind: Service
              metadata:
                name: "{{ vm.name }}"
                namespace: "{{ vm.kubevirt.namespace }}"
              spec:
                ports:
                  - port: 22
                    protocol: TCP
                    targetPort: 22
                selector:
                  kubevirt.io/domain: "{{ vm.name }}"
                type: NodePort
          loop: "{{ molecule_yml.platforms }}"
          loop_control:
            loop_var: vm

        - name: Retrieve service info
          kubernetes.core.k8s_info:
            api_version: v1
            kind: Service
            name: "{{ vm.name }}"
            namespace: "{{ vm.kubevirt.namespace }}"
          loop: "{{ molecule_yml.platforms }}"
          loop_control:
            loop_var: vm
          register: __kubevirt_node_port_services

    - name: Create VM dictionary
      ansible.builtin.include_tasks: tasks/create_vm_dictionary.yml
      loop: "{{ molecule_yml.platforms }}"
      loop_control:
        loop_var: vm

    - name: Create Ansible inventory from dictionary
      vars:
        molecule_inventory:
          all:
            children:
              molecule:
                hosts: "{{ __kubevirt_molecule_systems }}"
      ansible.builtin.copy:
        content: "{{ molecule_inventory | to_nice_yaml }}"
        dest: "{{ molecule_ephemeral_directory }}/inventory/molecule_inventory.yml"
        mode: "0600"

    - name: Refresh inventory
      ansible.builtin.meta: refresh_inventory

    - name: Assert molecule group exists
      ansible.builtin.assert:
        that: "'molecule' in groups"
        fail_msg: "Molecule group was not found in inventory groups: {{ groups }}"
      run_once: true # noqa: run-once[task]
```

---

## Task 5: KubeVirt provisioner — `destroy.yml`, `prepare.yml`

**Files:**
- Create: `extensions/molecule/provisioners/kubevirt/destroy.yml`
- Create: `extensions/molecule/provisioners/kubevirt/prepare.yml`

**Step 1: Write `destroy.yml`** (copy from devhost; deletes VM + service)

**Step 2: Write `prepare.yml`** (copy from devhost; just `wait_for_connection`).

The provisioner-level prepare is intentionally generic — scenario-specific
prep (Docker install, etc.) lives in the scenario's `prepare.yml`.

---

## Task 6: Scenario — `extensions/molecule/armbian_build/molecule.yml`

**Files:**
- Create: `extensions/molecule/armbian_build/molecule.yml`

**Step 1: Write the file**

```yaml
---
# Real-build scenario for the armbian_build role on a KubeVirt VM.
# Manual / not-CI by design — wall time is dominated by the upstream
# Armbian kernel build and is measured in tens of minutes to hours.
dependency:
  name: galaxy
  options:
    requirements-file: extensions/molecule/provisioners/kubevirt/requirements.yml
    force: true
driver:
  name: default
  options:
    managed: true
    ansible_connection_options:
      connection: local
platforms:
  - name: armbian-builder
    kubevirt:
      image: quay.io/containerdisks/centos-stream:10
      namespace: ${MOLECULE_NAMESPACE:-molecule}
      ssh_service:
        type: NodePort
      ansible_user: cloud-user
      memory: 16Gi
      cpu_cores: 8
      scratch_disk_size: 100Gi
      scratch_mount: /var/lib/armbian_build
provisioner:
  name: ansible
  playbooks:
    create: ../provisioners/kubevirt/create.yml
    destroy: ../provisioners/kubevirt/destroy.yml
    prepare: prepare.yml
    converge: converge.yml
    verify: verify.yml
  inventory:
    links:
      group_vars: ../provisioners/kubevirt/group_vars/
verifier:
  name: ansible
scenario:
  name: armbian_build
  test_sequence:
    - dependency
    - syntax
    - create
    - prepare
    - converge
    - verify
    - destroy
```

**Note:** `prepare:` points at the scenario-local `prepare.yml`, which
*chains* the provisioner's prepare and then layers Docker/build-host setup.

---

## Task 7: Scenario — `prepare.yml`

**Files:**
- Create: `extensions/molecule/armbian_build/prepare.yml`

Two plays. The first does the provisioner-level prepare
(`wait_for_connection`); the second installs Docker and build prereqs.

**Step 1: Write the file**

```yaml
---
- name: Wait for VM SSH
  hosts: all
  gather_facts: false
  tasks:
    - name: Wait for the host to be reachable
      ansible.builtin.wait_for_connection:
        timeout: 300

- name: Prepare Armbian builder host
  hosts: all
  gather_facts: true
  become: true
  tasks:
    - name: Install dnf-plugins-core (for the docker-ce repo plugin)
      ansible.builtin.dnf:
        name: dnf-plugins-core
        state: present

    - name: Add docker-ce repo
      ansible.builtin.command:
        cmd: dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        creates: /etc/yum.repos.d/docker-ce.repo

    - name: Install Docker CE + build prerequisites
      ansible.builtin.dnf:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-buildx-plugin
          - docker-compose-plugin
          - xz
          - git
        state: present

    - name: Enable and start docker
      ansible.builtin.systemd:
        name: docker
        enabled: true
        state: started

    - name: Add cloud-user to docker group
      ansible.builtin.user:
        name: cloud-user
        groups: docker
        append: true

    - name: Reset SSH connection so cloud-user picks up the docker group
      ansible.builtin.meta: reset_connection

    - name: Verify Docker reachability as cloud-user
      ansible.builtin.command:
        cmd: docker info
      become: false
      changed_when: false
      register: _docker_info

    - name: Assert Docker info reports a running daemon
      ansible.builtin.assert:
        that:
          - _docker_info.rc == 0
          - "'Server Version' in _docker_info.stdout"
        fail_msg: >-
          docker info as cloud-user did not report a running daemon.
          Got rc={{ _docker_info.rc }} stdout={{ _docker_info.stdout | default('') }}
```

---

## Task 8: Scenario — `converge.yml`

**Files:**
- Create: `extensions/molecule/armbian_build/converge.yml`

**Step 1: Write the file**

```yaml
---
- name: Converge — build orangepi5pro Armbian image with PXE-first U-Boot
  hosts: all
  gather_facts: true
  become: false

  tasks:
    - name: Apply armbian_build role
      ansible.builtin.include_role:
        name: david_igou.armbian_netboot.armbian_build
      vars:
        armbian_build_board: orangepi5pro
        armbian_build_branch: current
        armbian_build_release: bookworm
        armbian_build_cache_dir: /var/lib/armbian_build
        armbian_build_output_dir: /var/lib/armbian_build/output
        armbian_build_userpatches:
          - dest: "config/boards/orangepi5pro.conf"
            content: |
              function pre_config_uboot_target__orangepi5pro_pxe_first() {
                  declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
                  sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                      include/configs/rockchip-common.h
              }
```

---

## Task 9: Scenario — `verify.yml`

**Files:**
- Create: `extensions/molecule/armbian_build/verify.yml`

**Step 1: Write the file**

```yaml
---
- name: Verify
  hosts: all
  gather_facts: false
  become: false
  vars:
    _output_dir: /var/lib/armbian_build/output/orangepi5pro
    _userpatch_path: /var/lib/armbian_build/build/userpatches/config/boards/orangepi5pro.conf

  tasks:
    - name: Find the produced .img.xz
      ansible.builtin.find:
        paths: "{{ _output_dir }}"
        patterns: "(?i)Armbian.*orangepi5pro.*\\.img\\.xz$"
        use_regex: true
      register: _image_files

    - name: Assert exactly one .img.xz was produced
      ansible.builtin.assert:
        that:
          - _image_files.files | length == 1
          - _image_files.files[0].size > 100 * 1024 * 1024
        fail_msg: >-
          Expected exactly one .img.xz larger than 100 MiB in {{ _output_dir }};
          found {{ _image_files.files | length }}
          ({{ _image_files.files | map(attribute='path') | list }})

    - name: Test image with `xz -t`
      ansible.builtin.command:
        cmd: "xz -t {{ _image_files.files[0].path }}"
      changed_when: false

    - name: Read manifest.json
      ansible.builtin.slurp:
        src: "{{ _output_dir }}/manifest.json"
      register: _manifest_raw

    - name: Parse manifest and assert schema
      vars:
        _manifest: "{{ _manifest_raw.content | b64decode | from_json }}"
      ansible.builtin.assert:
        that:
          - _manifest.image_filename is string and _manifest.image_filename | length > 0
          - _manifest.armbian_build_ref is string and _manifest.armbian_build_ref | length > 0
          - _manifest.patch_hash is string and _manifest.patch_hash | length > 0
        fail_msg: "manifest.json missing expected fields: {{ _manifest }}"

    - name: Stat the userpatch file
      ansible.builtin.stat:
        path: "{{ _userpatch_path }}"
      register: _userpatch_stat

    - name: Assert userpatch landed at the expected path with the expected hook
      ansible.builtin.assert:
        that:
          - _userpatch_stat.stat.exists
          - _userpatch_stat.stat.isreg

    - name: Slurp the userpatch contents
      ansible.builtin.slurp:
        src: "{{ _userpatch_path }}"
      register: _userpatch_raw

    - name: Assert userpatch contents
      ansible.builtin.assert:
        that:
          - "'pre_config_uboot_target__orangepi5pro_pxe_first' in (_userpatch_raw.content | b64decode)"

    - name: Print verification summary
      ansible.builtin.debug:
        msg:
          - "Image: {{ _image_files.files[0].path }}"
          - "Size: {{ (_image_files.files[0].size / 1024 / 1024) | round(1) }} MiB"
          - "Manifest: {{ (_manifest_raw.content | b64decode | from_json) }}"
```

---

## Task 10: Update Makefile

**Files:**
- Modify: `Makefile`

**Step 1: Update `MOLECULE_SCENARIOS`** to include `armbian_build`.

**Step 2: Add `molecule-kubevirt` target**

```make
molecule-kubevirt: ## Run molecule test against kubevirt (SCENARIO=armbian_build)
	PROVISIONER=kubevirt molecule test -s $(or $(SCENARIO),armbian_build)
```

Add `molecule-kubevirt` to `.PHONY`.

---

## Task 11: Validate

**Step 1: Syntax-check the new playbooks**

```bash
ansible-playbook --syntax-check extensions/molecule/provisioners/kubevirt/create.yml
ansible-playbook --syntax-check extensions/molecule/provisioners/kubevirt/destroy.yml
ansible-playbook --syntax-check extensions/molecule/provisioners/kubevirt/prepare.yml
ansible-playbook --syntax-check extensions/molecule/armbian_build/prepare.yml
ansible-playbook --syntax-check extensions/molecule/armbian_build/converge.yml
ansible-playbook --syntax-check extensions/molecule/armbian_build/verify.yml
```

Expected: each prints "playbook: <path>" with no syntax errors.

**Step 2: Lint**

```bash
ansible-lint extensions/molecule/
```

Expected: no errors. Warnings about hardcoded namespaces or kubevirt
specifics are OK.

**Step 3: Optional — molecule create/destroy smoke**

If KUBECONFIG is reachable from this dev container and the SA can talk
to the cluster, run a destroy-only sanity check first to ensure no
leftover resources, then a `molecule create -s armbian_build` to spin
the VM (without converging the long build) and confirm SSH lands.

```bash
molecule create -s armbian_build      # spin VM, run prepare, stop short of converge
molecule destroy -s armbian_build      # tear down
```

If converge is to be exercised in the same session, expect 30–90 min wall
time. Skip in this scaffolding PR; document the manual run command in
the scenario directory's commit message.
