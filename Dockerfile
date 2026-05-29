# --- Build stage ------------------------------------------------------------
# Uses gleam's official image which bundles a matching Erlang/OTP. We export
# an erlang-shipment, which is a self-contained directory of compiled BEAM
# files for the app and all its deps plus an entrypoint script that boots
# everything as an OTP release.
FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang AS build

WORKDIR /build

# Resolve and cache deps first so source-only changes don't bust the layer.
COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY src ./src
COPY priv ./priv

RUN gleam export erlang-shipment

# --- Runtime stage ----------------------------------------------------------
# Plain erlang:27-slim is enough — the shipment includes everything app-side.
FROM erlang:28-slim

WORKDIR /app

# CA certs for outbound HTTPS to api.voyageai.com and api.github.com.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /build/build/erlang-shipment ./

EXPOSE 8000

# Migrations run automatically on startup via cigogne (see
# src/database/connection.gleam). DATABASE_URL and the other secrets are
# read from the environment (see src/config.gleam).
ENTRYPOINT ["./entrypoint.sh"]
CMD ["run"]
