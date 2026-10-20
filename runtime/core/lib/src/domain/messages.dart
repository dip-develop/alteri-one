// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Roles in the model conversation.
enum MessageRole { system, user, assistant, tool }

/// One message of the model conversation (docs/spec/domain.md, section 9).
///
/// Skeleton: M2 pins the exact shape when the agent loop and the prompt
/// wrapping (section 13) are implemented.
final class Message(
  /// Who produced the message.
  final MessageRole role,

  /// Text content.
  final String text,

  /// Tool calls attached to an assistant message.
  final List<ToolCall> toolCalls,

  /// Tool results attached to a `tool` message.
  final List<ToolResultBlock> toolResults,
) {
  /// A system instruction.
  factory system(String text) =>
      Message(MessageRole.system, text, const [], const []);

  /// A user message.
  factory user(String text) =>
      Message(MessageRole.user, text, const [], const []);

  /// An assistant message, optionally with tool calls.
  factory assistant(String text, [List<ToolCall> toolCalls = const []]) =>
      Message(MessageRole.assistant, text, toolCalls, const []);

  /// A message carrying tool results.
  factory toolResults(List<ToolResultBlock> results) =>
      Message(MessageRole.tool, '', const [], results);
}

/// A tool call requested by the model (docs/spec/domain.md, section 9).
final class ToolCall(
  /// Call identifier from the provider, echoed in the result.
  final String id,

  /// LLM name of the tool.
  final String name,

  /// Arguments as produced by the model.
  final Map<String, Object?> input,

  /// Whether the provider reported invalid arguments. A malformed call is
  /// answered with an error result without failing the run.
  final bool isMalformed,

  /// Why the arguments are invalid, when [isMalformed] is set.
  final String? reason,
) {
  /// A well-formed call.
  factory valid({
    required String id,
    required String name,
    required Map<String, Object?> input,
  }) => ToolCall(id, name, input, false, null);

  /// A call with invalid arguments; [reason] explains what is wrong.
  factory malformed({
    required String id,
    required String name,
    required String reason,
  }) => ToolCall(id, name, const {}, true, reason);
}

/// The result of one tool invocation, returned to the model.
final class ToolResultBlock(
  /// The call this answers.
  final String callId,

  /// The tool's output when it succeeded.
  final Object? value,

  /// Machine-readable error code when it failed, for example `denied` or
  /// `not_approved`. Details go to the journal, not to the model context.
  final String? errorCode,
) {
  /// A successful result.
  factory ok(String callId, Object? value) =>
      ToolResultBlock(callId, value, null);

  /// A failed result.
  factory error(String callId, String errorCode) =>
      ToolResultBlock(callId, null, errorCode);

  /// Whether the tool succeeded.
  bool get isOk => errorCode == null;
}

/// One model turn (docs/spec/domain.md, sections 8.5 and 9).
final class Turn(
  /// Reply text; may be empty when the model only requested tools.
  final String text,

  /// The assistant message to append to the conversation.
  final Message assistant,

  /// Tool calls the model requested, unexecuted.
  final List<ToolCall> toolCalls,
) {
  /// Whether the model wants tools to run.
  bool get hasToolCalls => toolCalls.isNotEmpty;
}
