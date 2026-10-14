# --- Build stage ------------------------------------------------------------
# Plain erlang plus the static gleam binary, rather than gleam's -erlang image:
# that one bundles whatever erlang:latest was when it was built, so a gleam
# bump could silently move OTP out from under the runtime stage, which must
# match its major. Spelled out here, Renovate can keep them together. We
# export an erlang-shipment, which is a self-contained directory of compiled
# BEAM files for the app and all its deps plus an entrypoint script that
# boots everything as an OTP release.
FROM erlang:29 AS build

COPY --from=ghcr.io/gleam-lang/gleam:v1.19.2-scratch /bin/gleam /bin/gleam

WORKDIR /build

# Resolve and cache deps first so source-only changes don't bust the layer.
COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY src ./src
COPY priv ./priv

RUN gleam export erlang-shipment

# --- Runtime stage ----------------------------------------------------------
# Plain erlang slim is enough — the shipment includes everything app-side.
FROM erlang:29-slim

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
