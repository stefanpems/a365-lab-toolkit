# Agent 365 lab web-fetch MCP server - image for Azure Container Apps (one tool: fetch_url at /mcp).
FROM python:3.12-slim

# No .pyc files, unbuffered logs. FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false disables the anti
# DNS-rebinding Host/Origin guard (required behind a public ACA FQDN; lab, no-auth ingress).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000 \
    FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py web_fetch.py ./

EXPOSE 8000

CMD ["python", "server.py"]
