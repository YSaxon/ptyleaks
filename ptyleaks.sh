#!/usr/bin/env bash
# Classify /dev/ptmx master fds as live or leaked, optionally close the leaked ones.
# See THEORY.md for the decode/liveness/race theory behind this.
# Usage: ptyleaks.sh [--close] [pid ...]   (default targets: every process holding /dev/ptmx)
set -euo pipefail

KEEP_NEWEST=10   # newest N fds per pid always held back, never closed — see THEORY.md false positives
CLOSE=0

# A slave is live if anything at all has /dev/ttysNNN open (self or child) —
# checking this directly beats trying to match against ps's controlling-tty
# column, which misses ptys a process holds without making them its ctty.
declare -A LIVE_CACHE
is_live() {
  local tty="$1"
  if [ -z "${LIVE_CACHE[$tty]+x}" ]; then
    if [ -n "$(lsof -t "/dev/$tty" 2>/dev/null)" ]; then
      LIVE_CACHE[$tty]=1
    else
      LIVE_CACHE[$tty]=0
    fi
  fi
  [ "${LIVE_CACHE[$tty]}" = "1" ]
}

# `comm` just says "node" for CLI wrappers; the actual tool name lives in the
# full command line's args, e.g. ".../bin/gemini" or ".../native-binary/claude".
detect_name() {
  local pid="$1" full comm tool
  comm=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
  full=$(ps -p "$pid" -o command= 2>/dev/null || true)
  for tok in $full; do
    case "${tok##*/}" in
      gemini|claude|claude-code) tool="${tok##*/}"; break ;;
    esac
  done
  if [ -n "${tool:-}" ] && [ "$tool" != "$comm" ]; then
    echo "$comm -> $tool"
  else
    echo "$comm"
  fi
}

pids_with_ptmx() {
  lsof -n /dev/ptmx 2>/dev/null | awk 'NR>1{print $2}' | sort -u
}

# Closes the given fds inside $pid via lldb, bracketed by SIGSTOP/SIGCONT so
# the process is frozen for the whole snapshot-to-close window (kills the
# fd-number-reuse race: confirmed reproducible in under 2s without this).
close_fds() {
  local pid="$1"; shift
  local fds=("$@")
  [ ${#fds[@]} -eq 0 ] && return 0

  local cmd_file; cmd_file=$(mktemp)
  local fd
  for fd in "${fds[@]}"; do
    echo "expr (int)close($fd)" >> "$cmd_file"
  done
  echo "process detach" >> "$cmd_file"
  echo "quit" >> "$cmd_file"

  kill -STOP "$pid"
  lldb -p "$pid" --batch -s "$cmd_file" >/dev/null 2>&1
  local rc=$?
  kill -CONT "$pid"
  rm -f "$cmd_file"

  if [ "$rc" -ne 0 ]; then
    echo "  close FAILED (lldb attach failed — needs sudo? try: sudo $0 ...)" >&2
    return 1
  fi
  echo "  closed ${#fds[@]} fd(s): ${fds[*]}"
}

classify_pid() {
  local pid="$1"
  local rows fd dev ttyname n=0
  rows=$(lsof -p "$pid" -Fd -Fr -Fn 2>/dev/null || true)
  [ -z "$rows" ] && return 0

  local -a fds=() ttys=()
  while IFS= read -r line; do
    case "$line" in
      f*) fd="${line#f}" ;;
      r*) dev=$(( 16#${line#r0x} & 0xffffff )) ;;
      n/dev/ptmx)
        ttyname="ttys${dev}"
        fds+=("$fd"); ttys+=("$ttyname")
        ;;
    esac
  done <<<"$rows"

  local count=${#fds[@]}
  [ "$count" -eq 0 ] && return 0

  local cmd; cmd=$(detect_name "$pid")
  echo "pid $pid ($cmd) — $count /dev/ptmx fds"

  local -a to_close=()
  local i cutoff=$(( count - KEEP_NEWEST ))
  for i in "${!fds[@]}"; do
    local status="live"
    if ! is_live "${ttys[$i]}"; then
      status="LEAKED"
      if [ "$i" -lt "$cutoff" ]; then
        to_close+=("${fds[$i]}")
      else
        status="LEAKED (newest $KEEP_NEWEST, held back)"
      fi
    fi
    printf '  fd %-4s %-9s %s\n' "${fds[$i]}" "${ttys[$i]}" "$status"
  done

  if [ "$CLOSE" -eq 1 ] && [ ${#to_close[@]} -gt 0 ]; then
    close_fds "$pid" "${to_close[@]}"
  fi
}

main() {
  local targets=()
  for a in "$@"; do
    case "$a" in
      --close) CLOSE=1 ;;
      *) targets+=("$a") ;;
    esac
  done
  [ ${#targets[@]} -eq 0 ] && mapfile -t targets < <(pids_with_ptmx)

  if [ ${#targets[@]} -eq 0 ]; then
    echo "no process holds /dev/ptmx"
    exit 0
  fi

  for pid in "${targets[@]}"; do
    classify_pid "$pid"
  done
}

main "$@"
