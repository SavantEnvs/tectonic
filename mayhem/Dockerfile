# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for tectonic (Rust, cargo-fuzz). Builds on the org base image and adds a
# pinned Rust nightly + cargo-fuzz under /opt/toolchains/rust (fixed, $HOME-independent, so the cargo
# registry this online build fills is found again by the air-gapped re-run of mayhem/build.sh).
#
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile --build-arg COMMIT=$(git rev-parse HEAD) -t tectonic-commit:test .
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

ARG RUST_CHANNEL=nightly-2026-09-01
ARG CARGO_FUZZ_VERSION=0.13.1
# cargo-fuzz's locked deps (rustix 0.36) don't build on nightly, so it is built with a pinned stable.
ARG RUST_STABLE=1.90.0

# System libraries tectonic links through pkg-config (harfbuzz is external so the harfbuzz git
# submodule is not needed).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        pkg-config libfontconfig-dev libfreetype-dev libgraphite2-dev libharfbuzz-dev \
        libharfbuzz-icu0 libicu-dev libpng-dev zlib1g-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && rustup toolchain install "${RUST_STABLE}" --profile minimal \
 && cargo "+${RUST_STABLE}" install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rustup toolchain uninstall "${RUST_STABLE}" \
 && rm -f /tmp/rustup-init.sh \
 && chown -R 2000:2000 /opt/toolchains/rust

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
