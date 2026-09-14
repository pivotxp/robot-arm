# Robot Arm (iPad app)

One small iPad app that runs and edits the camera-arm programs. No coding needed to use it.

The rig has two machines:

- **The arm** (UFACTORY xArm 5, five joints). It lives at network address 192.168.1.231.
- **The rail** (Glamatic slider, run by a Siemens control box). It lives at 192.168.1.2.
  The rail's movements are stored inside its own control box as numbered programs. The app
  starts them by number; it does not edit the rail's path.

Each **program** in the app is: a rail program number to start, what starts the arm, and a list
of **steps** for the arm. A program lives at a **code** — one number the rail's control box
understands, 0 to 63. The 39 factory programs (codes 0 to 38) are the ones that were on the arm
when this app was made. The rail has moves stored at codes 1–15 and 17–38 (found by running every
number on the real rail); code 0 is its home; every other code is empty on the rail, so a program
you add there moves the arm only. **New program** (the + button) puts a program at any free code.

## One-time iPad setup

1. Plug a USB-C Ethernet adapter into the iPad and a cable from it to the arm's network switch.
2. On the iPad: **Settings → Ethernet → tap the adapter → Configure IP → Manual**.
   IP Address `192.168.1.50`, Subnet Mask `255.255.255.0`, Router: leave blank. Save.
3. Turn **Wi-Fi off** while at the rig (a Wi-Fi network that also uses 192.168.1.x would confuse it).
4. Open Robot Arm. The first time, iOS asks "Robot Arm would like to find and connect to devices
   on your local network". Tap **Allow**. (If you missed it: Settings → Privacy & Security →
   Local Network → turn on Robot Arm.)
5. **Important:** in xArm Studio (the arm's own web page at http://192.168.1.231:18333) make sure
   the old "robottheword" program is **not** running, and is not set to start by itself when the
   arm powers on. If it is running, the arm gets told what to do by two things at once and does
   every program **twice** (once from the old program, once from this app).

That's it. The app connects to the arm and the rail on its own whenever the cable is in.

## Using it

The top strip is always there:

- **Arm** light: green = connected. Under it: ready / moving / stopped / fault number.
- **Rail** light: green = logged in. Under it: where the carriage is.
- The text next to STOP says what is happening ("Running Program 14…", "Done", or why it didn't run).
- **STOP** stops the arm and the rail. Always works. After STOP, just press Run again.

**Programs screen**: press **Run** on a program. Tap the row to edit it.

**Program screen**:
- *Rail program to start*: which of the rail's stored moves to fire. Blank = don't touch the rail.
- *Arm starts*: **When the rail signals** (the default) — the rail's control box raises the
  program number on six wires into the arm's inputs CI1–CI6, and the arm goes the moment it sees
  its number, exactly as the original arm program did. The app watches the wires from before the
  trigger and waits up to 15 s; if no signal comes, the arm starts anyway and the status line
  says "no signal on the wires". **On a timer** — the arm starts straight after the trigger; only
  for when the wires are not connected.
- *Extra seconds*: normally 0. Added after the signal (or the trigger).
- *The wires → Test the wires* (bottom of the Programs screen): fires a rail program with the arm standing still and reports whether the
  control box signalled that number and how long after the trigger. Do this once on a new rig.
- *Steps, in order*: the arm does these one after another. Tap a step to change it, swipe left to
  delete, **Edit** to drag them into a new order, **Add a step** to add one.
- *Reset this program to factory*: puts back the original version of this one program.

**Step screen — the easy way to set a joint move:**
1. At the top is a live **Side view** picture of the arm and a Pan dial. It moves as the arm moves.
2. Under **Drive the arm**, press **Turn the arm on to drive it** (only needed once per session).
3. Use the big − / + buttons next to Pan, Lift, Bend, Tilt, Roll to move the real arm. Pick how
   far each tap moves at the top (1°, 5°, or 15°). Watch the arm and the picture.
4. When the arm is where you want it, press **Save this position into the step**.
5. **Move the arm to the saved position** replays it so you can double-check.

That's it — no typing. If you ever want exact numbers, open **Type exact numbers**.

Reference for what each control does:
- **Joint move**: the five joints, in degrees. Pan (turn), Lift (shoulder), Bend (elbow),
  Tilt (wrist up/down), Roll (wrist twist).
- **Straight line**: move the camera in a straight line to X / Y / Z in millimetres.
- **Pause**: just wait.
- **Go home**: the arm's built-in home position (all joints at 0).
- *Speed*: degrees per second for joint moves (the factory programs go up to 180),
  millimetres per second for straight lines.
- *Acceleration*: how quickly it gets up to speed. Bigger = snappier.
- *Blend radius*: 0 = stop exactly at this point. Bigger (e.g. 60) = round the corner without
  stopping, for smoother, faster moves.
- *Wait this many seconds before the next step*: a pause after this step.
- **Move the arm here now**: tries just this one step on the arm, so you can see it.
- **Use where the arm is right now**: copies the arm's current position into this step.

Orange text is a warning (a number outside what the factory programs ever used). It does not stop
you; the arm itself refuses anything it truly cannot do.

## Safety

- Keep the physical E-stop within reach. STOP in the app is a software stop.
- Try an edited program at a low speed (e.g. 30) before running it at full speed.
- Only one thing runs at a time. Run is greyed out while something is running.

## Where the programs live

Each program is a small text file, `program_14.json` etc., in the app's folder. You can see them in
the **Files** app → On My iPad → Robot Arm. They can be edited as text too, if you ever need to,
or copied to another iPad.

## For whoever builds it (Mac with Xcode)

- `./install.sh` builds the app and puts it on the iPad plugged into the Mac.
- `tools/generate_factory_programs.py` turns a new xArm Studio export into
  `RobotArm/factory_programs.json` (only needed if the arm is re-programmed in xArm Studio).
- Code: `RobotArm/` — nine Swift files. `ArmLink` talks to the arm, `RailLink` to the rail,
  `Runner` runs a program, `ProgramStore` saves files, and three screens.
