# syntax=docker/dockerfile:1
# Dockerfile to create a stable CoralNPU build environment
#
# Build command:
# docker build -t coralnpu -f utils/coralnpu.dockerfile .
#
# Run command:
# docker run -it coralnpu /bin/bash

FROM debian:trixie AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ARG _UID=1000
ARG _GID=1000
ARG _USERNAME=builder
ENV HOME=/home/${_USERNAME}

WORKDIR /tmp/build
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=tmpfs,target=/tmp/build <<EOF
    set -eux -o pipefail
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes
    apt-get update
    apt-get install -y -qq \
        apt-transport-https \
        autoconf \
        build-essential \
        ca-certificates \
        ccache \
        cmake \
        curl \
        fuse3 \
        gawk \
        git \
        gnupg \
        libelf-dev \
        libftdi1-dev \
        liblz4-dev \
        libmpfr-dev \
        libusb-1.0-0-dev \
        lsb-release \
        markdownlint \
        ninja-build \
        openjdk-21-jdk-headless \
        openjdk-21-jre-headless \
        python-is-python3 \
        python3 \
        python3-numpy \
        python3-pip \
        python3-setuptools \
        python3-venv \
        shfmt \
        shellcheck \
        srecord \
        sudo \
        tzdata \
        unzip \
        xxd \
        yapf3 \
        zip
    update-ca-certificates
    # Install clang-19 and configure
    apt-get install -y -qq \
        clang-19 \
        clang-tools-19 \
        lld-19 \
        clang-format-19 \
        clang-tidy-19
    ln -s /usr/bin/clang-19 /usr/bin/clang
    ln -s /usr/bin/clang++-19 /usr/bin/clang++
    ln -s /usr/bin/clang-cpp-19 /usr/bin/clang-cpp
    ln -s /usr/bin/clang-format-19 /usr/bin/clang-format
    ln -s /usr/bin/clang-tidy-19 /usr/bin/clang-tidy
    ln -s /usr/bin/ld.lld-19 /usr/bin/ld.lld
    ln -s /usr/bin/llvm-symbolizer-19 /usr/bin/llvm-symbolizer
    # Install Bazel
    curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > /tmp/bazel-archive-keyring.gpg
    mv /tmp/bazel-archive-keyring.gpg /usr/share/keyrings/
    echo "deb [arch=$(dpkg-architecture -q DEB_HOST_ARCH) signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8" | sudo tee /etc/apt/sources.list.d/bazel.list
    apt-get update
    apt-get install bazel bazel-8.6.0 bazel-9.1.0
    # Install buildifier
    curl -fL -o buildifier https://github.com/bazelbuild/buildtools/releases/download/v7.3.1/buildifier-linux-amd64
    echo "5474cc5128a74e806783d54081f581662c4be8ae65022f557e9281ed5dc88009  buildifier" | sha256sum --check -
    install buildifier /usr/local/bin
    # Install verible-verilog-lint
    curl -fL -o verible.tar.gz https://github.com/chipsalliance/verible/releases/download/v0.0-4051-g9fdb4057/verible-v0.0-4051-g9fdb4057-linux-static-x86_64.tar.gz
    echo "f52e5920ef63f70620a6086e09dea8bd778147cd7a9ff827bb7de5d6316b1754  verible.tar.gz" | sha256sum --check -
    mkdir -p verible
    tar -xf verible.tar.gz --strip-components=1 -C verible
    install verible/bin/verible-verilog-* /usr/local/bin
    # Install scalafmt
    curl -fL -o scalafmt.zip https://github.com/scalameta/scalafmt/releases/download/v3.10.7/scalafmt-x86_64-pc-linux.zip
    echo "a238a4e73141538a2a2e4e834f80154906b8a3f654ff14b6752fc3a3feeb5be1  scalafmt.zip" | sha256sum --check -
    unzip scalafmt.zip
    install scalafmt /usr/local/bin
    # Set up builder user
    echo "${_USERNAME} ALL=(ALL) NOPASSWD:/usr/bin/apt-get" >> /etc/sudoers.d/${_USERNAME}
    echo "${_USERNAME} ALL=(ALL) NOPASSWD:/usr/bin/apt" >> /etc/sudoers.d/${_USERNAME}
    echo "${_USERNAME} ALL=(ALL) NOPASSWD:/bin/mkdir" >> /etc/sudoers.d/${_USERNAME}
    echo "${_USERNAME} ALL=(ALL) NOPASSWD:/bin/chown" >> /etc/sudoers.d/${_USERNAME}
    echo "${_USERNAME} ALL=(ALL) NOPASSWD:/bin/ln" >> /etc/sudoers.d/${_USERNAME}
    groupadd --gid ${_GID} ${_USERNAME}
    useradd \
        --home-dir ${HOME} \
        --comment "" \
        --uid ${_UID} \
        --gid ${_GID} \
        ${_USERNAME}
    mkdir -p /home/${_USERNAME}
    chown ${_USERNAME}:${_USERNAME} ${HOME}
    # Work around differeing libmpfr versions between distros
    ln -sf /lib/x86_64-linux-gnu/libmpfr.so.6.2.0 /lib/x86_64-linux-gnu/libmpfr.so.4
EOF
USER ${_USERNAME}
WORKDIR /home/${_USERNAME}/
