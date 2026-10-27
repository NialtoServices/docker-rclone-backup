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

# The base must be glibc-based, for the MySQL client copied from Oracle's image, and have PGDG
# packages for every supported PostgreSQL major on one release. Debian has both.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS debian

# Oracle's MySQL clients come from the official image rather than Debian, which carries MariaDB's in
# their place, and neither family's client stands in for the other's. The 9.7 LTS client dumps and
# restores every supported server, 8.0 to 9.x. The client is always an LTS release and moves only to
# the next LTS, because an innovation release stops receiving fixes once the next one arrives.
FROM mysql:9.7@sha256:8fb11c38b3551e22d50adbb688f027f8ff4ea2d2445aa277c1cc97b4af85ec54 AS mysql-oracle

# rclone must be verifiable back to its publisher's signing key, which only the official release zip
# allows. The zip is verified against the PGP-signed SHA256SUMS, and that signature against the
# signing key committed in keys/rclone.asc, so a version bump needs no checksum edits.
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

# PGDG signs its apt repository with the key committed in keys/pgdg.asc. The stage checks that the file
# holds exactly the one key with PGDG's published fingerprint, so a changed file fails the build, and
# the postgres image installs the key from here. PGDG's key has no expiry date, so a rotation shows up
# as a failed build and not as a silent change.
FROM debian AS pgdg-key

ARG PGDG_SIGNER_FINGERPRINT=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8

COPY keys/pgdg.asc /tmp/pgdg.asc

RUN apt-get update \
	&& apt-get install -y --no-install-recommends gpg gpg-agent \
	&& rm -rf /var/lib/apt/lists/*

RUN set -eu; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --show-keys --with-colons /tmp/pgdg.asc | awk -F: '$1 == "pub" { primary = 1; next } $1 == "fpr" && primary { print $10; primary = 0 }' > /tmp/fingerprints; \
	[ "$(cat /tmp/fingerprints)" = "${PGDG_SIGNER_FINGERPRINT}" ]

# The scheduler must run jobs as the image's non-root user, pass them the container's environment
# (which holds every setting) and log to standard output; supercronic does all three.
#
# supercronic's releases publish no checksum file or signature, so each architecture's SHA-256 is
# pinned here and a version bump is checked by hand against the SHA-1s in the release notes.
FROM debian AS supercronic

ARG TARGETARCH
# renovate: datasource=github-releases depName=aptible/supercronic extractVersion=^v(?<version>.+)$
ARG SUPERCRONIC_VERSION=0.2.51
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

# A publishing run passes a different value each time, so the layer below is never served from the
# build cache and every publish, the weekly rebuild included, installs the packages Debian holds
# that day. CI passes a fixed value and keeps its cache. The value is echoed so that BuildKit counts
# it as an input of this step. The stages that follow install more packages and rebuild with it.
ARG PACKAGE_REFRESH=stable

RUN echo "package refresh: ${PACKAGE_REFRESH}" \
	&& apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends ca-certificates curl procps tini tzdata zstd \
	&& rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 65532 rclone-backup \
	&& useradd --uid 65532 --gid 65532 --no-create-home --shell /usr/sbin/nologin rclone-backup

COPY --from=rclone /tmp/rclone/rclone /usr/local/bin/rclone
COPY --from=supercronic /tmp/supercronic/supercronic /usr/local/bin/supercronic
COPY lib/ /usr/local/lib/rclone-backup/
COPY --chmod=0755 bin/start bin/monitor /usr/local/bin/

# The image user has no home directory, so rclone's default config path doesn't exist and every run
# would log a NOTICE about it. A remote defined through RCLONE_CONFIG_<REMOTE>_* variables needs no
# file, so the default is /dev/null; a deployment that mounts a config file names it in its own
# RCLONE_CONFIG, which replaces this.
ENV RCLONE_CACHE_DIR=/tmp/rclone-cache \
	RCLONE_CONFIG=/dev/null

USER 65532:65532

ENTRYPOINT ["/usr/bin/tini", "--"]

FROM base AS files

COPY --chmod=0755 jobs/files /usr/local/bin/backup

CMD ["/usr/local/bin/start"]

LABEL org.opencontainers.image.description="Scheduled rclone mirror of a folder or remote into a versioned bucket"

FROM base AS sqlite

USER 0:0

RUN apt-get update \
	&& apt-get install -y --no-install-recommends sqlite3 \
	&& rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 jobs/sqlite /usr/local/bin/backup

USER 65532:65532

CMD ["/usr/local/bin/start"]

LABEL org.opencontainers.image.description="Scheduled snapshot of a SQLite database, checked and compressed, uploaded to a versioned bucket"

FROM base AS postgres

USER 0:0

# Every supported major's client sits side by side under /usr/lib/postgresql/<major>/bin, because a
# dump must be taken, and listed, by the client of the server's own major. ca-certificates, which the
# repository's HTTPS needs, is already in base.
COPY --from=pgdg-key /tmp/pgdg.asc /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

RUN echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends postgresql-client-15 postgresql-client-16 postgresql-client-17 postgresql-client-18 \
	&& rm -rf /var/lib/apt/lists/*

# LD_BIND_NOW makes the dynamic linker resolve every symbol at start-up, so a client with a missing
# library fails here, at build time, and not at the first run.
RUN for tool in /usr/lib/postgresql/*/bin/pg_dump /usr/lib/postgresql/*/bin/pg_restore /usr/lib/postgresql/*/bin/psql; do \
		LD_BIND_NOW=1 "${tool}" --version || exit 1; \
	done

COPY --chmod=0755 jobs/postgres /usr/local/bin/backup

USER 65532:65532

CMD ["/usr/local/bin/start"]

LABEL org.opencontainers.image.description="Scheduled pg_dump of one PostgreSQL database, checked and uploaded to a versioned bucket"

FROM base AS mariadb

USER 0:0

# Debian's mariadb-client also installs /usr/bin/mysql and /usr/bin/mysqldump as links to MariaDB's
# own tools. They're removed so the image carries one name for each tool, and nothing here can reach
# for a MySQL client that isn't there.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends mariadb-client \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm /usr/bin/mysql /usr/bin/mysqldump

# LD_BIND_NOW makes the dynamic linker resolve every symbol at start-up, so a client with a missing
# library fails here, at build time, and not at the first run.
RUN for tool in /usr/bin/mariadb /usr/bin/mariadb-dump; do \
		LD_BIND_NOW=1 "${tool}" --version || exit 1; \
	done

COPY --chmod=0755 jobs/mariadb /usr/local/bin/backup

USER 65532:65532

CMD ["/usr/local/bin/start"]

LABEL org.opencontainers.image.description="Scheduled mariadb-dump of one MariaDB database, checked and uploaded to a versioned bucket"

FROM base AS mysql

USER 0:0

# These are the libraries the copied clients link against that base doesn't carry.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends libncurses6 libssl3t64 libstdc++6 zlib1g \
	&& rm -rf /var/lib/apt/lists/*

# mysqldump has no connect timeout option, so the job probes the server with the mysql client first.
# Both are kept out of the PATH and called by absolute path, so nothing can pick up a MariaDB client.
COPY --from=mysql-oracle /usr/bin/mysql /usr/bin/mysqldump /opt/mysql/bin/

# LD_BIND_NOW makes the dynamic linker resolve every symbol at start-up, so a client with a missing
# library fails here, at build time, and not at the first run.
RUN for tool in /opt/mysql/bin/mysql /opt/mysql/bin/mysqldump; do \
		LD_BIND_NOW=1 "${tool}" --version || exit 1; \
	done

COPY --chmod=0755 jobs/mysql /usr/local/bin/backup

USER 65532:65532

CMD ["/usr/local/bin/start"]

LABEL org.opencontainers.image.description="Scheduled mysqldump of one MySQL database, checked and uploaded to a versioned bucket"
