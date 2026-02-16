# gunicorn.conf.py
import os

# ── Binding ────────────────────────────────────────────────────────────────────
# Docker:  set GUNICORN_BIND=0.0.0.0:8000  (via docker run -e or docker-compose)
# Direct EC2 (systemd): defaults to Unix socket (picked up by nginx)
bind = os.environ.get("GUNICORN_BIND", "unix:/run/wanderlog/gunicorn.sock")

# ── Workers ────────────────────────────────────────────────────────────────────
workers     = 2          # safe for SQLite (no concurrent writes)
worker_class = "sync"
timeout     = 120        # generous window for 200 MB video uploads
keepalive   = 5

# ── Logging — stdout/stderr, captured by Docker or systemd journal ─────────────
accesslog = "-"
errorlog  = "-"
loglevel  = "info"
access_log_format = '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s"'

# ── Process naming ─────────────────────────────────────────────────────────────
proc_name = "wanderlog"

# ── Request limits ─────────────────────────────────────────────────────────────
limit_request_line       = 8190
limit_request_fields     = 100
limit_request_field_size = 8190
