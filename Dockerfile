FROM ubuntu:noble-20240429

RUN DEBIAN_FRONTEND=noninteractive \
  apt update \
  && apt upgrade \
  && apt install -y wget \
  && apt install -y unzip \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir /packit
RUN wget -O 'Linux64-bitx86.zip' https://nightly.link/packwiz/packwiz/workflows/go/main/Linux%2064-bit%20x86.zip
RUN unzip 'Linux64-bitx86.zip'

VOLUME ["/modpack"]
WORKDIR /modpack

EXPOSE 8080

ENTRYPOINT [ "/packit/packwiz", "server", "--port", "8080"]