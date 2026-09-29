# Release tooling

Scripts that gate a release. They run from the workspace root, so a gate never needs to
know which package it is inspecting. Each exits non-zero on a failure that must block a
release.

| Script | What it protects |
|---|---|
| `closure_check.dart` | The release dependency closure is free of build hooks, which `dart compile aot-snapshot` would silently omit. Task `0.30`. |
| `naming_check.dart` | No installed path, launcher, installer or default configuration value contains `alteri_one`. Task `0.31`. |
| `install_check.dart` | An install from the fixture release verifies every digest and fails closed. Task `0.30`. |
| `version_check.dart` | Coordinated versions follow the package DAG. Task `6.5`. |
| `artifact_check.dart` | Three platform artifacts with checksums. Task `6.6`. |
| `signature_check.dart` | Every artifact is signed. Task `6.7`. |
| `startup_check.dart` | The release build meets its p95 cold-start budget. Task `6.9`. |
| `offline_check.dart` | The release build passes the offline scenarios with zero telemetry. Task `6.10`. |
| `publish_dry_run.dart` | Every publishable package passes `dart pub publish --dry-run`. Task `6.8`. |

## `repo_settings.sh` is different

Every other script here checks the *artifacts*. This one checks the *repository*, and it
deliberately configures nothing.

```
tool/release/repo_settings.sh --record > repo-settings.json   # capture
tool/release/repo_settings.sh --check                          # compare with live
```

`repo-settings.json` at the repository root records the description, the homepage, the
feature toggles, the label set and the branch rulesets. The `--check` mode diffs the live
settings against the record, so a protection rule removed in the GitHub UI shows up as a
failing gate instead of as a surprise at the next release.

It does not *apply* the settings, and that is the point. A script that configures the
repository on every run is a script that will eventually overwrite a deliberate change with
a stale copy of an old one. A script that only reports can be wrong in exactly one way —
it fails and tells you — rather than two.

Re-record after a deliberate settings change, and say why in the commit:

```bash
tool/release/repo_settings.sh --record > repo-settings.json
```

Three settings cannot be recorded this way, because they are not repository properties:
HTTPS enforcement on Pages (which waits on a certificate), `secret_scanning_validity_checks`
(plan-gated), and the DNS records for the apex domain.
