# The one-shot init service: OpenBao's own image (for its CLI) plus openssl,
# which the image does not ship, to make the TLS certificates.
FROM openbao/openbao:2.6.3@sha256:a60afafda36337abe833c4a63894bf1095098f29abea4091e7e555a33dd52889

USER root
RUN apk add --no-cache openssl
COPY init.sh /usr/local/bin/openbao-init
RUN chmod 0555 /usr/local/bin/openbao-init

ENTRYPOINT ["/usr/local/bin/openbao-init"]
