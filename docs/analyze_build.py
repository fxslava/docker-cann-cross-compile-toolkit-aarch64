#!/usr/bin/env python3
"""Break down a `--progress=plain` buildx log into per-step wall time."""
import re
import sys
from collections import OrderedDict

log = sys.argv[1]

step_name = {}
step_last = {}
step_order = []

hdr = re.compile(r"^#(\d+)\s+\[([^\]]+)\]\s+(.*)$")
tick = re.compile(r"^#(\d+)\s+(\d+\.\d+)\s")
done = re.compile(r"^#(\d+)\s+(DONE|CACHED)\s*(\d+\.\d+)?s?")

with open(log, errors="replace") as fh:
    for line in fh:
        m = hdr.match(line)
        if m:
            n, tag, rest = m.groups()
            if n not in step_name:
                step_name[n] = (tag, rest[:110])
                step_order.append(n)
            continue
        m = tick.match(line)
        if m:
            n, t = m.groups()
            step_last[n] = max(step_last.get(n, 0.0), float(t))
            continue
        m = done.match(line)
        if m:
            n, kind, t = m.groups()
            if kind == "CACHED":
                step_last.setdefault(n, 0.0)
            elif t:
                step_last[n] = max(step_last.get(n, 0.0), float(t))

rows = []
for n in step_order:
    tag, rest = step_name[n]
    rows.append((step_last.get(n, 0.0), n, tag, rest))

rows.sort(reverse=True)
total = sum(r[0] for r in rows)
print("%8s  %-6s %s" % ("seconds", "step", "instruction"))
print("-" * 100)
for secs, n, tag, rest in rows:
    if secs < 1:
        continue
    print("%8.1f  #%-5s [%s] %s" % (secs, n, tag, rest))
print("-" * 100)
print("%8.1f  TOTAL of non-cached steps (%.1f min)" % (total, total / 60))
