#!/usr/bin/env bash
# deploy/setup.sh
# One-time provisioning script for the WanderLog EC2 instance.
# Run as the default ubuntu user (has passwordless sudo).
#
# Usage (after uploading the project to /home/ubuntu/travel_blog/):
#   bash /home/ubuntu/travel_blog/deploy/setup.sh
#
# Idempotent — safe to run again if something fails midway.

set -euo pipefail

APP_DIR="/home/ubuntu/travel_blog"
APP_USER="wanderlog"
VENV_DIR="$APP_DIR/.venv"

echo ""
echo "======================================================"
echo "  WanderLog EC2 Setup"
echo "======================================================"
echo ""

# ── [1/8] System packages ─────────────────────────────────────────────────────
echo "[1/8] Installing system packages..."
sudo apt-get update -y -q
sudo apt-get install -y -q \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    python3-pip \
    nginx \
    curl \
    build-essential

# ── [2/8] Create unprivileged app user ────────────────────────────────────────
echo "[2/8] Creating app user '$APP_USER'..."
if ! id "$APP_USER" &>/dev/null; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
    echo "  Created user: $APP_USER"
else
    echo "  User $APP_USER already exists, skipping."
fi

# ── [3/8] Set file ownership and permissions ──────────────────────────────────
echo "[3/8] Setting file permissions..."
sudo chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
sudo chmod -R 750 "$APP_DIR"
# Uploads directory needs to be readable by nginx (www-data)
sudo chmod -R 775 "$APP_DIR/static/uploads"
# Allow SQLite to create -wal and -shm journal files alongside the DB
sudo chmod 664 "$APP_DIR/travel_blog.db" 2>/dev/null || true

# ── [4/8] Python virtual environment ─────────────────────────────────────────
echo "[4/8] Setting up Python virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    sudo -u "$APP_USER" python3.12 -m venv "$VENV_DIR"
fi
sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install --upgrade pip -q
sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" -q
echo "  Dependencies installed."

# ── [5/8] Upload directories ──────────────────────────────────────────────────
echo "[5/8] Creating upload directories..."
sudo -u "$APP_USER" mkdir -p "$APP_DIR/static/uploads/images"
sudo -u "$APP_USER" mkdir -p "$APP_DIR/static/uploads/videos"

# ── [6/8] Initialise the database ─────────────────────────────────────────────
echo "[6/8] Initialising the database..."
sudo -u "$APP_USER" "$VENV_DIR/bin/python" -c "
import sys
sys.path.insert(0, '$APP_DIR')
from app import init_db
init_db()
print('  Database ready.')
"

# ── [7/8] Systemd service ─────────────────────────────────────────────────────
echo "[7/8] Installing and starting systemd service..."
sudo cp "$APP_DIR/deploy/wanderlog.service" /etc/systemd/system/wanderlog.service
sudo systemctl daemon-reload
sudo systemctl enable wanderlog
sudo systemctl restart wanderlog
sleep 2
sudo systemctl is-active wanderlog && echo "  Service is running." || echo "  WARNING: Service failed to start. Check: sudo journalctl -u wanderlog -n 50"

# ── [8/8] nginx ───────────────────────────────────────────────────────────────
echo "[8/8] Configuring nginx..."
sudo cp "$APP_DIR/deploy/nginx.conf" /etc/nginx/sites-available/wanderlog
sudo ln -sf /etc/nginx/sites-available/wanderlog /etc/nginx/sites-enabled/wanderlog
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx
echo "  nginx configured."

# ── Done ──────────────────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<EC2_PUBLIC_IP>")

echo ""
echo "======================================================"
echo "  Setup complete!"
echo "  App URL: http://$PUBLIC_IP"
echo "======================================================"
echo ""
echo "NEXT STEP — inject your secrets (required before the app works):"
echo ""
echo "  sudo systemctl edit wanderlog"
echo ""
echo "  Paste this into the editor that opens, filling in your values:"
echo ""
echo "  [Service]"
echo "  Environment=SECRET_KEY=\$(python3 -c \"import secrets; print(secrets.token_hex(32))\")"
echo "  Environment=ANTHROPIC_API_KEY=sk-ant-..."
echo ""
echo "  Save and close, then:"
echo "  sudo systemctl restart wanderlog"
echo ""
echo "  Check logs:"
echo "  sudo journalctl -u wanderlog -f"
echo ""
