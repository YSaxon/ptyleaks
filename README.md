# PTYLEAKS

Agentic AIs[^1] have a tendency to leak ptys[^2] on macOS every time they run a command, leading to pervasive errors[^3]. You can try to raise the ceiling but not by much[^4], and it's tricky to persist it[^5].

This tool identifies and closes those leaks where possible[^6]. Running the script raw will just identify leaks, running with `--close` will close them.

Code written mostly by Claude. I can't guarantee there aren't mistakes but in my own testing it seems fine and safe.

[^1]: **Gemini CLI** and **Claude Code** (and potentially other node-based CLIs or agents, though they haven't been tested).

[^2]: This is a known problem caused by upstream PTY master file descriptor (`/dev/ptmx`) leaks on macOS. Some possibly related issues and PRs:
    - **Upstream Node-PTY Issues & Fixes**:
      - [microsoft/node-pty#882](https://github.com/microsoft/node-pty/pull/882) — *Upstream macOS fix PR: "fix: /dev/ptmx leak on macOS"*
      - [microsoft/node-pty#931](https://github.com/microsoft/node-pty/pull/931) — *Fix: close kqueue fd in SetupExitCallback on macOS*
    - **Gemini CLI Issues & Fixes**:
      - [google-gemini/gemini-cli#20804](https://github.com/google-gemini/gemini-cli/issues/20804) — *PTY file descriptor leak issue*
      - [google-gemini/gemini-cli#26327](https://github.com/google-gemini/gemini-cli/issues/26327) — *macOS: Gemini CLI processes retain hundreds of /dev/ptmx handles, exhausting PTYs*
      - [google-gemini/gemini-cli#27155](https://github.com/google-gemini/gemini-cli/issues/27155) — *PTY memory and file descriptor leak in ShellExecutionService*
      - [google-gemini/gemini-cli#27147](https://github.com/google-gemini/gemini-cli/pull/27147) — *PR: Upgrade pty dependencies to pull upstream fix (closed unmerged)*
      - [google-gemini/gemini-cli#27154](https://github.com/google-gemini/gemini-cli/pull/27154) — *PR: Prevent PTY memory leak by synchronously deleting active entries (closed unmerged)*

[^3]: Pervasive errors you might see when system-wide PTY limits are exhausted:
    - `posix_spawn failed: Resource temporarily unavailable` / `EAGAIN`
    - `forkpty: Device not configured` / `ENXIO` (when opening terminal panes, tabs, or spawning shells)
    - `posix_openpt failed: Device not configured` (in VS Code/Cursor terminal views)
    - `Could not create a new process and open a pseudo-tty.`
    - `unable to allocate pty: Device not configured` (when executing commands like `sudo`)

[^4]: Default on macOS is 511 and the max that macOS will accept is 999: `/usr/sbin/sysctl -w kern.tty.ptmx_max=999`. If your system is already out and everything is failing you can try `osascript -e 'do shell script "/usr/sbin/sysctl -w kern.tty.ptmx_max=999" with administrator privileges'` instead.

[^5]: Modern macOS (Big Sur and later) ignores `/etc/sysctl.conf`. If desperate, you could fake it with a launchdaemon that runs the above command at boot.

[^6]: Does not work on binaries signed with the macOS Hardened Runtime (most shipped apps, e.g. VS Code and other Electron apps) or SIP-protected Apple binaries, because `lldb attach` is blocked even with `sudo`; the script detects this from the code signature and reports it. This is not a problem for CLI-based tools like `claude` or `gemini`, which run as raw node processes and can be attached to successfully. Terminal emulators (Terminal, iTerm2, VS Code, kitty, tmux, ...) are skipped by `--close` unless you pass `--include-terminals`, since their ptys are your real sessions.
