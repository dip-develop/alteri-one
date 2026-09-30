#!/usr/bin/env bash
# A falsification harness for the documentation contract. Not part of the gate.
#
# A contract test that only ever passes proves nothing: it is equally consistent with a tree
# that is governed and a tree that is not. This script mutates the tree in each of the ways
# the contract claims to notice, asserts the test goes red, and restores the file.
#
# It exists because the alternative is trusting a green run, and this repository's whole
# argument is that prose needs a mechanical check. Run it when the contract changes, and
# when anyone wonders whether the contract is real.
#
# It rewrites tracked files, so it refuses to run against a dirty tree and it restores on
# every exit path. See "Safety" below for why both are load-bearing rather than cautious.

set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root" || exit 1

test_file="test/governance/documentation_contract_test.dart"

# The only files this harness is allowed to rewrite. A mutation aimed at anything outside
# this list is refused, so a typo in a label cannot send the rewrite at a real file.
targets=(
  SECURITY.md
  CONTRIBUTING.md
  CODE_OF_CONDUCT.md
  ARCHITECTURE.md
  .github/CODEOWNERS
  docs/vision-and-scope.md
  docs/security/threat-model.md
  docs/extensibility/plugins.md
  docs/architecture/protocol.md
  docs/decisions/0003-execution-tiers.md
  docs/decisions/README.md
)

pass=0
fail=0
mutated=()

is_target() {
  local candidate="$1" known
  for known in "${targets[@]}"; do
    [ "$candidate" = "$known" ] && return 0
  done
  return 1
}

# Restore from git rather than from a copy taken before the mutation.
#
# A copy is the obvious approach and it is wrong: the restore then overwrites whatever the
# file has become, including a genuine edit made while the harness was running. `git
# checkout --` restores the committed state, which is exactly the state the clean-tree check
# below promised when it started.
restore() { git checkout -- "$1" 2>/dev/null; }

# Safety: restore everything on every exit path, including an interrupt.
#
# A harness that leaves the tree dirty after being cancelled becomes a tool for losing work,
# and the damage shows up later as a documentation defect that nobody can explain.
cleanup() {
  for target in "${mutated[@]:-}"; do
    [ -n "$target" ] && restore "$target"
  done
  return 0
}
trap cleanup EXIT INT TERM

# Safety: refuse a dirty tree.
#
# Every mutation is undone with `git checkout --`, which discards uncommitted work in the
# file it touches. On a clean tree that is lossless, because the file matches HEAD. On a
# dirty tree it is not, and the loss would be silent.
if ! git diff --quiet -- "${targets[@]}"; then
  echo "refusing to run: a file this harness rewrites has uncommitted changes:"
  git diff --name-only -- "${targets[@]}" | sed 's/^/  /'
  echo
  echo "Commit or stash them first. The restore is 'git checkout --', which discards"
  echo "uncommitted work in the file it touches, so a dirty tree would lose it silently."
  exit 1
fi

if ! command -v dart >/dev/null 2>&1; then
  echo "refusing to run: dart is not on PATH."
  exit 1
fi

# mutate <path> <python-expression-over-text> <label>
#
# The expression reads `text` and returns the replacement. `re` is in scope. The expression
# is `eval`'d from this file, which is fine: the file is the harness, and anyone who can
# edit it can already run anything.
mutate() {
  local target="$1" expression="$2" label="$3"

  if ! is_target "$target"; then
    echo "REFUSED  $label ($target is not a target this harness may rewrite)"
    fail=$((fail + 1))
    return
  fi

  if [ ! -f "$target" ]; then
    echo "MISSING  $label ($target does not exist)"
    fail=$((fail + 1))
    return
  fi

  if ! TARGET="$target" EXPR="$expression" python3 - <<'PY'
import os
import re
import sys

path = os.environ['TARGET']
expr = os.environ['EXPR']
with open(path, encoding='utf-8') as handle:
    text = handle.read()

try:
    result = eval(expr, {'text': text, 're': re})  # noqa: S307
except Exception as error:  # a broken mutation is a harness bug, not a test result
    sys.stderr.write(f'{type(error).__name__}: {error}\n')
    sys.exit(2)

if result == text:
    # Refuse to count a no-op as a pass or a miss. A mutation that changed nothing proves
    # nothing, and recording it as "caught" would make the harness lie.
    sys.stderr.write('the expression left the file unchanged\n')
    sys.exit(3)

with open(path, 'w', encoding='utf-8') as handle:
    handle.write(result)
PY
  then
    echo "NO-OP    $label (the mutation did not change the file)"
    restore "$target"
    fail=$((fail + 1))
    return
  fi

  mutated+=("$target")

  if dart test "$test_file" >/dev/null 2>&1; then
    echo "MISSED   $label"
    fail=$((fail + 1))
  else
    echo "CAUGHT   $label"
    pass=$((pass + 1))
  fi

  restore "$target"
  mutated=("${mutated[@]:0:${#mutated[@]}-1}")
}

echo "Falsifying $test_file"
echo

# --- the required records -----------------------------------------------------------
mutate SECURITY.md '""' 'SECURITY.md emptied'
mutate SECURITY.md 'text.split("## Reporting a vulnerability")[0]' \
  'the vulnerability reporting section deleted'
mutate SECURITY.md \
  'text.replace("## Reporting a vulnerability", "## Getting started")' \
  'the reporting section renamed'
mutate SECURITY.md \
  're.sub(r"GitHub Security Advisories", "the issue tracker", text)' \
  'the reporting channel turned into a public issue'
mutate SECURITY.md 're.sub(r"90 days", "whenever", text)' \
  'the disclosure window removed'
mutate CODE_OF_CONDUCT.md 're.sub(r"## Enforcement", "## Notes", text)' \
  'the enforcement section removed'
mutate .github/CODEOWNERS 're.sub(r"^/SECURITY\.md.*$", "", text, flags=re.M)' \
  'the /SECURITY.md owner removed'
mutate .github/CODEOWNERS 'text.replace("@DipDevDevelopers", "@dip-develop")' \
  'an owner replaced with the organisation login'
mutate .github/CODEOWNERS 're.sub(r"^/pubspec\.lock.*$", "", text, flags=re.M)' \
  'the /pubspec.lock owner removed'
mutate ARCHITECTURE.md 're.sub(r"## Trust tiers", "## Overview", text)' \
  'the trust-tier section removed'
mutate ARCHITECTURE.md 're.sub(r"^## The six nouns.*?(?=^## )", "", text, flags=re.M|re.S)' \
  'the six-noun table removed'

# --- the constitution ---------------------------------------------------------------
mutate docs/vision-and-scope.md \
  're.sub(r"^## 3\. Constitution", "## 3. Goals", text, flags=re.M)' \
  'the constitution heading removed'
mutate docs/vision-and-scope.md \
  're.sub(r"^9\. \*\*Untrusted by default\.\*\*.*?Tier 2 runs fail-closed\.", "9. **Untrusted by default.** Content informs.", text, flags=re.M|re.S)' \
  'the fail-closed clause dropped from principle 9'
mutate ARCHITECTURE.md \
  're.sub(r"^## The ten principles.*?(?=^## )", "", text, flags=re.M|re.S)' \
  'the ten principles removed from ARCHITECTURE.md'

# --- the ADRs -----------------------------------------------------------------------
mutate docs/decisions/0003-execution-tiers.md '""' 'ADR-0003 emptied'
mutate docs/decisions/0003-execution-tiers.md \
  're.sub(r"^## Consequences.*?(?=^## )", "", text, flags=re.M|re.S)' \
  'the Consequences section removed'
mutate docs/decisions/0003-execution-tiers.md \
  're.sub(r"^## Alternatives considered.*?(?=^## |\Z)", "## Alternatives considered\n\n- **Isolate-based sandboxing.**\n", text, flags=re.M|re.S)' \
  'the rejected alternative reduced to a bare name'
mutate docs/decisions/0003-execution-tiers.md \
  're.sub(r"^\*\*Status:\*\* Accepted", "**Status:** Draft", text, flags=re.M)' \
  'a named decision downgraded to Draft'
mutate docs/decisions/0003-execution-tiers.md \
  're.sub(r"^\*\*Date:\*\*.*$", "", text, flags=re.M)' \
  'the decision date removed'
mutate docs/decisions/README.md \
  'text.replace("[0003](0003-execution-tiers.md)", "0003")' \
  'a record unlinked from the index'
mutate docs/decisions/0003-execution-tiers.md \
  're.sub(r"^## Context", "## Background", text, flags=re.M)' \
  'the Context section renamed'

# --- Tier 2 fails closed -----------------------------------------------------------
mutate docs/extensibility/plugins.md \
  'text.replace("Process + OS sandbox + capability broker; on failure, a fail-closed refusal", "Process + OS sandbox + capability broker")' \
  'the Tier 2 boundary cell loses its refusal'
mutate docs/extensibility/plugins.md \
  'text.replace("| Sandbox unavailable or preflight failed | `-32040` | Refused; no degraded mode |", "| Sandbox unavailable or preflight failed | `-32040` | Warned |")' \
  'a failed sandbox downgraded to a warning'
mutate docs/extensibility/plugins.md \
  're.sub(r"^\- \*\*macOS and Windows\.\*\* Tier 2 is unsupported until a platform supervisor exists\.", "- **macOS and Windows.** Tier 2 runs on both.", text, flags=re.M)' \
  'the macOS and Windows policy bullet rewritten'
mutate docs/architecture/protocol.md \
  're.sub(r"- `warn\+degrade` is permitted only.*?fail-closed\.", "- `warn+degrade` is permitted whenever convenient.", text, flags=re.S)' \
  'the degrade policy loses its carve-out'
mutate docs/security/threat-model.md \
  're.sub(r"fail-closed", "warn", text)' \
  'every fail-closed in the threat model swapped for a warning'
mutate docs/security/threat-model.md \
  're.sub(r"(fail-closed|refus\w*)", "proceeds", text)' \
  'the trust-boundary section stripped of its refusal'
mutate SECURITY.md \
  're.sub(r"(?<=^## Trust boundaries you can rely on\n)(.*?)(?=^This document)", "", text, flags=re.M|re.S)' \
  'the trust-boundary claim section emptied'
mutate docs/extensibility/plugins.md \
  'text + "\n\nTier 2 will fall back to tier 1 if the sandbox cannot be established.\n"' \
  'a fallback to Tier 1 appended'
mutate docs/extensibility/plugins.md \
  'text + "\n\nIf no sandbox is available the plugin still runs.\n"' \
  'a plugin allowed to run without a sandbox appended'

echo
echo "caught $pass, missed $fail"
[ "$fail" -eq 0 ]
