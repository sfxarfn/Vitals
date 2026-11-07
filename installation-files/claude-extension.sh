#!/bin/sh

# Claude Code sends hook context as JSON on stdin. `plutil` ships with macOS, so
# the hook does not make jq another installation requirement.
mode=${1-}
session_id=$(/usr/bin/plutil -extract session_id raw -o - -- - 2>/dev/null) || exit 0
[ -n "$session_id" ] || exit 0

case "$mode" in
    start)
        "$HOME/.local/bin/vitals-notify" extension-start claude --id "claude-$session_id" >/dev/null 2>&1 || :
        ;;
    stop)
        "$HOME/.local/bin/vitals-notify" extension-stop --id "claude-$session_id" >/dev/null 2>&1 || :
        ;;
    # Wired on `Stop` only, beside `stop`: a turn that ended normally. Not on
    # `StopFailure` or `SessionEnd`, which also stop the Extension but have
    # nothing to announce.
    finished)
        "$HOME/.local/bin/vitals-notify" event claude-finished >/dev/null 2>&1 || :
        ;;
esac
