# Vitals

Vitals is a personal macOS notch surface for machine state and long-running
work. It is installed on another Mac by copying a known-good `Vitals.app` from
the original machine; the destination machine does not need the source code or
Xcode to install it.

## Installation

### Requirements

- A Mac with a built-in display notch
- macOS 26 or later
- A copy of `Vitals.app` that already runs on the original Mac

### Prepare the copy on the original Mac

1. Use the copy of `Vitals.app` in `/Applications` that you have already tested.
2. Quit Vitals before copying it: right-click the notch and choose
   **Quit Vitals**.
3. In Finder, right-click `Vitals.app` and choose **Compress “Vitals”**. Transfer
   the resulting `Vitals.zip` using AirDrop, an external drive, or another
   trusted private channel. Compressing first keeps the app bundle intact.
4. If you use command notifications, also copy `vitals-notify` from
   `~/.local/bin`. It is a separate executable and is not contained in
   `Vitals.app`.

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
Right-click the notch to open Settings or quit the app.

### Grant permissions

Open Vitals Settings by right-clicking the notch.

- Under **Permissions**, choose **Grant…** for Accessibility, then enable Vitals
  in **System Settings → Privacy & Security → Accessibility**. This is required
  for automatic Xcode progress and verdict detection. If Vitals is already
  checked but cannot read Xcode, remove it from the list and add the copy in
  `/Applications` again.
- Allow Bluetooth access when macOS asks if you want accessory connection and
  battery Events.
- Enable **Launch at login** under **General** if Vitals should start after each
  login.

Command notifications, power, thermal, CPU, and network telemetry do not depend
on the Accessibility permission.

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

## Command notifications

The `vitals-notify` command lets a process report facts it already knows,
instead of making Vitals infer completion from CPU load or another app's UI.

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

## Uninstalling Vitals

1. Right-click the notch, open **Settings**, and disable **Launch at login**.
2. Right-click the notch again and choose **Quit Vitals**.
3. Move `/Applications/Vitals.app` to the Trash.
4. Remove the installed command:

   ```sh
   rm "$HOME/.local/bin/vitals-notify"
   ```

5. Open **System Settings → Privacy & Security → Accessibility**, select Vitals,
   and remove it with the minus button. Remove or disable it under **Bluetooth**
   there as well if it remains listed.
6. Check **System Settings → General → Login Items & Extensions** and remove any
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
