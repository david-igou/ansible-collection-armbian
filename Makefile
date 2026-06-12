COLLECTION_NAMESPACE := david_igou
COLLECTION_NAME      := armbian
COLLECTION           := $(COLLECTION_NAMESPACE).$(COLLECTION_NAME)
COLLECTION_VERSION   := $(shell grep '^version:' galaxy.yml | awk '{print $$2}')

# Molecule scenarios are discovered from extensions/molecule/*/ via
# MOLECULE_GLOB below; there is deliberately no hardcoded scenario list
# here to drift out of date.

# PROVISIONER picks which mp.<backend> block to use when a scenario's
# inventory declares more than one. Most scenarios declare only one
# backend, so leaving this unset is correct — molecule_provisioners
# auto-selects. Override only for scenarios with multiple backends
# (e.g. `PROVISIONER=podman make molecule SCENARIO=<dual-backend>`).
# Do NOT default this to a single backend at the Makefile level:
# forcing PROVISIONER=podman on a qemu-only scenario errors with
# "Host 'instance' is missing mp.podman in inventory".

# Scenarios live at extensions/molecule/<scenario>/molecule.yml — point
# molecule at that layout via MOLECULE_GLOB so the `molecule` target
# works from the collection root and auto-discovers the shared base
# config at extensions/molecule/config.yml.
export MOLECULE_GLOB := extensions/molecule/*/molecule.yml

# The dev shell (igou-devenv) exports ANSIBLE_INVENTORY=.inventory so
# ad-hoc ansible-playbook runs use the real inventory. That env var
# leaks into molecule's subprocess and overrides per-scenario inventory
# in subtle ways. Strip it from any target that shells out to ansible.
unexport ANSIBLE_INVENTORY

.PHONY: help install install-lint lint yamllint ansible-lint molecule molecule-kubevirt test test-build-image-vars collection-build collection-install galaxy-import clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

install: ## Install runtime collection dependencies (roles/ only)
	ansible-galaxy collection install -r requirements.yml

# Lint covers both roles/ and the top-level + reference playbooks
# under playbooks/, which reference community.routeros and
# ansible.netcommon (via diagnostic_bundle.yml, test_*_e2e.yml, etc.).
# Those collections deliberately are not in the runtime requirements
# — install them only at lint time. playbooks/routeros/ itself is
# excluded via .ansible-lint exclude_paths.
install-lint: install ## Install everything ansible-lint needs (runtime + routeros deps)
	ansible-galaxy collection install -r playbooks/routeros/requirements.yml

lint: yamllint ansible-lint ## Run yamllint and ansible-lint (installs collections first)

yamllint: ## Run yamllint on roles/, playbooks/, inventory/
	yamllint -c .yamllint.yml roles/ playbooks/ inventory/

ansible-lint: install-lint ## Run ansible-lint on roles/ and playbooks/
	ansible-lint playbooks/ roles/

molecule: ## Run molecule test (SCENARIO=<name> for one, omit for --all)
	molecule test \
		$(if $(SCENARIO),-s $(SCENARIO),--all --continue-on-failure) \
		--report

molecule-kubevirt: ## Run molecule test against kubevirt (SCENARIO=image_build)
	PROVISIONER=kubevirt molecule test -s $(or $(SCENARIO),image_build)

test-build-and-publish-vars: ## Run the localhost-only build_and_publish_from_inventory vars contract test
	ansible-playbook -i inventory/ playbooks/tests/test_build_and_publish_vars.yml

test: lint test-build-and-publish-vars molecule ## Run lint, build_and_publish vars contract test, and molecule

collection-build: ## Build the collection tarball
	ansible-galaxy collection build --force

collection-install: collection-build ## Build and install the collection locally
	ansible-galaxy collection install $(COLLECTION_NAMESPACE)-$(COLLECTION_NAME)-*.tar.gz --force

galaxy-import: ## Run galaxy-importer locally (pip install galaxy-importer)
	@printf '[galaxy-importer]\nCHECK_REQUIRED_TAGS=True\n' > /tmp/galaxy-importer.cfg
	GALAXY_IMPORTER_CONFIG=/tmp/galaxy-importer.cfg \
		python3 -m galaxy_importer.main --git-clone-path . --output-path /tmp

clean: ## Remove build artefacts
	rm -f $(COLLECTION_NAMESPACE)-$(COLLECTION_NAME)-*.tar.gz
