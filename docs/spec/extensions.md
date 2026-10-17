# 11. Extensions

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 11.1 Model

An extension is a separate AOT module. The core loads it through `Isolate.spawnUri`. The transport sits behind the `ExtensionTransport` interface. Loading an AOT module with `Isolate.spawnUri` on Dart 3.13 is verified (ADR-0007).

Capability kinds: `tools`, `triggers`, `channels`, `context`, `memory` (backend), and `skills`. An extension implements any subset.

LLM providers are not extensions (section 12).

## 11.2 Handshake

1. The host calls `Isolate.spawnUri(aotUri, [], hostPort, onExit: exitPort, errorsAreFatal: true)`.
2. The extension replies with `hello`: its own `SendPort`, its manifest, and the list of `ToolSpec`, triggers, and channels.
3. The host checks the manifest against its signature and against the permissions in `extensions/*.yaml`. It registers only what the manifest declares and the owner has approved.
4. Routes to the extension are not registered until `hello` has been received.

## 11.3 Lifecycle

```
discovered → verified → spawned → active → draining → stopped
                 ↓          ↓                  ↓
             rejected   handshake-timeout   crashed → restart (backoff) or stopped
```

- **Load.** Verify the signature and the sha256 hash, spawn, receive `hello`, publish a new routing snapshot. The reference swap is atomic: Dart is single-threaded within an isolate.
- **Unload.** Remove the routes from the new snapshot. Wait for in-flight calls up to a timeout. Then kill the isolate.
- **Update.** AOT modules are not patched in place. A new version is a new file. Load v2 next to v1, switch the routes, and drain v1.
- **Name conflict.** Two extensions declaring the same tool name: loading the second one is rejected.
- **Restart.** After a crash, restart with backoff. After several consecutive crashes the extension moves to `stopped`, and an event is sent to the API.

## 11.4 Trust and permissions

- An isolate is not a sandbox. An extension in the same process can see the host's memory, read files, and call FFI. Therefore only signed extensions that the owner has explicitly approved are loaded.
- Permissions: `net:<host>`, `host.memory.read`, `host.memory.write`, `host.secret:<NAME>`, `host.fs:<path>`. The host API checks the permission on every call.
- Secrets never enter the model context. An extension receives a secret value through `host.secret` only when it holds the permission.
- The signing algorithm is Ed25519. For personal builds, the signing key belongs to the owner. The procedure for issuing, rotating, and revoking keys for public releases is described in `docs/security/`.

## 11.5 Author SDK

An extension author works only with `ToolSpec` and a handler function. The handshake, timeouts, and error handling are provided by `runExtension`.

```dart
// extensions/alteri_one_ext_weather/bin/main.dart
import 'dart:isolate';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';

Future<void> main(List<String> args, SendPort host) => runExtension(host, (ext) {
      ext.tool(
        ToolSpec(
          name: 'forecast',
          description: 'Weather forecast for 1–7 days for a city. Call for weather questions.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
              'days': {'type': 'integer', 'minimum': 1, 'maximum': 7},
            },
            'required': ['city'],
          },
          risk: Risk.external,
        ),
        (input) async => {'city': input['city'], 'summary': 'rain, 12 °C'},
      );
    });
```

The core registers the tool under `{extId}__{name}`, for example `weather__forecast`. Allowed characters: `[a-z0-9_]`, up to 48 characters. The internal route stays `weather.forecast`.

## 11.6 Integration modes: built-in and loaded

An extension can be connected in two ways. The source code is the same.

| | Built-in (compile-time) | Loaded (runtime, AOT) |
|---|---|---|
| How it reaches the binary | a package listed in `distribution.yaml`, called from the entry point | a signed `.aot` file loaded through `Isolate.spawnUri` |
| Dependency versions | resolved together with the core | its own, isolated |
| Performance | direct call, no serialization at the isolate boundary | serialization on every call |
| Update | rebuild the binary | replace the file, no rebuild |
| Trust | trusted code of the build | signature and permission check on every load |
| Typical use | the main set, personal builds | third-party extensions, experiments, updates between releases |

The same extension code (API names are illustrative; the final ones are in `alteri_one_sdk`):

```dart
// extensions/weather/lib/weather.dart
final class WeatherExtension implements AlterioneExtension {
  const WeatherExtension();

  @override
  void register(ExtensionContext ctx) {
    ctx.tool(forecastSpec, _forecast);
    ctx.observe(Topic.runs, _onRun);
  }
}
```

- Built-in mode: the build's entry point calls `register` directly.
- Loaded mode: the AOT entry point calls `runExtension(host, (ctx) => const WeatherExtension().register(ctx))` from `alteri_one_sdk`.

Rules:
- An extension must not assume it runs in the same process as the core. There are no shared mutable singletons and no direct calls into the core.
- Tool names are unique across the whole build. A loaded extension with a name that is already taken is rejected.
- A built-in extension may run in its own isolate (a configuration option). By default it runs in the main isolate.

## 11.7 Personal builds

A personal build is a binary with a chosen set of extensions and providers. Its contents are described in YAML.

```yaml
# distributions/home/distribution.yaml
name: home
version: 1.0.0
mode: local                          # local or remote (section 18.6)
providers:
  - package: alteri_one_provider_llama_cpp
    version: ^1.0.0
extensions:
  - package: alteri_one_ext_weather
    version: ^1.0.0
    load: built_in                   # compiled into the binary
  - package: alteri_one_ext_workspace
    version: ^1.0.0
    load: built_in
  - package: acme_finance
    version: ^0.3.0
    load: runtime                    # signed AOT module, loaded without rebuilding
defaults:
  profile: assistant
```

The command `alterione build distributions/home` (in `runtime/bin`):
1. Validates the YAML against the schema and checks that the package versions are available.
2. Generates `pubspec.yaml` and `bin/main.dart` in `build/distributions/home/`. The entry point registers the built-in extensions and the providers.
3. Resolves dependencies. A version conflict between built-in packages is reported with a clear message.
4. Compiles the binary (`dart build cli`, [VERIFY]).
5. Compiles the loaded extensions to AOT and signs them (`tools/signing`).

The `minimal` build contains only chat and no extensions. The `official` build describes the contents of the official binary. At launch it contains the built-in extensions from the repository: `workspace`, `lsp`, `mcp`, `memory_hive`, and `weather` (a reference example).

`alterione doctor` compares the binary's contents with its `distribution.yaml` and reports any mismatch.

## 11.8 Integrations in the MVP

LSP and MCP are implemented as extensions and are described in section 28. Both use the same mechanisms for tools, rights, and taint labels as any other extension.
