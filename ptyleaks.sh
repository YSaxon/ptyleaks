#!/usr/bin/env bash
# Classify /dev/ptmx master fds as live or leaked, optionally close the leaked ones.
# See THEORY.md for the decode/liveness/race theory behind this.
# Usage: ptyleaks.sh [--close] [--quiet] [--keep-newest N] [pid ...]
#   (default targets: every process holding /dev/ptmx; default --keep-newest: 10)
set -euo pipefail

KEEP_NEWEST=10   # newest N fds per pid always held back, never closed — see THEORY.md false positives
CLOSE=0
QUIET=0

# running totals across every pid, printed as one summary at the end
G_FDS=0 G_LIVE=0 G_LEAKED=0 G_HELD=0 G_ELIGIBLE=0 G_CLOSED=0 G_CLOSE_FAILED=0 G_UNATTACHABLE=0

# A slave is live if anything at all has /dev/ttysNNN open (self or child) —
# checking this directly beats trying to match against ps's controlling-tty
# column, which misses ptys a process holds without making them its ctty.
#
# One lsof call per fd (lsof -t /dev/ttysNNN) is what made early versions of
# this slow: each call rescans every process on the system, and with
# hundreds of leaked fds that's hundreds of full-system scans. A single
# system-wide scan up front, turned into a lookup set, replaces all of them.
declare -A LIVE_SET
build_live_set() {
  local line
  # -n is the actual fix for the slowness: without it, lsof does a reverse
  # DNS lookup for every open network socket on the system before it can
  # print anything. Measured 11.6s -> 0.5s, identical results otherwise.
  while IFS= read -r line; do
    LIVE_SET["${line#/dev/}"]=1
  done < <(lsof -n -Fn 2>/dev/null | awk '/^n\/dev\/ttys/{print substr($0,2)}' | sort -u)
}
is_live() {
  [ -n "${LIVE_SET[$1]+x}" ]
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

# Heuristic, not a guarantee: any process running from inside a .app bundle
# (Electron/Chromium helpers, standard Mac apps) is almost always built with
# the hardened runtime, which blocks same-user lldb attach outright — no
# amount of sudo fixes that. Confirmed directly against a VS Code helper
# ("Not allowed to attach to process"). Plain CLI binaries (gemini, node,
# claude.exe under homebrew/node_modules) are not affected.
looks_unattachable() {
  local pid="$1" full
  full=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$full" in
    *.app/Contents/MacOS/*) return 0 ;;
    *) return 1 ;;
  esac
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

  [ "$QUIET" -eq 0 ] && echo "  closing ${#fds[@]} fd(s): ${fds[*]} ..."

  # This function must NEVER return nonzero. Under `set -e`, callers invoke
  # it as a bare statement (`if ...; then close_fds ...; fi`), and any
  # nonzero return there kills the ENTIRE script mid-loop — confirmed for
  # real: hitting one unattachable Electron pid silently aborted every pid
  # after it, with no summary, no error visible past that point. Failures
  # are reported via stderr + G_CLOSE_FAILED instead of via exit status.
  #
  # Same reasoning applies to every command in the STOP/CONT window: kill
  # -STOP failing (process already gone) or lldb failing must not be bare
  # commands either, or the same abort happens one level down.
  local stop_rc=0
  kill -STOP "$pid" 2>/dev/null || stop_rc=$?
  if [ "$stop_rc" -ne 0 ]; then
    echo "  close FAILED for all ${#fds[@]} fd(s): process vanished before STOP (already exited?)" >&2
    G_CLOSE_FAILED=$((G_CLOSE_FAILED + ${#fds[@]}))
    rm -f "$cmd_file"
    return 0
  fi

  local lldb_out="" attach_rc=0
  lldb_out=$(lldb -p "$pid" --batch -s "$cmd_file" 2>&1) || attach_rc=$?
  kill -CONT "$pid" 2>/dev/null || true
  rm -f "$cmd_file"

  if [ "$attach_rc" -ne 0 ] || printf '%s' "$lldb_out" | grep -q "attach failed"; then
    echo "  close FAILED for all ${#fds[@]} fd(s): lldb could not attach." >&2
    echo "  likely cause: hardened-runtime / sandboxed process (common for" >&2
    echo "  Electron/Chromium .app helpers) — same-user attach is blocked" >&2
    echo "  regardless of sudo. This pid cannot be force-closed this way." >&2
    G_CLOSE_FAILED=$((G_CLOSE_FAILED + ${#fds[@]}))
    return 0
  fi

  # each "expr (int)close(N)" line produces "(int) $K = <result>" in order;
  # 0 = success, -1 = EBADF (already closed / never was a valid fd)
  local -a results=()
  while IFS= read -r r; do results+=("$r"); done < <(
    printf '%s' "$lldb_out" | grep -oE '\(int\) \$[0-9]+ = -?[0-9]+' | grep -oE -- '-?[0-9]+$'
  )

  # lldb reporting close()==0 isn't proof the fd is actually gone — verify
  # against the live fd table instead of trusting the return value alone.
  local still_open; still_open=$(lsof -n -p "$pid" -Fd 2>/dev/null | sed -n 's/^f//p')

  local i ok=0 fail=0
  for i in "${!fds[@]}"; do
    local fd="${fds[$i]}" verified="not verified"
    if grep -qx "$fd" <<<"$still_open"; then
      verified="STILL OPEN"
    else
      verified="confirmed closed"
    fi
    if [ "${results[$i]:-1}" = "0" ] && [ "$verified" = "confirmed closed" ]; then
      [ "$QUIET" -eq 0 ] && echo "    fd $fd: closed ($verified)"
      ok=$((ok+1))
    else
      echo "    fd $fd: FAILED (close() returned ${results[$i]:-?}, $verified)" >&2
      fail=$((fail+1))
    fi
  done
  echo "  close result: $ok closed, $fail failed (verified against live fd table)"
  G_CLOSED=$((G_CLOSED + ok))
  G_CLOSE_FAILED=$((G_CLOSE_FAILED + fail))
}

classify_pid() {
  local pid="$1"
  local rows fd dev ttyname n=0
  rows=$(lsof -n -p "$pid" -Fd -Fr -Fn 2>/dev/null || true)
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
  G_FDS=$((G_FDS + count))
  if looks_unattachable "$pid"; then
    echo "  note: runs from a .app bundle — hardened runtime likely blocks lldb attach, --close will probably FAIL here"
    G_UNATTACHABLE=$((G_UNATTACHABLE + 1))
  fi

  local -a to_close=()
  local i cutoff=$(( count - KEEP_NEWEST )) live_n=0 leaked_n=0 held_n=0
  for i in "${!fds[@]}"; do
    local status="live" char="."
    if ! is_live "${ttys[$i]}"; then
      if [ "$i" -lt "$cutoff" ]; then
        status="LEAKED"; char="X"
        to_close+=("${fds[$i]}")
        leaked_n=$((leaked_n+1))
      else
        status="LEAKED (newest $KEEP_NEWEST, held back)"; char="H"
        held_n=$((held_n+1))
      fi
    else
      live_n=$((live_n+1))
    fi
    if [ "$QUIET" -eq 1 ]; then
      printf '%s' "$char"
    else
      printf '  fd %-4s %-9s %s\n' "${fds[$i]}" "${ttys[$i]}" "$status"
    fi
  done
  [ "$QUIET" -eq 1 ] && printf '\n'
  # held-back fds ARE leaked, just excluded from closing — nest them under
  # the leaked total instead of listing as a separate sibling count, since
  # "4 live, 4 leaked, 6 held back" reads as three disjoint buckets when
  # held-back is really a subset of leaked.
  echo "  $live_n live, $((leaked_n + held_n)) leaked total ($leaked_n eligible to close, $held_n held back as newest)"
  G_LIVE=$((G_LIVE + live_n)); G_LEAKED=$((G_LEAKED + leaked_n)); G_HELD=$((G_HELD + held_n))
  G_ELIGIBLE=$((G_ELIGIBLE + leaked_n))

  if [ "$CLOSE" -eq 1 ] && [ ${#to_close[@]} -gt 0 ]; then
    close_fds "$pid" "${to_close[@]}"
  fi
}

main() {
  local targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --close) CLOSE=1 ;;
      --quiet) QUIET=1 ;;
      --keep-newest) shift; KEEP_NEWEST="$1" ;;
      *) targets+=("$1") ;;
    esac
    shift
  done
  [ ${#targets[@]} -eq 0 ] && mapfile -t targets < <(pids_with_ptmx)

  if [ ${#targets[@]} -eq 0 ]; then
    echo "no process holds /dev/ptmx"
    exit 0
  fi

  # this one call replaced hundreds of per-fd lsof calls (see build_live_set
  # comment) — it's now the only slow part, so say so instead of going quiet
  [ "$QUIET" -eq 0 ] && echo "scanning system for live ptys (one-time)..."
  local scan_start scan_end
  scan_start=$SECONDS
  build_live_set
  scan_end=$SECONDS
  [ "$QUIET" -eq 0 ] && echo "scan done in $((scan_end - scan_start))s"

  for pid in "${targets[@]}"; do
    classify_pid "$pid"
  done

  echo "=== summary across ${#targets[@]} pid(s) ==="
  echo "  ptmx fds at start:  $G_FDS"
  echo "  live:               $G_LIVE"
  echo "  leaked:             $((G_LEAKED + G_HELD))  ($G_ELIGIBLE eligible, $G_HELD held back as newest)"
  if [ "$CLOSE" -eq 1 ]; then
    echo "  closed (verified):  $G_CLOSED"
    echo "  close failed:       $G_CLOSE_FAILED"
    echo "  pids likely unattachable (.app bundles): $G_UNATTACHABLE"
    echo "  ptmx fds remaining: $((G_FDS - G_CLOSED))  (computed, not rescanned)"
  fi
}

main "$@"
