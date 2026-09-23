FROM python:3.12-slim AS base

# System dependencies: Xvfb, VNC, noVNC, supervisor
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb x11vnc novnc websockify supervisor \
    curl xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Browsers go outside /root (mode 700), where the non-root runtime user can
# read them.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

# Patchright (patched Playwright — bypasses Cloudflare/PerimeterX __playwright detection)
# + real Google Chrome on amd64, Chromium on arm64 (Chrome for Testing has no ARM64 Linux builds)
RUN pip install --no-cache-dir patchright \
    && if [ "$(dpkg --print-architecture)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then \
         python -m patchright install chromium && python -m patchright install-deps chromium; \
       else \
         python -m patchright install chrome && python -m patchright install-deps chrome; \
       fi \
    && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"

# App dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

# App code
COPY app/ /app/

# Supervisor config (fix Windows CRLF)
COPY supervisord.conf /etc/supervisor/conf.d/web-automator.conf
RUN sed -i 's/\r$//' /etc/supervisor/conf.d/web-automator.conf

# Entrypoint script (fix Windows CRLF)
COPY scripts/entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# The runtime user. The root filesystem is read-only at run time and /tmp is a
# tmpfs, so everything the processes write — X socket, browser profile,
# downloads, supervisord's pid file — goes under /tmp.
RUN useradd --uid 10001 --user-group --no-create-home --shell /usr/sbin/nologin automator

ENV DISPLAY=:99
ENV DOWNLOAD_DIR=/tmp/downloads
ENV NOVNC_PORT=6080
ENV HOME=/tmp

EXPOSE 6900 6080

USER 10001:10001

# The test suite's dependencies, pinned, in a stage of their own: the runtime
# image does not carry them, and the test container cannot install anything
# at run time (its root filesystem is read-only too).
FROM base AS test
USER root
COPY requirements-test.txt /tmp/requirements-test.txt
RUN pip install --no-cache-dir -r /tmp/requirements-test.txt && rm /tmp/requirements-test.txt
USER 10001:10001

# The last stage is what `docker compose build` builds by default.
FROM base AS runtime
CMD ["/entrypoint.sh"]
