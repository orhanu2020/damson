#!/bin/bash
# Starts the LangGraph agent server Damson uses for the Company tab.
cd "$(dirname "$0")/../agents" || exit 1
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
exec .venv/bin/python server.py
