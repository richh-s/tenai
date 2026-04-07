# Stage 1: Build frontend SPA
FROM node:22-slim AS frontend
WORKDIR /app/webapp/frontend
COPY webapp/frontend/package*.json ./
RUN npm ci --production=false
COPY webapp/frontend/ ./
RUN npm run build

# Stage 2: Python backend
FROM python:3.12-slim

# Install SSH client for remote device access
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps
RUN pip install --no-cache-dir \
    fastapi \
    uvicorn[standard] \
    python-dotenv \
    pydantic \
    pyyaml

# Copy application
COPY webapp/ /app/webapp/
COPY config/ /app/config/
COPY scripts/ /app/scripts/

# Copy built frontend from stage 1
COPY --from=frontend /app/webapp/frontend/dist /app/webapp/frontend/dist

# Create non-root user (UID 1000 matches typical host user)
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app

# Default env
ENV WEBAPP_PORT=7700 \
    WEBAPP_HOST=0.0.0.0 \
    CONFIG_DIR=/app/config \
    PYTHONPATH=/app/webapp

EXPOSE 7700

# Entrypoint fixes SSH permissions before starting the server
ENTRYPOINT ["/app/webapp/entrypoint.sh"]
CMD ["python", "webapp/server.py"]

# Switch to non-root user (after entrypoint setup)
USER appuser
