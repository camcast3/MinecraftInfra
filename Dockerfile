FROM ubuntu:noble-20240429

RUN DEBIAN_FRONTEND=noninteractive \
  apt update \
  && apt upgrade \
  && apt install -y wget \
  && apt install -y unzip \
  && rm -rf /var/lib/apt/lists/*

RUN wget -O 'Linux64-bitx86.zip' https://nightly.link/packwiz/packwiz/workflows/go/main/Linux%2064-bit%20x86.zip
RUN unzip 'Linux64-bitx86.zip'

RUN chmod 774 packwiz

VOLUME ["/data"]
WORKDIR /data

EXPOSE 8080

ENTRYPOINT [ "/packwiz", "server", "--port", "8080"]