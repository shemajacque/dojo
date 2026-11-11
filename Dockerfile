# syntax=docker/dockerfile:1

FROM ubuntu:24.04 AS kata-builder

ARG TARGETARCH=amd64
ENV KATA_VERSION=4.1.0

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN <<EOF
if [ "$TARGETARCH" != "arm64" ]; then
  apt-get update
  apt-get install -y --no-install-recommends \
      build-essential bc flex bison libssl-dev libelf-dev dwarves \
      curl ca-certificates yq git
  rm -rf /var/lib/apt/lists/*
  git clone --depth 1 --branch "$KATA_VERSION" https://github.com/kata-containers/kata-containers.git /src/kata-containers
fi
mkdir -p /usr/share/kata-containers
touch /usr/share/kata-containers/vmlinux.container
EOF

WORKDIR /src/kata-containers/tools/packaging/kernel

RUN <<EOF
if [ "$TARGETARCH" != "arm64" ]; then
  mkdir -p configs/fragments/x86_64
  cat > configs/fragments/x86_64/dojo.conf <<'CONF'
CONFIG_SECURITY_LANDLOCK=y

CONFIG_BPF_JIT=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_KPROBE_EVENTS=y
CONFIG_KPROBES=y
CONFIG_PERF_EVENTS=y
CONFIG_PROFILING=y
CONF
  KERNEL_VERSION=$(yq -r '.assets.kernel.version' ../../../versions.yaml)
  ./build-kernel.sh -v "$KERNEL_VERSION" setup
  ./build-kernel.sh -v "$KERNEL_VERSION" build
  ./build-kernel.sh -v "$KERNEL_VERSION" install
fi
EOF

FROM ubuntu:24.04 AS dojo

ARG TARGETARCH=amd64

SHELL ["/bin/bash", "-ceox", "pipefail"]

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_CTYPE=C.UTF-8

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && xargs apt-get install -yqq <<EOF && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
        build-essential
        btrfs-progs
        curl
        git
        host
        htop
        iproute2
        iputils-ping
        jq
        kmod
        python3-requests
        unzip
        wget
        wireguard
        zstd
EOF

RUN <<EOF
curl -fsSL https://get.docker.com | VERSION=27.5.1 sh
sed -i 's|-H fd:// ||' /lib/systemd/system/docker.service
EOF

COPY etc/docker/daemon*.json /tmp/
RUN cp /tmp/daemon.json /etc/docker/daemon.json

ADD https://raw.githubusercontent.com/moby/profiles/master/seccomp/default.json /etc/docker/seccomp.json

RUN <<EOF
if [ "$TARGETARCH" != "arm64" ]; then
  KATA_VERSION=4.1.0
  curl -fL https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst | tar --zstd -x --strip-components=2 -C /opt
  ln -s /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
fi
EOF

COPY --from=kata-builder /usr/share/kata-containers/vmlinux.container /opt/kata/share/kata-containers/vmlinux.container

RUN <<EOF
case "$TARGETARCH" in
  arm64) AWS_ARCH=aarch64 ;;
  *) AWS_ARCH=x86_64 ;;
esac
cd /tmp
wget -O aws.zip "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"
unzip aws.zip
./aws/install
rm -rf aws.zip aws
EOF

COPY <<EOF /etc/fstab
shm /dev/shm tmpfs defaults,nosuid,nodev,noexec,size=50% 0 0
tmpfs /run/dojo tmpfs defaults,mode=755,shared 0 0
/data/homes /run/homefs none defaults,bind,nosuid 0 0
EOF

COPY <<EOF /etc/sysctl.d/90-dojo.conf
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
kernel.pty.max = 1048576
kernel.core_pattern = core
kernel.apparmor_restrict_unprivileged_userns = 0
EOF

WORKDIR /opt/pwn.college
COPY . .

RUN <<EOF
find /opt/pwn.college/etc/systemd/system -type f -exec ln -s {} /etc/systemd/system/ \;
find /opt/pwn.college/etc/systemd/system -type f -name '*.timer' -exec sh -c \
    'ln -s "/etc/systemd/system/$(basename "{}")" "/etc/systemd/system/timers.target.wants/$(basename "{}")"' \;
ln -s /opt/pwn.college/etc/systemd/system/pwn.college.service /etc/systemd/system/multi-user.target.wants/
find /opt/pwn.college/dojo -type f -executable -exec ln -s {} /usr/local/bin/ \;
EOF

EXPOSE 22
EXPOSE 80
EXPOSE 443
EXPOSE 8001
CMD ["dojo", "init"]
