.PHONY: build up down logs seed seed-financial restart api-map status backup-openbao reset-2fa test gate-elixir gate-python test-elixir test-failed test-stale test-python test-unit test-integration test-adversarial test-stress

build:
	docker compose build --build-arg BUILD_NUMBER=$$(git rev-list --count HEAD 2>/dev/null || echo 0)

up: build
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f alexclaw-prod

restart:
	docker compose restart alexclaw-prod

seed:
	docker compose exec alexclaw-prod bin/alex_claw rpc \
		'Path.wildcard("lib/alex_claw-*/priv/repo/seeds/example_workflows.exs") |> hd() |> Code.eval_file()'

seed-financial:
	docker compose exec alexclaw-prod bin/alex_claw rpc \
		'Path.wildcard("lib/alex_claw-*/priv/repo/seeds/financial_workflows.exs") |> hd() |> Code.eval_file()'

# Regenerates local-docs/API_MAP.md (local, not in the repository) from lib/.
api-map:
	docker compose -f docker-compose.test.yml run --rm --no-deps -v "$$PWD/lib:/app/lib" -v "$$PWD/mix.exs:/app/mix.exs:ro" -v "$$PWD/.git:/app/.git:ro" -v "$$PWD/local-docs:/app/local-docs" tools mix alex_claw.api_map

# Production containers, the test stack, stray containers from this repository's
# images, and make/mix/docker processes started from this checkout. Exits 1 when
# anything besides production is running. See scripts/status.sh.
status:
	@./scripts/status.sh

# Turns the admin's second factor off when the authenticator AND every recovery
# code are lost: asks for RESET, then runs in the live node. See scripts/reset-2fa.sh.
reset-2fa:
	./scripts/reset-2fa.sh

# OpenBao's raft snapshot, next to the database backups, mode 600, checked.
# REASON names it (default "manual"). See scripts/backup-openbao.sh.
backup-openbao:
	./scripts/backup-openbao.sh $(REASON)

test-down:
	docker compose -f docker-compose.test.yml down

test: test-elixir test-python

# Both suites run under a hard time limit (TEST_TIME_LIMIT, default 2400s), with
# a kept log in local-docs/test-logs/ and a progress line every 30s; the Elixir
# run is also dumped and stopped when no test has started after 120s. See
# scripts/test-limits.sh, scripts/test-elixir.sh and scripts/test-python.sh.
# The whole suites, as gates only (.claude/rules/20-tests.md). make test-elixir
# with no FILES= and make test-python refuse a full run.
gate-elixir:
	./scripts/gate-elixir.sh

gate-python:
	./scripts/gate-python.sh

test-elixir:
	./scripts/test-elixir.sh $(FILES)

test-failed:
	./scripts/test-elixir.sh --failed

test-stale:
	./scripts/test-elixir.sh --stale

test-python:
	./scripts/test-python.sh

test-unit:
	@echo "Running unit tests only..."
	@docker compose -f docker-compose.test.yml build --quiet test-elixir
	docker compose -f docker-compose.test.yml run --rm test-elixir sh -c "mix ecto.create && mix ecto.migrate && mix test --only unit"
	@docker compose -f docker-compose.test.yml down

test-integration:
	@echo "Running integration tests only..."
	@docker compose -f docker-compose.test.yml build --quiet test-elixir
	docker compose -f docker-compose.test.yml run --rm test-elixir sh -c "mix ecto.create && mix ecto.migrate && mix test --only integration"
	@docker compose -f docker-compose.test.yml down

test-adversarial:
	@echo "Running adversarial tests only..."
	@docker compose -f docker-compose.test.yml build --quiet test-elixir
	docker compose -f docker-compose.test.yml run --rm test-elixir sh -c "mix ecto.create && mix ecto.migrate && mix test --only adversarial"
	@docker compose -f docker-compose.test.yml down

test-stress:
	@echo "Running stress tests only..."
	@docker compose -f docker-compose.test.yml build --quiet test-elixir
	docker compose -f docker-compose.test.yml run --rm test-elixir sh -c "mix ecto.create && mix ecto.migrate && mix test --only stress"
	@docker compose -f docker-compose.test.yml down
