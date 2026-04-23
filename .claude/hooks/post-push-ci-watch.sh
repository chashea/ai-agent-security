#!/usr/bin/env bash
# PostToolUse hook — fires after successful `git push` and tells Claude to
# launch the devops-engineer subagent to watch CI and auto-fix failures
# per the "Post-push CI watch (automatic)" rule in CLAUDE.md.
#
# Idempotent: if the marker already records the current HEAD SHA, no-op.
# Filters: the command must contain "git push" and must NOT contain
# "--dry-run". Silent no-op for non-matching commands.

set -u
REPO="/Users/charlesshea/repos/ai-agent-security"

# Read tool input JSON from stdin.
payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo '')"

# Filter: only fire on real `git push` commands.
case "$cmd" in
  *"--dry-run"*) exit 0 ;;
  *"git push"*) ;;
  *) exit 0 ;;
esac

# Best-effort HEAD SHA; degrade gracefully if the repo is missing.
sha="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
marker="$REPO/.claude/pending_ci_watch"

# Idempotent: same SHA already pending → no-op.
if [ -f "$marker" ] && grep -qx "sha=$sha" "$marker" 2>/dev/null; then
  exit 0
fi

mkdir -p "$REPO/.claude"
{
  echo "sha=$sha"
  echo "repo=$REPO"
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "command=$cmd"
} > "$marker"

# Emit hookSpecificOutput.additionalContext — injected into Claude's context
# next turn, triggering the autonomous CI-watch loop.
jq -cn \
  --arg sha "$sha" \
  --arg marker "$marker" \
  --arg repo "$REPO" \
  '{
     systemMessage: ("git push detected for " + $sha + " — launching devops-engineer CI watch."),
     hookSpecificOutput: {
       hookEventName: "PostToolUse",
       additionalContext: ("A git push just completed from the " + $repo + " repo (HEAD=" + $sha + "). Immediately launch the devops-engineer subagent to watch the GitHub Actions run for this SHA per the \"Post-push CI watch (automatic)\" rule in CLAUDE.md. On CI failure, autonomously launch a fix subagent — do not ask the user first. Three-fix circuit breaker applies. Marker file: " + $marker)
     }
   }'
