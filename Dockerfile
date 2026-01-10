FROM elixir:1.18.4 AS build

WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
COPY config config
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib

RUN mix compile
RUN mix release

FROM debian:trixie-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends libssl3 ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
ENV ZONES_FOLDER=/data/zones

COPY --from=build /app/_build/prod/rel/exdns ./

EXPOSE 53/udp 8080

VOLUME ["/data"]

CMD ["bin/exdns", "start"]
