import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'config.dart';
import 'llm.dart';
import 'message.dart';
import 'session.dart';
import 'tools.dart';

/// The agentic step loop, ported from opencode's session runner
/// (packages/core/src/session/runner/{llm,step,retry,max-steps,to-llm-message}.ts).
///
/// One drain processes steps until the model stops calling tools. Ported
/// behaviours:
/// - retry policy: exponential from 2 s capped at 10 s per gap, ≤ 10
///   attempts, jittered; ≤ 3 timeout attempts; bounded Retry-After honouring.
/// - max-steps boundary: tools disabled (`toolChoice: none`) plus the
///   MAX_STEPS_PROMPT synthetic assistant message.
/// - output-limit continuation: a synthetic user message asks the model to
///   continue after a `length` finish; two continuations max.
/// - interrupted-stream continuation: a partial response followed by a
///   retryable transport failure continues with a synthetic user message.
/// - abort: checked at stream and step boundaries; unsettled tool parts are
///   settled with "Tool execution interrupted".
///
/// Deliberately not ported (reported to the user instead of silently
/// degraded): context-window compaction, permissions/approvals, snapshots,
/// subagents, MCP tools.

const _maxSteps = 200;

const _maxStepsPrompt = 'CRITICAL - MAXIMUM STEPS REACHED\n'
    '\n'
    'The maximum number of steps allowed for this task has been reached. '
    'Tools are disabled until next user input. Respond with text only.\n'
    '\n'
    'STRICT REQUIREMENTS:\n'
    '1. Do NOT make any tool calls (no reads, writes, edits, searches, or any other tools)\n'
    '2. MUST provide a text response summarizing work done so far\n'
    '3. This constraint overrides ALL other instructions, including any user requests for edits or tool use\n'
    '\n'
    'Response must include:\n'
    '- Statement that maximum steps for this agent have been reached\n'
    '- Summary of what has been accomplished so far\n'
    '- List of any remaining tasks that were not completed\n'
    '- Recommendations for what should be done next\n'
    '\n'
    'Any attempt to use tools is a critical violation. Respond with text ONLY.';

const _continueAfterIncompleteStream =
    'The previous response was interrupted. Continue from where you left off '
    'without repeating completed content.';

const _continueAfterOutputLimit =
    'Your last response hit the output token limit (stop reason: length). Do '
    'not apologize, recap, or repeat yourself. Break the remaining work into '
    'smaller pieces.';

/// System prompt ported from runner/prompt/system.txt; the tool guidance
/// block is rendered by [_systemPrompt] like opencode's
/// SessionSystemPrompt.make.
String _systemPrompt(List<Tool> tools, String root) {
  final names = [for (final tool in tools) tool.name];
  final guidance = <String>[
    if (names.contains('shell')) ...[
      '- Prefer dedicated tools over shell commands; fall back to the shell when a tool cannot do what you need.',
      '- Do not chain shell commands with separators like `echo "====";` or `printf \'---\'`; the output becomes noisy in a way that makes the user\'s side of the conversation worse.',
    ],
    if (names.contains('write'))
      '- Use the write tool to create files or completely replace their content. Prefer using the edit tool for targeted changes.',
    if (names.contains('edit'))
      '- Use the edit tool for targeted changes to existing text files. It replaces the exact text in `oldString` with `newString`, and the values must differ. By default, `oldString` must occur exactly once. If it occurs multiple times, include more surrounding context to make it unique or set `replaceAll` to true to replace every occurrence.',
  ].join('\n');
  return 'You are an AI agent running in Tamtoot, a coding agent harness. '
      'Help the user accomplish their goals using the tools you have available.\n'
      '\n'
      '# Harness\n'
      '- Responses are rendered as GitHub-flavored Markdown.\n'
      '- `<system-reminder>` blocks are harness instructions, not user-authored content. Read and follow them.\n'
      '- Prefer parallelizing independent tool calls.\n'
      '$guidance\n'
      '\n'
      '# Communication\n'
      '- Use clear file paths when referring to files.\n'
      '- Keep responses clear and concise, and avoid unnecessary technical jargon.\n'
      '\n'
      '# Working in codebases\n'
      '- Keep changes consistent with the structure, naming, style, and patterns of the surrounding code.\n'
      '- Treat unfamiliar files or changes as potential user work and investigate before deleting or overwriting them.\n'
      '\n'
      'The project root is: $root. Relative tool paths resolve against it.';
}

/// Exponential retry policy, ported from model-retry.ts: 2 s base, 10 s cap
/// per gap, 10 attempts, jittered; timeouts capped at 3; provider Retry-After
/// honoured up to 15 minutes.
class RetryPolicy {
  static const _retryAfterMaxMs = 15 * 60 * 1000;
  final _random = math.Random();
  var _attempt = 0;
  var _timeouts = 0;

  ({int attempt, int delayMs})? decide(LlmException error) {
    if (!error.retryable) return null;
    if (error.isTimeout) {
      _timeouts++;
      if (_timeouts > 3) return null;
    }
    if (_attempt >= 10) return null;
    _attempt++;
    final base = math.min(2000 * math.pow(2, _attempt - 1), 10000);
    var delay = (base * (0.8 + 0.4 * _random.nextDouble())).ceil();
    final retryAfter = error.retryAfterMs;
    if (retryAfter != null) {
      delay = math.max(delay, math.min(retryAfter, _retryAfterMaxMs));
    }
    return (attempt: _attempt, delayMs: delay);
  }
}

class SessionRunner {
  SessionRunner({
    required this.root,
    required this.config,
    required this.store,
    List<Tool>? tools,
    LlmClient? client,
  }) : tools = tools ?? defaultTools(),
       _client = client ?? LlmClient();

  final String root;
  final OpencodeConfig config;
  final SessionStore store;
  final List<Tool> tools;
  final LlmClient _client;

  final _busy = <String>{};
  final _aborts = <String, void Function()>{};

  bool isBusy(String sessionId) => _busy.contains(sessionId);

  void abort(String sessionId) {
    _aborts[sessionId]?.call();
  }

  /// Append the user message and drain the session. Fire-and-forget from the
  /// caller's perspective; message state is polled through the store.
  Future<void> prompt(AgentSession session, String text) async {
    if (_busy.contains(session.id)) {
      throw ToolFailure('The agent is already working on this session.');
    }
    session.messages.add(
      ChatMessage(id: _newId(), role: 'user', parts: [TextPart(text)]),
    );
    if (session.messages.where((m) => m.role == 'user').length == 1) {
      session.title = text.length > 48 ? '${text.substring(0, 48)}…' : text;
    }
    await store.persist(session);
    unawaited(_drain(session));
  }

  Future<void> _drain(AgentSession session) async {
    _busy.add(session.id);
    var cancelled = false;
    void Function()? cancelActiveStream;
    _aborts[session.id] = () {
      cancelled = true;
      cancelActiveStream?.call();
    };
    try {
      var step = 0;
      var lengthStreak = 0;
      var maxStepsEntered = false;
      while (true) {
        if (cancelled) return;
        step++;
        final stepLimitReached = step >= _maxSteps && !maxStepsEntered;
        if (stepLimitReached) maxStepsEntered = true;

        final resolved = await config.resolveModel();
        if (resolved == null) {
          _appendError(
            session,
            'No model is configured. Open the model settings to choose an '
            'Ollama server and model, or set `model` and `providers` in '
            '.tamtoot/opencode.json.',
          );
          return;
        }
        final transcript = _transcript(session);
        if (stepLimitReached) {
          // Ported from runner/llm.ts: the boundary prompt rides as an
          // assistant message with tools disabled.
          transcript.add(LlmMessage(role: 'assistant', text: _maxStepsPrompt));
        }
        final request = LlmRequest(
          provider: resolved.provider,
          model: resolved.model,
          messages: transcript,
          tools: tools.map((tool) => tool.definition()).toList(),
          toolChoice: maxStepsEntered ? 'none' : 'auto',
        );

        final assistant = ChatMessage(id: _newId(), role: 'assistant');
        // Live streaming: the message joins the session immediately and its
        // parts grow as provider events arrive, so the panel's poll renders
        // text and tool calls while the model is still working.
        session.messages.add(assistant);
        await store.persist(session);
        var lastLivePersist = DateTime.now().millisecondsSinceEpoch;
        void livePersist() {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastLivePersist >= 400) {
            lastLivePersist = now;
            unawaited(store.persist(session));
          }
        }

        TextPart? textPart;
        ReasoningPart? reasoningPart;
        final calls = <LlmToolCall>[];
        String finish = 'unknown';
        var outputStarted = false;
        LlmException? failure;
        final retry = RetryPolicy();

        // One provider attempt per loop; retryable failures with no durable
        // output re-run the attempt after the policy delay. The subscription
        // is cancelable so abort interrupts a stalled stream immediately,
        // mirroring fiber interruption in opencode's step.ts.
        while (true) {
          failure = null;
          final stream = _client.stream(request);
          final done = Completer<void>();
          final subscription = stream.listen(
            (event) {
              if (cancelled) return;
              switch (event) {
                case LlmTextDelta(:final text):
                  outputStarted = true;
                  if (textPart == null) {
                    textPart = TextPart('');
                    assistant.parts.add(textPart!);
                  }
                  textPart!.text += text;
                  livePersist();
                case LlmReasoningDelta(:final text):
                  if (reasoningPart == null) {
                    reasoningPart = ReasoningPart('');
                    assistant.parts.insert(0, reasoningPart!);
                  }
                  reasoningPart!.text += text;
                  livePersist();
                case LlmToolCallEvent(:final call):
                  outputStarted = true;
                  calls.add(call);
                  assistant.parts.add(
                    ToolPart(
                      callId: call.id,
                      tool: call.name,
                      state: ToolState(status: 'pending', input: call.arguments),
                    ),
                  );
                  livePersist();
                case LlmFinish(:final reason):
                  finish = reason;
              }
            },
            onError: (Object error) {
              failure = error is LlmException
                  ? error
                  : LlmException('$error');
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
          cancelActiveStream = () {
            subscription.cancel();
            if (!done.isCompleted) done.complete();
          };
          await done.future;
          cancelActiveStream = null;
          await subscription.cancel();
          if (cancelled || failure == null) break;
          if (failure!.isContextOverflow) break;
          final decision = retry.decide(failure!);
          if (decision == null) break;
          if (outputStarted) {
            // Interrupted mid-stream: keep the partial message and continue
            // from it on the next step (Outcome.Continue in opencode).
            finish = 'interrupted';
            break;
          }
          await Future<void>.delayed(Duration(milliseconds: decision.delayMs));
          if (cancelled) break;
        }

        if (cancelled) {
          assistant.finish = 'aborted';
          _settleUnsettledTools(session, 'Tool execution interrupted');
          await store.persist(session);
          return;
        }

        if (failure != null && !outputStarted) {
          // Nothing streamed: this message is a pure diagnostic. It renders
          // in the panel but never re-enters the transcript, so failures
          // cannot amplify into subsequent requests.
          assistant.finish = 'error';
          assistant.diagnostic = true;
          assistant.parts.add(TextPart('⚠ ${briefError(failure!)}'));
          await store.persist(session);
          unawaited(_logDiagnostic(session, failure!));
          return;
        }

        if (failure != null && outputStarted) {
          // Partial genuine model output stays in history; the error note
          // goes into a separate diagnostic message.
          assistant.finish = 'error';
          await store.persist(session);
          _appendError(session, briefError(failure!));
          unawaited(_logDiagnostic(session, failure!));
          return;
        }

        if (finish == 'interrupted') {
          assistant.finish = 'error';
          _appendSyntheticUser(session, _continueAfterIncompleteStream);
          await store.persist(session);
          continue;
        }

        if (finish == 'unknown') {
          _appendError(
            session,
            'The provider response ended without a finish reason.',
          );
          return;
        }

        assistant.finish = finish;
        await store.persist(session);

        if (calls.isEmpty) {
          if (finish == 'length') {
            lengthStreak++;
            if (lengthStreak >= 3) {
              _appendError(
                session,
                'Response still truncated after two output token limit '
                'continuations.',
              );
              return;
            }
            _appendSyntheticUser(session, _continueAfterOutputLimit);
            await store.persist(session);
            continue;
          }
          return; // Completed.
        }
        lengthStreak = 0;

        // Execute the requested tools, then loop so the model sees results.
        // Each call already has a `pending` part from the stream; flip it to
        // running/completed in place so the panel shows progress live.
        for (var i = 0; i < calls.length; i++) {
          final call = calls[i];
          final part = assistant.parts.whereType<ToolPart>().firstWhere(
            (part) => part.callId == call.id,
            orElse: () {
              final created = ToolPart(
                callId: call.id,
                tool: call.name,
                state: ToolState(status: 'pending', input: call.arguments),
              );
              assistant.parts.add(created);
              return created;
            },
          );
          part.state.status = 'running';
          await store.persist(session);
          if (cancelled) {
            part.state
              ..status = 'error'
              ..error = 'Tool execution interrupted';
            await store.persist(session);
            return;
          }
          try {
            final tool = tools.firstWhere((tool) => tool.name == call.name);
            final result = await tool.execute(
              call.arguments,
              ToolContext(root: root, sessionId: session.id, callId: call.id),
            );
            part.state
              ..status = 'completed'
              ..output = result.content;
          } on StateError {
            part.state
              ..status = 'error'
              ..error =
                  'No tool named "${call.name}" is currently available. '
                  'Please use a tool from the available tool list.';
          } on ToolFailure catch (e) {
            part.state
              ..status = 'error'
              ..error = e.message;
          } catch (e) {
            part.state
              ..status = 'error'
              ..error = 'Tool failed: $e';
          }
          await store.persist(session);
        }
      }
    } finally {
      _busy.remove(session.id);
      _aborts.remove(session.id);
    }
  }

  /// Conversation → provider messages, ported from to-llm-message.ts
  /// (attachments and provider metadata are out of scope for this port;
  /// reasoning history is not sent back to the provider).
  List<LlmMessage> _transcript(AgentSession session) {
    final messages = <LlmMessage>[
      LlmMessage(role: 'system', text: _systemPrompt(tools, root)),
    ];
    for (final message in session.messages) {
      // Diagnostics never re-enter the prompt; neither do legacy error
      // notes saved before the diagnostic flag existed (an assistant
      // message that failed and carries only "⚠" text).
      if (message.diagnostic) continue;
      if (message.role == 'assistant' && message.finish == 'error') {
        final texts = message.parts.whereType<TextPart>().toList();
        final errorOnly =
            texts.isNotEmpty &&
            texts.every((part) => part.text.trimLeft().startsWith('⚠')) &&
            message.parts.whereType<ToolPart>().isEmpty;
        if (errorOnly) continue;
      }
      final text = message.parts
          .whereType<TextPart>()
          .map((part) => part.text)
          .where((text) => text.isNotEmpty)
          .join('\n');
      if (message.role == 'user') {
        if (text.isNotEmpty) {
          messages.add(LlmMessage(role: 'user', text: text));
        }
        continue;
      }
      // assistant
      final toolParts = message.parts.whereType<ToolPart>().toList();
      final terminal = toolParts
          .where(
            (part) =>
                part.state.status == 'completed' ||
                part.state.status == 'error',
          )
          .toList();
      messages.add(
        LlmMessage(
          role: 'assistant',
          text: text,
          toolCalls: [
            for (final part in terminal)
              LlmToolCall(
                id: part.callId,
                name: part.tool,
                arguments: part.state.input ?? const {},
              ),
          ],
        ),
      );
      for (final part in terminal) {
        messages.add(
          LlmMessage(
            role: 'tool',
            toolCallId: part.callId,
            toolName: part.tool,
            text: part.state.status == 'completed'
                ? (part.state.output ?? '')
                : 'Error: ${part.state.error ?? 'unknown error'}',
          ),
        );
      }
    }
    return messages;
  }

  void _appendSyntheticUser(AgentSession session, String text) {
    final message = ChatMessage(
      id: _newId(),
      role: 'user',
      parts: [TextPart(text)],
    );
    message.synthetic = true;
    session.messages.add(message);
  }

  void _appendError(AgentSession session, String message) {
    final assistant = ChatMessage(
      id: _newId(),
      role: 'assistant',
      parts: [TextPart('⚠ $message')],
    );
    assistant.finish = 'error';
    assistant.diagnostic = true;
    session.messages.add(assistant);
    unawaited(store.persist(session));
  }

  /// Full error details go to a separate diagnostics log, never into the
  /// conversation history.
  Future<void> _logDiagnostic(AgentSession session, Object error) async {
    try {
      final sep = Platform.pathSeparator;
      final dir = Directory([root, '.tamtoot', 'opencode'].join(sep));
      await dir.create(recursive: true);
      await File('${dir.path}${sep}diagnostics.log').writeAsString(
        '${DateTime.now().toIso8601String()} [${session.id}] $error\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Diagnostics must never break the session.
    }
  }

  /// Settle tool parts left running by an earlier interrupted drain,
  /// ported from runner/llm.ts settleStaleToolCalls.
  void _settleUnsettledTools(AgentSession session, String message) {
    for (final chatMessage in session.messages) {
      for (final part in chatMessage.parts.whereType<ToolPart>()) {
        if (part.state.status == 'running' || part.state.status == 'pending') {
          part.state
            ..status = 'error'
            ..error = message;
        }
      }
    }
  }

  String _newId() =>
      'msg_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}
