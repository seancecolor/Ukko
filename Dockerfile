# Stage 1: Build Svelte/Vite frontend into priv/static
FROM node:20-bookworm-slim AS frontend-builder

WORKDIR /build/frontend
COPY frontend/package*.json ./
RUN npm install

COPY frontend/ ./
RUN mkdir -p /build/priv/static && npm run build

# Stage 2: Build Elixir/Phoenix release
FROM elixir:1.17-slim AS elixir-builder

RUN apt-get update -y && \
    apt-get install -y build-essential git ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY --from=frontend-builder /build/priv/static ./priv/static
COPY lib lib

RUN mix compile

COPY config/runtime.exs config/
RUN mix release

# Stage 3: Minimal production runtime image
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV="prod"
ENV PHX_SERVER="true"

WORKDIR /app
RUN chown nobody /app

COPY --from=elixir-builder --chown=nobody:root /app/_build/prod/rel/ukko ./

USER nobody

EXPOSE 4000

CMD ["/app/bin/ukko", "start"]
