#!/bin/bash
# Record the repository settings this project depends on, so they are reviewable and
# reproducible rather than living only in a settings page nobody can diff.
#
# The output is NOT a script that configures anything. It is a record: running it tells you
# what the repository looks like, and diffing it against the live settings shows what has
# drifted. The two failure modes this avoids are a setting that was changed in the UI and
# never written down, and a script that "fixes" the repository every time it runs, which is
# how a stale script slowly overwrites a deliberate change.
#
# Usage:
#   tool/release/repo_settings.sh --record > repo-settings.json
#   tool/release/repo_settings.sh --check
set -euo pipefail

repo=dip-develop/alteri-one
mode=${1:---check}

# One ruleset as a compact JSON object: the rules that carry parameters are the ones that
# can drift silently, so their parameters are kept, minus the empty reviewer lists that
# change shape without changing meaning.
one_ruleset() {
  gh api "repos/$repo/rulesets/$1" \
    --jq '{
             name: .name,
             enforcement: .enforcement,
             target: .target,
             branch: (.conditions.ref_name.include // []),
             rules: [ .rules[]
                      | { type: .type,
                          parameters: (if (.type == "pull_request"
                                          or .type == "required_status_checks")
                                       then (.parameters | del(.required_reviewers))
                                       else null end) } ]
           }'
}

snapshot() {
  local meta labels rulesets='[]' id

  meta=$(gh repo view "$repo" \
    --json description,homepageUrl,hasWikiEnabled,hasDiscussionsEnabled,hasIssuesEnabled,deleteBranchOnMerge,defaultBranchRef,visibility)
  labels=$(gh label list --limit 100 --json name --jq '[.[].name] | sort')

  for id in $(gh api "repos/$repo/rulesets" --jq '.[].id' 2>/dev/null || true); do
    rulesets=$(jq -n --argjson a "$rulesets" --argjson b "$(one_ruleset "$id")" '$a + [$b]')
  done

  jq -n \
    --argjson repository "$meta" \
    --argjson labels "$labels" \
    --argjson rulesets "$(printf '%s' "$rulesets" | jq 'sort_by(.name)')" \
    '{ repository: $repository, labels: $labels, rulesets: $rulesets }'
}

case "$mode" in
  --record)
    snapshot
    ;;
  --check)
    if [ ! -f repo-settings.json ]; then
      echo "repo-settings.json is missing. Record it once with --record and commit it." >&2
      exit 1
    fi
    live=$(snapshot)
    if diff <(jq -S . repo-settings.json) <(printf '%s' "$live" | jq -S .) > /tmp/settings.diff; then
      echo "repository settings match repo-settings.json"
    else
      echo "repository settings have drifted from repo-settings.json:" >&2
      cat /tmp/settings.diff >&2
      echo >&2
      echo "If the change was deliberate, re-record it:" >&2
      echo "  tool/release/repo_settings.sh --record > repo-settings.json" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: repo_settings.sh [--record | --check]" >&2
    exit 2
    ;;
esac
