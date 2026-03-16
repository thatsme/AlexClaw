FROM python:3.12-slim

# System dependencies: Xvfb, VNC, noVNC, supervisor
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb x11vnc novnc websockify supervisor \
    curl xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Patchright (patched Playwright — bypasses Cloudflare/PerimeterX __playwright detection)
# + real Google Chrome on amd64, Chromium on arm64 (Chrome for Testing has no ARM64 Linux builds)
RUN pip install --no-cache-dir patchright \
    && if [ "$(dpkg --print-architecture)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then \
         python -m patchright install chromium && python -m patchright install-deps chromium; \
       else \
         python -m patchright install chrome && python -m patchright install-deps chrome; \
       fi

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

# Download directory
RUN mkdir -p /tmp/downloads /tmp/recordings

ENV DISPLAY=:99
ENV DOWNLOAD_DIR=/tmp/downloads
ENV NOVNC_PORT=6080

EXPOSE 6900 6080

CMD ["/entrypoint.sh"]
