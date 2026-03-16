.PHONY: build up down logs seed seed-financial restart test test-elixir test-python

build:
	docker compose build --build-arg BUILD_NUMBER=$$(git rev-list --count HEAD 2>/dev/null || echo 0)

up: build
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f alexclaw

restart:
	docker compose restart alexclaw

seed:
	docker compose exec alexclaw bin/alex_claw rpc \
		'Path.wildcard("lib/alex_claw-*/priv/repo/seeds/example_workflows.exs") |> hd() |> Code.eval_file()'

seed-financial:
	docker compose exec alexclaw bin/alex_claw rpc \
		'Path.wildcard("lib/alex_claw-*/priv/repo/seeds/financial_workflows.exs") |> hd() |> Code.eval_file()'

test: test-elixir test-python

test-elixir:
	docker compose -f docker-compose.test.yml run --rm --build test-elixir

test-python:
	docker compose -f docker-compose.test.yml run --rm --build test-python
