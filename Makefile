VENV := .venv
PYTHON ?= python3
PIP := $(VENV)/bin/pip
ANSIBLE := $(VENV)/bin/ansible
ANSIBLE_PLAYBOOK := $(VENV)/bin/ansible-playbook
ANSIBLE_LINT := $(VENV)/bin/ansible-lint
GALAXY := $(VENV)/bin/ansible-galaxy
INVENTORY ?= inventories/hosts.yml

.DEFAULT_GOAL := help

.PHONY: help install inventory ping syntax lint check deploy verify idempotency

help:
	@printf '%s\n' \
		'make install       Install the controller-side Ansible environment' \
		'make inventory     Create an ignored inventory from the example' \
		'make ping          Verify SSH and Python access to all targets' \
		'make syntax        Run the Ansible syntax check' \
		'make lint          Run ansible-lint' \
		'make check         Run syntax and lint checks' \
		'make deploy        Converge the complete Cloud-1 deployment' \
		'make verify        Run remote deployment assertions' \
		'make idempotency   Converge twice, then run verification'

$(VENV)/bin/ansible-playbook: requirements-controller.txt requirements.yml
	$(PYTHON) -c 'import sys; sys.exit("Cloud-1 requires Python 3.12-3.14 for Ansible Core 2.20.") if not ((3, 12) <= sys.version_info[:2] < (3, 15)) else None'
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/python -c 'import sys; sys.exit("Existing .venv does not use Python 3.12-3.14; remove it and rerun make install.") if not ((3, 12) <= sys.version_info[:2] < (3, 15)) else None'
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements-controller.txt
	$(GALAXY) collection install -r requirements.yml
	@touch $@

install: $(VENV)/bin/ansible-playbook

inventory:
	@if test -e $(INVENTORY); then \
		echo "$(INVENTORY) already exists"; \
	else \
		cp inventories/hosts.example.yml $(INVENTORY); \
		echo "Created $(INVENTORY); replace the example host and domain before deploying."; \
	fi

ping: install
	@test -f $(INVENTORY)
	$(ANSIBLE) cloud1 -i $(INVENTORY) -m ansible.builtin.ping

syntax: install
	@test -f $(INVENTORY)
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/site.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/verify.yml --syntax-check

lint: install
	$(ANSIBLE_LINT) playbooks roles

check: syntax lint

deploy: install
	@test -f $(INVENTORY)
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/site.yml

verify: install
	@test -f $(INVENTORY)
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/verify.yml

idempotency: deploy
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/site.yml
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/verify.yml
