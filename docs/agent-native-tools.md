# Native tools and reliable agent execution

Open **Agent → Agent options → Tool calling**:

- **Auto (Ollama detection)** is the desktop panel default. Tamtoot asks the
  selected model's `/api/show` endpoint whether its capabilities include `tools`.
  It uses native Ollama `/api/chat` when advertised; unknown capabilities,
  unavailable discovery and unsupported models use JSON actions.
- **Native tools** explicitly enables standard function calling for Ollama Chat
  or Chat Completions providers. Other API formats keep their JSON protocol.
- **JSON actions (fallback)** preserves the existing content-based protocol.

This preference is device-local. Programmatic `AgentRunOptions` callers retain
JSON mode by default and can explicitly select `auto` or `native`. No model-name
allowlist assumes that every Ollama model supports tools. Enhanced privacy skips
capability discovery; explicit native mode still masks outgoing conversation
messages and attachments.

## Wire protocol

Tools are generated from the current executor schema. Calls use the same path
validation, approvals, editing tools and execution budgets as JSON actions.
Chat Completions sends `tools` and `tool_choice: auto`; a provider rejecting the
optional `tool_choice` gets one retry without that field. Ollama native sends
`tools` at the top level and returns `role: tool` messages with `tool_name`.
Chat Completions tool results preserve the corresponding `tool_call_id`.

Multiple calls are executed sequentially, in the returned order, with at most
eight calls per response. Every call gets its actual host outcome, including
blocked calls and argument errors. Native prose cannot execute JSON or fabricate
a tool result. After verified edits, a natural final response passes through the
same completion checks as `finish`; premature prose gets a correction request,
then a bounded stop. A model/server rejecting tools falls back to JSON once.

References: [Ollama tool calling](https://docs.ollama.com/capabilities/tool-calling),
[Ollama API capabilities](https://github.com/ollama/ollama/blob/main/docs/api.md#show-model-information).

## Safety, progress and completion

- Existing local/native files must be read at their current version before an
  edit. Source changes since that read reject the write. Whole-file writes are
  rechecked after approval, so an approval wait cannot silently overwrite edits.
- Exact replacements must exist and be unique. Unchanged writes and attempts to
  restore an earlier version produced during the run are rejected. No automatic
  rollback discards the user's files.
- Reading or searching backend source does not authorize writing it for a
  frontend task. Crossing an inferred working area requires explicit approval,
  including in YOLO mode.
- New files must be explicitly requested, be part of a requested empty-project
  scaffold, match the requested feature within the working area, or be requested
  tests. Placeholder paths remain blocked.
- Read/action repetitions, edit retry limits, no-progress and action budgets
  apply to native execution. Errors are returned to the model rather than
  silently consuming the iteration limit.
- Numbered/bulleted multi-part native tasks require source evidence for every
  requirement at successful finish: its zero-based `id`, a previously read
  `path`, and an exact current `excerpt`. This is evidence validation, not a
  general proof of program correctness.
- The reported public Angular Help-page task has additional conservative host
  checks: actual page content grounded in read project documentation, application
  integration, navigation, and a Help route without guards on it or an ancestor.
  A selected menu item alone fails these checks. Nonstandard routing arrangements
  may need review; the agent can finish with `unresolved` items instead of
  claiming success.
- `finish.unresolved` reports partial/blocked work as an unsuccessful outcome.
  Failed replacements and test commands retain their actual failure status.

## Context and diagnostics

Conversation state retains IDs and actual tool results. Compaction removes only
complete assistant/tool groups; it does not leave orphaned results. Old results
become short host-generated outcome notes. The full initial project index is
replaced after the first response by the original task and working area; tool
schemas are API definitions, not repeated chat messages.

Diagnostics show provider/model, protocol selection/fallback, tool-call IDs and
outcomes, token usage, context size, completion checks and termination reasons.
Agent model diagnostics contain metadata rather than full prompts, source
snapshots or raw function arguments. Profiles, project instructions and normal
file content are not removed by protocol switching.

Mocked regressions live in `test/agent_native_tools_test.dart`. They cover both
wire formats, fallback, real multi-step Angular source changes, failed edits,
stale versions, reversals, scope approvals, missing files, requirement evidence
and final responses. A passing mock test does not establish that a live model
will implement arbitrary user requirements correctly. Builds/tests still need
an available runner and explicit command approval.
