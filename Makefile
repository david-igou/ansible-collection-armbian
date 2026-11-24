COLLECTION_NAMESPACE := david_igou
COLLECTION_NAME      := armbian

# Scenarios live at extensions/molecule/<scenario>/molecule.yml. Run from the
# collection root so molecule also finds extensions/molecule/config.yml.
export MOLECULE_GLOB := extensions/molecule/*/molecule.yml

# A dev shell's ANSIBLE_INVENTORY would override the scenario inventories.
unexport ANSIBLE_INVENTORY

.PHONY: help install lint yamllint ansible-lint molecule collection-build collection-install clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Install the runtime and test collection dependencies
	ansible-galaxy collection install -r requirements.yml
	ansible-galaxy collection install -r extensions/molecule/requirements-test.yml

lint: yamllint ansible-lint ## Run yamllint and ansible-lint over the repository

yamllint: ## Run yamllint over the repository
	yamllint -c .yamllint.yml .

ansible-lint: install ## Run ansible-lint over the repository
	ansible-lint

molecule: ## Run molecule (SCENARIO=<name> for one scenario, all otherwise)
	molecule test $(if $(SCENARIO),-s $(SCENARIO),--all --continue-on-failure) --report

collection-build: ## Build the collection tarball
	ansible-galaxy collection build --force

collection-install: collection-build ## Build and install the collection locally
	ansible-galaxy collection install $(COLLECTION_NAMESPACE)-$(COLLECTION_NAME)-*.tar.gz --force

clean: ## Remove build artefacts
	rm -f $(COLLECTION_NAMESPACE)-$(COLLECTION_NAME)-*.tar.gz
