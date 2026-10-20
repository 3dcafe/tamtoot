# Local Ollama coding agent

Choose **Ollama** with `http://localhost:11434/api/chat`, or use your LAN host.
Chat Completions also works through `/v1/chat/completions`. A supplied `/api/tags`
model-list address is normalized for the selected generation API. Leave the
Agent token blank for a server without authentication.

Under **Agent options**, local/LAN profiles have these session controls:

- **Local output tokens**: 4096 by default, configurable from 256 to 32768.
- **Local temperature**: 0.15 by default.
- **Local response format**: Auto, JSON Schema, JSON Object, or Text. Auto requests
  a schema for recognized Ollama profiles and JSON Object for other local servers.
- **Local thinking**: request off, request on, or use the server default.

JSON actions are non-streaming. Native Ollama receives `think` and `format` at
the top level; temperature and `num_predict` belong in `options`. Recognized
Ollama Chat Completions profiles use `reasoning_effort` for the requested thinking
mode. Arbitrary compatible endpoints do not receive guessed template/thinking
parameters. Existing AI STAR-specific switches remain scoped to that provider.
The supported thinking controls depend on server version and model; an off
request cannot guarantee that every imported model suppresses reasoning.
See the [Ollama thinking reference](https://github.com/ollama/ollama/blob/main/docs/capabilities/thinking.mdx)
and [structured output reference](https://github.com/ollama/ollama/blob/main/docs/capabilities/structured-outputs.mdx).

The agent executes validated JSON from message content. Separate `reasoning`,
`reasoning_content` and Ollama `thinking` fields are metadata only; their text is
not promoted to a command or echoed in error logs. Leading `<think>` blocks are
removed without changing literal markup inside a JSON file-content string.
Local agents also reject native tool-call promotion into the text action protocol.

Schema mode requires each action's mandatory fields. For a new C# application,
phase-specific schemas guide creation of missing `.csproj` / `.cs` files, then
reading them, then finishing. New paths update the known index without rescanning
it. Empty projects do not trigger repeated search/list calls. C# 8 scaffolding
uses an explicit Main method and LangVersion 8.0; a .NET target version is a
separate setting. File reads verify contents, not compilation.

A server rejection falls back from JSON Schema to JSON Object and then Text.
Schema selection is still followed by host-side validation. Incomplete JSON is
never executed, and malformed actions get a small repair prompt within the
existing mistake limit. Empty content gets one reduced-context recovery request;
a second empty answer stops with an actionable error. HTTP 401/403/404/405 stops
unchanged retries. Other errors retain the existing bounded retry behavior.

Mock HTTP tests cover complete writes, truncated JSON, reasoning-only replies,
length limits, 405, empty projects, multi-file creation, repair and retry bounds.
The optional `test/local_model_live_check_test.dart` is skipped unless
`TAMTOOT_LIVE_OLLAMA_URL` is provided; it creates a synthetic C# project in memory
and never writes project files or launches generated commands. Set
`TAMTOOT_LIVE_OLLAMA_MODEL` to select the model.

Model-generated source can still be incorrect even when its JSON is valid. Use
[desktop test execution](agent-testing.md) for actual SDK checks. The latest live
verification could not complete because the LAN Ollama endpoint stopped accepting
connections; mocked regression coverage does not establish that a particular
model always completes a coding task.
