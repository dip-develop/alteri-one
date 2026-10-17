# runtime/core: domain and application

- `domain/` is pure Dart. It must not import genkit, shelf, hive, injectable, flutter, or `dart:io`.
- Use `bloc` only in the application layer, for long-lived state. Logic stays in pure domain functions (`docs/spec/domain.md`, section 8.10).
- `flutter_bloc` is forbidden here. `Bloc.observer` is for diagnostics only; the journal is written explicitly.
- Every side effect (model call, tool call, channel send) is written to the journal first.
- The `RunBloc` event transformer is `sequential`. Do not use `concurrent()` without a justification.
- State exposed to extensions goes through `StatePublisher` as serializable events. Bloc objects never leave the core (section 8.11).
