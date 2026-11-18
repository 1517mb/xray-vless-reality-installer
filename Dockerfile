FROM debian:bookworm-slim

ARG XRAY_VERSION=v26.11.9
COPY --chmod=755 xray-install-docker.sh /usr/local/sbin/xray-install-docker
RUN /usr/local/sbin/xray-install-docker --prepare \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 443/tcp
ENTRYPOINT ["/usr/local/bin/xray-entrypoint"]
