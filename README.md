# sunshine-screen-swapper

Swaps a KDE/Wayland desktop onto a dedicated streaming output when a
[Sunshine](https://github.com/LizardByte/Sunshine) session starts, and puts it back when
the session ends.

The streaming output is set to the closest mode the client actually asked for — resolution,
refresh rate and HDR are read from Sunshine's `prep-cmd` environment, so one Sunshine app
entry covers every resolution/fps/HDR combination instead of needing one entry per combination.

The desktop layout is **discovered and snapshotted at runtime**, never hardcoded. If your main
monitor moves from `DP-4` to `DP-6` because you changed a cable or a GPU port, nothing needs
editing.

## Requirements

### Mandatory

| | |
|---|---|
| OS | Linux. Developed and tested on Arch. |
| Desktop | **KDE Plasma** — `kscreen-doctor` is KDE-specific and there is no equivalent for GNOME/wlroots. Tested on Plasma 6.7.4. |
| Display server | **Wayland.** Tested on `XDG_SESSION_TYPE=wayland`. X11 is unsupported: `kscreen-doctor` cannot set fractional scale there, and HDR/WCG do not exist on X11 at all. |
| `kscreen-doctor` | From `libkscreen` (Arch: `libkscreen`). Tested 6.7.4. |
| `jq` | 1.6+. Tested 1.8.2. |
| `bash` | 4.0+ (uses `${var,,}` case folding). Tested 5.3.15. |
| Sunshine | Any version that exports `SUNSHINE_CLIENT_*` to `prep-cmd`. Tested 2026.516.143833. |

### Two outputs

The script needs **two outputs that KDE can enable independently**:

- a **streaming output** — what Sunshine captures, disabled when you are not streaming
- one or more **desktop outputs** — your real monitors, disabled while streaming

The streaming output must appear as `connected` in `kscreen-doctor -o`. Any of these work:

- an **HDMI/DP dummy plug** (EDID emulator), the usual approach — cheap, no config, and it
  advertises a fixed mode list the script picks from
- a **real second display** you do not otherwise use
- a **virtual KMS output**, e.g. amdgpu/i915 `video=` kernel parameters, or a driver that
  exposes writeback connectors

The mode list of your streaming output is the hard limit on what can be matched — the script
can only pick modes the output already advertises. `kscreen-doctor` has no API for creating
custom modes, so a client asking for something the output does not advertise gets the closest
available mode, not an exact one. Run `status` (below) to see exactly what yours offers.

HDR additionally requires an output reporting HDR as capable. The script checks this and
silently streams SDR rather than failing if the output cannot do it.

### Optional

- **Steam** — only if you want Big Picture launched automatically.

## Install

```bash
cp sunshine-display.sh ~/.config/sunshine/
chmod +x ~/.config/sunshine/sunshine-display.sh
```

Then check it identifies your outputs correctly:

```bash
~/.config/sunshine/sunshine-display.sh status
```

If your streaming output is not named `HDMI-A-1`, set `VIRTUAL_OUTPUT` — see
[Configuration](#configuration).

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

Name an app so it contains `steam` (case-insensitive) and Big Picture launches with it — no
extra config, no `detached` block:

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

**Enable "change resolution on client request" (sops)** in the Sunshine Web UI. Without it
Sunshine does not send the client's resolution and the script falls back to defaults.

## Usage

```
sunshine-display.sh activate     # switch to the streaming output
sunshine-display.sh deactivate   # restore the desktop
sunshine-display.sh status       # show outputs, saved state, and the mode that would be picked
```

`activate` and `deactivate` accept `--dry-run`, which prints the `kscreen-doctor` command
without running it and leaves the state file alone.

Test the mode matcher without streaming:

```bash
SUNSHINE_CLIENT_WIDTH=3840 SUNSHINE_CLIENT_HEIGHT=2160 SUNSHINE_CLIENT_FPS=120 \
  ./sunshine-display.sh activate --dry-run
```

> **Running `activate` outside a stream blanks your desktop.** Arm a restore timer *before*
> the switch so you are not left with a dark screen:
>
> ```bash
> ( sleep 30; ./sunshine-display.sh deactivate ) &
> ./sunshine-display.sh activate
> ```
>
> If you are ever stranded, switch to a TTY with `Ctrl+Alt+F3` and run `deactivate` there.

## Configuration

All settings are environment variables with defaults; nothing needs editing in the script.

| Variable | Default | Meaning |
|---|---|---|
| `VIRTUAL_OUTPUT` | `HDMI-A-1` | The streaming output's connector name. |
| `STEAM_MATCH` | `steam` | Case-insensitive substring of `SUNSHINE_APP_NAME` that triggers Big Picture. |
| `DEFAULT_FPS` | `60` | Used when the client sends no fps. |
| `ASPECT_TOLERANCE` | `0.02` | Relative aspect-ratio tolerance when grouping candidate modes. |
| `FPS_TOLERANCE` | `0.5` | Absorbs EDID rounding, so 59.94 counts as 60. |
| `BP_CLOSE_WAIT` | `2` | Seconds to wait after closing Big Picture before moving displays. |
| `SUNSHINE_DISPLAY_STATE` | `$XDG_RUNTIME_DIR/sunshine-display-state.json` | Saved desktop layout. |
| `SUNSHINE_DISPLAY_LOG` | `~/.config/sunshine/sunshine-display.log` | Log file. |

Read from Sunshine, not set by you: `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`,
`SUNSHINE_CLIENT_FPS`, `SUNSHINE_CLIENT_HDR`, `SUNSHINE_APP_NAME`. All are optional — the
script falls back to the output's current mode and `DEFAULT_FPS` when they are missing.

## How mode matching works

**Resolution wins over refresh rate.** A resolution mismatch means the client rescales the
image and everything looks soft; a refresh mismatch just feels less smooth.

1. Prefer modes matching the client's aspect ratio (within `ASPECT_TOLERANCE`). Only if none
   match is the full mode list considered. A 16:10 client gets a 16:10 mode rather than a
   pixel-closer 16:9 one, avoiding letterboxing.
2. Within that group, pick the resolution with the closest total pixel count. Exact ties
   prefer not going below what was asked for.
3. At that resolution, pick the highest refresh rate that does not exceed the request. If
   every mode there is faster than requested, take the slowest available.

Modes are addressed by **mode id**, never as `WxH@rate`. Mode lists routinely contain several
entries sharing a display name — `3840x2160@60` may appear as both id 1 and id 9 — and the
string form gives no control over which one is selected.

Worked examples against a typical 4K dummy plug:

| Client asks | Gets | Why |
|---|---|---|
| `3840x2160@120` | `3840x2160@60` | Resolution kept, refresh capped at what 4K supports. |
| `2560x1440@120` | `2560x1440@120` | Exact match. |
| `1920x1200@60` | `1680x1050@59.88` | 16:10 preserved instead of the pixel-closer `1920x1080`. |
| `1280x720@60` | `1280x720@60` | Exact match. |

## Restoring the desktop

`activate` snapshots every enabled non-streaming output — connector name, mode id, scale,
position, priority, rotation, HDR/WCG state — to a JSON state file before changing anything.
`deactivate` replays it.

The state file lives in `$XDG_RUNTIME_DIR`, so it dies with your session. A reboot mid-stream
cannot leave a stale snapshot that tries to restore a layout that no longer exists.

Safety behaviour:

- **Atomic transactions.** Enabling the streaming output and disabling the desktop happen in
  one `kscreen-doctor` invocation. Doing it in two calls would briefly leave the compositor
  with zero enabled outputs, which it rejects.
- **Re-entrancy guard.** If `activate` runs while the streaming output is already enabled
  (Sunshine retry, double launch, a `deactivate` that never finished), the existing state file
  is kept rather than overwritten. Without this, the second run would record the *streaming*
  layout as "the desktop" and `deactivate` would restore a blank screen.
- **Missing state fallback.** If the state file is gone or corrupt, `deactivate` enables every
  connected non-streaming output at its current mode.
- **Disconnected outputs are skipped individually.** One monitor that went away does not stop
  the others coming back.
- **Restore never hard-fails.** If the full restore is rejected, it retries with modes and
  enable only — dropping scale/position/priority/HDR, the parts most likely to be refused —
  and always exits 0. A failing undo would leave you looking at a dead desktop.
- **HDR is only ever set on an output that reports it as capable.** Passing `hdr.enable` to an
  incapable output fails the *entire* atomic transaction, taking the resolution change with it.

## Troubleshooting

Everything is logged, including the full `kscreen-doctor` command and its output:

```bash
tail -30 ~/.config/sunshine/sunshine-display.log
```

**The desktop did not come back.** `Ctrl+Alt+F3` to a TTY, then:

```bash
bash ~/.config/sunshine/sunshine-display.sh deactivate
```

**Resolution is always the same regardless of client.** Check the `env:` line in the log after
a stream. If it is empty or missing `SUNSHINE_CLIENT_WIDTH`, Sunshine is not passing client
values — enable *change resolution on client request* in the Web UI.

**Big Picture does not launch.** `SUNSHINE_APP_NAME` must contain `steam`. Check the `env:`
line in the log for what the app is actually called.

**HDR never turns on.** Run `status` and check the streaming output's `hdr=` column. If it
reads `incapable`, the output cannot do HDR and the log will say so on each activate.

## Notes

- The script only ever touches display configuration and, optionally, Steam Big Picture. It
  does not unlock the session, start Sunshine, or manage the stream itself.
- `kscreen-doctor`'s JSON output reports `wideColorGamut` and `capabilities` as `null` even
  when those features are active, so HDR/WCG capability and state are parsed from the
  human-readable `kscreen-doctor -o` output instead. If a future release changes that format,
  HDR detection is the first thing to check.
