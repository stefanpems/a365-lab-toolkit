# Knowledge-base MCP shim — image for Azure Container Apps.
# Hosts ONE MCP server at the ROOT path '/mcp' (single-segment path required by Agent 365
# registration) that queries an Azure AI Search index with a read-only query key.
FROM python:3.12-slim

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
