# syntax=docker/dockerfile:1

# Base image pinned by version AND digest so every build uses the exact same bytes.
# To upgrade: docker pull python:3.12-slim-bookworm, then update both values below.
ARG PYTHON_IMAGE=python:3.12.15-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258

# ---------- Stage 1: install dependencies ----------
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Copy only requirements first so this layer is cached until dependencies change.
COPY app/requirements.txt .

RUN --mount=type=cache,target=/root/.cache/pip \
    python -m venv /opt/venv \
 && /opt/venv/bin/pip install -r requirements.txt \
 && /opt/venv/bin/pip uninstall -y pip

# ---------- Stage 2: minimal runtime ----------
FROM ${PYTHON_IMAGE} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_ENV=production

# Unprivileged user with a fixed UID that Kubernetes can enforce via runAsNonRoot.
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

# Only the installed packages and the app code reach the final image.
# Files stay owned by root and read-only, so the app user cannot modify them.
COPY --from=builder /opt/venv /opt/venv
COPY --chmod=0444 app/app.py .

USER 10001:10001
EXPOSE 8080

# Uses Python's standard library because slim images do not include curl.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"]

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-tmp-dir", "/tmp", "--access-logfile", "-", "app:app"]
