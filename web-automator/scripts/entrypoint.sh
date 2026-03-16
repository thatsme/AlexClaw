#!/bin/bash
set -e

echo "=== Web Automator starting ==="
echo "  DISPLAY=${DISPLAY}"
echo "  API port: 6900"
echo "  noVNC port: ${NOVNC_PORT:-6080}"

exec supervisord -n -c /etc/supervisor/conf.d/web-automator.conf
