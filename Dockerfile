###############################################################################
# Builder stage
###############################################################################
# hadolint global ignore=DL3003,DL3008,SC2028,DL3013
# Base images pinned by digest (amd64 manifest, not the index: index digests churn
# on attestation entries while the platform manifest stays put). Bump both together.
#   python:3.13.18        -> sha256:bcaf104e...
#   python:3.13.18-slim   -> sha256:48d88481...
FROM python:3.13.18@sha256:bcaf104ef2827b827bdd0b8b351742783fc050296e1dc150113e6ec869e652d0 AS builder

# Use TARGETARCH build argument
ARG TARGETARCH
# Set environment variable for use in this stage
ENV ARCH=$TARGETARCH

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /builder
COPY . .

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN python3 -m pip install --no-cache-dir -U \
  build pip setuptools wheel setuptools_scm && \
  python3 -m build && \
  pip wheel --no-cache-dir --wheel-dir /wheels . && \
  rm /wheels/jupyter_quant-*.whl


###############################################################################
# Final stage
###############################################################################
FROM python:3.13.18-slim@sha256:48d884813cf44e927cf64c5529dd630dd3b18338c6dc727991eef9b71e934a20

# Use TARGETARCH build argument
ARG TARGETARCH
# Set environment variable for use in this stage
ENV ARCH=$TARGETARCH

ARG DEBIAN_FRONTEND=noninteractive

ENV APT_PROXY_FILE=/etc/apt/apt.conf.d/01proxy

# Identity is a build input, not a literal: compose and CI pass USER/USER_ID/USER_GID.
# Upstream declared only `ARG USER_ID`, so a `USER` build-arg was silently discarded.
ARG USER=quant
ARG USER_ID=1500
ARG USER_GID=1500
ENV USER=${USER}
ARG IMAGE_VERSION=dev
ENV IMAGE_VERSION=${IMAGE_VERSION}
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_USER=true
ENV PIP_NO_CACHE_DIR=1
ENV PATH="$PATH:/home/$USER/.local/bin"

# base data directory
ENV BASE_DATA="/home/${USER}/.local"
ENV BASE_CONFIG="/home/${USER}/.config"

# XDG env
ENV XDG_CACHE_HOME="${BASE_DATA}/cache"
ENV XDG_CONFIG_HOME="${BASE_CONFIG}"
ENV XDG_DATA_HOME="${BASE_DATA}/share"
ENV XDG_STATE_HOME="${BASE_DATA}/state"
# ipython
ENV IPYTHONDIR="${BASE_CONFIG}/ipython"
# jupyter
ENV JUPYTER_CONFIG_DIR="${BASE_CONFIG}/jupyter"
ENV JUPYTER_DATA_DIR="${BASE_DATA}/share/jupyter"
ENV JUPYTERLAB_DIR="${BASE_DATA}/share/jupyter/lab"
ENV JUPYTERLAB_SETTINGS_DIR="${JUPYTER_CONFIG_DIR}/lab/user-settings"
ENV JUPYTERLAB_WORKSPACES_DIR="${JUPYTER_CONFIG_DIR}/lab/workspaces"
ENV JUPYTER_SERVER_ROOT="/home/${USER}/Notebooks"
# matplotlib
ENV MPLCONFIGDIR="${BASE_CONFIG}/matplotlib"
# shell
ENV SHELL="/bin/bash"

COPY 99-arial-alias.conf /etc/fonts/conf.d/

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN if [ -n "$APT_PROXY" ]; then \
      echo "Acquire::http { Proxy \"${APT_PROXY}\"; }"  \
      | tee "${APT_PROXY_FILE}" \
    ;fi && \
  apt-get update && \
  apt-get install --no-install-recommends -y \
    openssh-client sshpass curl graphviz git tzdata unzip less xclip nano-tiny \
    ffmpeg pandoc stow jq bash-completion procps fontconfig fonts-jetbrains-mono \
    fonts-dejavu-core fonts-firacode fonts-liberation2 && \
  apt-get clean && rm -rf /var/lib/apt/lists/* && \
  if [ -f "${APT_PROXY_FILE}" ]; then \
    rm "${APT_PROXY_FILE}" \
  ;fi && \
  groupadd --gid "${USER_GID}" "${USER}" && \
  useradd -ms /bin/bash --uid "${USER_ID}" --gid "${USER_GID}" "${USER}" && \
  fc-cache -fv && \
  python -c "import compileall; compileall.compile_path(maxlevels=10)"

# supercronic — static Go binary, cron syntax, logs to stdout. Pinned version and per-arch
# checksum: the image is published publicly, so nothing enters a layer unverified.
ARG SUPERCRONIC_VERSION=v0.2.51
RUN set -eux; \
  arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
  case "${arch}" in \
    amd64) sha=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123 ;; \
    arm64) sha=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94 ;; \
    *) echo "unsupported arch ${arch}" >&2; exit 1 ;; \
  esac; \
  curl -fsSLo /tmp/supercronic \
    "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${arch}"; \
  echo "${sha}  /tmp/supercronic" | sha256sum -c -; \
  install -m 0755 /tmp/supercronic /usr/local/bin/supercronic; \
  rm -f /tmp/supercronic; \
  supercronic -version

USER $USER_ID:$USER_GID

COPY --chown=${USER}:${USER} matplotlibrc ${BASE_CONFIG}/matplotlib/matplotlibrc

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN --mount=type=bind,from=builder,source=/wheels,target=/wheels \
  pip install --user --no-deps --compile --no-cache-dir /wheels/* && \
  fc-cache -fv && \
  # Import matplotlib the first time to build the font cache.
  MPLBACKEND=Agg python -c "import matplotlib.pyplot" && \
  mkdir "${JUPYTER_SERVER_ROOT}"

COPY entrypoint.sh /
COPY scripts/equity-update.sh /opt/qr/pipelines/equity-update.sh
COPY docker/pipelines.crontab /etc/supercronic/crontab
WORKDIR ${JUPYTER_SERVER_ROOT}

CMD ["jupyter-lab", "--no-browser", "--ip=0.0.0.0"]
ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 8888

# /api is unauthenticated in Jupyter and returns 200 only when the server is actually serving.
HEALTHCHECK --interval=60s --timeout=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8888/api >/dev/null || exit 1

LABEL org.opencontainers.image.source=https://github.com/quantbelt/jupyter-quant
LABEL org.opencontainers.image.url=https://github.com/quantbelt/jupyter-quant/pkgs/container/jupyter-quant
LABEL org.opencontainers.image.description="A dockerized Jupyter quant research enviroment. "
LABEL org.opencontainers.image.licenses="Apache License Version 2.0"
