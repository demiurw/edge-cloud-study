FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    iperf3 \
    python3 \
    python3-pip \
    sqlite3 \
    curl \
    iproute2 \
    net-tools \
    iputils-ping \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Keep container running
CMD ["tail", "-f", "/dev/null"]
