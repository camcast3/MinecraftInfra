ARG BASE_IMAGE=alpine/socat:1.8.1.3@sha256:3d9e7966201dd3a065df591020a09fd3c70845de7e7086e3531ea69db774406b
FROM ${BASE_IMAGE}

ARG RELEASE
ENV RELEASE=${RELEASE}

COPY fixture-server.sh /usr/local/bin/fixture-server
RUN chmod 0555 /usr/local/bin/fixture-server

ENTRYPOINT ["/usr/local/bin/fixture-server"]
