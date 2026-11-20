"""LangGraph workflow for one company agent: plan -> act -> reply.

The LLM is a local Ollama model (DAMSON_MODEL). Set DAMSON_FAKE_LLM=1 to run without a model (tests).
"""
import json
import os
import urllib.request
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

OLLAMA = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
MODEL = os.environ.get("DAMSON_MODEL", "qwen3.6:35b-a3b")


class AgentState(TypedDict, total=False):
    name: str
    role: str
    command: str
    plan: str
    result: str
    reply: str


def llm(system: str, user: str) -> str:
    if os.environ.get("DAMSON_FAKE_LLM"):
        return f"[sahte] {user[:60]}"
    body = json.dumps({
        "model": MODEL,
        "stream": False,
        "think": False,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }).encode()
    req = urllib.request.Request(OLLAMA + "/api/chat", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)["message"]["content"].strip()


def persona(state: AgentState) -> str:
    return (f"You are {state['name']}, working at the company as '{state['role']}'. "
            "The user is your boss. Reply in the language the command is written in, short and clear.")


def plan(state: AgentState) -> AgentState:
    text = llm(persona(state) + " Write a plan of at most 3 short steps for the given command.", state["command"])
    return {"plan": text}


def act(state: AgentState) -> AgentState:
    # Placeholder for real tools (files, shell, browser). For now the agent only reasons about the plan.
    text = llm(persona(state) + " Assume you carried out the plan and summarize the result in one sentence.",
               f"Command: {state['command']}\nPlan: {state['plan']}")
    return {"result": text}


def reply(state: AgentState) -> AgentState:
    text = state.get("result", "").strip().replace("\n", " ")
    if len(text) > 160:
        text = text[:157].rstrip() + "..."
    return {"reply": f"Very well. {text}".strip()}


def build():
    g = StateGraph(AgentState)
    g.add_node("plan", plan)
    g.add_node("act", act)
    g.add_node("reply", reply)
    g.add_edge(START, "plan")
    g.add_edge("plan", "act")
    g.add_edge("act", "reply")
    g.add_edge("reply", END)
    return g.compile()


GRAPH = build()


def run(name: str, role: str, command: str) -> str:
    return GRAPH.invoke({"name": name, "role": role, "command": command})["reply"]
