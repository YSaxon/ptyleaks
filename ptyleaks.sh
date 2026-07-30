#!/usr/bin/env bash
# Classify /dev/ptmx master fds as live or leaked, optionally close the leaked ones.
# See THEORY.md for the decode/liveness/race theory behind this.
# Usage: ptyleaks.sh [--close] [--quiet|-q] [--confirm-delay N] [pid ...]
#   (default targets: every process holding /dev/ptmx; default --confirm-delay: 2)
set -euo pipefail

CLOSE=0
QUIET=0
CONFIRM_DELAY=2   # seconds between the two leak-confirmation scans, see close_leaked()

usage() {
  cat <<'EOF'
ptyleaks.sh — classify /dev/ptmx master fds as live or leaked, optionally close the leaked ones

Usage: ptyleaks.sh [options] [pid ...]

  (no pid given)       classify every process on the system holding /dev/ptmx
  pid [pid ...]         classify only the given pid(s)

Options:
  --close               actually close fds confirmed LEAKED (see below for how
                         "confirmed" works). Uses a SIGSTOP-bracketed lldb
                         attach; verified against the live fd table afterward,
                         not just lldb's return value. Never touches anything
                         classified "live".
  --confirm-delay N      seconds between the two leak-confirmation scans
                         (default: 2). A pty can look leaked for a few
                         milliseconds right after creation — master opened,
                         slave not yet opened/exec'd by the child. A single
                         scan can't tell that apart from a real leak, because
                         a lone snapshot carries no information about age.
                         Two scans separated by real time can: a candidate
                         only closes if it's still leaked after the delay,
                         which is long enough for any in-flight setup to
                         either attach (now live, excluded) or have long
                         since finished (still leaked, confirmed).
  --quiet, -q            one character per fd instead of a full row
                         (. live, X leaked). Per-pid and summary lines still
                         print.
  --help, -h             show this help and exit

Notes:
  - Processes running from a .app bundle (Electron/Chromium helpers, most
    Mac apps) are flagged: their hardened runtime blocks lldb attach
    regardless of sudo, so --close will report FAILED for them, not silently
    do nothing.
  - See THEORY.md in this directory for the decode/liveness/race theory
    behind how this classifies fds.
EOF
}

# running totals across every pid, printed as one summary at the end
G_FDS=0 G_LIVE=0 G_LEAKED=0 G_CLOSED=0 G_CLOSE_FAILED=0 G_UNATTACHABLE=0 G_EXCLUDED=0

# A slave is live if anything at all has /dev/ttysNNN open (self or child) —
# checking this directly beats trying to match against ps's controlling-tty
# column, which misses ptys a process holds without making them its ctty.
#
# One lsof call per fd (lsof -t /dev/ttysNNN) is what made early versions of
# this slow: each call rescans every process on the system, and with
# hundreds of leaked fds that's hundreds of full-system scans. A single
# system-wide scan, turned into a lookup set, replaces all of them.
declare -A LIVE_SET
build_live_set() {
  LIVE_SET=()
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

# Closes the given fds inside $pid via lldb. Does NOT pre-stop the process
# with an external SIGSTOP first — that was tried and it BREAKS lldb attach:
# reproduced directly, "attach failed: attached to process, but could not
# pause execution" — lldb's own attach mechanism needs to be the one
# suspending the target, and pre-stopping it externally conflicts with that
# badly enough that the target didn't survive the experiment. lldb's attach
# already halts the process for the whole scripted session on its own (that's
# why the `expr` calls run synchronously) — no extra pause is needed or safe.
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
  # it as a bare statement, and any nonzero return there kills the ENTIRE
  # script mid-loop — confirmed for real: hitting one unattachable Electron
  # pid silently aborted every pid after it, with no summary, no error
  # visible past that point. Failures are reported via stderr + globals
  # instead of via exit status.
  local lldb_out="" attach_rc=0
  lldb_out=$(lldb -p "$pid" --batch -s "$cmd_file" 2>&1) || attach_rc=$?
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

# Per-pid candidate lists from the classify pass, keyed by pid: space-separated
# fd numbers that read as leaked in the FIRST scan. Populated by classify_pid,
# consumed by the confirm-and-close pass in main(). CANDIDATE_PIDS tracks
# membership/order separately — under `set -u`, ${#CANDIDATES[@]} and
# ${!CANDIDATES[@]} throw "unbound variable" on an EMPTY associative array
# on this bash (reproduced directly: `bash -c 'set -u; declare -A A; echo
# ${#A[@]}'` fails). A plain indexed array doesn't have that bug.
declare -A CANDIDATES
CANDIDATE_PIDS=()

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

  local -a candidates=()
  local i live_n=0 leaked_n=0
  for i in "${!fds[@]}"; do
    local status="live" char="."
    if ! is_live "${ttys[$i]}"; then
      status="LEAKED"; char="X"
      candidates+=("${fds[$i]}")
      leaked_n=$((leaked_n+1))
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
  echo "  $live_n live, $leaked_n leaked"
  G_LIVE=$((G_LIVE + live_n)); G_LEAKED=$((G_LEAKED + leaked_n))

  if [ ${#candidates[@]} -gt 0 ]; then
    CANDIDATES["$pid"]="${candidates[*]}"
    CANDIDATE_PIDS+=("$pid")
  fi
}

# Confirms each pid's scan-1 candidates are STILL leaked after a real delay,
# then closes only the intersection. A single fresh scan, taken without a
# reference to scan 1, carries no age information at all — a pty opened one
# millisecond before that scan and one opened an hour before it look
# identical to a lone snapshot. It's the persistence across two checkpoints
# separated by real time that tells you anything; requiring agreement with
# scan 1 also costs nothing extra since scan 1 is already computed.
confirm_and_close() {
  local pids=("$@")
  [ ${#pids[@]} -eq 0 ] && return 0

  echo "waiting ${CONFIRM_DELAY}s to confirm leaks are still leaked before closing..."
  sleep "$CONFIRM_DELAY"
  build_live_set

  local pid
  for pid in "${pids[@]}"; do
    local -a candidates=(${CANDIDATES["$pid"]})
    local -a still_leaked=() excluded=()
    local fd ttyname dev
    for fd in "${candidates[@]}"; do
      # re-derive this fd's tty the same way classify_pid did — cheap,
      # scoped to just this pid's known candidates, no new lsof calls beyond
      # the one fresh build_live_set already did above.
      local row; row=$(lsof -n -p "$pid" -a -d "$fd" -Fr 2>/dev/null | sed -n 's/^r0x//p')
      if [ -z "$row" ]; then
        # fd no longer exists at all (process closed it itself, or exited) — nothing to do
        continue
      fi
      dev=$(( 16#$row & 0xffffff ))
      ttyname="ttys${dev}"
      if is_live "$ttyname"; then
        excluded+=("$fd")
      else
        still_leaked+=("$fd")
      fi
    done

    if [ ${#excluded[@]} -gt 0 ]; then
      echo "pid $pid: ${#excluded[@]} fd(s) became live during the confirm delay, excluding: ${excluded[*]}"
      G_EXCLUDED=$((G_EXCLUDED + ${#excluded[@]}))
    fi
    if [ ${#still_leaked[@]} -gt 0 ]; then
      local cmd; cmd=$(detect_name "$pid")
      echo "pid $pid ($cmd): confirmed leaked, closing"
      close_fds "$pid" "${still_leaked[@]}"
    fi
  done
}

main() {
  local targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --close) CLOSE=1 ;;
      --quiet|-q) QUIET=1 ;;
      --confirm-delay) shift; CONFIRM_DELAY="$1" ;;
      # only digits count as a pid — anything else that isn't a known flag
      # is a typo'd option, and silently treating it as a pid used to just
      # neuter the whole run (e.g. -q alone, before this got an alias,
      # would've added the literal string "-q" as a "pid" and matched
      # nothing).
      [0-9]*) targets+=("$1") ;;
      *) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
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

  if [ "$CLOSE" -eq 1 ] && [ ${#CANDIDATE_PIDS[@]} -gt 0 ]; then
    confirm_and_close "${CANDIDATE_PIDS[@]}"
  fi

  echo "=== summary across ${#targets[@]} pid(s) ==="
  echo "  ptmx fds at start:  $G_FDS"
  echo "  live:               $G_LIVE"
  echo "  leaked:             $G_LEAKED"
  if [ "$CLOSE" -eq 1 ]; then
    [ "$G_EXCLUDED" -gt 0 ] && echo "  excluded (became live during confirm delay): $G_EXCLUDED"
    echo "  closed (verified):  $G_CLOSED"
    echo "  close failed:       $G_CLOSE_FAILED"
    echo "  pids likely unattachable (.app bundles): $G_UNATTACHABLE"
    echo "  ptmx fds remaining: $((G_FDS - G_CLOSED))  (computed, not rescanned)"
  fi
}

main "$@"
