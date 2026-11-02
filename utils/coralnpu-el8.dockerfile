# syntax=docker/dockerfile:1
FROM rockylinux:8 AS base

ENV TZ=UTC
ARG _UID=1000
ARG _GID=1000
ARG _USERNAME=builder
ENV HOME=/home/${_USERNAME}

WORKDIR /tmp/build

RUN --mount=type=tmpfs,target=/tmp/build <<EOF
    set -eux -o pipefail
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone

    # Enable EPEL and PowerTools
    dnf install -y \
        'dnf-command(config-manager)' \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
    dnf config-manager -y --set-enabled powertools

    dnf install -y \
        autoconf \
        automake \
        bzip2 \
        ca-certificates \
        cmake \
        curl \
        diffutils \
        dtc \
        elfutils-libelf-devel \
        findutils \
        fuse3 \
        gawk \
        gcc \
        gcc-c++ \
        gcc-toolset-13 \
        git \
        gnupg2 \
        gzip \
        java-21-openjdk-devel \
        java-21-openjdk-headless \
        libftdi-devel \
        libusbx-devel \
        llvm-toolset \
        lz4-devel \
        m4 \
        make \
        mpfr-devel \
        ninja-build \
        patch \
        python3.11 \
        sudo \
        tar \
        tzdata \
        unzip \
        vim-common \
        which \
        xz \
        zip \
        zlib-devel

    alternatives --set python3 /usr/bin/python3.11
    ln -sf /usr/bin/python3 /usr/bin/python
    dnf clean all

    # Install bazel
    curl -L -O https://github.com/bazelbuild/bazel/releases/download/9.1.0/bazel-9.1.0-installer-linux-x86_64.sh
    echo "7c24f89a64035c32f3a071d336f07bb41a75f657c7e79f3c053f9e04d89f338f  bazel-9.1.0-installer-linux-x86_64.sh" | sha256sum --check -
    bash bazel-9.1.0-installer-linux-x86_64.sh
        echo "${_USERNAME} ALL=(ALL) NOPASSWD:/usr/bin/apt-get" >> /etc/sudoers.d/${_USERNAME}
        echo "${_USERNAME} ALL=(ALL) NOPASSWD:/usr/bin/apt" >> /etc/sudoers.d/${_USERNAME}
        echo "${_USERNAME} ALL=(ALL) NOPASSWD:/bin/mkdir" >> /etc/sudoers.d/${_USERNAME}
        echo "${_USERNAME} ALL=(ALL) NOPASSWD:/bin/chown" >> /etc/sudoers.d/${_USERNAME}
        echo "${_USERNAME} ALL=(ALL) NOPASSWD:/bin/ln" >> /etc/sudoers.d/${_USERNAME}
        groupadd -f plugdev
        groupadd -f dialout
        groupadd --gid ${_GID} ${_USERNAME}
        useradd \
            --home-dir ${HOME} \
            --comment "" \
            --uid ${_UID} \
            --gid ${_GID} \
            --groups plugdev,dialout \
            ${_USERNAME}

        mkdir -p /home/${_USERNAME}
        chown ${_USERNAME}:${_USERNAME} ${HOME}
EOF
USER ${_USERNAME}
WORKDIR /home/${_USERNAME}/
