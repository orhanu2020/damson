#!/usr/bin/env python3
"""Checks whether local Ollama models are suitable for Damson (speed, tool calling, thinking switch).
Usage:  python3 scripts/test_ollama.py [model ...] 2>&1 | tee ollama-test.txt
Default models: qwen3.6:35b-a3b qwen3-coder:30b. The first request per model loads it into memory (can take minutes)."""
import json, sys, time, urllib.request, urllib.error

BASE = "http://localhost:11434"
MODELS = sys.argv[1:] or ["qwen3.6:35b-a3b", "qwen3-coder:30b"]


def call(method, path, body=None, timeout=900):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={"Content-Type": "application/json"})
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read()), time.time() - start, None
    except urllib.error.HTTPError as e:
        return None, time.time() - start, "HTTP %d: %s" % (e.code, e.read().decode()[:300])
    except Exception as e:
        return None, time.time() - start, str(e)


def rate(d):
    ec, ed = d.get("eval_count", 0), d.get("eval_duration", 0)
    return ec / (ed / 1e9) if ed else 0.0


def short(s, n=150):
    s = (s or "").replace("\n", " ")
    return s if len(s) <= n else s[:n] + "..."


def chat(model, messages, **extra):
    body = {"model": model, "stream": False, "messages": messages, "options": {"num_predict": extra.pop("num_predict", 600), "temperature": 0.2}}
    body.update(extra)
    return call("POST", "/api/chat", body)


print("Damson local-model check")
print("Time:", time.strftime("%Y-%m-%d %H:%M:%S"))
d, secs, err = call("GET", "/api/tags", timeout=10)
if err:
    print("Ollama is not reachable at", BASE, "->", err, "\nStart Ollama and try again.")
    sys.exit(1)
installed = [m["name"] for m in d.get("models", [])]
print("Installed models:", ", ".join(installed) or "(none)")

results = {}
for model in MODELS:
    print("\n" + "=" * 60 + "\nMODEL:", model)
    r = {}
    if model not in installed:
        print("  Not installed. Run: ollama pull", model)
        results[model] = {"installed": False}
        continue

    # 1. warm-up + basic reply (includes load time)
    d, secs, err = chat(model, [{"role": "user", "content": "Reply with exactly one word: pong"}], think=False, num_predict=200)
    if err and "think" in err.lower():
        d, secs, err = chat(model, [{"role": "user", "content": "Reply with exactly one word: pong"}], num_predict=800)
        r["think_false_accepted"] = False
    else:
        r["think_false_accepted"] = err is None
    print("[1] first reply (includes model load): %.1fs" % secs, "->", repr(short(d["message"]["content"])) if d else err)
    print("    'think: false' accepted:", r["think_false_accepted"])

    # 2. conversational speed, thinking off, warm
    d, secs, err = chat(model, [{"role": "user", "content": "In one short sentence, say good morning and ask how you can help."}], think=False, num_predict=120)
    if d:
        r["voice_secs"], r["voice_tps"] = secs, rate(d)
        m = d["message"]
        print("[2] short reply: %.1fs, %.1f tokens/s, reasoning text present: %s" % (secs, rate(d), bool(m.get("thinking")) or "<think>" in m.get("content", "")))
        print("    reply:", repr(short(m.get("content", ""))))
    else:
        print("[2] FAILED:", err)

    # 3. tool calling
    tools = [{"type": "function", "function": {"name": "get_weather", "description": "Get the current weather for a city",
              "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
    d, secs, err = chat(model, [{"role": "user", "content": "What is the weather in Paris right now? Use the tool."}], tools=tools, think=False, num_predict=400)
    if d:
        calls = d["message"].get("tool_calls") or []
        r["tools"] = bool(calls)
        print("[3] tool calling:", "OK -> " + json.dumps(calls[0].get("function", {}))[:150] if calls else "NO tool call. Reply: " + repr(short(d["message"].get("content", ""))))
    else:
        r["tools"] = False
        print("[3] tool calling FAILED:", err)

    # 4. development suggestion (quality + speed)
    prompt = "I have a Swift actor that caches API responses. In 4 short bullet points, suggest how to handle cache invalidation and concurrent duplicate requests."
    d, secs, err = chat(model, [{"role": "user", "content": prompt}], think=False, num_predict=500)
    if d:
        r["dev_tps"] = rate(d)
        print("[4] dev suggestion: %.1fs, %.1f tokens/s" % (secs, rate(d)))
        print("    ", short(d["message"].get("content", ""), 500))
    else:
        print("[4] FAILED:", err)
    results[model] = r

print("\n" + "=" * 60 + "\nSUMMARY (voice-ready means a short reply in under 4 seconds)")
for model, r in results.items():
    if not r.get("installed", True):
        print("-", model, ": not installed")
        continue
    voice = r.get("voice_secs")
    print("- %s: speed %.0f tok/s, short reply %s, tools %s, think:false %s" % (
        model, r.get("voice_tps", 0), ("%.1fs (%s)" % (voice, "voice-ready" if voice < 4 else "too slow for voice")) if voice else "n/a",
        "yes" if r.get("tools") else "NO", "ok" if r.get("think_false_accepted") else "not accepted"))
