# The one-shot init service: OpenBao's own image (for its CLI) plus openssl,
# which the image does not ship, to make the TLS certificates.
FROM openbao/openbao:2.6.3@sha256:a60afafda36337abe833c4a63894bf1095098f29abea4091e7e555a33dd52889

USER root
# Pinned to the version this image's Alpine release (3.24) ships, so a rebuild
# installs the same openssl. A newer package fails the build rather than
# changing silently: bump the pin with the base image.
RUN apk add --no-cache openssl=3.5.8-r0
COPY init.sh /usr/local/bin/openbao-init
# The on-demand snapshot (the `openbao-backup` service runs this image).
COPY backup.sh /usr/local/bin/openbao-backup
RUN chmod 0555 /usr/local/bin/openbao-init /usr/local/bin/openbao-backup

ENTRYPOINT ["/usr/local/bin/openbao-init"]
