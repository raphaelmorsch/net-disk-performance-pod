FROM registry.fedoraproject.org/fedora:40

RUN dnf install -y \
      iperf3 \
      fio \
      iproute \
      iputils \
      bind-utils \
      traceroute \
      curl \
      wget \
      jq \
      procps-ng \
      sysstat \
      util-linux \
      nmap-ncat \
      openssl \
      hostname \
      which \
      tar \
      gzip \
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN mkdir -p /work /data \
    && chmod -R g=u /work /data

WORKDIR /work

USER 1001

CMD ["sleep", "infinity"]