# Models, coding agent, hooks, MCP and Kanban

Tamtoot can send prompts to several model API formats and run a bounded coding
agent inside the current Git workspace. This document describes the implemented
behavior, local files, security boundaries and current limitations.

## Quick start with Ollama

1. Start Ollama and download a model, for example `ollama pull qwen3-coder`.
2. Open a Git project in Tamtoot.
3. Open **Tools → Settings → Model profiles and prompts**.
4. Select **Ollama Chat**, keep `http://localhost:11434/api/chat`, then press
   **Detect Ollama**. Choose a detected model and save the profile.
5. Use **Run model…** for a single prompt, or **Tools → Agent…** for a coding
   task that may inspect and modify the project.

Ollama discovery calls `/api/tags`; model details and the context window come
from `/api/show`. Requests use native streaming `/api/chat`. The default local
endpoint does not require an API key. If an Ollama installation does require a
key through a proxy, enter it only when opening the run or agent dialog.

## Model profiles

Profiles are stored per project at:

```text
.tamtoot/agents/models/<profile-id>.json
.tamtoot/agents/instructions.md
```

The instructions file is appended to the system prompt of every profile. A
profile uses schema version 1:

```json
{
  "schemaVersion": 1,
  "id": "local-code",
  "name": "Local coding model",
  "provider": "ollama",
  "model": "qwen3-coder",
  "systemPrompt": "You are a coding assistant.",
  "userTemplate": "Task:\n{{task}}\n\nFile: {{file_path}}\n{{file}}\n\nSelected code:\n{{selection}}",
  "parameters": {
    "temperature": 0.2,
    "num_ctx": 32768
  },
  "apiFormat": "ollama",
  "endpoint": "http://localhost:11434/api/chat"
}
```

Supported `apiFormat` values are:

| Value | Protocol |
| --- | --- |
| `ollama` | Ollama Chat API |
| `chat-completions` | OpenAI-compatible Chat Completions |
| `responses` | OpenAI Responses API |
| `anthropic` | Anthropic Messages API |

Public endpoints must use HTTPS. Plain HTTP is accepted only for localhost and
private IPv4 ranges. URLs containing credentials, query parameters or fragments
are rejected. Redirects are not followed.

### Custom OpenAI-compatible server

Choose **Custom compatible API** and enter any of these forms in **Server URL**:

- a base URL such as `https://models.example`;
- a discovery URL such as `https://models.example/v1/models`;
- the full request URL such as `https://models.example/v1/chat/completions`.

For Chat Completions, Tamtoot normalizes the first two forms to the request
endpoint automatically. **Check connection** reads both OpenAI `data` model
lists and compatible `models` lists, fills the model selector and displays the
final request URL.

Tested example:

```text
Model server: Custom compatible API
Server URL: https://ai.qird.ru/v1/models
API format: Chat Completions
Model: /home/latin/models/bonsai/Ternary-Bonsai-2-27B-PQ2_0.gguf
API parameters: {"temperature": 0.2, "max_tokens": 2048}
```

The template variables are `{{task}}`, `{{file_path}}`, `{{file}}` and
`{{selection}}`. Substitution happens once, so template-looking text from a file
is kept as ordinary file content. The Parameters field must contain a JSON
object. Request structure and credential fields such as `model`, `messages`,
`input`, `headers`, `authorization`, `api_key`, `token`, `tools` and `stream` are
reserved because Tamtoot controls them.

API keys are never written to profiles or application settings. The dialogs keep
the key in memory until the request finishes or the window closes. The headless
agent reads `TAMTOOT_API_KEY`. Error text is sanitized before display.

### AI STAR

Choose **AI STAR · compatible API**, or use **Add AI STAR agent** when creating
a profile. Tamtoot fills in `https://ai.starimg.ru/v1`, Chat Completions format,
and the coding model `gpt-6.1-sol`. Paste the service token into the temporary
API key field and select **Check connection** to load the models available to
your account. Save the profile, open the **Agent** sidebar tab, select the saved
profile, and send a task. The saved token is filled automatically.

The token is shared by the profile editor, model request dialog, and Agent.
Enter it once when checking or saving the profile; Tamtoot stores it in local
application preferences for that profile. It is not written to `.tamtoot`, the
project, or Git. Use **Forget token** in Agent to remove it from the device.
The alternative service host can be entered manually as
`https://ai.starimg.space/v1` when the primary domain is unavailable.

## Single model requests

**Preview prompts** resolves the selected profile locally and sends nothing.
**Run model…** shows the resolved request, accepts an optional API key, streams
the response when supported, and provides Stop and Copy controls. The active
file and selection may include unsaved editor content.

Requests have bounded response sizes and timeouts. Stopping a request closes the
active HTTP client. Browser builds additionally depend on the endpoint allowing
cross-origin requests.

## Coding agent

Open **Tools → Agent…**, select a saved profile and enter a task. The model must
answer with one structured action per iteration. Tamtoot validates the action
before it runs it.

The paperclip accepts any file type. Desktop and tablet users can also drag files
from another app into the visible Agent tab when the platform exposes file
drag-and-drop. Attachments are limited to four files, 8 MiB per file and 12 MiB
in total. Text and images are sent in the form
supported by the selected API; other binary files require an API with file-part
support.

The visible conversation is saved after every update and restored when the
project is reopened. It is stored locally in
`.tamtoot/agents/chat_history.json`. Internal model request payloads and source
snapshots are omitted to keep the file bounded. **Clear conversation** deletes
the stored history as well.

The available actions are:

| Action | Behavior |
| --- | --- |
| `say` | Adds a progress message to the run log |
| `list_files` | Lists one project-relative directory |
| `search_files` | Searches paths and text, returning a small set of matching lines |
| `read_file` | Reads one project-relative regular file or a requested line range |
| `read_files` | Reads up to four project-relative files in one step (shared optional `startLine` / `lineCount`) |
| `replace_in_file` | Replaces one unique exact fragment in an existing file |
| `write_file` | Replaces one project-relative regular file |
| `mcp_call` | Calls a tool advertised by a connected MCP server |
| `finish` | Completes the task after all run conditions are satisfied |

Paths must stay inside the open project. `.git` and `.tamtoot` cannot be accessed
through agent file actions. Files and tool output have size limits. The loop has
a timeout, an iteration limit and a consecutive-mistake limit. Stop cancels the
active model request and terminates the active command or hook.

Normal mode asks once before each file write or MCP call. Read-only file
inspection does not require approval. Every agent request states that Tamtoot is
a mobile IDE without a terminal, interpreter, compiler, debugger, build runner,
or test runner. The agent must inspect changed files and finish without trying to
execute tests or other commands. If a model still emits `run_command`, the host
skips it and reminds the model about the mobile runtime limit.

Each task begins in implementation mode. The model should start with the most
useful tool action rather than a separate planning `say`. Optional short status
messages are allowed, but repeating `say` without tools is rejected.

Agent context is incremental. User attachments are sent only with the first
request. The first request also receives a compact project file index once. The
model then uses literal `search_files` queries (concrete symbols/identifiers,
not natural-language descriptions), directory listing and ranged reads to select
relevant content. The host enforces at most two consecutive `search_files`
calls since the last read/edit, soft-rejects duplicate/similar queries under
overlapping paths (returning known matches without counting a mistake), and
after ≤4 implementation-file hits requires `read_file` / `read_files` before
another search. Reads without an explicit range focus ~40 lines around prior
search hits instead of lines 1–N. Active file context keeps up to six larger
excerpts. Prefer `read_files` only when several files are necessary. Recent
search results and listings remain in a bounded investigation history. Small
edits use `replace_in_file`, so the model can change a verified fragment without
reconstructing an entire large file. Older context is still evicted when the
combined limits are reached, preventing every iteration from resending all
attachments and every file inspected earlier.

Desktop multi-root workspaces are visible to Agent. Paths in the primary
project remain ordinary relative paths. Every additional Solution folder is
mounted below a unique `@folder/` prefix shown in the project index. Agent
writes keep the same approval rules, and YOLO checks every attached Git working
tree before allowing edits.

Before the first edit, an investigation budget applies by default: at most five
`search_files`, eight file reads, and twelve model iterations. After two
searches and two reads without an edit, the host injects a progress note urging
`replace_in_file`, `write_file`, or one final targeted read. When the budget is
exhausted, `search_files`, `list_files` and `say` are soft-rejected, while reads
and edits stay available: the host narrows one final read to two files and sixty
lines each instead of denying it. Over-wide or out-of-range read requests are
normalized the same way — trimmed paths and clamped line ranges — because
denying them would only cost another model round-trip for a smaller version of
the same request.

Completion budgets are small by design: one navigation action gets 700 tokens
and an edit 1600, which is ample for a single JSON object. The budget is sent
under the key the selected API format expects (`max_tokens`,
`max_output_tokens` or Ollama's `num_predict`), together with the
thinking-disable switches that format documents, and Chat Completions requests
additionally ask for JSON mode. If a reply still arrives with empty
`message.content` — typical for thinking builds that fill `reasoning_content`
until the limit — Tamtoot retries once with a minimal recovery request stating
only the task line, the required phase, the allowed actions and the known
relevant files. The failed reasoning is never sent back, and the retry does not
count as a mistake unless it also fails.

Persistent project memory lives in `.tamtoot/agents/project_memory.json`. It is
merged after a successful `finish` and also when a run is cut short by the
mistake limit, the iteration limit, a timeout or Stop, so an aborted
investigation is not repeated from scratch. Each entry is a compact area summary
(files, learned relationships, edits, fingerprints). The next task receives only
a relevance-selected slice, pinned at the top of the prompt where fresh
observations cannot evict it, plus an up-front note naming the known files to
read instead of searching. Memory may skip redundant searches when known
locations already answer the query; the model must still verify a current
excerpt before editing. Secrets are scrubbed, and the on-disk document is hard-
capped (~8k characters) with automatic compaction.

## YOLO Mode

YOLO Mode automatically approves agent writes, commands and MCP tool calls. The
IDE displays a warning the first time it is enabled in the current application
run. YOLO can start with uncommitted changes in the working tree.

YOLO still enforces project path checks, command restrictions, response limits,
the total timeout, the iteration and mistake limits, and the successful-check
requirement after a write. The default timeout is 600 seconds. The Stop button
remains available throughout the run.

## Headless CLI

Run the CLI from the root of a supported Git repository:

```sh
TAMTOOT_API_KEY=... dart run bin/ide_agent.dart \
  --profile local-code \
  --timeout 600 \
  --max-consecutive-mistakes 3 \
  "fix the failing tests"
```

Add `-y` or `--yolo` for automatic approvals. Add `--json` for line-delimited
JSON events suitable for scripts:

```sh
cat issue.txt | TAMTOOT_API_KEY=... \
  dart run bin/ide_agent.dart --json --profile local-code "implement this issue"
```

Piped input is appended as task context. With no explicit profile, the first
profile returned from `.tamtoot/agents/models/` is used. The process exits with
0 on success, 1 when the run fails, and 2 for an unsupported repository or a
missing profile. Invalid CLI usage exits with 64. Ctrl+C requests a clean stop.

Each JSON event contains `type`, `text`, a millisecond Unix timestamp in `ts`,
and optional `data`. The final `result` event also contains `success` and
`iterations`. To install a standalone executable, use:

```sh
dart compile exe bin/ide_agent.dart -o ide-agent
```

## Lifecycle hooks

Project hooks are executable files with no extension at:

```text
.tamtoot/hooks/TaskStart
.tamtoot/hooks/UserPromptSubmit
.tamtoot/hooks/PreToolUse
.tamtoot/hooks/PostToolUse
.tamtoot/hooks/TaskCancel
```

Tamtoot starts a hook without a shell, uses the project root as its working
directory and writes one JSON object to standard input. The exact input depends
on the lifecycle point. Tool hooks include the action and its arguments; start
and prompt hooks include the task or prompt.

A hook may write no output, or one JSON object:

```json
{
  "cancel": false,
  "errorMessage": "",
  "contextModification": "Additional instructions for this run"
}
```

`cancel: true` blocks the current start, prompt or tool action. A non-empty
`contextModification` from `UserPromptSubmit`, `PreToolUse` or `PostToolUse` is
added to the agent context. `TaskStart` currently uses `cancel` and
`errorMessage`; its context modification is not consumed. Hooks have a 10-second
timeout and a 1 MiB stdout limit; stderr shown for a failed hook is truncated.
The executable bit and interpreter line are the hook author's responsibility.

Only project hooks and the five names above are implemented. Global hooks and a
`TaskResume` lifecycle event are planned but unavailable.

## MCP servers

Open **Tools → Settings → MCP servers** to edit and test `.tamtoot/mcp.json`.
The file follows the common `mcpServers` shape and currently has no Tamtoot
`schemaVersion` field.

STDIO example:

```json
{
  "mcpServers": {
    "local-tools": {
      "type": "stdio",
      "command": "/absolute/path/to/server",
      "args": ["--workspace", "."],
      "timeoutSeconds": 30,
      "disabled": false
    }
  }
}
```

Streamable HTTP example:

```json
{
  "mcpServers": {
    "remote-tools": {
      "type": "streamableHttp",
      "url": "https://example.com/mcp",
      "headers": {
        "Authorization": "Bearer replace-me"
      },
      "timeoutSeconds": 30,
      "disabled": false
    }
  }
}
```

Tamtoot performs MCP initialization, lists tools, accepts JSON or SSE responses,
retains the returned session ID, and exposes discovered tools to the agent.
Server names may contain letters, numbers, `_` and `-`. Timeouts range from 1 to
600 seconds. HTTP is accepted only for localhost; remote servers require HTTPS.
STDIO transport is available on platforms with process support.

Header values are stored as plain text in `.tamtoot/mcp.json`. Use short-lived
credentials where possible and do not commit this file with secrets. Tamtoot's
built-in Git commit UI excludes `.tamtoot`, but another Git client can still add
it unless the repository ignores it.

## Agent Kanban and worktrees

Open **Tools → Agent Kanban…** to manage cards in
`.tamtoot/agents/kanban.json`. Columns are Todo, In Progress, Review and Done.
A card contains an ID, title, description, model profile, dependencies and run
metadata. A card is ready only when every referenced dependency is Done.

Starting a ready card on desktop creates a real Git worktree at
`.tamtoot/worktrees/<card-id>` on branch `tamtoot/<card-id>`. Tamtoot adds
`/.tamtoot/` to the repository's local `.git/info/exclude` so these local files
do not pollute the built-in Git view.

The current Kanban UI creates and records worktrees and allows manual status
movement. It does not yet schedule cards, start agents automatically, stream an
agent into each card, provide inline diff review, commit changes, push branches,
or create pull requests. The `autoCommit` and `autoPr` fields are reserved state
for those future workflows and have no execution effect today.

## Platform support

| Capability | Desktop | Android/iOS | Web |
| --- | --- | --- | --- |
| HTTP model requests | Yes | Yes, subject to platform networking | Subject to browser CORS |
| Agent project file tools | Yes | Depends on the granted project provider | Depends on the granted browser folder |
| Commands and executable hooks | Yes | No supported OS process workflow | No |
| STDIO MCP | Yes | No supported OS process workflow | No |
| HTTP MCP | Yes | Yes, subject to networking | Subject to browser CORS |
| Git worktree creation | Yes | No | No |

## Local data and Git

All agent configuration belongs to the open project:

```text
.tamtoot/
├── agents/
│   ├── instructions.md
│   ├── chat_history.json
│   ├── kanban.json
│   └── models/
│       └── <profile-id>.json
├── hooks/
│   └── <HookType>
├── mcp.json
└── worktrees/
```

The built-in Git UI excludes `.tamtoot`. This makes profiles, prompts, MCP
headers, hooks, Kanban state and worktrees local by default when committing from
Tamtoot. Teams that want to share safe parts of the configuration should copy
reviewed files into version control with another Git client and keep credentials
out of them.

## Troubleshooting

- **Ollama is not detected:** verify `ollama list`, then check that the profile
  endpoint is `http://localhost:11434/api/chat` and no proxy blocks localhost.
- **YOLO refuses to start:** commit or discard every Git change, then refresh the
  project. `.tamtoot` metadata is excluded by Tamtoot's Git status handling.
- **The agent tries to run a command:** current prompts explicitly forbid test,
  build, interpreter and debug execution; any `run_command` action is skipped.
- **An MCP server does not appear:** test the JSON in Settings, ensure it is not
  disabled, and verify that initialization and `tools/list` return valid
  JSON-RPC objects.
- **HTTP works on desktop but not Web:** configure CORS on the model or MCP server.
- **A hook does not run:** make it executable and add an interpreter line such as
  `#!/bin/sh` or `#!/usr/bin/env python3`.

## Implementation status

Implemented: editable model prompts, four API formats, Ollama discovery and
streaming, bounded agent tools, normal approvals, YOLO checks, headless JSON
mode, project lifecycle hooks, STDIO and Streamable HTTP MCP tools, persistent
Kanban cards and desktop Git worktree creation.

Planned: automatic Kanban dependency scheduling, card-owned agent processes,
inline review and comments, automatic commit/push/pull request creation, global
hooks, task resume, persistent multi-agent teams, durable per-run log files and
prompt caching metrics.
