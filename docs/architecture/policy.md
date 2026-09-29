# Policy, approval and notifications

**Status: Accepted**

Hooks were folded into a single `policy` subsystem. Confirmations, denials and
observability are no longer duplicated between a profile and a separate `config/hooks.yaml`.
`policy` decides **before** any side effect; `notifications` only observes.

## 1. The decision type

```dart
sealed class PolicyDecision {
  const PolicyDecision();
}

final class Denied extends PolicyDecision {
  const Denied(this.reason);
  final String reason;              // machine-readable DiagnosticCode
}

final class NeedsApproval extends PolicyDecision {
  const NeedsApproval(this.prompt);
  final ApprovalPrompt prompt;      // carries the argument digest
}

final class Allowed extends PolicyDecision {
  const Allowed();
}
```

`bool` is never used. `Denied` and `NeedsApproval` carry a machine-readable reason and,
where relevant, a redaction-aware prompt. `policy.evaluate` receives the resolved tool
call, its arguments, origin and provenance, the profile, the declared capabilities and the
module identity. The decision is determined before the call.

## 2. Rules and precedence

```yaml
policy:
  default: allow
  rules:
    - match: { tool: shell.run }
      effect: confirm
    - match: { tool: fs.delete }
      effect: confirm
    - match: { tool: fs.delete, pathGlob: "~/.ssh/**" }
      effect: deny
    - match: { tool: fs.read, pathGlob: "~/.env" }
      effect: deny

notifications:
  - event: task_done
    channel: log
  - event: subagent_done
    channel: status
```

Profile, user (`~/.alteri_one/policies.d/`), admin and deployment policies are
**combined, not overwritten**. For all matching rules the strict precedence applies:

> `deny > confirm > allow`

Within one effect, the most specific rule wins, in this order:

1. exact resource and operation
2. resource glob with origin
3. glob with tool
4. tool only
5. the global default

On a full tie of both specificity and effect, the rule set MUST be unique; a duplicate is a
configuration error, not a coin flip.

`Allowed` grants no capability beyond the manifest, the profile, the OS sandbox and the
secret broker. If capability enforcement or the sandbox could not be established, the
policy outcome is `Denied`, never a quiet fallback.

## 3. Approval

For `NeedsApproval` the UI shows enough context to actually decide:

- the goal and a human-readable result of classification;
- normalised arguments and the resources they touch;
- a file diff, a write or message preview, or the exact command with its cwd and network
  destinations;
- the data source and its redaction state;
- the expected side effect and whether it is irreversible;
- the `idempotencyKey`, the retry count, and how long the approval remains valid.

For send, delete and update, the confirmation is bound to a digest of the exact arguments.
Changing the arguments, the destination or the capability invalidates the approval. A user
decline is returned to the model as `ToolOutcome.userDeclined`; the root run does not crash.

The engine never touches a terminal: it calls `ApprovalPort`, defined in
[engine.md](engine.md#2-the-loop). The CLI implements it interactively; headless mode
returns `Unavailable`, which becomes a denial and, if the run cannot proceed, exit code
`10`.

## 4. Notifications

`notifications` is a purely observational list. It may write a redacted status, emit a
local notification or subscribe to the event stream, but it cannot approve, deny, veto,
retry, change arguments or block a call.

An error in a notification observer does not change the tool outcome and is recorded as a
separate diagnostic event. Policy failures are always loud and always have a non-zero exit
path.

## 5. Egress

`policy.egress` restricts which hosts and methods the capability broker may use:

```yaml
policy:
  egress:
    - host: "api.github.com"
      methods: [GET]
```

Egress enforcement is broker-side, not client-side, and applies to Tier 1 plugins as well
as Tier 2. A redirect is re-checked against the same policy and never widens the original
scope. DNS resolution results are validated per connection, not only from the configured
hostname, so DNS rebinding cannot substitute an address between check and connect. The
default is deny.
