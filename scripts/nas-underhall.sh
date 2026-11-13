#!/bin/bash
# Daily NAS health check, run by launchd (see
# ~/Library/LaunchAgents/com.ryddmo.nas-underhall.plist). Runs the
# nas-underhall skill headless and saves the report. The ntfy notice is
# sent separately, here in the wrapper script (plain bash, not through
# Claude's Bash tool) - same pattern as the vps repo's underhall-vecka.sh,
# and avoids the headless run needing its own permission rule for curl.
set -euo pipefail

PROJECT_DIR="/Users/stefanrydin/Documents/dev/MediaServer"
OUT_DIR="$PROJECT_DIR/underhall-rapporter"
DATE=$(date +%Y-%m-%d)
REPORT="$OUT_DIR/$DATE.md"
NTFY_URL="https://notify.ryddmo.se/ugreen-architect"

mkdir -p "$OUT_DIR"
cd "$PROJECT_DIR"

/opt/homebrew/bin/claude -p "Run the nas-underhall skill (.claude/skills/nas-underhall/SKILL.md in this project) in full and write the whole report in nas-underhall's own format. NEVER make a change (a fix, an upgrade, a config edit) during this run - report only." \
  --output-format text \
  > "$REPORT" 2>&1

echo "Report saved: $REPORT"

# Short ntfy notice: all-clear, or a flag that the report needs a look.
if grep -qE '^\*\*(Needs attention|Needs a decision):\*\*' "$REPORT" 2>/dev/null \
   && ! grep -qE '^\*\*(Needs attention|Needs a decision):\*\* *$' "$REPORT" 2>/dev/null; then
  MESSAGE="Daily NAS check found something to look at - see $REPORT"
  TAGS="warning"
else
  MESSAGE="All clear, nothing to act on."
  TAGS="white_check_mark"
fi

curl -s -o /dev/null --max-time 10 \
  --header "Title: NAS daily check" \
  --header "Tags: $TAGS" \
  -d "$MESSAGE" "$NTFY_URL" || true
