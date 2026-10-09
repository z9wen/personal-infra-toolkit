SHELL := bash

SCRIPT_FILES := $(shell find . -type f -name '*.sh' -not -path './.git/*' -not -path '*/.terraform/*' | sort)
# Xray modules share globals across files, so they are linted as one freshly
# assembled installer. The committed networking/xray-install.sh is generated
# by CI and is not linted or edited locally.
XRAY_MODULES := $(filter ./networking/xray/src/%,$(SCRIPT_FILES))
LINT_FILES := $(filter-out $(XRAY_MODULES) ./networking/xray-install.sh,$(SCRIPT_FILES))
# The installer is generated, so formatting is checked on its sources instead.
FORMAT_FILES := $(filter-out ./networking/xray-install.sh,$(SCRIPT_FILES))
YAML_FILES := $(shell find . -type f \( -name '*.yml' -o -name '*.yaml' \) -not -path './.git/*' -not -path '*/.terraform/*' | sort)
WORKFLOW_FILES := $(shell find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
XRAY_BUILD := networking/xray/build.sh
TEST_FILES := $(shell find . -type f -path '*/tests/test_*.sh' -not -path './.git/*' | sort)
PYTHON_FILES := $(shell find . -type f -name '*.py' -not -path './.git/*' -not -path '*/.terraform/*' | sort)
TERRAFORM_DIRS := aws/terraform/bootstrap aws/terraform/app azure/terraform

.PHONY: check syntax lint format-check yaml-lint actionlint test python-test python-lint terraform-check xray-build xray-check xray-e2e list-scripts list-lint-files

check: syntax lint python-lint format-check yaml-lint actionlint test terraform-check

xray-build:
	@$(XRAY_BUILD)

xray-check:
	@$(XRAY_BUILD) --check

# Needs Docker and network access; downloads the latest stable and pre-release cores.
xray-e2e:
	@networking/xray/tests/e2e/run.sh

syntax:
	@for file in $(SCRIPT_FILES); do \
		bash -n "$$file"; \
	done
	@echo "Bash syntax OK"
	@python3 -m py_compile $(PYTHON_FILES)
	@echo "Python syntax OK"

test: python-test
	@for file in $(TEST_FILES); do \
		echo "==> $$file"; \
		bash "$$file" || exit 1; \
	done

python-test:
	@if python3 -c 'import pytest' >/dev/null 2>&1; then \
		python3 -m pytest -q -p no:cacheprovider aws/app/tests tools/tests; \
	else \
		echo "pytest not installed; skipped Python tests (pip install -r requirements-dev.txt)"; \
	fi

python-lint:
	@if command -v ruff >/dev/null 2>&1; then \
		ruff check --no-cache --select E,F,W,B --ignore E501 $(PYTHON_FILES); \
	else \
		echo "ruff not installed; skipped Python lint (pip install -r requirements-dev.txt)"; \
	fi

terraform-check:
	@if command -v terraform >/dev/null 2>&1; then \
		terraform fmt -check -recursive aws azure && \
		for dir in $(TERRAFORM_DIRS); do \
			echo "==> terraform validate $$dir"; \
			terraform -chdir="$$dir" init -backend=false -input=false >/dev/null && \
			terraform -chdir="$$dir" validate -no-color || exit 1; \
		done; \
	else \
		echo "terraform not installed; skipped Terraform checks"; \
	fi

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		bundle=$$(mktemp -d) && trap 'rm -rf "$$bundle"' EXIT && \
		XRAY_BUILD_OUTPUT="$$bundle/xray-install.sh" $(XRAY_BUILD) >/dev/null && \
		shellcheck --shell=bash --severity=warning $(LINT_FILES) "$$bundle/xray-install.sh"; \
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
	@printf '%s\n' $(LINT_FILES)
