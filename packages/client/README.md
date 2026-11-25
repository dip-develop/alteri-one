# alteri_one_client

> HTTP and SSE client for the AlteriOne daemon public API.

A public library published to pub.dev as part of AlteriOne.

**Status: pre-alpha.** M0 (scaffold) and M1 (core skeleton) are complete;
M4 (local mode) is in progress. APIs are not stable yet; see
[`docs/spec/roadmap.md`](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/roadmap.md).

## About AlteriOne

AlteriOne is a personal universal assistant: one runtime with three run modes
(`chat`, `task`, `resident`), extensions, LLM providers, and LSP and MCP
integrations. One owner per instance; no accounts, no multi-user mode.

See the [root README](https://github.com/dip-develop/alteri-one) and the [specification index](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/index.md).

## License

Apache-2.0. See [LICENSE](LICENSE) in this package and the repository root.

## Usage

The client speaks the daemon's `/v1` REST API and reconnects to its SSE event
stream. Construct it with the daemon base URL and the bearer token read from the
token file:

```dart
final client = AlteriOneClient(
  baseUrl: Uri.parse('http://127.0.0.1:4242'),
  token: tokenFromFile,
);
final info = await client.getInfo();
client.verifyVersion(info);
final runId = await client.createRun(profile: 'chat', input: 'hello');
await for (final event in client.events(since: 0)) {
  // event is an AgentEvent; unknown types arrive as UnknownEvent.
}
```

The API is still pre-alpha; see
[`docs/spec/roadmap.md`](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/roadmap.md).
