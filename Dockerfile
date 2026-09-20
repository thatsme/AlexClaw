FROM elixir:1.19-otp-28-alpine AS build

RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod
ARG BUILD_NUMBER=0
ENV BUILD_NUMBER=${BUILD_NUMBER}

COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod && \
    mix deps.compile

COPY config config/
COPY lib lib/
COPY priv priv/

# Copy Phoenix and LiveView JS assets from deps into priv/static/assets
RUN mkdir -p priv/static/assets && \
    cp deps/phoenix/priv/static/phoenix.min.js priv/static/assets/ && \
    cp deps/phoenix_live_view/priv/static/phoenix_live_view.min.js priv/static/assets/

# Bundle self-awareness docs for knowledge base embedding at boot
COPY ALEXCLAW_ARCHITECTURE.md SECURITY.md ./
COPY test/fixtures/skills/skill_template.ex ./
RUN mkdir -p priv/self_awareness && \
    cp ALEXCLAW_ARCHITECTURE.md priv/self_awareness/ && \
    cp SECURITY.md priv/self_awareness/ && \
    cp lib/alex_claw/skill.ex priv/self_awareness/ && \
    cp skill_template.ex priv/self_awareness/

RUN mix compile && mix release

# --- Test stage (used by docker-compose.test.yml) ---
FROM elixir:1.19-otp-28-alpine AS test

RUN apk add --no-cache build-base git

WORKDIR /app
ENV MIX_ENV=test

COPY mix.exs mix.lock .formatter.exs .credo.exs ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix deps.compile

COPY config config/
COPY lib lib/
COPY priv priv/
COPY test test/
# The docs are in the image because documentation_test.exs checks them against
# the source. Without them the checks would pass by finding nothing.
COPY docs docs/
COPY mkdocs.yml .env.example ./
COPY ALEXCLAW_ARCHITECTURE.md CLA.md CODE_OF_CONDUCT.md CODING_CONVENTIONS.md ./
COPY CONTRIBUTING.md INSTALLATION.md README.md ROADMAP.md SECURITY.md SELF_AWARENESS.md ./

RUN mix compile
CMD ["sh", "-c", "mix ecto.create && mix ecto.migrate && mix test"]

# --- Runtime ---
FROM alpine:3.22 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs postgresql-client git

WORKDIR /app

COPY --from=build /app/_build/prod/rel/alex_claw ./

# EPMD is needed for BEAM long-name distribution (clustering)
COPY --from=build /usr/local/lib/erlang/erts-*/bin/epmd /usr/local/bin/epmd
COPY entrypoint.sh ./
RUN sed -i 's/\r$//' entrypoint.sh && chmod +x entrypoint.sh

CMD ["./entrypoint.sh"]
