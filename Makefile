.PHONY: build up down logs seed seed-financial restart test test-elixir test-python

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

test-down:
	docker compose -f docker-compose.test.yml down

test: test-elixir test-python

test-elixir:
	@echo "Building test image..."
	@docker compose -f docker-compose.test.yml build --quiet test-elixir
	docker compose -f docker-compose.test.yml run --rm test-elixir
	@docker compose -f docker-compose.test.yml down

test-python:
	@echo "Building test image..."
	@docker compose -f docker-compose.test.yml build --quiet test-python
	docker compose -f docker-compose.test.yml run --rm test-python
	@docker compose -f docker-compose.test.yml down
