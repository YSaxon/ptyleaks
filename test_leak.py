#!/usr/bin/env python3
# Disposable test subject: opens N ptys, immediately leaks their masters
# (closes the slave side only), then idles so ptyleaks.sh has something
# to classify/close against. Usage: test_leak.py [n_leaks] [lifetime_s]
import pty, os, time, sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 3
life = int(sys.argv[2]) if len(sys.argv) > 2 else 60

for _ in range(n):
    m, s = pty.openpty()
    os.close(s)

print("PID", os.getpid(), flush=True)
time.sleep(life)
print("SURVIVED", flush=True)
