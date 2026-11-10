#!/usr/bin/env bash
set -euo pipefail
collection_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
export ANSIBLE_COLLECTIONS_PATH="${collection_root}/.ansible/collections"
export ANSIBLE_CONFIG="${collection_root}/ansible.cfg"
artifact_directory="${MOLECULE_EPHEMERAL_DIRECTORY:?}/artifacts"
mkdir -p "$artifact_directory"
rm -f "${artifact_directory}"/david_igou-armbian-*.tar.gz
ansible-galaxy collection install -r "${collection_root}/extensions/molecule/requirements-test.yml"
ansible-galaxy collection build "$collection_root" --output-path "$artifact_directory" --force
ansible-galaxy collection install "${artifact_directory}"/david_igou-armbian-*.tar.gz --force --no-deps
