# sunshine-display-swapper

> **Written with AI assistance.** This script and its documentation were produced with the help
> of an AI coding assistant, then tested on a real Arch/KDE/Wayland machine — mode matching,
> the live display switch, the re-entrancy guard, and the restore fallbacks were all exercised
> before release. Even so, read the script before running it. It disables your monitors as part
> of normal operation, so a bug or an untested edge case on your hardware can leave you looking
> at a dark screen. Know how to reach a TTY (`Ctrl+Alt+F3`) before you first run it.

Moves your KDE/Wayland desktop onto a dedicated streaming output when a
[Sunshine](https://github.com/LizardByte/Sunshine) session starts, and moves it back when the
session ends.

The streaming output is set to the closest mode it can offer to what the Moonlight client
asked for. Resolution, refresh rate and HDR are read from Sunshine's `prep-cmd` environment, so
a single Sunshine app entry covers every resolution/fps/HDR combination rather than needing one
entry per combination.

The desktop layout is **discovered and snapshotted at runtime**, never hardcoded. If your main
monitor moves from `DP-4` to `DP-6` because you changed a cable or a GPU port, nothing needs
editing.

## Requirements

### Mandatory

| Requirement | Detail |
|---|---|
| OS | Linux. Developed and tested on Arch. |
| Desktop | **KDE Plasma** — `kscreen-doctor` is KDE-specific and has no GNOME or wlroots equivalent. Tested on Plasma 6.7.4. |
| Display server | **Wayland.** Tested on `XDG_SESSION_TYPE=wayland`. X11 is unsupported: `kscreen-doctor` cannot set fractional scale there, and HDR/WCG do not exist on X11 at all. |
| `kscreen-doctor` | Ships with `libkscreen` (Arch: `libkscreen`). Tested 6.7.4. |
| `jq` | 1.6 or newer. Tested 1.8.2. |
| `bash` | 4.2 or newer — the script uses `declare -g`. Tested 5.3.15. |
| Sunshine | Any version that exports `SUNSHINE_CLIENT_*` to `prep-cmd`. Tested 2026.516.143833. |
| Core utilities | `awk`, `sed`, `date`, `readlink`, `dirname`, `mkdir` (coreutils) and `setsid` (util-linux). Present on any normal desktop install. |

### Two outputs

The script needs **two outputs that KDE can enable independently**:

- a **streaming output** — what Sunshine captures, kept disabled when you are not streaming
- one or more **desktop outputs** — your real monitors, disabled while streaming

The streaming output must show as `connected` in `kscreen-doctor -o`. Any of these work:

- an **HDMI/DP dummy plug** (EDID emulator) — the usual approach: cheap, needs no configuration,
  and it advertises a fixed mode list for the script to pick from
- a **real second display** you do not otherwise use
- a **virtual KMS output**, for example via amdgpu/i915 `video=` kernel parameters, or a driver
  that exposes writeback connectors

Your streaming output's mode list is the hard limit on what can be matched — the script can only
select modes the output already advertises. `kscreen-doctor` has no API for creating custom
modes, so a client asking for something the output does not advertise gets the closest available
mode rather than an exact one. Run `status` to see what yours offers.

HDR additionally requires an output that reports HDR as capable. The script checks this, and if
the output cannot do HDR it logs a warning and streams SDR instead of failing.

### Optional

- **Steam** — only if you want Big Picture launched automatically.

## Install

Clone the repository somewhere you are happy to keep it. The clone is where you will `git pull`
updates from, so do not delete it afterwards:

```bash
git clone https://github.com/subnebula/sunshine-display-swapper.git
cd sunshine-display-swapper
```

Copy the script next to your Sunshine config, **and the config file alongside it**:

```bash
cp sunshine-display.sh ~/.config/sunshine/
chmod +x ~/.config/sunshine/sunshine-display.sh
cp sunshine-display.conf.example ~/.config/sunshine/sunshine-display.conf
```

The config file is **required** — without it the script refuses to run. It must be named exactly
`sunshine-display.conf` and sit in the same directory as the script; that location is not
configurable.

The `chmod` is only needed if your filesystem dropped the executable bit — the file is committed
as executable.

Now check that the script identifies your outputs correctly:

```bash
~/.config/sunshine/sunshine-display.sh status
```

Read the `outputs:` table it prints. The example config assumes your streaming output is called
`HDMI-A-1`; **if yours has a different connector name**, set `VIRTUAL_OUTPUT` to match — see
[Configuration](#configuration).

### Symlink instead of copy

If you would rather have `git pull` update the installed script directly, symlink it:

```bash
ln -s "$PWD/sunshine-display.sh" ~/.config/sunshine/sunshine-display.sh
cp sunshine-display.conf.example sunshine-display.conf
```

The script resolves the symlink to its target before looking for the config, so with this layout
the config must sit **next to the real script inside the clone**, not next to the symlink.
`sunshine-display.conf` is gitignored, so `git pull` will not touch it.

The trade-off: moving or deleting the clone breaks the symlink, and Sunshine's prep-cmd then
fails. Copying is safer.

### Updating

```bash
cd /path/to/sunshine-display-swapper
git pull
cp sunshine-display.sh ~/.config/sunshine/    # skip if you symlinked
```

Your `sunshine-display.conf` is never overwritten by an update — it is not tracked by this
repository. Only the `.example` file is.

## Sunshine setup

Add this `prep-cmd` pair to each app in `~/.config/sunshine/apps.json`:

```json
{
    "name": "Desktop",
    "image-path": "desktop.png",
    "prep-cmd": [
        {
            "do":   "bash /home/YOU/.config/sunshine/sunshine-display.sh activate",
            "undo": "bash /home/YOU/.config/sunshine/sunshine-display.sh deactivate"
        }
    ]
}
```

Give an app a name containing `steam` (case-insensitive) and Big Picture launches with it — no
extra configuration, no `detached` block:

```json
{
    "name": "Steam Big Picture",
    "image-path": "steam.png",
    "prep-cmd": [
        {
            "do":   "bash /home/YOU/.config/sunshine/sunshine-display.sh activate",
            "undo": "bash /home/YOU/.config/sunshine/sunshine-display.sh deactivate"
        }
    ]
}
```

Restart Sunshine to pick up the change:

```bash
systemctl --user restart sunshine
```

**Enable "change resolution on client request" (sops)** in the Sunshine Web UI. Without it,
Sunshine never sends the client's resolution, and the script falls back to the streaming
output's current mode and your configured `DEFAULT_FPS` — meaning you get the same mode on
every stream regardless of what the client asked for.

## Usage

```
sunshine-display.sh activate     # switch to the streaming output
sunshine-display.sh deactivate   # restore the desktop
sunshine-display.sh status       # show outputs, saved state, and the mode that would be picked
```

`activate` and `deactivate` both accept `--dry-run`, which prints the `kscreen-doctor` command
instead of running it and leaves the state file alone.

Test the mode matcher without streaming — this changes nothing:

```bash
SUNSHINE_CLIENT_WIDTH=3840 SUNSHINE_CLIENT_HEIGHT=2160 SUNSHINE_CLIENT_FPS=120 \
  ~/.config/sunshine/sunshine-display.sh activate --dry-run
```

> **Running `activate` for real outside a stream blanks your desktop.** Arm a restore timer
> *before* the switch, so a mistake cannot strand you:
>
> ```bash
> ( sleep 30; ~/.config/sunshine/sunshine-display.sh deactivate ) &
> ~/.config/sunshine/sunshine-display.sh activate
> ```
>
> If you are ever stranded, switch to a TTY with `Ctrl+Alt+F3` and run `deactivate` there.

## Configuration

Nothing in the script itself needs editing. Each setting is looked for in the environment first,
then in the config file:

```
environment variable   >   config file
```

**Every setting is required.** If a value is absent from both places, the script lists the
missing settings and exits without touching anything — a broken config leaves your desktop
exactly as it was, rather than switching to an unintended output mid-stream.

### The config file

`sunshine-display.conf`, in the same directory as `sunshine-display.sh` — so
`~/.config/sunshine/sunshine-display.conf` for the standard install. The name and location are
fixed and cannot be overridden.

It is sourced as shell, so it must be valid bash: no spaces around `=`, and quote any value
containing spaces or `$`:

```bash
VIRTUAL_OUTPUT=DP-3
STEAM_MATCH=bigpicture
DEFAULT_FPS=120
```

To confirm it was picked up, run `status` — it prints which file it loaded and the resulting
values:

```console
$ ~/.config/sunshine/sunshine-display.sh status
config file    : /home/you/.config/sunshine/sunshine-display.conf (loaded)
virtual output : DP-3
```

**When configuring for Sunshine, use this file rather than environment variables.** Sunshine
does not run `prep-cmd` through a shell, so a `VAR=value bash script.sh` prefix in `apps.json`
is not parsed as an assignment — it is treated as a command name, and the prep-cmd fails. The
config file sidesteps that problem, which is also why the config's own location is not settable
by an environment variable: doing so would reintroduce it.

### Environment variables

A variable set in the environment overrides the config file, which is useful for one-off testing
without editing anything:

```bash
VIRTUAL_OUTPUT=DP-3 ~/.config/sunshine/sunshine-display.sh status
```

The environment can also supply a setting the config file leaves out; the two sources only need
to cover the full list between them.

If you genuinely need a per-app override from `apps.json`, wrap the command in a shell so the
assignment is parsed:

```json
"do": "sh -c 'VIRTUAL_OUTPUT=DP-3 bash /home/YOU/.config/sunshine/sunshine-display.sh activate'"
```

Sunshine's `apps.json` does have a top-level `env` block, but it applies to every app at once,
so it cannot express a per-app override.

### Settings

All are required. The values below are what ships in `sunshine-display.conf.example` and make
reasonable starting points.

| Variable | Example | Meaning |
|---|---|---|
| `VIRTUAL_OUTPUT` | `HDMI-A-1` | The streaming output's connector name. The one setting most people must change. |
| `STEAM_MATCH` | `steam` | Case-insensitive substring of `SUNSHINE_APP_NAME` that triggers Big Picture. |
| `DEFAULT_FPS` | `60` | Used when the client sends no fps. Positive integer. |
| `ASPECT_TOLERANCE` | `0.02` | Relative aspect-ratio tolerance when grouping candidate modes. `0.02` is 2%. |
| `FPS_TOLERANCE` | `0.5` | Refresh-rate tolerance in Hz. Absorbs EDID rounding, so 59.94 satisfies a request for 60. |
| `BP_CLOSE_WAIT` | `2` | Seconds to wait after closing Big Picture before moving displays. |
| `SUNSHINE_DISPLAY_STATE` | `$XDG_RUNTIME_DIR/sunshine-display-state.json` | Where the saved desktop layout is written. |
| `SUNSHINE_DISPLAY_LOG` | `~/.config/sunshine/sunshine-display.log` | Log file. |

`DEFAULT_FPS`, `BP_CLOSE_WAIT`, `ASPECT_TOLERANCE` and `FPS_TOLERANCE` are checked for being
numeric at startup, so a typo is rejected before anything changes.

Sunshine supplies `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`, `SUNSHINE_CLIENT_FPS`,
`SUNSHINE_CLIENT_HDR` and `SUNSHINE_APP_NAME` at runtime — you do not set these. All are
optional; when they are missing the script falls back to the streaming output's current mode and
`DEFAULT_FPS`. Do not put them in the config file, since they change with every stream.

## How mode matching works

**Resolution wins over refresh rate.** A resolution mismatch makes the client rescale the image
and everything looks soft; a refresh mismatch only feels less smooth.

1. Prefer modes matching the client's aspect ratio, within `ASPECT_TOLERANCE`. The full mode
   list is considered only if none match. A 16:10 client gets a 16:10 mode rather than a
   pixel-closer 16:9 one, which avoids letterboxing.
2. Within that group, pick the resolution with the closest total pixel count. Exact ties prefer
   not going below what was asked for.
3. At that resolution, pick the highest refresh rate that does not exceed the request. If every
   mode there is faster than requested, take the slowest available.

Modes are addressed by **mode id**, never as `WxH@rate`. Mode lists routinely contain several
entries sharing a display name — `3840x2160@60` may appear as both id 1 and id 9 — and the
string form gives no control over which one is selected.

Worked examples, against the mode list of one 4K dummy plug:

| Client asks | Gets | Why |
|---|---|---|
| `3840x2160@120` | `3840x2160@60` | Resolution kept; refresh capped at the fastest this output offers at 4K. |
| `2560x1440@120` | `2560x1440@120` | Exact match. |
| `1920x1200@60` | `1680x1050@59.88` | 16:10 preserved instead of the pixel-closer `1920x1080`. |
| `1280x720@60` | `1280x720@60` | Exact match. |

Your own output will differ. Run `status` to see its full mode list and what would be chosen.

## Restoring the desktop

`activate` snapshots every enabled non-streaming output — connector name, mode id, scale,
position, priority, rotation, and HDR/WCG state — to a JSON state file before changing anything.
`deactivate` replays that snapshot.

The example config puts the state file under `$XDG_RUNTIME_DIR`, so it is discarded when your
session ends. That matters: a reboot mid-stream cannot leave a stale snapshot behind that tries
to restore a layout which no longer exists.

Safety behaviour:

- **Atomic transactions.** Enabling the streaming output and disabling the desktop happen in a
  single `kscreen-doctor` invocation. Splitting them across two calls would briefly leave the
  compositor with zero enabled outputs, which it rejects.
- **Re-entrancy guard.** If `activate` runs while the streaming output is already enabled — a
  Sunshine retry, a double launch, or a `deactivate` that never finished — the existing state
  file is kept rather than overwritten. Without this, the second run would record the *streaming*
  layout as "the desktop", and `deactivate` would then restore a blank screen.
- **Missing state fallback.** If the state file is gone or corrupt, `deactivate` enables every
  connected non-streaming output at its current mode.
- **Disconnected outputs are skipped individually.** One monitor that went away does not stop
  the others coming back.
- **Restore never hard-fails.** If the full restore is rejected, it retries with modes and
  `enable` only, dropping scale, position, priority and HDR — the parts most likely to be
  refused — and exits 0 either way. A failing undo would leave you looking at a dead desktop.
- **HDR is only ever set on an output that reports it as capable.** Passing `hdr.enable` to an
  incapable output fails the *entire* atomic transaction, taking the resolution change down with
  it.

## Troubleshooting

Everything is logged, including each full `kscreen-doctor` command and its output:

```bash
tail -30 ~/.config/sunshine/sunshine-display.log
```

**`refusing to run, unset setting(s): ...`** — the config file is missing, is not named exactly
`sunshine-display.conf`, is not in the same directory as the script, or does not define every
setting. The message names which ones. Nothing was changed, so your displays are untouched. Run
`status` to see which path it looked in.

**`refusing to run, invalid setting(s): ...`** — a numeric setting has a non-numeric value.
Check for stray quotes or a trailing comment on the same line.

**The desktop did not come back.** Switch to a TTY with `Ctrl+Alt+F3`, then:

```bash
bash ~/.config/sunshine/sunshine-display.sh deactivate
```

**The same resolution is used regardless of client.** Check the `env:` line in the log after a
stream. If it is empty or missing `SUNSHINE_CLIENT_WIDTH`, Sunshine is not passing client values
— enable *change resolution on client request* in the Web UI.

**Big Picture does not launch.** `SUNSHINE_APP_NAME` must contain whatever `STEAM_MATCH` is set
to (`steam` in the example config). Check the `env:` line in the log to see what Sunshine
actually called the app.

**HDR never turns on.** Run `status` and check the streaming output's `hdr=` column. If it reads
`incapable`, that output cannot do HDR, and the log records a warning on every activate.

## Notes

- The script only touches display configuration and, optionally, Steam Big Picture. It does not
  unlock the session, start Sunshine, or manage the stream itself.
- `kscreen-doctor`'s JSON output reports `wideColorGamut` and `capabilities` as `null` even when
  those features are active, so HDR and WCG capability and state are parsed from the
  human-readable `kscreen-doctor -o` output instead. If a future release changes that format,
  HDR detection is the first thing to check.
