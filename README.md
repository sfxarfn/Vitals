# Vitals

Vitals is a personal macOS notch surface for machine state and long-running
work. The app is built and run from `Vitals.xcodeproj`.

## Command notifications

`bin/vitals-notify` lets a process report facts it already knows, instead of
making Vitals infer completion from CPU load or another app's UI.

Add the repository command to your path, or symlink it into a directory already
on your path:

```sh
ln -s "$PWD/bin/vitals-notify" "$HOME/bin/vitals-notify"
```

Vitals must be running. Commands fail visibly when it is not, rather than
silently dropping a notification.

```text
vitals-notify event <event-name>
vitals-notify activity-start <activity-name>
vitals-notify activity-stop
vitals-notify run <activity-name> -- <command> [arguments...]
```

For most shell work, use `run`. It preserves the wrapped command's exit status,
stops the Activity on interruption, and publishes a matching success or failure
Event:

```sh
vitals-notify run tests -- npm test
vitals-notify run deploy -- ./scripts/deploy.sh
```

Separate start and stop calls use the parent shell as their default Activity
identity. Use `--id` or `VITALS_ACTIVITY_ID` when a script needs an explicit,
stable identity. More than one ID may be active; the newest is shown, and the
previous Activity resumes when it stops.
