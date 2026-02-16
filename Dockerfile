# ── Stage 1: build dependencies ───────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /install

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/deps -r requirements.txt


# ── Stage 2: production image ─────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# Create non-root user (mirrors the systemd service approach)
RUN useradd --system --no-create-home --shell /bin/false wanderlog

# Copy installed packages from builder stage
COPY --from=builder /deps /usr/local

# Copy application code (owned by app user)
COPY --chown=wanderlog:wanderlog . .

# Create persistent-data directories — these are bind-mounted at runtime on EC2
# so uploads and the DB survive container restarts and re-deploys.
RUN mkdir -p static/uploads/images static/uploads/videos \
 && chown -R wanderlog:wanderlog static/uploads

# Gunicorn will bind to 0.0.0.0:8000 (set via GUNICORN_BIND in gunicorn.conf.py)
EXPOSE 8000

USER wanderlog

# gunicorn.conf.py is read automatically via -c flag
CMD ["gunicorn", "-c", "gunicorn.conf.py", "app:app"]
