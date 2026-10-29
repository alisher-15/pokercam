# Commands from CLAUDE.md. Toolchain: Python 3.12, Node 24, Flutter 3.47, Docker with compose.
SHELL := /bin/bash
.DEFAULT_GOAL := help

# Pass the settings from .env (if there is one) to docker compose, the backend and its tests.
-include .env
export $(shell sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' .env 2>/dev/null)

PYTHON ?= python3.12
VENV := backend/.venv
APPS := apps/shared apps/camera_android apps/viewer_windows

.PHONY: help setup setup-backend setup-node setup-apps dev down logs db keys seed acceptance acceptance-dvr load-test \
	test test-contracts test-backend test-media-server test-apps \
	lint lint-backend lint-media-server lint-tools lint-apps codegen l10n check-generated

help: ## List the commands
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

setup: setup-backend setup-node setup-apps ## Install every component's dependencies

setup-backend:
	test -x $(VENV)/bin/python || $(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -q -r backend/requirements-dev.txt

setup-node:
	cd contracts && npm ci --no-audit --no-fund
	cd media-server && npm ci --no-audit --no-fund
	cd tools && npm ci --no-audit --no-fund

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

keys: ## Print fresh secrets for .env (production needs them)
	cd backend && .venv/bin/python -m app.cli gen-keys

seed: ## Demo brand, client with a paid month, one table; admin from ADMIN_EMAIL / ADMIN_PASSWORD
	docker compose exec backend python -m app.cli seed

acceptance: ## Against `make dev`: a fake camera and MAX_VIEWERS_PER_TABLE fake viewers (stage 3)
	key=$$(docker compose exec -T backend python -m app.cli create-client "Acceptance $$(date +%s)") && \
	cd tools && node acceptance/stage3.ts --key "$$key" --viewers $${MAX_VIEWERS_PER_TABLE:-5}

acceptance-dvr: ## Against `make dev`: DVR for DVR_MINUTES (11) min, FFmpeg killed, access, expired license (stage 4)
	docker compose exec -T backend python -m app.cli create-admin "$$ADMIN_EMAIL" "$$ADMIN_PASSWORD" > /dev/null && \
	key=$$(docker compose exec -T backend python -m app.cli create-client "DVR $$(date +%s)") && \
	other=$$(docker compose exec -T backend python -m app.cli create-client "DVR other $$(date +%s)") && \
	cd tools && node acceptance/stage4.ts --key "$$key" --other-key "$$other" --minutes $${DVR_MINUTES:-11} \
		--segments $${DVR_SEGMENTS:-600} --ffmpeg-container media-server \
		--license-wait $$(( $${LICENSE_CHECK_INTERVAL_S:-600} + 30 ))

load-test: ## Against `make dev`: LOAD_TABLES × LOAD_VIEWERS bots for LOAD_MINUTES, memory/CPU/losses (SPEC 7.4)
	key=$$(docker compose exec -T backend python -m app.cli create-client "Load $$(date +%s)" --tables $${LOAD_TABLES:-1}) && \
	container=$$(docker compose ps -q media-server) && \
	cd tools && node load_test/index.ts --key "$$key" --tables $${LOAD_TABLES:-1} --viewers $${LOAD_VIEWERS:-1} \
		--duration $${LOAD_MINUTES:-60} --server-container "$$container"

test: db test-contracts test-backend test-media-server test-apps ## All tests of all components

test-contracts:
	cd contracts && npm test

test-backend:
	cd backend && .venv/bin/pytest

test-media-server:
	cd media-server && npm test

test-apps:
	for app in $(APPS); do (cd $$app && flutter test) || exit 1; done

lint: lint-backend lint-media-server lint-tools lint-apps ## Linters: ruff, eslint + tsc, dart format + analyze

lint-backend:
	cd backend && .venv/bin/ruff check . && .venv/bin/ruff format --check .

lint-media-server:
	cd media-server && npm run lint && npm run typecheck

lint-tools:
	cd tools && npm run lint && npm run typecheck

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
