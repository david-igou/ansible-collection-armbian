.PHONY: help install lint yamllint ansible-lint clean

COLLECTION_NAMESPACE := david_igou
COLLECTION_NAME      := armbian_netboot
COLLECTION_VERSION   := $(shell grep '^version:' galaxy.yml | awk '{print $$2}')

help:
	@echo "david_igou.armbian_netboot — available targets:"
	@echo ""
	@echo "  install       Install external collection dependencies"
	@echo "  lint          Run yamllint + ansible-lint"
	@echo "  yamllint      Run yamllint on roles/, playbooks/, inventory/"
	@echo "  ansible-lint  Run ansible-lint on roles/ and playbooks/"
	@echo "  build         Build the collection tarball"
	@echo "  clean         Remove build artefacts"

install:
	ansible-galaxy collection install -r requirements.yml

lint: yamllint ansible-lint

yamllint:
	yamllint -c .yamllint.yml roles/ playbooks/ inventory/

ansible-lint:
	ansible-lint playbooks/ roles/

build:
	ansible-galaxy collection build --force

clean:
	rm -f $(COLLECTION_NAMESPACE)-$(COLLECTION_NAME)-*.tar.gz
