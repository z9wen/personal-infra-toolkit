SHELL := bash

SCRIPT_FILES := $(shell find . -type f -name '*.sh' -not -path './.git/*' | sort)
LINT_FILES := acme_manage.sh copy_user_key_to_root.sh fix_acme_serverauth.sh sql_manage.sh

.PHONY: check syntax lint list-scripts list-lint-files

check: syntax lint

syntax:
	@for file in $(SCRIPT_FILES); do \
		bash -n "$$file"; \
	done
	@echo "Bash syntax OK"

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(LINT_FILES); \
	else \
		echo "shellcheck not installed; skipped local lint"; \
	fi

list-scripts:
	@printf '%s\n' $(SCRIPT_FILES)

list-lint-files:
	@printf '%s\n' $(LINT_FILES)
