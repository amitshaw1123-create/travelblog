#!/usr/bin/env bash
# deploy/ec2-docker-setup.sh
# One-time bootstrap for the EC2 instance (Docker + nginx deployment).
# Run once via SSH after launching a fresh Ubuntu 22.04 t2.micro:
#
#   ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP>
#   bash /home/ubuntu/travel_blog/deploy/ec2-docker-setup.sh
#
# After this script: GitHub Actions handles all future deployments.

set -euo pipefail

DATA_DIR="/home/ubuntu/data"

echo ""
echo "======================================================"
echo "  WanderLog — EC2 Docker Bootstrap"
echo "======================================================"
echo ""

# ── [1/5] Install Docker ──────────────────────────────────────────────────────
echo "[1/5] Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker ubuntu
    echo "  Docker installed. (SSH re-login needed to use docker without sudo,"
    echo "  but this script uses 'sudo docker' so it works immediately.)"
else
    echo "  Docker already installed, skipping."
fi

# ── [2/5] Install nginx ───────────────────────────────────────────────────────
echo "[2/5] Installing nginx..."
sudo apt-get update -y -q
sudo apt-get install -y -q nginx

# ── [3/5] Persistent data directories ────────────────────────────────────────
echo "[3/5] Creating persistent data directories..."
mkdir -p "$DATA_DIR/uploads/images"
mkdir -p "$DATA_DIR/uploads/videos"

# Initialise an empty SQLite DB so the bind mount has a real file to attach to.
# Docker cannot bind-mount a file that doesn't exist yet on the host.
if [ ! -f "$DATA_DIR/travel_blog.db" ]; then
    echo "  Initialising empty database..."
    python3 -c "import sqlite3; sqlite3.connect('$DATA_DIR/travel_blog.db').close()"
    echo "  Database created at $DATA_DIR/travel_blog.db"
else
    echo "  Database already exists, skipping."
fi

# ── [4/5] Configure nginx ─────────────────────────────────────────────────────
echo "[4/5] Configuring nginx..."

# Copy the Docker-specific nginx config (proxies to localhost:8000)
# The project must already be uploaded for this path to exist.
NGINX_SRC=""
if [ -f "/home/ubuntu/travel_blog/deploy/nginx-docker.conf" ]; then
    NGINX_SRC="/home/ubuntu/travel_blog/deploy/nginx-docker.conf"
else
    # Fallback: write a minimal inline config so nginx starts even without the file
    echo "  nginx-docker.conf not found — writing inline fallback config."
    NGINX_SRC="/tmp/wanderlog-nginx.conf"
    cat > "$NGINX_SRC" <<'NGINXEOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 200M;
    proxy_read_timeout 120s;

    location /static/ {
        # Static files are served by gunicorn inside the container for now.
        # Upload the project and run this script again to serve them via nginx.
        proxy_pass http://127.0.0.1:8000;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host             $host;
        proxy_set_header X-Real-IP        $remote_addr;
        proxy_set_header X-Forwarded-For  $proxy_add_x_forwarded_for;
    }
}
NGINXEOF
fi

sudo cp "$NGINX_SRC" /etc/nginx/sites-available/wanderlog
sudo ln -sf /etc/nginx/sites-available/wanderlog /etc/nginx/sites-enabled/wanderlog
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx
echo "  nginx configured."

# ── [5/5] Done ────────────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<EC2_PUBLIC_IP>")

echo ""
echo "======================================================"
echo "  Bootstrap complete!"
echo "======================================================"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Push your code to GitHub (main branch)."
echo "   GitHub Actions will build the Docker image, push it to GHCR,"
echo "   and deploy it to this server automatically."
echo ""
echo "2. Add these secrets to your GitHub repo"
echo "   (Settings → Secrets and variables → Actions):"
echo ""
echo "   EC2_HOST          = $PUBLIC_IP"
echo "   EC2_SSH_KEY       = <paste the full contents of your .pem key file>"
echo "   SECRET_KEY        = <run: python3 -c \"import secrets; print(secrets.token_hex(32))\">"
echo "   ANTHROPIC_API_KEY = sk-ant-..."
echo ""
echo "3. After the first deployment succeeds, access your app at:"
echo "   http://$PUBLIC_IP"
echo ""
echo "Useful commands:"
echo "   docker logs -f wanderlog            # live app logs"
echo "   docker ps                           # running containers"
echo "   sudo journalctl -u nginx -f         # nginx logs"
echo "   sudo tail -f /var/log/nginx/wanderlog_error.log"
echo ""
