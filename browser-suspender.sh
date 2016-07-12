#!/usr/bin/env bash
#
# browser-suspender: Periodically check whether firefox is out of focus
# and STOP it in that case after a time delay; if in focus but stopped,
# send SIGCONT.
#
# (c) Petr Baudis <pasky@ucw.cz>  2014
# (c) Martin Kourim <kourim@protonmail.com>  2016
# MIT licence if this is even copyrightable

read_timeout=4  # [s]
stop_delay=10   # [s]

battery_mode=false
case "$1" in
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

resume() {
  for proc in "${procs[@]}"; do
    if [ -n "$proc" ] && [ "${pstate[$proc]}" = stopped ]; then
      echo "$(date)  Resuming firefox @ $proc"
      if kill -CONT "$proc"; then
        pstate[$proc]=running
      else
        unset -v procs["$window"]
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
    [ "${#wclass[@]}" -gt 0 ] && for i in $ARR; do unset -v "$i"; declare -A "$i"; done
    continue
  fi

  # Get active window id
  [ -n "$xprop_out" ] && window="${xprop_out#*# }"
  [ -z "$window" -o "$window" = '0x0' ] && continue

  # What kind of window is it?
  [ -z "${wclass[$window]}" ] && wclass[$window]="$(xprop -id "$window" WM_CLASS)"

  if [[ "${wclass[$window]}" =~ Navigator ]]; then
    # Firefox! We know it is running. Make sure we
    # have its pid and update the last seen date.
    # If we stopped it, resume again.
    window_proc="${procs[$window]}"
    if [ -n "$window_proc" ] && [ "${pstate[$window_proc]}" = stopped ]; then
      echo "$(date)  Resuming firefox @ $window_proc"
      if kill -CONT "$window_proc"; then
        pstate[$window_proc]=running
      else
        unset -v procs["$window"]
      fi
    fi

    last_in_focus[$window]="$(date +%s)"
    if [ -z "${procs[$window]}" ]; then
      wpid="$(xprop -id "$window" _NET_WM_PID)"
      procs[$window]="${wpid#*= }"
    fi

    continue
  fi

  # Not Firefox! If it's running and it's been long enough, stop it now.
  now="$(date +%s)"
  for key in "${!procs[@]}"; do
    proc="${procs[$key]}"
    if [ -z "$proc" ] || [ "${pstate[$proc]}" = stopped ]; then
      continue
    fi

    if [ $((now - ${last_in_focus[$key]})) -ge "$stop_delay" ]; then
      echo "$(date)  Stopping firefox @ $proc"
      pstate[$proc]=stopped
      if ! kill -STOP "$proc"; then
        pstate[$proc]=running
        unset -v procs["$key"]
      fi
    fi
  done
done
