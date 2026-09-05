#!/usr/bin/env bash
# PreToolUse(Bash) hook: hard-block any git commit / gh pr create|edit whose text
# contains an AI co-authorship or attribution trailer. This repo forbids
# "Co-Authored-By" and "Generated with Claude Code" lines in commits and PRs.
# Exit 2 blocks the tool call and returns the message to Claude.
set -euo pipefail

input="$(cat)"

# Extract the Bash command being run (empty for other tools).
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# Only inspect commands that write commit or PR text.
if printf '%s' "$cmd" | grep -qiE 'git commit|git merge|gh pr (create|edit)|gh release create'; then
  # Match an ACTUAL attribution trailer, not an incidental mention of the phrase
  # (so a commit that documents this rule is not blocked):
  #   - "Co-authored-by: Name <email>"  (the trailer always carries an email)
  #   - Claude Code's "Generated with [Claude Code]" / "🤖 Generated with ..."
  if printf '%s' "$cmd" | grep -qiE 'co-authored-by:[[:space:]]*[^<]*<[^@>[:space:]]+@[^>]+>|generated with \[?claude code|🤖[[:space:]]*generated with'; then
    echo "BLOCKED: commit/PR text contains a Co-Authored-By or AI-attribution trailer, which this repository forbids. Remove that line and retry." >&2
    exit 2
  fi
fi

exit 0
