FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DATA_DIR=/var/lib/codex-ssh \
    WRAPPER_HOME=/opt/codex-ssh

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        openssh-server \
        openssh-client \
        python3 \
        python3-pip \
        bash \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --home-dir /home/codex --shell /bin/bash codex \
    && passwd -d codex \
    && mkdir -p ${DATA_DIR} ${WRAPPER_HOME}/bin ${WRAPPER_HOME}/originals \
    && chown -R codex:codex ${DATA_DIR} /home/codex \
    && chmod 700 ${DATA_DIR}

COPY entrypoint.sh /entrypoint.sh
COPY codex-hostctl ${WRAPPER_HOME}/bin/codex-hostctl
COPY bin/ ${WRAPPER_HOME}/bin/
RUN chmod +x /entrypoint.sh ${WRAPPER_HOME}/bin/* \
    && ln -s ${WRAPPER_HOME}/bin/codex-hostctl /usr/local/bin/codex-hostctl \
    && ln -s ${WRAPPER_HOME}/bin/codex-ssh-wrapper /usr/local/bin/codex-ssh-wrapper

EXPOSE 22
VOLUME ["${DATA_DIR}"]
ENTRYPOINT ["/entrypoint.sh"]
