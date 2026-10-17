# 0009. Windows daemon: logon task in the MVP

- Status: Accepted
- Date: 2026-10-17

## Context
The owner decided that the daemon runs on macOS, Linux, and Windows at the same time (ADR-0006). On Windows, a background process can be started in two ways: as a Windows service, which runs without a logon, or as a Task Scheduler task, which starts at user logon. A service needs installation through the Service Control Manager and a stop mechanism that does not rely on SIGTERM.

## Decision
In the MVP, the daemon on Windows is a Task Scheduler task that starts at user logon and runs `alterione serve` with the user's privileges. A Windows service comes after the MVP.

## Alternatives
- A Windows service in the MVP. Rejected for the MVP: it adds installation, service control, and a stop mechanism while the other platforms are being built at the same time.

## Consequences
- On Windows the daemon runs only after the user logs on. This is acceptable for a personal assistant on a desktop.
- The stop mechanism and the directory mapping remain open and are checked as T20.
- The Windows service is listed as a post-MVP item in the roadmap.
