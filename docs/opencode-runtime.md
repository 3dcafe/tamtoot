# Current in-process coding agent

The rewritten runtime is in `lib/core/opencode/`. Older model-profile and JSON
agent guides describe the previous implementation.

## Ollama configuration

Save project configuration in `.tamtoot/opencode.json` (or use model settings):

```json
{
  "model": "ollama/qwen3:14b",
  "providers": {
    "ollama": {
      "type": "ollama",
      "baseURL": "http://192.168.0.84:11434",
      "think": false
    }
  }
}
```

Use the server base URL, without `/api/tags`. No token is needed for an
unauthenticated local server. Ollama requests retain UTF-8 encoding and native
`/api/chat` streaming. The runtime requests a 16,384-token context and limits
individual responses to 4,096 tokens.

## Agent and Chat

**Agent** exposes native `read`, `glob`, `grep`, `edit`, `write`, and `shell`
functions. Relative paths resolve against the selected project's root. It sends
the tool definitions on each normal step, executes returned native calls, then
sends the assistant calls and named `role: tool` results back to the provider.
Ollama uses `tool_name`; OpenAI-compatible providers retain `tool_call_id`.

**Chat** advertises no tools and rejects attempted tool execution. Choose Agent
for repository analysis or editing. Start a new session when changing tasks
substantially; each session has its own transcript.

A project question cannot finish as a successful analysis without a successful
file read in that turn. A text-only answer without evidence triggers one native
read recovery request. A second ungrounded answer is marked diagnostic and the
run stops. This is a runtime check, not just a system-prompt instruction; it
proves a read occurred, but cannot guarantee every statement in a model's answer
is accurate. Model-generated reasoning and diagnostic messages are not replayed
as conversation context.

The runtime caps a turn at 40 actions/steps, rejects a third identical read of
an unchanged file range, stops after three consecutive tool errors, and bounds
each tool result to 24,000 characters. Empty responses are reported explicitly.
These bounds do not replace a full context-compaction implementation.

The trash button deletes the selected session, first stopping its run. Disk
writes are serialized and deleted IDs are tombstoned, so delayed streaming
snapshots cannot recreate a deleted conversation. Another session is selected,
or an empty one is created if none remain.

## Focused validation

Mock regressions: `test/opencode_runtime_test.dart` and
`test/opencode_transport_test.dart`. They cover native transport, refusal
recovery, workspace reads, read/edit/verification, Chat mode, and late writes
after deletion.

One opt-in live, read-only scenario runs the actual runner and transport:

```sh
dart tool/agent_readme_diagnostic.dart /path/to/Bego http://192.168.0.84:11434 qwen3:14b
```

It asks **«О чем этот проект?»**, requires a native successful `read` of
`README.md`, checks that the real content is returned to the model, and checks
for a Russian summary mentioning Bego's CRM domain. A human should also assess
the final summary against the README. Session state and a trace are saved to a
new system temporary directory; mutation tools are blocked during this test.
The trace contains project source excerpts; review it before sharing.

## References

- [Ollama native tool-calling protocol](https://docs.ollama.com/capabilities/tool-calling)
- [OpenCode v2 step execution](https://github.com/anomalyco/opencode/blob/v2/packages/core/src/session/runner/step.ts)
- [Open SWE investigation, implementation and validation workflow](https://github.com/langchain-ai/open-swe)

These projects informed lifecycle and execution checks. Tamtoot does not gain
Open SWE's PR/CI integrations or OpenCode's complete permission and compaction
systems from this change.

## Recorded smoke result (2026-10-21)

The single Bego/Qwen3:14b live run completed in two model requests: one native
`read` of `README.md`, followed by a named tool result and a Russian summary
correctly identifying the concrete-plant CRM, ASP.NET Core 8 and Angular 22.
No project mutations were permitted. Manual review found one unsupported Jest
mention; the README does not identify that framework. The system guidance now
explicitly prohibits inferring frameworks from test commands, but this guidance
change has not been retested against the model. The automated smoke asserts the
read/result cycle and main subject, not factual correctness of every sentence.
The prepared mock regressions and editing scenario were not executed in this
pass, following the request to run only the project-description scenario first.
