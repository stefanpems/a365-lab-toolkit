"""Minimal Bedrock Converse assistant hosted in an isolated AgentCore session."""

from __future__ import annotations

import json
import os
from pathlib import Path
from threading import Lock

from bedrock_agentcore.runtime import BedrockAgentCoreApp
import boto3
from botocore.config import Config


settings = json.loads(Path(__file__).with_name("agent_config.json").read_text(encoding="utf-8"))
app = BedrockAgentCoreApp()
model = boto3.client(
    "bedrock-runtime",
    region_name=os.environ["AWS_REGION"],
    config=Config(retries={"total_max_attempts": 1}),
)
messages: list[dict] = []
conversation_lock = Lock()


@app.entrypoint
def invoke(payload: dict) -> dict:
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("A nonempty prompt string is required.")
    with conversation_lock:
        candidate = [*messages, {"role": "user", "content": [{"text": prompt}]}]
        response = model.converse(
            modelId=settings["model_id"],
            system=[{"text": settings["instructions"]}],
            messages=candidate,
            inferenceConfig={"maxTokens": settings["max_tokens"]},
        )
        answer = response["output"]["message"]
        text = "".join(block["text"] for block in answer["content"] if "text" in block)
        if not text:
            raise ValueError("The model returned no text response.")
        if response.get("stopReason") == "max_tokens":
            raise ValueError("The model reached max_tokens; increase the configured limit before retrying.")
        messages[:] = [*candidate, answer]
        return {"result": text, "stop_reason": response.get("stopReason")}


if __name__ == "__main__":
    app.run()
