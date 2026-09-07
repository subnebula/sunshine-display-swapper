#!/usr/bin/env bash
#
# sunshine-display.sh - switch KDE/Wayland outputs for Sunshine game streaming.
#
#   activate     Enable the virtual capture output at the closest mode to what the
#                Moonlight client asked for, and disable the real desktop outputs.
#                The desktop layout is snapshotted first so deactivate can restore it.
#   deactivate   Restore the snapshotted desktop layout, disable the virtual output.
#   status       Print outputs, saved state and the mode that would be chosen. Read only.
#
# activate and deactivate both accept --dry-run, which prints the kscreen-doctor
# command instead of running it and leaves the state file alone.
#
# Configuration comes from sunshine-display.conf next to this script, with any
# environment variable of the same name taking precedence. Every setting is
# required; see the block below.
#
# Client parameters come from Sunshine's prep-cmd environment:
#   SUNSHINE_CLIENT_WIDTH / _HEIGHT / _FPS / _HDR, SUNSHINE_APP_NAME
# Those are optional and are read per stream, never from the config file.

set -euo pipefail

# Settings resolve as: environment variable > config file. Every setting is
# required and must come from one of those two places; the script refuses to
# run otherwise rather than guessing at which output to switch to. Validation
# happens before anything touches the display, so a bad or missing config
# aborts with the desktop untouched.
#
# The config file is always sunshine-display.conf sitting next to this script.
# Its location is deliberately not configurable: Sunshine does not run prep-cmd
# through a shell, so a "VAR=value bash script.sh" prefix in apps.json is not
# parsed as an assignment and cannot be used to point the script elsewhere.
#
# BASH_SOURCE is resolved with readlink so that a symlinked install finds the
# config next to the real script rather than next to the symlink.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONFIG_FILE="$SCRIPT_DIR/sunshine-display.conf"

_SETTINGS=(
    VIRTUAL_OUTPUT STEAM_MATCH DEFAULT_FPS ASPECT_TOLERANCE FPS_TOLERANCE
    BP_CLOSE_WAIT SUNSHINE_DISPLAY_STATE SUNSHINE_DISPLAY_LOG
)

# Remember which settings arrived from the environment, so sourcing the config
# file cannot silently clobber an explicit override.
for _s in "${_SETTINGS[@]}"; do
    declare "_env_${_s}=${!_s-}"
done

# The config file is sourced as shell, exactly like .bashrc.
CONFIG_LOADED=""
if [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    CONFIG_LOADED="$CONFIG_FILE"
fi

for _s in "${_SETTINGS[@]}"; do
    _e="_env_${_s}"
    [[ -n "${!_e}" ]] && declare -g "${_s}=${!_e}"
done
unset _s _e

# Fail loudly and specifically. This runs on every invocation including
# deactivate, so the message has to be enough to fix the problem from a TTY.
_missing=()
for _s in "${_SETTINGS[@]}"; do
    [[ -n "${!_s-}" ]] || _missing+=("$_s")
done
if [[ ${#_missing[@]} -gt 0 ]]; then
    {
        echo "sunshine-display.sh: refusing to run, unset setting(s): ${_missing[*]}"
        if [[ -n "$CONFIG_LOADED" ]]; then
            echo "  config file $CONFIG_LOADED was loaded but does not define them."
        else
            echo "  no config file found at $CONFIG_FILE"
            echo "  copy sunshine-display.conf.example there, or set the variables in the environment."
        fi
        echo "  every setting is required; nothing was changed."
    } >&2
    exit 1
fi
unset _s _missing

_bad=()
[[ "$DEFAULT_FPS" =~ ^[0-9]+$ ]] || _bad+=("DEFAULT_FPS='$DEFAULT_FPS' (want a positive integer)")
[[ "$BP_CLOSE_WAIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || _bad+=("BP_CLOSE_WAIT='$BP_CLOSE_WAIT' (want a number)")
[[ "$ASPECT_TOLERANCE" =~ ^[0-9]*[.]?[0-9]+$ ]] || _bad+=("ASPECT_TOLERANCE='$ASPECT_TOLERANCE' (want a number)")
[[ "$FPS_TOLERANCE" =~ ^[0-9]*[.]?[0-9]+$ ]] || _bad+=("FPS_TOLERANCE='$FPS_TOLERANCE' (want a number)")
if [[ ${#_bad[@]} -gt 0 ]]; then
    {
        echo "sunshine-display.sh: refusing to run, invalid setting(s):"
        printf '  %s\n' "${_bad[@]}"
        echo "  nothing was changed."
    } >&2
    exit 1
fi
unset _bad

STATE_FILE="$SUNSHINE_DISPLAY_STATE"
LOG_FILE="$SUNSHINE_DISPLAY_LOG"

DRY_RUN=0
KD_JSON=""
CAPS_JSON=""

# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #

log() {
    local line
    line="[$(date -Is)] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    [[ -t 1 || $DRY_RUN -eq 1 ]] && printf '%s\n' "$line" >&2
    return 0
}

die() {
    log "FATAL: $*"
    exit 1
}

# --------------------------------------------------------------------------- #
# reading current display state
# --------------------------------------------------------------------------- #

# kscreen-doctor -j gives us structure (modes, ids, scale, position) but its
# hdr field is null for outputs that cannot do HDR and its wideColorGamut field
# is null even for outputs that currently have WCG on. The human-readable
# output is the only place both capability and state are exposed, so parse that
# for HDR/WCG and use JSON for everything else.

load_json() {
    [[ -n "$KD_JSON" ]] && return 0
    KD_JSON="$(kscreen-doctor -j 2>/dev/null)" || die "kscreen-doctor -j failed"
    [[ -n "$KD_JSON" ]] || die "kscreen-doctor -j returned nothing"
}

load_caps() {
    [[ -n "$CAPS_JSON" ]] && return 0
    CAPS_JSON="$(
        kscreen-doctor -o 2>&1 |
            sed -e 's/\x1b\[[0-9;]*m//g' |
            awk '
                /^Output:/ { name = $3 }
                /^[ \t]*HDR:/ {
                    sub(/^[ \t]*HDR:[ \t]*/, "")
                    print name "\thdr\t" $0
                }
                /^[ \t]*Wide Color Gamut:/ {
                    sub(/^[ \t]*Wide Color Gamut:[ \t]*/, "")
                    print name "\twcg\t" $0
                }' |
            jq -Rn '
                [inputs | select(length > 0) | split("\t")]
                | reduce .[] as $r ({};
                    .[$r[0]] = ((.[$r[0]] // {}) + { ($r[1]): $r[2] }))
            '
    )" || CAPS_JSON="{}"
    [[ -n "$CAPS_JSON" ]] || CAPS_JSON="{}"
}

# cap_state <output> <hdr|wcg> -> "enabled" / "disabled" / "incapable" / "unknown"
cap_state() {
    load_caps
    jq -r --arg o "$1" --arg k "$2" '.[$o][$k] // "unknown"' <<<"$CAPS_JSON"
}

# cap_supported <output> <hdr|wcg> -> exit 0 if the output can do it
cap_supported() {
    local s
    s="$(cap_state "$1" "$2")"
    [[ "$s" != "incapable" && "$s" != "unsupported" && "$s" != "unknown" ]]
}

output_exists() {
    load_json
    jq -e --arg o "$1" 'any(.outputs[]; .name == $o)' <<<"$KD_JSON" >/dev/null
}

output_enabled() {
    load_json
    jq -e --arg o "$1" \
        'any(.outputs[]; .name == $o and .enabled == true)' <<<"$KD_JSON" >/dev/null
}

# --------------------------------------------------------------------------- #
# mode selection
# --------------------------------------------------------------------------- #

# Resolution wins over refresh rate. Prefer modes matching the client's aspect
# ratio, then the closest total pixel count, then the highest refresh rate that
# does not exceed what was asked for.
#
# Modes are addressed by id, never by "WxH@rate": the mode list contains several
# entries sharing a display name (3840x2160@60 appears as both id 1 and id 9,
# 1920x1080@60 twice) and the string form gives no control over which is picked.
#
# Prints: id, width, height, refresh, res_exact, fps_exact, aspect_matched
select_mode() {
    local rw="$1" rh="$2" rfps="$3"
    load_json
    jq -r \
        --arg vo "$VIRTUAL_OUTPUT" \
        --argjson rw "$rw" --argjson rh "$rh" --argjson rfps "$rfps" \
        --argjson atol "$ASPECT_TOLERANCE" --argjson ftol "$FPS_TOLERANCE" '
        def abs: if . < 0 then - . else . end;

        (.outputs[] | select(.name == $vo) | .modes) as $modes
        | ($rw * $rh) as $reqpx
        | ($rw / $rh) as $reqar

        # Stage 1a: restrict to modes with the requested aspect ratio, if any exist.
        | [ $modes[]
            | select(((.size.width / .size.height) - $reqar | abs) <= ($atol * $reqar)) ]
          as $aspect_pool
        | (($aspect_pool | length) > 0) as $aspect_matched
        | (if $aspect_matched then $aspect_pool else $modes end) as $pool

        # Stage 1b: closest total pixel count; ties prefer not going below the request.
        | ($pool
            | map({ w: .size.width, h: .size.height })
            | unique
            | sort_by([ ((.w * .h) - $reqpx | abs),
                        (if .w >= $rw then 0 else 1 end) ])
            | .[0]) as $res

        # Stage 2: highest refresh at that resolution that does not exceed the
        # request. If every mode there is faster than asked, take the slowest.
        | [ $pool[]
            | select(.size.width == $res.w and .size.height == $res.h) ] as $cand
        | ([ $cand[] | select(.refreshRate <= ($rfps + $ftol)) ]
            | sort_by(.refreshRate) | last) as $capped
        | (if $capped == null
           then ($cand | sort_by(.refreshRate) | first)
           else $capped end) as $mode

        | [ $mode.id,
            $mode.size.width,
            $mode.size.height,
            ($mode.refreshRate * 100 | round / 100),
            (($mode.size.width == $rw and $mode.size.height == $rh) | tostring),
            ((($mode.refreshRate - $rfps) | abs) <= $ftol | tostring),
            ($aspect_matched | tostring) ]
        | @tsv
    ' <<<"$KD_JSON"
}

# --------------------------------------------------------------------------- #
# client request parsing
# --------------------------------------------------------------------------- #

is_positive_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

# Echoes: width height fps hdr(0|1)
client_request() {
    load_json
    local rw rh rfps rhdr

    rw="${SUNSHINE_CLIENT_WIDTH:-}"
    rh="${SUNSHINE_CLIENT_HEIGHT:-}"
    rfps="${SUNSHINE_CLIENT_FPS:-}"

    # Sunshine may report fps as a float; take the integer part.
    rfps="${rfps%%.*}"

    if ! is_positive_int "$rw" || ! is_positive_int "$rh"; then
        # Fall back to whatever the virtual output is currently set to.
        local cur
        cur="$(jq -r --arg o "$VIRTUAL_OUTPUT" '
            (.outputs[] | select(.name == $o)) as $out
            | ($out.modes[] | select(.id == $out.currentModeId))
            | "\(.size.width) \(.size.height)"' <<<"$KD_JSON")"
        rw="${cur%% *}"
        rh="${cur##* }"
        log "client width/height unset or invalid, defaulting to current mode ${rw}x${rh}"
    fi

    if ! is_positive_int "$rfps"; then
        rfps="$DEFAULT_FPS"
        log "client fps unset or invalid, defaulting to ${rfps}"
    fi

    rhdr=0
    case "${SUNSHINE_CLIENT_HDR:-}" in
        [1yY]* | [tT][rR][uU][eE] | [oO][nN]) rhdr=1 ;;
    esac

    printf '%s %s %s %s\n' "$rw" "$rh" "$rfps" "$rhdr"
}

# --------------------------------------------------------------------------- #
# applying configuration
# --------------------------------------------------------------------------- #

# kscreen-doctor applies every argument in one atomic transaction. Enabling the
# virtual output and disabling the desktop outputs MUST therefore go in a single
# invocation: disabling everything in a separate earlier call would momentarily
# leave the compositor with no enabled output, which it rejects.
run_kscreen() {
    local -a args=("$@")
    log "kscreen-doctor ${args[*]}"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf 'DRY RUN: kscreen-doctor %s\n' "${args[*]}"
        return 0
    fi
    local out rc=0
    out="$(kscreen-doctor "${args[@]}" 2>&1)" || rc=$?
    [[ -n "$out" ]] && log "kscreen-doctor output: $out"
    if [[ $rc -ne 0 ]]; then
        log "kscreen-doctor exited $rc"
        return "$rc"
    fi
    log "kscreen-doctor succeeded"
    return 0
}

# KScreen rotation enum -> kscreen-doctor keyword. Anything unrecognised is
# left alone rather than guessed at.
rotation_keyword() {
    case "${1:-1}" in
        1) echo "none" ;;
        2) echo "left" ;;
        4) echo "inverted" ;;
        8) echo "right" ;;
        *) echo "" ;;
    esac
}

# --------------------------------------------------------------------------- #
# snapshot / restore state
# --------------------------------------------------------------------------- #

snapshot_outputs() {
    load_json
    load_caps
    jq -c --arg vo "$VIRTUAL_OUTPUT" --argjson caps "$CAPS_JSON" '
        [ .outputs[]
          | select(.connected == true and .enabled == true and .name != $vo)
          | { name,
              modeId:   .currentModeId,
              scale:    (.scale // 1),
              rotation: (.rotation // 1),
              priority: (.priority // 1),
              x:        (.pos.x // 0),
              y:        (.pos.y // 0),
              hdr:      ($caps[.name].hdr // "unknown"),
              wcg:      ($caps[.name].wcg // "unknown") } ]
    ' <<<"$KD_JSON"
}

# Every connected non-virtual output, regardless of current enabled state.
# Used as the restore fallback when the state file is gone or unusable.
fallback_outputs() {
    load_json
    load_caps
    jq -c --arg vo "$VIRTUAL_OUTPUT" --argjson caps "$CAPS_JSON" '
        [ .outputs[]
          | select(.connected == true and .name != $vo)
          | { name,
              modeId:   .currentModeId,
              scale:    1,
              rotation: (.rotation // 1),
              priority: (.priority // 1),
              x:        (.pos.x // 0),
              y:        (.pos.y // 0),
              hdr:      ($caps[.name].hdr // "unknown"),
              wcg:      ($caps[.name].wcg // "unknown") } ]
    ' <<<"$KD_JSON"
}

write_state() {
    local outputs_json="$1" steam_launched="$2" virtual_prev="$3"
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    jq -n \
        --argjson outputs "$outputs_json" \
        --argjson steam "$steam_launched" \
        --argjson vprev "$virtual_prev" \
        --arg vo "$VIRTUAL_OUTPUT" \
        --arg ts "$(date -Is)" \
        '{ saved_at: $ts, virtual: $vo, virtual_prev_enabled: $vprev,
           steam_launched: $steam, outputs: $outputs }' >"$STATE_FILE"
    log "state written to $STATE_FILE"
}

read_state() {
    [[ -r "$STATE_FILE" ]] || return 1
    jq -e . "$STATE_FILE" >/dev/null 2>&1 || return 1
    cat "$STATE_FILE"
}

# --------------------------------------------------------------------------- #
# activate
# --------------------------------------------------------------------------- #

cmd_activate() {
    load_json
    output_exists "$VIRTUAL_OUTPUT" || die "virtual output $VIRTUAL_OUTPUT not found"

    log "=== activate ==="
    [[ -n "$CONFIG_LOADED" ]] && log "config loaded from $CONFIG_LOADED"
    log "virtual output: $VIRTUAL_OUTPUT"
    log "env: $(env | grep -E '^SUNSHINE_' | sort | tr '\n' ' ')"

    local req rw rh rfps rhdr
    req="$(client_request)"
    read -r rw rh rfps rhdr <<<"$req"
    log "requested: ${rw}x${rh}@${rfps} hdr=${rhdr}"

    # Re-entrancy guard. If the virtual output is already enabled we are being
    # run a second time (Sunshine retry, double launch, or a deactivate that
    # never completed). Snapshotting now would record the *streaming* layout as
    # "the desktop" and deactivate would then restore a blank screen, so the
    # existing state file is kept untouched.
    local snapshot state_json steam_prev=false virtual_prev=false reuse_state=0
    if output_enabled "$VIRTUAL_OUTPUT"; then
        virtual_prev=true
        if state_json="$(read_state)"; then
            log "GUARD: $VIRTUAL_OUTPUT already enabled and state file exists; keeping saved desktop layout"
            snapshot="$(jq -c '.outputs' <<<"$state_json")"
            steam_prev="$(jq -r '.steam_launched // false' <<<"$state_json")"
            reuse_state=1
        else
            log "GUARD: $VIRTUAL_OUTPUT already enabled but no usable state file; reconstructing from all connected outputs"
            snapshot="$(fallback_outputs)"
        fi
    else
        snapshot="$(snapshot_outputs)"
    fi

    # A state file written before a hardware change could name what is now the
    # virtual output. Enabling and disabling the same output in one transaction
    # is incoherent, so drop it.
    snapshot="$(jq -c --arg vo "$VIRTUAL_OUTPUT" '[ .[] | select(.name != $vo) ]' <<<"$snapshot")"
    log "desktop outputs to disable: $(jq -r 'if length == 0 then "(none)" else [.[].name] | join(", ") end' <<<"$snapshot")"

    # Pick the mode.
    local mode_id mw mh mrate res_exact fps_exact aspect_matched
    IFS=$'\t' read -r mode_id mw mh mrate res_exact fps_exact aspect_matched \
        < <(select_mode "$rw" "$rh" "$rfps")
    [[ -n "$mode_id" ]] || die "no usable mode found on $VIRTUAL_OUTPUT"
    log "selected mode id=$mode_id ${mw}x${mh}@${mrate} (res_exact=$res_exact fps_exact=$fps_exact aspect_matched=$aspect_matched)"
    [[ "$res_exact" == "false" ]] && log "NOTE: resolution compromised, client asked ${rw}x${rh}"
    [[ "$fps_exact" == "false" ]] && log "NOTE: refresh compromised, client asked ${rfps}"

    # Build the atomic command.
    local -a args=(
        "output.${VIRTUAL_OUTPUT}.mode.${mode_id}"
        "output.${VIRTUAL_OUTPUT}.scale.1"
        "output.${VIRTUAL_OUTPUT}.position.0,0"
        "output.${VIRTUAL_OUTPUT}.priority.1"
    )

    # Only touch HDR/WCG on an output that supports them. Passing hdr.enable to
    # an incapable output fails the whole atomic transaction, which would take
    # the resolution change down with it.
    if cap_supported "$VIRTUAL_OUTPUT" hdr; then
        if [[ "$rhdr" == "1" ]]; then
            args+=("output.${VIRTUAL_OUTPUT}.hdr.enable")
            cap_supported "$VIRTUAL_OUTPUT" wcg &&
                args+=("output.${VIRTUAL_OUTPUT}.wcg.enable")
        else
            args+=("output.${VIRTUAL_OUTPUT}.hdr.disable")
            cap_supported "$VIRTUAL_OUTPUT" wcg &&
                args+=("output.${VIRTUAL_OUTPUT}.wcg.disable")
        fi
    elif [[ "$rhdr" == "1" ]]; then
        log "WARNING: client requested HDR but $VIRTUAL_OUTPUT reports it as $(cap_state "$VIRTUAL_OUTPUT" hdr); streaming SDR"
    fi

    args+=("output.${VIRTUAL_OUTPUT}.enable")

    local name
    while read -r name; do
        [[ -n "$name" ]] && args+=("output.${name}.disable")
    done < <(jq -r '.[].name' <<<"$snapshot")

    if ! run_kscreen "${args[@]}"; then
        die "failed to switch to $VIRTUAL_OUTPUT; desktop left untouched"
    fi

    # Steam Big Picture, launched after the switch so it opens on the right output.
    local steam_launched="$steam_prev"
    if should_launch_steam; then
        if [[ "$steam_prev" == "true" && $reuse_state -eq 1 ]]; then
            log "Big Picture already launched by a previous activate; not relaunching"
        elif [[ $DRY_RUN -eq 1 ]]; then
            printf 'DRY RUN: setsid steam steam://open/bigpicture\n'
            steam_launched=true
        else
            log "launching Steam Big Picture (SUNSHINE_APP_NAME=${SUNSHINE_APP_NAME:-})"
            setsid steam steam://open/bigpicture >/dev/null 2>&1 &
            steam_launched=true
        fi
    fi

    # Only record state once the switch actually succeeded.
    if [[ $reuse_state -eq 0 ]]; then
        write_state "$snapshot" "$steam_launched" "$virtual_prev"
    elif [[ "$steam_launched" != "$steam_prev" && $DRY_RUN -eq 0 ]]; then
        local tmp
        tmp="$(jq --argjson s "$steam_launched" '.steam_launched = $s' "$STATE_FILE")" &&
            printf '%s\n' "$tmp" >"$STATE_FILE"
    fi

    log "activate complete"
}

should_launch_steam() {
    local name="${SUNSHINE_APP_NAME:-}"
    [[ -n "$name" ]] || return 1
    [[ "${name,,}" == *"${STEAM_MATCH,,}"* ]]
}

# --------------------------------------------------------------------------- #
# deactivate
# --------------------------------------------------------------------------- #

# Restore must be forgiving. A failure here leaves the user staring at a dark
# desktop, so every recoverable problem falls through to a best-effort restore
# and the command still reports success.
cmd_deactivate() {
    load_json
    log "=== deactivate ==="

    local state_json outputs steam_launched=false used_fallback=0
    if state_json="$(read_state)"; then
        outputs="$(jq -c '.outputs // []' <<<"$state_json")"
        steam_launched="$(jq -r '.steam_launched // false' <<<"$state_json")"
        log "restoring from $STATE_FILE: $(jq -r '[.[].name] | join(", ")' <<<"$outputs")"
    else
        log "no usable state file at $STATE_FILE; falling back to all connected outputs"
        outputs="$(fallback_outputs)"
        used_fallback=1
    fi

    # Close Big Picture before the displays move, so Steam is not repositioning
    # itself onto an output that is about to disappear.
    if [[ "$steam_launched" == "true" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            printf 'DRY RUN: setsid steam steam://close/bigpicture\n'
        else
            log "closing Steam Big Picture"
            setsid steam steam://close/bigpicture >/dev/null 2>&1 || true
            sleep "$BP_CLOSE_WAIT"
        fi
    fi

    # Drop any saved output that is no longer connected. One monitor going away
    # must not stop the others coming back.
    # Also drop the virtual output itself, in case a stale state file names it:
    # restoring it in the same transaction that disables it is incoherent.
    local present
    present="$(jq -c --argjson kd "$KD_JSON" --arg vo "$VIRTUAL_OUTPUT" '
        [ .[] as $o
          | select($o.name != $vo)
          | select(any($kd.outputs[]; .name == $o.name and .connected == true))
          | $o ]' <<<"$outputs")"

    local dropped
    dropped="$(jq -r --argjson p "$present" '[.[].name] - [$p[].name] | join(", ")' <<<"$outputs")"
    [[ -n "$dropped" ]] && log "WARNING: saved outputs no longer connected, skipping: $dropped"

    if [[ "$(jq 'length' <<<"$present")" == "0" ]]; then
        log "WARNING: nothing to restore from state; re-deriving from connected outputs"
        present="$(fallback_outputs)"
        used_fallback=1
    fi

    if [[ "$(jq 'length' <<<"$present")" == "0" ]]; then
        log "ERROR: no connected non-virtual outputs at all; leaving $VIRTUAL_OUTPUT enabled"
        return 0
    fi

    if restore_outputs "$present"; then
        [[ $DRY_RUN -eq 0 ]] && rm -f "$STATE_FILE" && log "state file removed"
        log "deactivate complete"
        return 0
    fi

    # The precise restore failed. Retry with a minimal command: modes and enable
    # only, no scale/position/priority/HDR, which is the most likely thing to
    # have been rejected.
    log "ERROR: full restore failed; retrying minimal restore"
    if restore_outputs "$present" minimal; then
        [[ $DRY_RUN -eq 0 ]] && rm -f "$STATE_FILE"
        log "minimal restore succeeded"
        return 0
    fi

    log "ERROR: minimal restore failed too; leaving state file in place for a manual retry"
    return 0
}

# restore_outputs <outputs_json> [minimal]
restore_outputs() {
    local outputs="$1" mode="${2:-full}"
    local -a args=()
    local name modeId scale rotation priority x y hdr wcg rot_kw

    while IFS=$'\t' read -r name modeId scale rotation priority x y hdr wcg; do
        [[ -n "$name" ]] || continue
        [[ -n "$modeId" && "$modeId" != "null" ]] && args+=("output.${name}.mode.${modeId}")

        if [[ "$mode" == "full" ]]; then
            [[ -n "$scale" && "$scale" != "null" ]] && args+=("output.${name}.scale.${scale}")
            args+=("output.${name}.position.${x},${y}")
            [[ -n "$priority" && "$priority" != "null" ]] && args+=("output.${name}.priority.${priority}")
            rot_kw="$(rotation_keyword "$rotation")"
            [[ -n "$rot_kw" ]] && args+=("output.${name}.rotation.${rot_kw}")
            case "$hdr" in
                enabled) args+=("output.${name}.hdr.enable") ;;
                disabled) args+=("output.${name}.hdr.disable") ;;
            esac
            case "$wcg" in
                enabled) args+=("output.${name}.wcg.enable") ;;
                disabled) args+=("output.${name}.wcg.disable") ;;
            esac
        fi

        args+=("output.${name}.enable")
    done < <(jq -r '.[] | [.name, .modeId, .scale, .rotation, .priority, .x, .y, .hdr, .wcg] | @tsv' <<<"$outputs")

    [[ ${#args[@]} -gt 0 ]] || return 1

    # Same atomicity rule as activate: the desktop outputs must come back in the
    # same transaction that turns the virtual output off.
    args+=("output.${VIRTUAL_OUTPUT}.disable")

    run_kscreen "${args[@]}"
}

# --------------------------------------------------------------------------- #
# status
# --------------------------------------------------------------------------- #

cmd_status() {
    load_json
    load_caps

    if [[ -n "$CONFIG_LOADED" ]]; then
        echo "config file    : $CONFIG_LOADED (loaded)"
    else
        echo "config file    : $CONFIG_FILE (not present; all values from environment)"
    fi
    echo "virtual output : $VIRTUAL_OUTPUT"
    echo "state file     : $STATE_FILE $([[ -r "$STATE_FILE" ]] && echo "(present)" || echo "(absent)")"
    echo "log file       : $LOG_FILE"
    echo "steam match    : SUNSHINE_APP_NAME contains '$STEAM_MATCH' (case-insensitive)"
    echo

    echo "outputs:"
    jq -r --argjson caps "$CAPS_JSON" '
        .outputs[]
        | "  \(.name)  \(if .enabled then "enabled " else "disabled" end)  " +
          "\(if .connected then "connected" else "disconnected" end)  " +
          "mode=\(.currentModeId)  scale=\(.scale)  pos=\(.pos.x),\(.pos.y)  " +
          "prio=\(.priority)  hdr=\($caps[.name].hdr // "?")  wcg=\($caps[.name].wcg // "?")"
    ' <<<"$KD_JSON"
    echo

    if [[ -r "$STATE_FILE" ]]; then
        echo "saved state:"
        jq -r '"  saved_at=\(.saved_at)  steam_launched=\(.steam_launched)",
               (.outputs[] | "  \(.name) mode=\(.modeId) scale=\(.scale) pos=\(.x),\(.y) hdr=\(.hdr) wcg=\(.wcg)")' \
            "$STATE_FILE"
        echo
    fi

    local req rw rh rfps rhdr
    req="$(client_request 2>/dev/null)"
    read -r rw rh rfps rhdr <<<"$req"
    echo "client request : ${rw}x${rh}@${rfps} hdr=${rhdr}"

    local mode_id mw mh mrate res_exact fps_exact aspect_matched
    IFS=$'\t' read -r mode_id mw mh mrate res_exact fps_exact aspect_matched \
        < <(select_mode "$rw" "$rh" "$rfps")
    echo "would select   : id=$mode_id ${mw}x${mh}@${mrate}"
    echo "                 exact resolution=$res_exact  exact fps=$fps_exact  aspect matched=$aspect_matched"
    echo

    echo "modes on $VIRTUAL_OUTPUT:"
    jq -r --arg vo "$VIRTUAL_OUTPUT" '
        .outputs[] | select(.name == $vo) | .modes
        | sort_by(- (.size.width * .size.height), - .refreshRate)
        | .[] | "  id=\(.id)\t\(.size.width)x\(.size.height)@\(.refreshRate * 100 | round / 100)"
    ' <<<"$KD_JSON"
}

# --------------------------------------------------------------------------- #
# entry point
# --------------------------------------------------------------------------- #

usage() {
    cat <<EOF
usage: $(basename "$0") {activate|deactivate|status} [--dry-run]

  activate     Switch to $VIRTUAL_OUTPUT using the Sunshine client's requested
               resolution / fps / HDR, disabling the desktop outputs.
  deactivate   Restore the desktop outputs and disable $VIRTUAL_OUTPUT.
  status       Show current outputs, saved state and the mode that would be picked.

  --dry-run    Print what would be done without changing anything.
EOF
}

main() {
    local action="${1:-}"
    shift || true

    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
    done

    for tool in kscreen-doctor jq; do
        command -v "$tool" >/dev/null || die "required tool not found: $tool"
    done

    case "$action" in
        activate) cmd_activate ;;
        deactivate) cmd_deactivate ;;
        status) cmd_status ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
