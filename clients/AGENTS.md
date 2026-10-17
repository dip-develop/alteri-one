# clients/: applications

- The SSE and REST protocol lives only in `alteri_one_client`. Do not duplicate it in the apps.
- `bloc` and `flutter_bloc` are used only here. State event shapes match the core.
- Take design tokens from `alteri_one_design`; do not hard-code colors.
- Skip unknown event types (`UnknownEvent`) without failing.
