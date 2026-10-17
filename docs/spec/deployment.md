# 18. Startup, services, deployment modes

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 18.1 Daemon

- `alterione serve` runs in the foreground. It does not fork or daemonize itself: systemd (Linux), launchd (macOS), or a Task Scheduler task (Windows) handles that.
- Logs are JSON lines on stdout, collected by journald. Metrics and tracing: `genkit_otel`, optional.
- Single instance: a lock file in the data directory. A second instance exits with a clear message and an exit code.

## 18.2 Shutdown on SIGTERM

1. New runs receive `503 shutting_down`.
2. Active tool calls finish, up to a timeout.
3. Unfinished runs are marked `interrupted`.
4. SSE clients receive `server.shutdown`.
5. Extensions are unloaded.
6. Hive boxes are flushed, and the lock file is released.

The shutdown timeout is 30 seconds, after which the process is terminated forcibly. Test: SIGTERM in the middle of a tool call. On Windows there is no SIGTERM for this purpose; the stop mechanism is verified in T20 (section 18.7).

## 18.3 Paths

XDG defaults, overridden by `ALTERIONE_HOME`:
- configuration: `~/.config/alterione`;
- data (Hive, lock file): `~/.local/share/alterione`;
- cache: `~/.cache/alterione`.

Windows directory mapping is verified in T20.

## 18.4 TLS and certificates

Dart 3.13.0 removed the built-in fallback root certificates. If the host has no system certificate store (a container or a minimal OS), point the VM at a CA file:

```
DART_VM_OPTIONS=--root-certs-file=/path/to/cacert.pem
```

For a standalone AOT binary, set the variable in the service environment. The option is needed only for outbound HTTPS requests made by extensions and providers.

## 18.5 systemd (user service)

```ini
[Unit]
Description=AlteriOne daemon
After=network-online.target

[Service]
ExecStart=%h/.local/bin/alterione serve
Restart=on-failure
RestartSec=3
TimeoutStopSec=30
MemoryMax=2G
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=%h/.local/share/alterione %h/.config/alterione %h/.cache/alterione
PrivateTmp=yes

[Install]
WantedBy=default.target
```

- `MemoryMax` limits the whole service, including extensions. A leak in one extension cannot exhaust the machine.
- `ProtectSystem=strict` forbids writes outside the listed directories. Extension access to files is granted explicitly through policy.
- The service runs after logout only with `loginctl enable-linger`.
- `alterione service install` generates the unit, copies it to `~/.config/systemd/user/`, and runs `systemctl --user enable`. It never runs as root.
- macOS: a LaunchAgent with `KeepAlive`.

## 18.6 Deployment modes: local and remote

One binary, one configuration, different network and security rules. The mode is set by `mode:` in `alterione.yaml`.

| Aspect | `local` | `remote` |
|---|---|---|
| Where it runs | the owner's machine | a server (VPS or home server) |
| Listening address | `127.0.0.1` | a chosen interface, for example a VPN address or `0.0.0.0` |
| TLS | optional | mandatory: through a reverse proxy by default, or with a certificate and key file |
| Device pairing | required (token) | required, with a rate limit on attempts |
| Host allowlist | `localhost`, `127.0.0.1` | public host names from the configuration |
| Web client | same origin | same origin over TLS |
| Authentication log | event log | event log and authentication log |
| `doctor` | checks the token and its rights | refuses to start without TLS and a token of at least 256 bits |

Remote mode configuration example:

```yaml
mode: remote
api:
  bind: 0.0.0.0
  port: 8443
  public_hosts: [alteri.example.net]
tls:
  cert_file: /etc/alterione/tls/fullchain.pem
  key_file: /etc/alterione/tls/privkey.pem
pairing:
  rate_limit: 5 per 10m
```

Rules:
- **Certificate pinning.** The response to `POST /v1/pair` contains the SHA-256 fingerprint of the server certificate. Native clients pin the fingerprint, so a self-signed certificate on a home server is acceptable. Browsers trust the certificate through the usual mechanism, which requires a CA-signed certificate or a reverse proxy.
- **Reverse proxy.** TLS may be terminated by a proxy (Caddy, nginx). The daemon then listens on loopback and trusts `X-Forwarded-*` headers only from the proxy address set in the configuration. Proxy buffering must be disabled for SSE, otherwise events arrive in batches.
- **Multiple servers.** The CLI works with contexts, like `kubectl`: `alterione context add home https://...` and `alterione context use home`. The local daemon is also a context.
- **Limits.** Pairing attempts are rate-limited. Failed authentication attempts are logged and delayed. The `read.io` scope is not granted to devices by default.
- **Remote access to the machine.** An extension that reads files or runs commands gives access to that machine when it runs on a server. In remote mode such rights require a separate approval from the owner.

A server service runs as a system service under a dedicated unprivileged user. The unit is similar to the user unit (section 18.5), with `User=alterione` and `WantedBy=multi-user.target`.

## 18.7 Windows

- The daemon starts as a Task Scheduler task at user logon (MVP, ADR-0009). The task runs `alterione serve` with the user's privileges.
- A Windows service that runs without a logon is planned after the MVP.
- The stop mechanism without SIGTERM and the directory mapping (`%APPDATA%`) are verified in T20.
