# A minimal systemd machine for tests/run.sh.
ARG BASE=debian:12
FROM ${BASE}
RUN if command -v apt-get >/dev/null; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd systemd-sysv openssl iproute2 procps && \
      rm -rf /var/lib/apt/lists/*; \
    else \
      dnf -y install systemd openssl iproute procps-ng && dnf clean all; \
    fi && \
    # systemd-binfmt --unregister on container stop would wipe the host's amd64
    # emulation handlers (the container is privileged and shares the kernel).
    systemctl mask systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
