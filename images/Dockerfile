FROM alpine:latest

RUN mkdir -p /run /tmp

RUN apk add --no-cache \
    bash \
    python3 python3-dev py3-pip \
    nodejs npm \
    build-base cmake \
    git patch \
    curl wget openssh-client ca-certificates \
    jq tar gzip zip unzip findutils coreutils grep sed less vim \
    file tree ripgrep \
    sqlite sqlite-dev \
    libstdc++ libffi-dev openssl-dev \
    tzdata
