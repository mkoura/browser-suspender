#!/usr/bin/env bash
#
# browser-suspender: Periodically check whether firefox is out of focus
# and STOP it in that case after a time delay; if in focus but stopped,
# send SIGCONT.
#
# (c) Petr Baudis <pasky@ucw.cz>  2014
# (c) Martin Kourim <kourim@protonmail.com>  2016
# MIT licence if this is even copyrightable

hash xprop 2>/dev/null || { echo "Please install xprop"; exit 1; }

loop_delay=1.5  # [s]
stop_delay=10   # [s]

declare -A procs
declare -A pstate
declare -A last_in_focus
declare -A wclass

resume() {
  for proc in "${procs[@]}"; do
    if [ -n "$proc" ] && [ "${pstate[$proc]}" = stopped ]; then
      echo "$(date)  Resuming firefox @ $proc"
      kill -CONT "$proc"
    fi
  done
}

cleanup() {
  resume
  exit 0
}
trap cleanup HUP INT TERM

while true; do
  sleep "$loop_delay"

  # Resume all if we are not running on battery
  read battery </sys/class/power_supply/BAT0/status
  if [ "$battery" != Discharging ]; then
    resume
    continue
  fi

  # Get active window id
  window="$(xprop -root _NET_ACTIVE_WINDOW)"
  window="${window#*# }"
  # What kind of window is it?
  [ -z "${wclass[$window]}" ] && wclass[$window]="$(xprop -id "$window" WM_CLASS)"

  if [[ "${wclass[$window]}" =~ Navigator ]]; then
    # Firefox!  We know it is running.  Make sure we
    # have its pid and update the last seen date.
    # If we stopped it, resume again.
    window_proc="${procs[$window]}"
    if [ -n "$window_proc" ] && [ "${pstate[$window_proc]}" = stopped ]; then
      echo "$(date)  Resuming firefox @ $window_proc"
      if kill -CONT "$window_proc"; then
        pstate[$window_proc]=running
      else
        procs[$window]=''
      fi
    fi

    last_in_focus[$window]="$(date +%s)"
    if [ -z "${procs[$window]}" ]; then
      wpid="$(xprop -id "$window" _NET_WM_PID)"
      procs[$window]="${wpid#*= }"
    fi

    continue
  fi

  # Not Firefox!
  # If it's running and it's been long enough, stop it now.
  for key in "${!procs[@]}"; do
    proc="${procs[$key]}"
    if [ -z "$proc" ] || [ "${pstate[$proc]}" = stopped ]; then
      continue
    fi

    if [ $(($(date +%s) - ${last_in_focus[$key]})) -ge "$stop_delay" ]; then
      echo "$(date)  Stopping firefox @ $proc"
      pstate[$proc]=stopped
      if ! kill -STOP "$proc"; then
        pstate[$proc]=running
        procs[$key]=''
      fi
    fi
  done
done
