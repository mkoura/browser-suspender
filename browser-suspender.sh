#!/usr/bin/env bash
#
# browser-suspender: Periodically check whether the web browser is out of
# focus and STOP it in that case after a time delay; if in focus but stopped,
# send SIGCONT.
#
# (c) Petr Baudis <pasky@ucw.cz>  2014
# (c) Martin Kourim <kourim@protonmail.com>  2016
# MIT licence if this is even copyrightable

read_timeout=4  # [s]
stop_delay=10   # [s]

# Max number of cached WIN_CLASS entries
max_cached_entries=1000
# Cached WIN_CLASS counter
wincount=0

battery_mode=false
case "$1" in
  # Disregard whether we run on battery or not and suspend / resume browsers
  -b | *battery) battery_mode=true ;;
  -h | *help) echo "Usage: ${0##*/} [-b|-battery]" >&2; exit 0 ;;
esac

hash xprop 2>/dev/null || { echo "Please install xprop" >&2; exit 1; }

# Let xprop run in spy mode and output to named pipe
xprop_pipe="$(mktemp -u /tmp/browser-suspender.XXXXXXX)"
mkfifo "$xprop_pipe" || exit 1
exec 10<>"$xprop_pipe"  # assign pipe to file descriptor
xprop -spy -root _NET_ACTIVE_WINDOW > "$xprop_pipe" &
xprop_pid="$!"

ARR="procs pstate last_in_focus wclass"
for i in $ARR; do declare -A "$i"; done

get_pids() {
  # Parses output of `ps` to determine the process tree. Not very elegant,
  # but the `ps` is run only once and thus the number of wakeups is low.
  pids="$1"
  while read line; do
    if [ -z "$spaces" ]; then
      case "$line" in
        "${1} "*)
          sline="${line#* }"
          sline="${sline% *}"
          # Spaces between "pid" and "process name" for child processes
          # in the output of `ps`
          spaces="$sline    "
        ;;
      esac
    else
      case "$line" in
        *"${spaces}"*)
          read pid _ < <(echo "$line")
          pids="${pids} $pid"
        ;;
        *)
          break
        ;;
      esac
    fi
  done < <(ps -eH -o pid,fname)
  # Print pids of all subproceses
  echo "$pids"
}

resume() {
  for pid in "${!pstate[@]}"; do
    if [ "${pstate[$pid]}" = stopped ]; then
      pids="$(get_pids "$pid")"
      if kill -CONT $pids; then
        echo "$(date)  Resuming browser @ $pids"
        pstate[$pid]=running
      fi
    fi
  done
}

cleanup() {
  resume
  kill "$xprop_pid"
  rm -f "$xprop_pipe"
}
trap cleanup EXIT
trap exit HUP INT TERM

on_battery() {
  for bat_file in /sys/class/power_supply/BAT*/status; do
    read battery < "$bat_file"
    [ "$battery" = Discharging ] && return 0
  done
  return 1
}

while true; do
  # Any changes in root window? Return immediately if so,
  # otherwise wait for "$read_timeout" seconds.
  read -t "$read_timeout" xprop_out <&10

  # Resume all and clear all collected data if we are not running on battery
  if [ "$battery_mode" != true ] && ! on_battery; then
    resume
    if [ "$wincount" -gt 0 ]; then
      for i in $ARR; do unset -v "$i"; declare -A "$i"; done
      wincount=0
    fi
    continue
  fi

  now="$(date +%s)"

  # Get active window id
  [ -n "$xprop_out" ] && window="${xprop_out#*# }"
  [ -z "$window" ] || [ "$window" = '0x0' ] && continue

  if [ -z "${wclass[$window]}" ]; then
    # Clear cache
    [ "$wincount" -gt "$max_cached_entries" ] && { unset -v wclass; declare -A wclass; wincount=0; }
    # What kind of window is it?
    wclass[$window]="$(xprop -id "$window" WM_CLASS)"
    ((wincount++))
  fi

  case "${wclass[$window]}" in
    # It's not safe to suspend Chrome because of chrome-based apps. Browser
    # and apps share the same processes. Leaving Chrome out.
    # 'Navigator' is not enough - it will not match e.g. save file dialog
    *Navigator*|*Firefox*|*Iceweasel*|*PaleMoon*)
      # Browser! We know it is running. Make sure we
      # have its pid and update the last seen date.
      # If we stopped it, resume again.
      pid="${procs[$window]}"

      if [ -z "$pid" ]; then
        wpid="$(xprop -id "$window" _NET_WM_PID)"
        pid="${wpid#*= }"
        procs[$window]="$pid"
        [ -z "${pstate[$pid]}" ] && pstate[$pid]=running
      fi

      if [ -n "$pid" ] && [ "${pstate[$pid]}" = stopped ]; then
        pids="$(get_pids "$pid")"
        if kill -CONT $pids; then
          echo "$(date)  Resuming browser @ $pids"
          pstate[$pid]=running
        fi
      fi

      last_in_focus[$pid]="$now"
    ;;
  esac

  # Stop browsers
  for pid in "${!pstate[@]}"; do
    focus_t="${last_in_focus[$pid]}"

    if [[ -z "$focus_t" || "${pstate[$pid]}" = stopped || "${pstate[$pid]}" = blacklist ]]; then
      continue
    fi

    # Out of focus for long enough?
    (( (now - focus_t) < stop_delay )) && continue

    # Suspend the process
    pids="$(get_pids "$pid")"
    if kill -STOP $pids 2>/dev/null; then
      echo "$(date)  Stopping browser @ $pids"
      pstate[$pid]=stopped
    else
      if [ -e /proc/"$pid" ]; then
        # We don't have permissions to send signal
        pstate[$pid]=blacklist
      else
        # The process no longer exists, clean up
        unset -v pstate["$pid"]
        unset -v last_in_focus["$pid"]
      fi
    fi

  done
done
