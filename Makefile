.PHONY: all build run test test-release release fmt fmt-check clean help \
        setup-windows build-windows build-windows-debug \
        nats-up nats-down nats-logs pg-up pg-down pg-logs pg-psql \
        services-up services-down \
        cell-mgr cell-mgr-harness ship-sim gateway

all: build

build:
	zig build

run:
	zig build run

test:
	zig build test

# ReleaseFast tests — needed to verify perf gates that are skipped in
# Debug (e.g. M6.1's filter <500 ns / clustering <100 µs targets).
test-release:
	zig build test -Doptimize=ReleaseFast --summary all

release:
	zig build -Doptimize=ReleaseFast

fmt:
	zig fmt build.zig src

fmt-check:
	zig fmt --check build.zig src

clean:
	rm -rf zig-out .zig-cache

# -----------------------------------------------------------------------------
# Windows builds (cross-compile from Linux, or native on a Windows host).
# Recipes use `python` rather than `python3` so they work on both Arch and
# stock Windows Python installs. The build.zig itself prints a friendly
# error if vulkan-1.lib is missing — no separate dep-check recipe needed.
# -----------------------------------------------------------------------------

setup-windows:
	@python scripts/fetch_windows_deps.py

build-windows:
	zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

build-windows-debug:
	zig build -Dtarget=x86_64-windows

# -----------------------------------------------------------------------------
# Phase 1 services (M6.3+). Dev NATS broker runs in podman as a single
# container. infra/compose.yml documents the canonical declarative shape but
# we drive it through plain `podman run` to skip the podman-compose dep.
# Keep the two in sync if you change image / ports / args.
# -----------------------------------------------------------------------------

PODMAN ?= podman
NATS_NAME ?= notatlas-nats
NATS_IMAGE ?= docker.io/nats:2.14
NATS_VOLUME ?= notatlas_nats_data

nats-up:
	@$(PODMAN) container exists $(NATS_NAME) && \
	    $(PODMAN) start $(NATS_NAME) >/dev/null || \
	    $(PODMAN) run -d --name $(NATS_NAME) \
	        --network host \
	        -v $(NATS_VOLUME):/data \
	        $(NATS_IMAGE) \
	        --name=notatlas-dev --http_port=8222 \
	        --jetstream --store_dir=/data/jetstream
	@echo "nats listening on 127.0.0.1:4222 (monitor on :8222)"

nats-down:
	-@$(PODMAN) stop $(NATS_NAME) >/dev/null 2>&1
	-@$(PODMAN) rm $(NATS_NAME) >/dev/null 2>&1
	@echo "nats stopped"

nats-logs:
	$(PODMAN) logs -f $(NATS_NAME)

# Postgres dev instance — sole writer is persistence-writer per locked
# architecture decision 5. Schema in infra/db/init.sql is auto-applied
# on first start (when the named volume is empty).
PG_NAME ?= notatlas-pg
PG_IMAGE ?= docker.io/postgres:16-alpine
PG_VOLUME ?= notatlas_pg_data
PG_USER ?= notatlas
PG_PASS ?= notatlas
PG_DB ?= notatlas

pg-up:
	@$(PODMAN) container exists $(PG_NAME) && \
	    $(PODMAN) start $(PG_NAME) >/dev/null || \
	    $(PODMAN) run -d --name $(PG_NAME) \
	        --network host \
	        -e POSTGRES_USER=$(PG_USER) \
	        -e POSTGRES_PASSWORD=$(PG_PASS) \
	        -e POSTGRES_DB=$(PG_DB) \
	        -v $(PG_VOLUME):/var/lib/postgresql/data \
	        -v $(CURDIR)/infra/db/init.sql:/docker-entrypoint-initdb.d/00-schema.sql:ro \
	        $(PG_IMAGE)
	@echo "postgres listening on 127.0.0.1:5432 (user=$(PG_USER) db=$(PG_DB))"

pg-down:
	-@$(PODMAN) stop $(PG_NAME) >/dev/null 2>&1
	-@$(PODMAN) rm $(PG_NAME) >/dev/null 2>&1
	@echo "postgres stopped"

pg-logs:
	$(PODMAN) logs -f $(PG_NAME)

pg-psql:
	$(PODMAN) exec -it $(PG_NAME) psql -U $(PG_USER) -d $(PG_DB)

services-up: nats-up pg-up

services-down: nats-down pg-down

cell-mgr:
	zig build cell-mgr -- $(ARGS)

cell-mgr-harness:
	zig build cell-mgr-harness -- $(ARGS)

ship-sim:
	zig build ship-sim -- $(ARGS)

gateway:
	zig build gateway -- $(ARGS)

help:
	@echo "make build               — debug build"
	@echo "make run                 — debug build + run sandbox"
	@echo "make test                — run unit tests"
	@echo "make test-release        — run unit tests in ReleaseFast (verifies perf gates)"
	@echo "make release             — ReleaseFast build"
	@echo "make fmt                 — format all sources"
	@echo "make fmt-check           — verify formatting (non-zero on diff)"
	@echo "make clean               — remove zig-out and .zig-cache"
	@echo "make setup-windows       — download vulkan-1.lib for Windows cross-compile"
	@echo "make build-windows       — cross-compile sandbox.exe (ReleaseSafe)"
	@echo "make build-windows-debug — cross-compile sandbox.exe (Debug)"
	@echo "make nats-up             — start dev nats-server in podman"
	@echo "make nats-down           — stop the dev nats-server"
	@echo "make nats-logs           — tail the dev nats-server logs"
	@echo "make pg-up               — start dev postgres in podman"
	@echo "make pg-down             — stop the dev postgres"
	@echo "make pg-logs             — tail the dev postgres logs"
	@echo "make pg-psql             — open psql shell in the dev postgres"
	@echo "make services-up         — start nats + postgres"
	@echo "make services-down       — stop nats + postgres"
	@echo "make cell-mgr            — run cell-mgr (pass args via ARGS=...)"
	@echo "make cell-mgr-harness    — run cell-mgr-harness (pass args via ARGS=...)"
	@echo "make ship-sim            — run ship-sim (pass args via ARGS=...)"
	@echo "make gateway             — run gateway (pass args via ARGS=...)"
