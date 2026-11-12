# Same recipe as upstream/m1n1/Dockerfile, with two constraints from this machine.
# The base image is the public ECR copy of Debian, so the build does not need a
# Docker Hub login. Trixie is required because src/utils.h emits `.arch armv9.4-a`
# and bookworm binutils 2.40 rejects that directive. Trixie binutils 2.44 accepts it.
FROM public.ecr.aws/debian/debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y build-essential bash curl git locales gcc-aarch64-linux-gnu libc6-dev-arm64-cross device-tree-compiler \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

RUN curl -fsSL https://sh.rustup.rs | bash -s -- -y --target aarch64-unknown-none-softfloat

ENV LANG en_US.utf8
ENV PATH "/root/.cargo/bin:${PATH}"

WORKDIR /m1n1
COPY . .

CMD ["/bin/bash"]
