#!/usr/bin/env python3
"""
Turn the xArm Studio export (robottheword.txt) into factory_programs.json for the iPad app.

Usage:
    python3 tools/generate_factory_programs.py tools/robottheword.txt RobotArm/factory_programs.json

You only need to run this again if a NEW export comes off the arm. Day-to-day editing of
programs happens in the app (or in the Files app), not here.

What it does, in plain words:
  * The export is one giant "if input pins = N: do these moves" list. We cut it into programs.
  * Every `set_servo_angle(...)` becomes a JOINT step (5 angles, degrees).
  * Every `set_position(...)` becomes a LINE step (x y z mm, roll pitch yaw degrees).
  * Every `set_pause_time(t)` is folded into the step before it as "pauseAfter".
  * `move_gohome()` becomes a HOME step.
  * `move_circle(...)` (one, in program 5) is not supported and becomes a note on the program.
  * The speed / acceleration in force at the time of each move is written onto that step.
"""
import json
import re
import sys

src_path = sys.argv[1] if len(sys.argv) > 1 else "tools/robottheword.txt"
out_path = sys.argv[2] if len(sys.argv) > 2 else "RobotArm/factory_programs.json"
src = open(src_path).read()

# Split on the print("PROGRAM N") markers. Each branch ends where the next
# `if ... get_cgpio_digital` guard begins.
parts = re.split(r'print\("PROGRAM (\d+)"\)', src)
branches = {}
for i in range(1, len(parts), 2):
    num = int(parts[i])
    body = parts[i + 1]
    m = re.search(r'\n\s*if (?:not \()?self\._arm\.get_cgpio_digital', body)
    if m:
        body = body[:m.start()]
    branches[num] = body

# Values the export puts in place before every run (run() lines ~36-37 and ~127-128).
DEFAULT_ANGLE_SPEED = 180.0
DEFAULT_ANGLE_ACC = 800.0
DEFAULT_TCP_SPEED = 100.0
DEFAULT_TCP_ACC = 2000.0

totals = {"joint": 0, "line": 0, "pause": 0, "home": 0, "circle": 0}
joint_seen = []
programs = []

for num in sorted(branches):
    body = branches[num]
    angle_speed, angle_acc = DEFAULT_ANGLE_SPEED, DEFAULT_ANGLE_ACC
    tcp_speed, tcp_acc = DEFAULT_TCP_SPEED, DEFAULT_TCP_ACC
    steps = []
    notes = []

    for line in body.splitlines():
        s = line.strip()

        m = re.match(r'self\._angle_speed = (\d+(?:\.\d+)?)', s)
        if m:
            angle_speed = float(m.group(1)); continue
        m = re.match(r'self\._angle_acc = (\d+(?:\.\d+)?)', s)
        if m:
            angle_acc = float(m.group(1)); continue
        m = re.match(r'self\._tcp_speed = (\d+(?:\.\d+)?)', s)
        if m:
            tcp_speed = float(m.group(1)); continue
        m = re.match(r'self\._tcp_acc = (\d+(?:\.\d+)?)', s)
        if m:
            tcp_acc = float(m.group(1)); continue

        m = re.search(r'set_servo_angle\(angle=\[([^\]]+)\].*?wait=(True|False).*?radius=(-?[\d.]+)', s)
        if m:
            joints = [float(x) for x in m.group(1).split(',')][:5]
            wait = m.group(2) == "True"
            radius = float(m.group(3))
            # The SDK blocks on wait=True, so a blend radius never took effect there.
            if radius < 0 or wait:
                radius = -1.0
            joint_seen.append(joints)
            steps.append({"kind": "joint", "joints": joints, "speed": angle_speed,
                          "acc": angle_acc, "radius": radius, "pauseAfter": 0.0})
            totals["joint"] += 1
            continue

        m = re.search(r'set_position\(\*\[([^\]]+)\].*?radius=(-?[\d.]+)', s)
        if m:
            pose = [float(x) for x in m.group(1).split(',')][:6]
            radius = float(m.group(2))
            if radius < 0 or "wait=True" in s:
                radius = -1.0
            steps.append({"kind": "line", "pose": pose, "speed": tcp_speed,
                          "acc": tcp_acc, "radius": radius, "pauseAfter": 0.0})
            totals["line"] += 1
            continue

        m = re.search(r'set_pause_time\(([\d.]+)\)', s)
        if m:
            t = float(m.group(1))
            totals["pause"] += 1
            if steps:
                steps[-1]["pauseAfter"] += t
            else:
                steps.append({"kind": "pause", "pauseAfter": t})
            continue

        if "move_gohome(" in s:
            steps.append({"kind": "home", "speed": angle_speed, "acc": angle_acc,
                          "radius": -1.0, "pauseAfter": 0.0})
            totals["home"] += 1
            continue

        if "move_circle(" in s:
            totals["circle"] += 1
            notes.append("The factory version had an arc (move_circle) after step %d. "
                         "Arcs are not supported yet, so the arm goes straight to the next step instead."
                         % len(steps))
            continue

    if not steps:
        continue   # programs 39-63 exist in the export but are empty
    programs.append({
        "number": num,
        "name": "Home" if num == 0 else "Program %d" % num,
        "railProgram": num,
        "armDelay": 0.0,
        "note": " ".join(notes),
        "steps": steps,
    })

# Sanity checks against the export as received 2026-09-10.
expected = {"joint": 194, "line": 11, "pause": 32, "home": 1, "circle": 1}
print("totals:", totals)
assert totals == expected, "counts changed — is this a new export? expected %s" % expected
for jn in range(5):
    vals = [j[jn] for j in joint_seen]
    print("J%d range: %.1f .. %.1f" % (jn + 1, min(vals), max(vals)))
for p in programs:
    print("Program %2d: %2d steps%s" % (p["number"], len(p["steps"]), ("  NOTE: " + p["note"]) if p["note"] else ""))

json.dump({"programs": programs}, open(out_path, "w"), indent=1)
print("wrote", out_path, "with", len(programs), "programs")
