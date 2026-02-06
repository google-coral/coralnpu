# Dockerfile to create a stable CoralNPU build environment
#
# Build command:
# docker build -t coralnpu -f utils/coralnpu.dockerfile .
#
# Run command:
# docker run -it coralnpu /bin/bash

FROM debian:bookworm AS base

ENV TZ=UTC
ARG _UID=1000
ARG _GID=1000
ARG _USERNAME=builder
ENV HOME=/home/${_USERNAME}

ENV DEBIAN_FRONTEND=noninteractive
# Create a directory for dsim
WORKDIR /root

# Copy the dsim binary
COPY utils/AltairDSim2025.0.1_linux64.bin /root/
COPY utils/dsim-license.json /root/

# Make the binary executable
RUN chmod +x /root/AltairDSim2025.0.1_linux64.bin

# Install dsim
RUN /root/AltairDSim2025.0.1_linux64.bin -i silent -DACCEPT_EULA=YES

# Remove dsim installer
RUN rm /root/AltairDSim2025.0.1_linux64.bin

# Make /root directory traversable and dsim installation accessible to all users
RUN chmod a+rx /root && \
    chmod -R a+rX /root/AltairDSim && \
    chmod a+r /root/dsim-license.json

# Setup dsim environment
ENV DSIM=dsim
ENV DSIM_HOME=/root/AltairDSim/2025
ENV DSIM_LICENSE=/root/dsim-license.json
ENV DSIM_LIB_PATH=${DSIM_HOME}/lib
ENV UVM_HOME=${DSIM_HOME}/uvm/1.2/
ENV STD_LIBS=${DSIM_HOME}/std_pkgs/lib
ENV RADFLEX_PATH=${DSIM_HOME}/radflex
ENV LLVM_HOME=${DSIM_HOME}/llvm_small
ENV PATH=${LLVM_HOME}/bin:${DSIM_HOME}/bin:$PATH
ENV LD_LIBRARY_PATH=${DSIM_HOME}/lib:${LLVM_HOME}/lib

# Set CORALNPU_MPACT environment variable
ENV CORALNPU_MPACT=../../coralnpu-mpact

# Symlink libuvm_dpi.so to dsim lib path
RUN ln -s ${UVM_HOME}/src/dpi/libuvm_dpi.so ${DSIM_LIB_PATH}/libuvm_dpi.so

RUN ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && \
    echo "${TZ}" > /etc/timezone && \
    echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes && \
    apt-get update && \
    apt-get install -y -qq \
        apt-transport-https \
        autoconf \
        build-essential \
        ca-certificates \
        ccache \
        clang \
        curl \
        default-jdk \
        fuse3 \
        gawk \
        git \
        gnupg \
        libmpfr-dev \
        libsqlite3-dev \
        lsb-release \
        python-is-python3 \
        python3 \
        python3-pip \
        srecord \
        tzdata \
        unzip \
        xxd \
        zip && \
    update-ca-certificates && \
    curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > /tmp/bazel-archive-keyring.gpg && \
    mv /tmp/bazel-archive-keyring.gpg /usr/share/keyrings/ && \
    echo "deb [arch=$(dpkg-architecture -q DEB_HOST_ARCH) signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8" | tee /etc/apt/sources.list.d/bazel.list && \
    apt update && \
    apt install bazel bazel-7.4.1

# Install Python dependencies for UVM tests
RUN pip3 install --no-cache-dir --break-system-packages pyelftools

# Create builder user
RUN addgroup --gid ${_GID} ${_USERNAME} && \
    adduser \
        --home ${HOME} \
        --disabled-password \
        --gecos "" \
        --uid ${_UID} \
        --gid ${_GID} \
        ${_USERNAME} && \
    chown ${_USERNAME}:${_USERNAME} ${HOME} && \
    mkdir -p ${HOME}/.cache && \
    chown -R ${_USERNAME}:${_USERNAME} ${HOME}/.cache
# Work around differeing libmpfr versions between distros
RUN ln -sf /lib/x86_64-linux-gnu/libmpfr.so.6.2.0 /lib/x86_64-linux-gnu/libmpfr.so.4
USER ${_USERNAME}
WORKDIR ${HOME}

# Default to bash for interactive development
CMD ["/bin/bash"]