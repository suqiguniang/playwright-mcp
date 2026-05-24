#!/bin/bash
set -e

# Clean up stale locks
rm -f /tmp/.X99-lock

# Set Chinese locale
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8

# Setup VNC password
if [ -z "$VNC_PASSWORD" ]; then
  echo "Error: VNC_PASSWORD is required"
  exit 1
fi
mkdir -p ~/.vnc
echo "$VNC_PASSWORD" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Start Xvnc (supports dynamic resolution via RandR)
Xvnc :99 -geometry 1920x1080 -depth 24 \
  -rfbport 5900 \
  -PasswordFile ~/.vnc/passwd \
  -AlwaysShared \
  -AcceptSetDesktopSize \
  -SecurityTypes VncAuth \
  -desktop "Playwright MCP" &

sleep 2
export DISPLAY=:99

# Enable VNC clipboard support
vncconfig -display :99 -nowin &
sleep 1

# Sync X11 PRIMARY and CLIPBOARD selections (background to avoid blocking)
(
  # Wait a bit for X server to be fully ready, then start autocutsel
  sleep 2
  autocutsel -fork
  autocutsel -selection PRIMARY -fork
) &

# Start dbus (required for fcitx)
eval $(dbus-launch --sh-syntax)
export DBUS_SESSION_BUS_ADDRESS

# Setup input method environment
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export DefaultIMModule=fcitx

# Start fcitx input method
fcitx -d &
sleep 1

# Start openbox window manager (required for Chrome to maximize/resize)
openbox &
sleep 1

# Create index.html redirect to vnc.html
echo '<html><head><meta http-equiv="refresh" content="0;url=vnc.html"></head></html>' > /usr/share/novnc/index.html

# Start noVNC with auto-resize enabled
websockify --web=/usr/share/novnc 6080 localhost:5900 &

# Patch noVNC to enable resize by default
sed -i "s/'resize', 'off'/'resize', 'remote'/g" /usr/share/novnc/app/ui.js 2>/dev/null || true

# Start Chrome with CDP enabled (persistent browser)
mkdir -p /data/chrome-profile
# 启动 Chrome 前，清理可能残留的锁文件
echo "Cleaning up stale Chrome lock files..."
rm -f /data/chrome-profile/SingletonLock
rm -f /data/chrome-profile/SingletonSocket
rm -f /data/chrome-profile/SingletonCookie

# 然后启动 Chrome
google-chrome \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --remote-debugging-port=9222 \
  --user-data-dir=/data/chrome-profile \
  --no-first-run \
  --start-maximized \
  $EXTENSION_ARGS \
  "about:blank" &
# Build extension loading args
EXTENSION_ARGS=""
if [ -d "/data/extensions/switchyomega" ]; then
  EXTENSION_ARGS="--load-extension=/data/extensions/switchyomega"
fi

google-chrome \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --remote-debugging-port=9222 \
  --user-data-dir=/data/chrome-profile \
  --no-first-run \
  --start-maximized \
  $EXTENSION_ARGS \
  "about:blank" &

# Wait for Chrome CDP to be ready and get WebSocket URL
echo "Waiting for Chrome CDP..."
WS_URL=""
for i in {1..30}; do
  WS_URL=$(curl -s http://localhost:9222/json/version | grep -o '"webSocketDebuggerUrl": "[^"]*"' | cut -d'"' -f4)
  if [ -n "$WS_URL" ]; then
    echo "Chrome CDP ready: $WS_URL"
    break
  fi
  sleep 1
done

if [ -z "$WS_URL" ]; then
  echo "Failed to get Chrome WebSocket URL"
  exit 1
fi

# Start Playwright MCP on internal port (no external access)
MCP_INTERNAL_PORT=8932
node /app/cli.js \
  --port $MCP_INTERNAL_PORT \
  --host 127.0.0.1 \
  --allowed-hosts '*' \
  --caps vision,pdf \
  --cdp-endpoint "$WS_URL" &

# Wait for MCP to be ready
echo "Waiting for MCP to start..."
for i in {1..30}; do
  if curl -s http://127.0.0.1:$MCP_INTERNAL_PORT > /dev/null 2>&1; then
    echo ""
    echo "=== MCP Ready ==="
    echo "External endpoint: http://<host>:8931/mcp (with Bearer Token auth)"
    echo "Ignore the localhost:8932 config above, that is internal only."
    echo ""
    break
  fi
  sleep 1
done

# Start screenshot file server
mkdir -p /tmp/playwright-output
cd /tmp/playwright-output && python3 -m http.server 8933 --bind 0.0.0.0 &
cd /

# Start auth nginx on external port
if [ -z "$MCP_TOKEN" ]; then
  echo "Error: MCP_TOKEN is required"
  exit 1
fi
sed "s/__MCP_TOKEN__/$MCP_TOKEN/g" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
exec nginx -g 'daemon off;'
