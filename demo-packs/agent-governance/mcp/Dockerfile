# Demo MCP backends of the agent-governance pack: image for Azure Container Apps; one server per container at /mcp.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000 \
    FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py mcp-config.json ./
EXPOSE 8000
CMD ["python", "server.py"]
