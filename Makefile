SHELL := bash

SCRIPT_FILES := $(shell find . -type f -name '*.sh' -not -path './.git/*' | sort)
SOURCE_SCRIPT_FILES := $(filter-out ./networking/xray-install.sh,$(SCRIPT_FILES))
# Expand this baseline as legacy scripts are formatted. ShellCheck still covers all source scripts.
FORMAT_FILES := ./hestiash/hestia_rclone_backup.sh ./networking/xray/build.sh ./sql_manage.sh
YAML_FILES := $(shell find . -type f \( -name '*.yml' -o -name '*.yaml' \) -not -path './.git/*' | sort)
WORKFLOW_FILES := $(shell find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
XRAY_BUILD := networking/xray/build.sh

.PHONY: check syntax lint format-check yaml-lint actionlint xray-build xray-check list-scripts list-lint-files

check: xray-check syntax lint format-check yaml-lint actionlint

xray-build:
	@$(XRAY_BUILD)

xray-check:
	@$(XRAY_BUILD) --check

syntax:
	@for file in $(SCRIPT_FILES); do \
		bash -n "$$file"; \
	done
	@echo "Bash syntax OK"

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck --shell=bash --severity=error $(SOURCE_SCRIPT_FILES); \
	else \
		echo "shellcheck not installed; skipped local lint"; \
	fi

format-check:
	@if command -v shfmt >/dev/null 2>&1; then \
		shfmt -d -i 4 -ci -bn $(FORMAT_FILES); \
	else \
		echo "shfmt not installed; skipped local format check"; \
	fi

yaml-lint:
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint $(YAML_FILES); \
	else \
		echo "yamllint not installed; skipped local YAML lint"; \
	fi

actionlint:
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint $(WORKFLOW_FILES); \
	else \
		echo "actionlint not installed; skipped local workflow lint"; \
	fi

list-scripts:
	@printf '%s\n' $(SCRIPT_FILES)

list-lint-files:
	@printf '%s\n' $(SOURCE_SCRIPT_FILES)
