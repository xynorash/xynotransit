# syntax=docker/dockerfile:1
FROM rust:1-bookworm AS builder
WORKDIR /app

# Build the dependencies first so they stay cached until Cargo.toml or Cargo.lock change.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src \
 && echo 'fn main() {}' > src/main.rs \
 && echo '' > src/lib.rs \
 && cargo build --release \
 && rm -rf src target/release/deps/xynotransit* target/release/xynotransit* target/release/.fingerprint/xynotransit*

COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=builder /app/target/release/xynotransit-api /usr/local/bin/xynotransit-api
USER app
ENV BIND=0.0.0.0:8081 \
    RUST_LOG=info
EXPOSE 8081
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/xynotransit-api", "healthcheck"]
CMD ["xynotransit-api"]
