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
the paired slave is `/dev/ttysNNN` with NNN = that same index in **decimal**
(confirmed empirically — `pty.openpty()` handing out ttys519/520/521 in a
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
format as a plain decimal number appended to `ttys` — that's the slave tty
name for that fd.

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

## Known false positives (can't be fully resolved externally)

1. **Just-opened pty, shell not exec'd yet** — reads as leaked for a brief
   window. Mitigate by only classifying, or by freezing the process
   (`kill -STOP`) before sampling so the window is zero.
2. **Child exited, output still buffered** — master legitimately still
   needed to drain remaining bytes.
3. No supported way to inspect another process's kqueue registrations, so
   "does libuv still know about this fd" can't be checked directly.

## Optional stronger signal: `tcgetpgrp`

From inside the process (attach with `lldb`), calling
`(int)tcgetpgrp(fd)` on a live master with a foreground job returns a
positive pgid; a master with no session returns -1. Useful as a second
opinion, not proof — validate against a known-good pty first
(`python3 -c 'import pty,os,time; m,s=pty.openpty(); print(os.ttyname(s)); time.sleep(300)'`)
since the minor-number and ioctl semantics are OS-version implementation
details, not documented API.

## Policy this tool implements

Classify only, by default. Never close anything automatically. Exclude the
newest N fds per process from any "leaked" recommendation, since a fd
opened microseconds ago is indistinguishable from a real leak by this
method and the downside of guessing wrong (killing an in-flight tool call)
is worse than leaving a few fds unreclaimed.
