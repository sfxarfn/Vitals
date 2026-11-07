#!/bin/sh

# Cursor's `stop` hook sends its context as JSON on stdin, with a `status` that is
# `completed` when the agent finished its turn. `plutil` ships with macOS, so the
# hook does not make jq another installation requirement.
#
# ponytail: the payload shape comes from Cursor's hooks documentation as read
# secondhand, not from a captured payload. If `status` is missing the hook
# announces anyway; only `aborted` and `error` stay silent. Check against a real
# `stop` payload before trusting it.
status=$(/usr/bin/plutil -extract status raw -o - -- - 2>/dev/null) || status=
case "$status" in
    aborted|error) ;;
    *) "$HOME/.local/bin/vitals-notify" event cursor-finished >/dev/null 2>&1 || : ;;
esac

# Cursor reads the hook's stdout as JSON; an empty object asks for nothing.
printf '{}\n'
