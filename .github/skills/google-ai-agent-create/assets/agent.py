import os

from google.adk.agents import Agent
import vertexai
from vertexai.agent_engines import AdkApp


vertexai.init(
    project=os.environ["GOOGLE_CLOUD_PROJECT"],
    location=os.environ["GOOGLE_CLOUD_LOCATION"],
)

root_agent = AdkApp(
    agent=Agent(
        name=os.environ["GOOGLE_AGENT_NAME"],
        model=os.environ["GOOGLE_AGENT_MODEL"],
        description=os.environ["GOOGLE_AGENT_DESCRIPTION"],
        instruction=os.environ["GOOGLE_AGENT_INSTRUCTION"],
    ),
    enable_tracing=False,
)
