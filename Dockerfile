#
# Copyright 2026 Nialto Services Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS debian

# The official release zip is verified against the PGP-signed SHA256SUMS, and that signature against
# the signing key committed in keys/rclone.asc, so a version bump needs no checksum edits.
FROM debian AS rclone

ARG TARGETARCH
# renovate: datasource=github-releases depName=rclone/rclone extractVersion=^v(?<version>.+)$
ARG RCLONE_VERSION=1.75.2
ARG RCLONE_SIGNER_FINGERPRINT=FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA

COPY keys/rclone.asc /tmp/rclone.asc

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl gpg gpg-agent unzip \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/rclone

RUN set -eu; \
	release_url="https://downloads.rclone.org/v${RCLONE_VERSION}"; \
	archive="rclone-v${RCLONE_VERSION}-linux-${TARGETARCH}.zip"; \
	curl -fsSLO "${release_url}/${archive}"; \
	curl -fsSLO "${release_url}/SHA256SUMS"; \
	\
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --quiet --import /tmp/rclone.asc; \
	gpg --batch --status-fd 1 --verify SHA256SUMS > verification.log; \
	grep -q "^\[GNUPG:\] VALIDSIG .* ${RCLONE_SIGNER_FINGERPRINT}\$" verification.log; \
	\
	grep " ${archive}\$" SHA256SUMS | sha256sum -c -; \
	unzip -j "${archive}" "rclone-v${RCLONE_VERSION}-linux-${TARGETARCH}/rclone"; \
	chmod 0755 rclone

# supercronic's releases publish no checksum file or signature, so each architecture's SHA-256 is
# pinned here and a version bump is checked by hand against the SHA-1s in the release notes.
FROM debian AS supercronic

ARG TARGETARCH
# renovate: datasource=github-releases depName=aptible/supercronic extractVersion=^v(?<version>.+)$
ARG SUPERCRONIC_VERSION=0.2.50
ARG SUPERCRONIC_SHA256_AMD64=d2d7c97fbfefc763d5bbcbbb3f8d61f9dd3410ce5d05a737c414994b80b8cdd0
ARG SUPERCRONIC_SHA256_ARM64=a1c0af9872e8de89a1ce5c1b596e26c42917d5a2cf914d98faee2e28156899e2

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/supercronic

RUN set -eu; \
	case "${TARGETARCH}" in \
		amd64) expected_sha256="${SUPERCRONIC_SHA256_AMD64}" ;; \
		arm64) expected_sha256="${SUPERCRONIC_SHA256_ARM64}" ;; \
		*) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
	esac; \
	curl -fsSLo supercronic "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
	echo "${expected_sha256}  supercronic" | sha256sum -c -; \
	chmod 0755 supercronic

FROM debian AS base

RUN apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends ca-certificates curl procps tini tzdata zstd \
	&& rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 65532 rclone-backup \
	&& useradd --uid 65532 --gid 65532 --no-create-home --shell /usr/sbin/nologin rclone-backup

COPY --from=rclone /tmp/rclone/rclone /usr/local/bin/rclone
COPY --from=supercronic /tmp/supercronic/supercronic /usr/local/bin/supercronic
COPY lib/ /usr/local/lib/rclone-backup/

ENV RCLONE_CACHE_DIR=/tmp/rclone-cache

USER 65532:65532

ENTRYPOINT ["/usr/bin/tini", "--"]

FROM base AS files

COPY --chmod=0755 jobs/files /usr/local/bin/backup

LABEL org.opencontainers.image.description="Scheduled rclone mirror of a folder or remote into a versioned bucket"
