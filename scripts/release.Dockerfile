FROM hexpm/elixir:1.19.5-erlang-28.5-debian-bookworm-20260505-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential cmake curl ca-certificates git patch && rm -rf /var/lib/apt/lists/*
COPY scripts /tmp/ocex-scripts
RUN sh /tmp/ocex-scripts/install-occt.sh /opt/occt-7.9.3 > /tmp/occt-build.log 2>&1 || (tail -n 100 /tmp/occt-build.log && exit 1)
ENV OpenCASCADE_DIR=/opt/occt-7.9.3/lib/cmake/opencascade
RUN mix local.hex --force && mix local.rebar --force
