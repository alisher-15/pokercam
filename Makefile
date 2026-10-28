# Commands from CLAUDE.md. Toolchain: Python 3.12, Node 24, Flutter 3.47, Docker with compose.
SHELL := /bin/bash
.DEFAULT_GOAL := help

-include .env
export

PYTHON ?= python3.12
VENV := backend/.venv
APPS := apps/shared apps/camera_android apps/viewer_windows

.PHONY: help setup setup-backend setup-node setup-apps dev down logs db \
	test test-contracts test-backend test-media-server test-apps \
	lint lint-backend lint-media-server lint-apps codegen l10n check-generated

help: ## List the commands
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

setup: setup-backend setup-node setup-apps ## Install every component's dependencies

setup-backend:
	test -x $(VENV)/bin/python || $(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -q -r backend/requirements-dev.txt

setup-node:
	cd contracts && npm ci --no-audit --no-fund
	cd media-server && npm ci --no-audit --no-fund

setup-apps:
	for app in $(APPS); do (cd $$app && flutter pub get) || exit 1; done

dev: ## Start postgres, backend and media-server in docker compose
	docker compose up -d --build --wait

down: ## Stop docker compose
	docker compose down

logs: ## Follow docker compose logs
	docker compose logs -f

db: ## Start only postgres (for backend tests)
	docker compose up -d --wait postgres

test: db test-contracts test-backend test-media-server test-apps ## All tests of all components

test-contracts:
	cd contracts && npm test

test-backend:
	cd backend && .venv/bin/pytest

test-media-server:
	cd media-server && npm test

test-apps:
	for app in $(APPS); do (cd $$app && flutter test) || exit 1; done

lint: lint-backend lint-media-server lint-apps ## Linters: ruff, eslint + tsc, dart format + analyze

lint-backend:
	cd backend && .venv/bin/ruff check . && .venv/bin/ruff format --check .

lint-media-server:
	cd media-server && npm run lint && npm run typecheck

lint-apps:
	dart format --output=none --set-exit-if-changed $(addsuffix /lib,$(APPS)) $(addsuffix /test,$(APPS))
	for app in $(APPS); do (cd $$app && flutter analyze) || exit 1; done

codegen: ## Regenerate types from contracts/ for Dart, TypeScript and Python
	PYTHON=$(CURDIR)/$(VENV)/bin/python contracts/scripts/codegen.sh

l10n: ## Regenerate localizations from apps/shared/lib/l10n/*.arb
	cd apps/shared && flutter gen-l10n && dart format lib/l10n > /dev/null

check-generated: codegen l10n ## Fail if generated files differ from what is committed
	git add --intent-to-add --all
	git diff --exit-code
