# syntax=docker/dockerfile:1
# docker/Dockerfile — sandbox images assembled from the SAME declarations and
# modules the host converges (book ch 9: installation rules live in modules,
# assembly rules live here).
#
# Targets:
#   base    pinned Ubuntu + shared apt module (group: base)
#   tooling base + locked mise toolchains (toolchains/mise.toml + mise.lock)
#   agent   tooling + per-user agent CLIs via modules/apps.sh (claude, opencode)
#
# Inputs are pinned by digest in docker/inputs.txt (no floating defaults);
# build via docker/build.sh. Group `docker` (host engine) is deliberately NOT
# installed here. Host/image differences: docker/README.md.

ARG UBUNTU_IMAGE
ARG MISE_IMAGE
FROM ${MISE_IMAGE} AS mise_binary

# ---------- base: shared apt module, one implementation for host and image --
FROM ${UBUNTU_IMAGE} AS base
SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]
ENV LANG=C.UTF-8 TZ=Etc/UTC

# apt.sh derives repo_root from its own path — mirror the repository layout.
COPY modules/apt.sh /opt/workstation/modules/apt.sh
COPY packages/apt/base.txt /opt/workstation/packages/apt/base.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    bash /opt/workstation/modules/apt.sh base

# ---------- tooling: canonical locked toolchains (mise) ---------------------
FROM base AS tooling
COPY --from=mise_binary /usr/local/bin/mise /usr/local/bin/mise
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/toolchains \
    MISE_CACHE_DIR=/var/cache/mise \
    PATH="/opt/mise/shims:${PATH}"

# The canonical declaration is projected; never edited inside the image.
COPY toolchains/mise.toml /opt/toolchains/config.toml
COPY toolchains/mise.lock /opt/toolchains/mise.lock
WORKDIR /opt/toolchains
RUN --mount=type=cache,target=/var/cache/mise \
    mise install --locked

# Reuse an existing UID 1000 account; fail visibly on a collision (book ch 9).
RUN if getent passwd 1000 >/dev/null; then \
      old_user="$(getent passwd 1000 | cut -d: -f1)"; \
      if [[ "$old_user" != dev ]]; then usermod -l dev "$old_user"; fi; \
      usermod -d /home/dev -m -s /bin/bash dev; \
    else \
      useradd --create-home --uid 1000 --shell /bin/bash dev; \
    fi; \
    mkdir -p /workspaces /var/cache/mise; \
    chown dev: /workspaces /var/cache/mise

USER dev
ENV HOME=/home/dev
WORKDIR /workspaces
CMD ["bash"]

# ---------- agent: per-user apps through the shared apps module --------------
FROM tooling AS agent
COPY modules/apps.sh /opt/workstation/modules/apps.sh
COPY packages/apps/claude.txt packages/apps/opencode.txt /opt/workstation/packages/apps/
# Fetching is opt-in and hash-gated: every artifact is downloaded from its
# declaration's https source and must match the declared sha256 or the build
# fails. Cache mount keeps artifacts out of the image layers.
ENV PATH="/home/dev/.local/bin:${PATH}" \
    WORKSTATION_APP_FETCH=1
RUN --mount=type=cache,target=/home/dev/.cache/workstation/apps,sharing=locked \
    bash /opt/workstation/modules/apps.sh claude opencode
# claude's self-updater must stay off so the pins stay authoritative.
RUN mkdir -p /home/dev/.claude && printf '{\n  "env": {\n    "DISABLE_AUTOUPDATER": "1"\n  }\n}\n' > /home/dev/.claude/settings.json
CMD ["bash"]
