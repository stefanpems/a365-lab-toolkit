# Container image for the Agent Framework sample agent (Azure Container Apps)
FROM python:3.12-slim

# Avoid interactive prompts, ensure stdout/stderr are unbuffered for ACA logs.
# PYTHONUTF8/PYTHONIOENCODING force UTF-8 so emoji in log prints don't crash
# under the container's default C/POSIX locale.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUTF8=1 \
    PYTHONIOENCODING=utf-8 \
    PORT=3978

WORKDIR /app

# Install uv (fast installer) used to resolve the pinned agent-framework stack
RUN pip install --no-cache-dir uv

# Install dependencies first (better layer caching)
COPY pyproject.toml README.md ./
# Copy the application code
COPY . .

# Install the project (and its pinned deps) into the system environment
RUN uv pip install --system -e .

EXPOSE 3978

# The generic host reads PORT from the environment and serves /api/messages
CMD ["python", "start_with_generic_host.py"]
