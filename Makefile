COLLECTION_NAMESPACE := david_igou
COLLECTION_NAME      := armbian_netboot
COLLECTION           := $(COLLECTION_NAMESPACE).$(COLLECTION_NAME)
COLLECTION_VERSION   := $(shell grep '^version:' galaxy.yml | awk '{print $$2}')

MOLECULE_SCENARIOS := default rootfs_clone pxelinux_render image_build local_kernel_render
PROVISIONER ?= podman

.PHONY: help install lint yamllint ansible-lint molecule molecule-kubevirt test collection-build collection-install galaxy-import clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

install: ## Install external collection dependencies
	ansible-galaxy collection install -r requirements.yml

lint: yamllint ansible-lint ## Run yamllint and ansible-lint (installs collections first)

yamllint: ## Run yamllint on roles/, playbooks/, inventory/
	yamllint -c .yamllint.yml roles/ playbooks/ inventory/

# ansible-lint depends on install: with mock_modules removed from
# .ansible-lint (to stop it clobbering real modules), the collections
# referenced by the playbooks must be present at lint time.
ansible-lint: install ## Run ansible-lint on roles/ and playbooks/
	ansible-lint playbooks/ roles/

molecule: ## Run molecule test (SCENARIO=default PROVISIONER=podman)
	PROVISIONER=$(PROVISIONER) molecule test -s $(or $(SCENARIO),default)

molecule-kubevirt: ## Run molecule test against kubevirt (SCENARIO=image_build)
	PROVISIONER=kubevirt molecule test -s $(or $(SCENARIO),image_build)

test: lint molecule ## Run lint then molecule

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
