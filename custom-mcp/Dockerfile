# Agent 365 sample custom MCP server — image for Azure Container Apps.
# Hosts two MCP servers in one container: /anon/mcp (NoAuth) and /auth/mcp (EntraOAuth).
FROM python:3.12-slim

# No .pyc files, unbuffered logs. FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false disables the
# anti DNS-rebinding guard (required behind a public ACA FQDN; lab, no-auth ingress).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000 \
    FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

EXPOSE 8000

CMD ["python", "server.py"]
