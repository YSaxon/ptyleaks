# pty leak detection — theory

## Problem

`kern.tty.ptmx_max` caps live `/dev/ptmx` master opens system-wide. Node-based
CLIs (claude code, gemini cli) leak masters when a child pty's process exits
but the master fd never gets `close()`d (libuv loses the handle, event
listener never fires). Leaks accumulate across a session until the cap
trips and *any* new pty alloc — including `sudo` itself — fails.

## Mapping master → slave

`/dev/ptmx` is a devfs clone device. Each `open()` allocates a free pty
index; that index is the minor number of the resulting master vnode, and
the paired slave is `/dev/ttysNNN` with NNN = that same index in **decimal**,
**zero-padded to 3 digits** (`ttys004`, not `ttys4`) (confirmed empirically — `pty.openpty()` handing out ttys519/520/521 in a
row, matching the raw device minor exactly. An earlier hex-digit theory
was wrong and got caught by the validation probe below).

lsof exposes two different "device" fields and only one of them is useful:

- `D` = major/minor of the **filesystem** the file lives on. For anything
  under `/dev` that's devfs, so every entry — `/dev/null`, `/dev/ptmx`,
  `/dev/ttys516` — reports the *same* value. Useless here, and the trap is
  that it looks plausible until you check two different devices side by
  side.
- `r` = the raw device number (`st_rdev`) — major/minor of the device
  itself. This is the one that varies per pty and actually encodes the
  index.

Given a PID:

```
lsof -p $PID -Fd -Fr -Fn
```

`-Fd` = fd number, `-Fr` = raw device (hex), `-Fn` = name. Filter to rows
where name is `/dev/ptmx`, take the low bits of the raw device field, and
format as a 3-digit zero-padded decimal appended to `ttys`
(`printf 'ttys%03d'`) — that's the slave tty name for that fd.

The padding matters more than anything else here. An earlier version
appended the bare decimal, so every pty below 100 decoded as e.g. `ttys76`,
never matched lsof's `/dev/ttys076`, and read as leaked. `--close` then
closed live masters in iTerm2 and iTermServer, killing ~60 real terminal
sessions (and the script itself, mid-close, when it severed its own tty).
Earlier testing never caught it because test ptys happened to land on
3-digit numbers (ttys519/520/521 above). The two-scan confirm can't catch
this kind of bug either — both scans make the same decode mistake.

## Live vs leaked

First instinct is to check `ps -eo tty=` for a process whose *controlling*
terminal is the decoded slave. That's wrong: a process can hold a pty's
slave fd open (e.g. `pty.openpty()` opens both ends in the same process)
without ever making it the controlling terminal via `TIOCSCTTY`/`setsid`,
so this test reports live ptys as leaked. Verified by creating a real pty
pair and confirming `ps` didn't mention it while the fd was demonstrably
still open.

The direct question is simpler and doesn't need `ps` at all: does anything
have the slave device open, at all?

```
lsof -t /dev/ttysNNN
```

Empty output → no process (self or child) has the slave fd → the master is
leaked. Any output → live, regardless of controlling-terminal status.

One catch: without sudo, lsof silently omits other users' processes. Every
Terminal/iTerm session starts under a root-owned `/usr/bin/login`, and a
shell after `sudo -s` is root too, so a pty held *only* by root processes
reads as leaked. `ps -ax -o tty=` does see every process's controlling tty,
regardless of owner — so it's the wrong *sole* test (above) but the right
supplement: the script counts a tty as live if either lsof or ps sees it.

## Known false positives (can't be fully resolved externally)

1. **Just-opened pty, shell not exec'd yet** — reads as leaked for a
   millisecond-scale window right after `openpty()`, before the child has
   attached to the slave. See "confirm-before-close" below for how this is
   handled — a `kill -STOP` bracket was tried first and rejected; it broke
   the close mechanism itself (see below).
2. **Child exited, output still buffered** — master legitimately still
   needed to drain remaining bytes.
3. No supported way to inspect another process's kqueue registrations, so
   "does libuv still know about this fd" can't be checked directly.

Once a master's slave has been opened and then fully closed (child ran and
exited), it does **not** spontaneously become live again in normal
operation — nothing reopens that specific `/dev/ttysNNN` path afterward.
So the false-positive window is bounded to milliseconds around creation,
not an ongoing risk for anything that's been sitting leaked for more than
a second or two.

## Why a single fresh rescan isn't enough, and confirm-before-close is

A lone snapshot — even one taken right before closing, with no reference to
an earlier checkpoint — carries zero information about a fd's age. A pty
opened one millisecond before that scan and one opened an hour before it
look identical to it. Age only becomes evidence when you have two
checkpoints, separated by real elapsed time, and confirm the state
persisted between them.

So `--close` runs two scans: the initial classify scan, then — after a real
delay (`--confirm-delay`, default 2s) — a second scan restricted to exactly
the candidates the first scan called leaked. Only the intersection (leaked
in both) gets closed. If something flipped to live in the interim, that's
exactly the in-flight-setup case the delay exists to catch, and it's
excluded. This replaced an earlier `--keep-newest N` design (hold back the
newest N fds by fd-number position) that was a strictly worse proxy: fd
numbers get reused as old fds close, so "highest number" and "most
recently opened" can diverge, and a fixed count is wrong in both
directions — too loose for a slow leaker, too tight for a process that
opens a burst all at once.

## `kill -STOP` before `lldb attach` breaks attach — do not do this

An earlier version bracketed the `lldb attach` with an external
`kill -STOP` / `kill -CONT`, on the theory that freezing the process first
would close the fd-number-reuse race (see below) down to zero. This was
wrong and dangerous: reproduced directly, `kill -STOP` before attach made
`lldb` either hang for **exactly 30 seconds** before failing with
`"attach failed: attached to process, but could not pause execution"`, or
occasionally appear to attach fine — but in both cases the target process
did not survive. `lldb`'s own `process attach` already suspends the target
for the whole scripted session (that's why `expr` calls run synchronously
against it) — pre-stopping it externally conflicts with lldb's own
suspend/resume bookkeeping badly enough to kill the target. The fix: never
send an external `STOP`/`CONT` around an lldb attach. Let lldb do its own
pausing.

This also explains an earlier, unexplained "why does this take 30 seconds
when the scan itself is under 1 second" mystery from testing — it was
always this bug, not scan speed.

## Optional stronger signal: `tcgetpgrp`

From inside the process (attach with `lldb`), calling
`(int)tcgetpgrp(fd)` on a live master with a foreground job returns a
positive pgid; a master with no session returns -1. Useful as a second
opinion, not proof — validate against a known-good pty first
(`python3 -c 'import pty,os,time; m,s=pty.openpty(); print(os.ttyname(s)); time.sleep(300)'`)
since the minor-number and ioctl semantics are OS-version implementation
details, not documented API. Not currently used by the tool.

## `set -e` traps when scripting subprocess control

Two real bugs, both the same shape, found by running against live
processes rather than synthetic tests:

- A bare `var=$(cmd)` or bare `cmd` whose exit status is nonzero kills the
  whole script under `set -e` — even mid-loop, even if the caller meant to
  handle the failure. `close_fds` returning 1 on an attach failure, called
  as `if ...; then close_fds ...; fi`, silently aborted every pid after the
  first unattachable one, with no visible error. Fix: functions invoked as
  bare statements inside a `set -e` script must never return nonzero;
  report failure via stderr + counters instead of exit status.
- `${#ASSOC_ARRAY[@]}` and `${!ASSOC_ARRAY[@]}` throw "unbound variable"
  under `set -u` when `ASSOC_ARRAY` is a **declared-but-empty** associative
  array, at least on bash 5.3 on this machine (reproduced directly:
  `bash -c 'set -u; declare -A A; echo ${#A[@]}'` fails). Indexed arrays
  (`declare -a`) don't have this bug. Fix: track membership/emptiness with
  a plain indexed array alongside the associative one, never test the
  associative array's own size directly.

## Policy this tool implements

Classify by default, never closing anything. `--close` requires the
two-scan confirmation above (see "confirm-before-close") before touching
anything, and even then never touches anything classified live at either
scan.
