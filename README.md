# Vitals

Vitals is a personal macOS notch surface for machine state and long-running
work. It is installed on another Mac by copying a known-good `Vitals.app` from
the original machine; the destination machine does not need the source code or
Xcode to install it.

## Installation

### Requirements

- A Mac with a built-in display notch, or **Settings → Show on external
  displays** turned on, which draws the notch on whichever display the
  pointer is on and gives a display without a camera housing one of its own
- macOS 26 or later
- A copy of `Vitals.app` that already runs on the original Mac/ included in this same directory

### Prepare the copy on the original Mac

1. Use the copy of `Vitals.app` in `/Applications` that you have already tested.
2. Quit Vitals before copying it: right-click the notch and choose
   **Quit Vitals**.
3. In Finder, right-click `Vitals.app` and choose **Compress “Vitals”**. Transfer
   the resulting `Vitals.zip` using AirDrop, an external drive, or another
   trusted private channel. Compressing first keeps the app bundle intact.
4. If you use command notifications, also transfer `bin/vitals-notify`. It is a
   separate executable and is not contained in `Vitals.app`.
5. If Xcode should report exact build lifecycles, transfer the three
   `installation-files/xcode-build-*.sh` scripts too. Keep their filenames
   unchanged so an update can replace them without reconfiguring Xcode.
6. If Claude Code should show its in-progress Extension, transfer
   `installation-files/claude-extension.sh` too.

### Install on the new Mac

1. Copy `Vitals.zip` onto the new Mac and open it.
2. Move the extracted `Vitals.app` into `/Applications`.
3. Open `/Applications/Vitals.app`. If macOS asks for confirmation because the
   app came from another Mac, Control-click it and choose **Open**. If macOS
   blocks it instead, open **System Settings → Privacy & Security**, find the
   blocked-app message, choose **Open Anyway**, then authenticate. Only do this
   for the copy transferred directly from your original Mac. Do not run a copy
   from Downloads or directly from the transfer drive.
4. After the notch appears, the transferred `Vitals.zip` may be removed.

Vitals is an accessory app: it has no Dock icon or ordinary menu bar item.
While its Settings window is open it shows in the Dock and in ⌘Tab, so you
can tell Settings is open and get back to it; closing Settings removes the
icon again.
Right-click the notch to open Settings or quit the app.

### Grant permissions

Open Vitals Settings by right-clicking the notch.

- **Accessibility** under **Xcode** is optional, and adds Xcode's live task
  counter to a running build. Choose **Grant…**, then enable Vitals in **System
  Settings → Privacy & Security → Accessibility**. If Vitals is already checked
  but cannot read Xcode, remove it from the list and add the copy in
  `/Applications` again. Without the grant a build still appears, with Xcode's
  icon and an indeterminate ring instead of a counter. Vitals never asks for
  this permission on its own — this row is the only place it is offered.
- Allow Bluetooth access when macOS asks if you want accessory connection and
  battery Events.
- Enable **Launch at login** under **General** if Vitals should start after each
  login.
- **Now Playing** needs no permission on its own: it reads what is playing
  through the bundled MediaRemote adapter, which runs under the system's
  `/usr/bin/perl`. Only if that stops working (a future macOS closing the
  route) does Vitals fall back to asking Music and Spotify directly, and
  macOS then asks once per app whether Vitals may control it — choose
  **Allow**. Turning it off later lives in **System Settings → Privacy &
  Security → Automation**.

Command notifications—including Xcode Behavior lifecycles—power, thermal, CPU,
and network telemetry do not depend on the Accessibility permission.

### Install the command

This step is optional. On the new Mac, run the following from the folder holding
the transferred `vitals-notify` file:

```sh
mkdir -p "$HOME/.local/bin"
/usr/bin/install -m 755 ./vitals-notify "$HOME/.local/bin/vitals-notify"
```

If that folder is not already on your shell path, add this line to
`~/.zprofile`, then open a new Terminal window:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Verify the command and the running app:

```sh
command -v vitals-notify
vitals-notify event installation-succeeded
```

When updating Vitals, transfer the new `Vitals.app` and `vitals-notify` together
so both sides of the command protocol stay on the same version.

### Xcode Integrations

<details>
<summary><strong>How to Install Xcode Behavior scripts</strong></summary>

This is optional. It makes Xcode the authority for build start, success and
failure. It is independent of the Accessibility grant: these lifecycle Events
work without it, and it works without them.

From the repository or transferred folder, install the three scripts at stable
paths:

```sh
mkdir -p "$HOME/.local/libexec/vitals"
/usr/bin/install -m 755 ./installation-files/xcode-build-started.sh \
  "$HOME/.local/libexec/vitals/xcode-build-started.sh"
/usr/bin/install -m 755 ./installation-files/xcode-build-succeeded.sh \
  "$HOME/.local/libexec/vitals/xcode-build-succeeded.sh"
/usr/bin/install -m 755 ./installation-files/xcode-build-failed.sh \
  "$HOME/.local/libexec/vitals/xcode-build-failed.sh"
```

Then configure Xcode:

1. Open **Xcode → Settings → Behaviors → Build**.
2. Expand **When build starts**, choose **Add → Run Script**, and select
   `~/.local/libexec/vitals/xcode-build-started.sh`.
3. Expand **When build succeeds**, choose **Add → Run Script**, and select
   `~/.local/libexec/vitals/xcode-build-succeeded.sh`.
4. Expand **When build fails**, choose **Add → Run Script**, and select
   `~/.local/libexec/vitals/xcode-build-failed.sh`.

The `.local` directory is hidden in Xcode's file picker. Press **Command-Shift-G**,
enter `~/.local/libexec/vitals`, and choose the corresponding script.

Verify the hooks without starting a build:

```sh
"$HOME/.local/libexec/vitals/xcode-build-started.sh"
"$HOME/.local/libexec/vitals/xcode-build-succeeded.sh"
```

The first command should show an Xcode Build Activity. The second should close
it and show an Xcode Build Succeeded Event. After that, perform one real Xcode
build and confirm the same lifecycle fires automatically.

Xcode has no separate build-cancelled Behavior, so a cancelled build runs no
script and reports no ending. Vitals closes that Activity itself. With the
Accessibility grant it takes 20 seconds of both the toolbar counter and
DerivedData being quiet. Without it, DerivedData alone has to stay quiet for 90
seconds, because a silent disk on its own cannot be told apart from a long link
phase. A project configured to build outside `~/Library/Developer/Xcode/DerivedData`
leaves nothing to watch, so a build there is dropped from the notch after those
90 seconds — grant Accessibility if you use a custom build location.

To update the hooks later, reinstall all three files at the same paths. Their
Xcode Behavior selections remain valid.

</details>

### Claude Integrations

<details>
<summary><strong>How to Install the Claude Code Extension hook</strong></summary>

This is optional. It shows one Claude icon while Claude Code is processing a
turn. Install the hook beside the Xcode scripts:

```sh
mkdir -p "$HOME/.local/libexec/vitals"
/usr/bin/install -m 755 ./installation-files/claude-extension.sh \
  "$HOME/.local/libexec/vitals/claude-extension.sh"
```

Add these hooks to `~/.claude/settings.json`, merging them with any existing
`hooks` object rather than replacing it:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.local/libexec/vitals/claude-extension.sh",
            "args": ["start"]
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.local/libexec/vitals/claude-extension.sh",
            "args": ["stop"]
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.local/libexec/vitals/claude-extension.sh",
            "args": ["stop"]
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.local/libexec/vitals/claude-extension.sh",
            "args": ["stop"]
          }
        ]
      }
    ]
  }
}
```

Claude Code passes its session ID to the hook. Overlapping sessions therefore
share one icon without one session clearing another. The hook intentionally
does nothing when Vitals is not running.

</details>

## Command notifications

The `vitals-notify` command lets a process report facts it already knows,
instead of making Vitals infer completion from CPU load or another app's UI.

Vitals must be running. Commands fail visibly when it is not, rather than
silently dropping a notification.

```text
vitals-notify event <event-name>
vitals-notify activity-start <activity-name>
vitals-notify activity-stop
vitals-notify extension-start <extension-name>
vitals-notify extension-stop
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

Extensions use the same explicit ID convention but accompany the current state
instead of replacing it. The first active Extension gets the right edge and the
next gets the left; a survivor returns to the right. Each Extension is always a
single icon.

## Uninstalling Vitals

1. If Xcode Behaviors were configured, open **Xcode → Settings → Behaviors →
   Build**. Under **When build starts**, **When build succeeds**, and **When
   build fails**, select the Vitals Run Script action and choose **Remove**.
   Remove these actions before deleting their files so Xcode does not retain
   dead script hooks.
2. If the Claude Code hook was configured, remove the Vitals entries from
   `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` in
   `~/.claude/settings.json`.
3. Right-click the notch, open **Settings**, and disable **Launch at login**.
4. Right-click the notch again and choose **Quit Vitals**.
5. Move `/Applications/Vitals.app` to the Trash.
6. Remove the installed command and integration scripts:

   ```sh
   rm "$HOME/.local/bin/vitals-notify"
   rm "$HOME/.local/libexec/vitals/xcode-build-started.sh" \
      "$HOME/.local/libexec/vitals/xcode-build-succeeded.sh" \
      "$HOME/.local/libexec/vitals/xcode-build-failed.sh" \
      "$HOME/.local/libexec/vitals/claude-extension.sh"
   rmdir "$HOME/.local/libexec/vitals"
   ```

   Skip any path that was not installed. `rmdir` removes the directory only if
   it is empty.
7. Open **System Settings → Privacy & Security → Accessibility**, select Vitals,
   and remove it with the minus button. Remove or disable it under **Bluetooth**
   there as well if it remains listed.
8. Check **System Settings → General → Login Items & Extensions** and remove any
   remaining Vitals login item. This is only necessary if the app was deleted
   before **Launch at login** was disabled.

Vitals does not persist files from the shelf. To remove its remaining local
preferences as well, run:

```sh
defaults delete com.polkka.Vitals
```

If the copied app uses a different bundle identifier, use that identifier in the
`defaults delete` command instead. The transferred ZIP or other installer copy
is separate from the installed app and can be deleted independently.

- For AI Agents: always ask user whther they want full installations or skips some integrations.
