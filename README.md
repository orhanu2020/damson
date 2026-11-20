# Damson

A vendor-agnostic, voice-first AI assistant for macOS. Press **Start listening**, talk to it like a person, and it answers by voice or text.

- Native Swift + SwiftUI, macOS 14+, menu-bar app that keeps running when the window is closed
- Models behind one `LLMProvider` protocol: **Claude** (default) and **Ollama** (local) included; adding OpenAI or Gemini is one new file
- Tool layer with an approval policy (**anything that changes your Mac or an online account asks you first**); the task/helper-agent system that used it has been removed, so it is currently unused
- Voice in and out, with barge-in (interrupt Damson mid-sentence) and push to talk

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and diagrams.

> **Status: first version, written without a compiler.** The code has been syntax-checked but not yet built or run. Expect a few compiler errors on the first `swift build`; they should be quick fixes. See "First build" below.

## First build

Requirements: macOS 14 or later, Xcode 15.3+ (or the Command Line Tools with Swift 5.9+).

```bash
cd ~/Projects/Damson
swift build          # compile everything
swift test           # run the unit tests (no network, no API key needed)
scripts/make_app.sh  # builds build/Damson.app
open build/Damson.app
```

Use the `.app` (not `swift run`): macOS only shows the microphone and speech-recognition permission prompts for a proper app bundle.

You can also open `Package.swift` in Xcode and run the `Damson` scheme for development.

## First run

1. Click the menu-bar icon, choose **Open Damson**, go to **Settings**.
2. Install Claude Code and sign in with your Claude account (run `claude` once in Terminal). Damson uses that login, so Claude runs on your subscription and no API key is needed.
3. In **Chat**, click **Start listening** and approve the microphone and speech-recognition prompts.
4. Press **Start listening** and talk freely. It keeps listening until you press **Stop listening**.

Push to talk: hold **Control + Option + Space** anywhere, speak, release.

## Using it

| You say or do | What happens |
|---|---|
| "What time is it in Tokyo?" | Answered directly |
| A tool wants to change something | An approval card appears (and is read aloud). Click, or say "approve" or "deny" (currently unused, see Safety model) |
| Interrupt while Damson is talking | It stops and listens |

Approvals are decided only by you, by your clicks or your exact spoken words. A model can never approve an action.

## Safety model

- **Observe** actions (read files, list folders, read-only shell commands, fetch public web pages, read the sandbox browser) run immediately.
- **Change** actions (write outside the scratch folder, any other shell command, clicking or typing in the browser, MCP tools that aren't marked read-only) pause and ask. Unknown or ambiguous actions count as Change.
- A scratch folder under `~/Library/Application Support/Damson/scratch/` is the one place tools can write freely.
- Reading likely-secret locations (`~/.ssh`, Keychains, `.env`, cloud credentials) also needs approval.
- Text from web pages, files and tool output is treated as data, never as instructions.
- Every tool call and approval is stored in the audit log (`events` table in the SQLite database).

Honest limits: the shell classifier is deliberately conservative but is not a sandbox. Approving a command runs it with your user's permissions. Fetching a public URL can still send information in the URL, so very long URLs need approval.

## MCP tools (optional)

Create `~/Library/Application Support/Damson/mcp.json`:

```json
{ "servers": [ { "name": "filesystem", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Projects"] } ] }
```

Then use Settings > Reload MCP servers. MCP tools need approval unless the server marks them read-only.

## Project layout

```
Sources/
  DamsonSupport/    locking helper, app paths
  DamsonProviders/  LLMProvider protocol, neutral types, Claude + Ollama adapters, model router
  DamsonStore/      SQLite (system library)
  DamsonTools/      Tool protocol, policy gate, shell classifier, files, web, sandbox browser, MCP client
  DamsonCore/       engine (conversation), approvals, company view
  DamsonVoice/      speech-to-text, text-to-speech, conversation controller, hotkey
  DamsonUI/         SwiftUI: chat, company, settings, approvals, menu bar
  DamsonApp/        @main
Tests/DamsonTests/  unit tests
docs/               architecture notes
```

## Implementation status

| Milestone | State |
|---|---|
| M1 shell, store, settings | written |
| M2 provider layer + Claude, contract-style tests | written |
| M3 orchestrator (classify, plan, schedule, report, verify) | removed |
| M4 Kanban board | removed |
| M5 policy gate, approvals, shell/files tools | written, unit-tested |
| M6 voice: conversation mode, barge-in, push to talk, notifications | written; no wake word, listening starts with the button |
| M6 WhisperKit speech-to-text | **not done** (Apple on-device speech is used) |
| M7 sandboxed browser, MCP | written |
| M8 Ollama provider, packaging script | written; signing/notarization for public release still to do |

Known gaps: quiet hours, a "which approvals are remembered" screen.

The task system (classifier, planner, helper agents, Kanban board) was removed. The tool layer, approvals and sandbox browser remain but have no caller.

## License

Not chosen yet (planned: Apache-2.0 or MIT) before the first public commit.
