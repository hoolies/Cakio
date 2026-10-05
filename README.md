# Cakio: the camera kiosk

Cakio turns an HP t640 thin client into a screen that shows security cameras
and nothing else. You plug it in, it shows the cameras. Pull the power, it
comes back on its own. Nobody can do anything with the keyboard. You manage
it from your computer over SSH.

This guide explains how it works, how to set it up, and what to do when
something looks wrong. You do not need to know Linux to use it, but you will
type a few commands in a terminal on your Ubuntu computer.

---

## The one-minute version

1. **Once:** create your keys (`init-ca`) and build the installer stick.
2. **Per kiosk:** boot the t640 from the stick, answer four questions, pull
   the stick.
3. **Per kiosk, from your desk:** `enroll` it. From then on you can change
   its cameras, check on it, and take screenshots over SSH.

```
./kiosk-admin.sh init-ca                 # once
./kiosk-build.sh                         # once per software release
./kiosk-build.sh write                   # make the stick (plug it in when asked)

   ... boot the thin client from the stick, answer the questions ...

./kiosk-admin.sh login                   # once per working day
./kiosk-admin.sh enroll 10.20.30.40      # once per kiosk
./kiosk-admin.sh status 10.20.30.40      # any time
```

---

## How it works, in plain language

**The kiosk runs from memory.** The thin client's internal disk only holds
three things: the files needed to start, the software packages, and a small
saved-settings file. At every power-on the system is rebuilt in memory from
those files. Nothing is ever written to the disk while it runs, so a power
cut cannot corrupt it. Each boot is identical to the last.

**Each camera is its own window.** The screen is split into tiles following
a layout you write. Every tile is an independent video player. If one camera
goes down, only its tile says "No signal since 14:32"; the others keep
playing. When the camera comes back, the tile does too.

**It watches the network cable.** If the cable is unplugged, the whole
screen says "Connect the ethernet cable to view the cameras". Plug it back in
and the cameras return by themselves.

**There is no way in from the keyboard.** The kiosk logs itself into a user
whose only job is showing cameras. The keyboard and mouse are ignored, there
is no other console, and the usual Ctrl-Alt-Del or Ctrl-Alt-F2 tricks do
nothing. The only way in is SSH, and only with your certificate.

**SSH uses certificates, not passwords.** Think of it as two ID-card
printers that live in the `ca` folder on your computer:

- The *user CA* prints you a day pass. `kiosk-admin.sh login` signs your
  SSH key for 12 hours (and does nothing if a pass is already valid). Every
  kiosk trusts passes from this printer, so there is no password to
  remember or to leak. A lost laptop stops working by itself when the pass
  expires.
- The *host CA* prints each kiosk an ID card when you enroll it. Your
  computer trusts cards from this printer, so you never get a "are you sure
  you want to connect?" question again, and nobody can impersonate a kiosk.

**Settings live on the kiosk.** Hostname, layout, and camera credentials are
stored on the unit's own disk (in its saved-settings file). You change them
over SSH with `kiosk-admin.sh`; it saves them for you.

---

## What you need

- An Ubuntu computer (your workstation) with a terminal.
- Internet access from that computer, for the build.
- A USB stick of 2 GB or more. The build erases it.
- VPN access to the site, to reach the kiosks over SSH.
- The camera user name and password.
- DHCP reservations for the kiosks, so each one keeps the same address.
  The MAC address is printed on the t640's label.

Install the two tools the build needs (once):

```
sudo apt install qemu-system-x86 ovmf
```

If you also want to preview layouts on your own screen, install ffmpeg and
a font:

```
sudo apt install ffmpeg fonts-liberation
```

---

## What is in this folder

| Path | What it is |
|------|------------|
| `kiosk-admin.sh` | Your main tool. Creates the keys, logs you in, enrolls and manages kiosks. |
| `kiosk-build.sh` | Builds the installer stick, writes it to USB, or tries it in a virtual machine. |
| `kiosk-mosaic.sh` | The camera wall itself. Runs on every kiosk. You can also run it on your computer to preview a layout. |
| `layouts/` | Screen layouts. Start from `default.conf`: copy, rename for the site, and edit. |
| `image/kiosk/` | Everything that gets installed on a kiosk: settings and small helper scripts. |
| `image/installer/` | The installer that runs from the stick. |
| `builder/` | The script that assembles the stick inside the build virtual machine. |
| `ca/` | Created by `init-ca`. Your keys, the trust list, and the inventory of kiosks. **Private. Back it up. Never share it.** |

---

## Step 1: Create your keys (once)

Open a terminal in the `Cakio` folder.

```
./kiosk-admin.sh init-ca
```

You will be asked for two passphrases: one for the user CA (you type it at
`login` when you need a new day pass) and one for the host CA (you type it at
every `enroll`). Choose real passphrases and keep them somewhere safe.

This creates the `ca` folder. Back it up to an encrypted location now. If
you lose it, you lose the ability to log in to every kiosk, and you would
have to re-image them all.

You also need a personal SSH key. If `~/.ssh/id_ed25519` does not exist:

```
ssh-keygen -t ed25519
```

Each engineer who will manage kiosks needs their own SSH key and a copy of
the `ca` folder, or you can sign their public key for them:
`./kiosk-admin.sh --key /path/to/their_key login` (the signed certificate
appears next to the key; give it back to them).

---

## Step 2: Build the installer stick

```
./kiosk-build.sh
```

The first time, this downloads the official Alpine Linux release (about
370 MB) into `~/.cache/cakio`, checks its checksum and signature, and keeps
it. Later builds reuse that download. Each build asks Alpine's site whether
a newer release exists; if one does, you are asked:

```
kiosk-build.sh: Alpine 3.24.3 is available; you have 3.24.2. Download the newer one (about 370 MB)? [y/N]
```

Press Enter to keep what you have. `--update` says yes without asking,
`--no-update` says no without asking, and with no internet the build just
uses the cached release. The signature of the cached release is checked
again at every build.

The build then boots the release in a small virtual machine on your
computer that assembles the stick image. It takes a few minutes. You end up
with a file like `cakio-20260930-2326.img`. The number is the *release*; the
kiosks will show it, so you always know which build a unit is running.

Then write the image to a USB stick:

```
./kiosk-build.sh write
```

It tells you to plug the stick in and finds it by itself (if one is already
plugged in, it offers that one). Then it asks two things that every unit
imaged from this stick will start with:

**Camera user and password.** Typed once here, so on site the installer
only needs an Enter to accept them. The password is not shown while you
type. Leave the user empty if you would rather type the credentials on each
unit.

**Which cameras.** It lists the layouts in `layouts/` with their cameras
and asks which one the installer should offer first. Press Enter to let the
installer pick from each unit's hostname instead (a unit called
`dty7-cakio-dock` looks for `dock.conf` on the stick). Ship starts with
`default.conf`; copy and rename it per site before you build if you want
hostname matching to find a file.

It then shows what the stick is and what is on it, for example:

```
Stick:   /dev/sda  15.5 GB SanDisk Ultra
Image:   /home/you/Projects/Cakio/cakio-20261001-0745.img
Cameras: user viewer (password stored on the stick)
Layout:  default.conf

This stick has data on it:
  sda1: 14.5G vfat, label "HOLIDAY", open at /media/you/HOLIDAY

All of it will be erased. Type YES to erase the stick and write the image:
```

Type YES only if you are happy to lose what is listed. The tool unmounts the
stick itself if your desktop opened it, writes the image (you may be asked
for your password), stores your answers on the stick, and powers the stick
off when done so you can unplug it.

Three things to know: it never writes to anything that is not a USB or
removable disk, so your computer's own disk is safe even if you pick the
wrong number. Do not click the Eject icon in the file manager before
writing; that powers the stick off entirely and it disappears (unplug it and
plug it back in). And the stick now carries the camera password in plain
text, in `kiosk/defaults.conf`: treat it like a key, not like a spare USB
stick. Rewrite it with an empty user when you no longer need it.

The layouts in `layouts/` at build time are the ones the installer offers.
Copy `layouts/default.conf` to a new name (for example `layouts/dock.conf`),
edit the grid and camera lines, then rebuild — or add the file later: copy
it into the `layouts` folder on the stick (plug it in, it mounts as
`CAKIOUSB`, copy, eject), rebuild and write a new stick, or push the layout
over SSH after imaging (see "Change the cameras on a kiosk").

Options you may want:

- `--timezone America/Toronto` sets the kiosk clock zone (this is the
  default). It affects the "No signal since 14:32" times.
- `--output FILE` names the image.

---

## Step 3: Image a thin client (on site)

Do this once per unit. It takes about five minutes.

### 3a. BIOS settings (first time on each unit)

Turn the unit on and press **F10** repeatedly to enter the BIOS setup.

- **Security:** set a BIOS administrator password. Without it anyone with a
  keyboard can boot their own system on the unit.
- **Secure Boot:** turn it **off**. The kiosk system is not signed for it.
- **Power:** set "After Power Loss" to **Power On**, so the kiosk returns
  after a power cut without anyone touching it.
- **Boot order:** USB first for now. After imaging, come back and put the
  internal disk first, or disable USB boot.

Save and exit.

### 3b. Run the installer

1. Plug in the stick and a keyboard. Turn the unit on. If it does not boot
   from the stick, press **F9** at power-on and pick the USB device.
2. The installer shows the internal disk it found and asks five things.
   Where the stick already holds an answer (from `write`), Enter accepts it.

   **Hostname.** Use the pattern `whid-cakio-location`, all lowercase, for
   example `dty7-cakio-dock` or `yhm1-cakio-main-entrance`. The *location*
   part picks the default layout when the stick does not name one.

   **Layout.** A numbered list of the layouts on the stick. Press Enter to
   take the default, type a number, or `0` to set it later over SSH.

   **Camera user and password.** If the stick carries them, press Enter
   twice. Otherwise type them; the password is not shown. Type `none` as
   the user to set the credentials later over SSH; the screen will say
   "No camera credentials" until you do.

   **Daily reboot time.** The kiosk restarts itself once a day to start
   fresh; it is back on the cameras within a minute. Enter takes 03:00
   (the unit's local time), or type another time such as `23:30`, or
   `none`. You can change it later with `kiosk-admin.sh reboot-time`.

   **Confirmation.** A summary, then `Type YES to continue`. Anything else
   starts over. Nothing is erased before you type YES.

3. The installer erases the old partitions completely (HP's own system
   leaves several behind), partitions the internal disk, copies the system,
   creates the unit's SSH identity, and writes a record of the unit to the
   stick. It ends with:

   ```
   Installed dty7-cakio-dock
   Host key: SHA256:UbXLddLubJAGMo3oQvdJ9akMg//D/wkM+FHQ9gN4U6A
   Record written to the stick: records/dty7-cakio-dock-*.txt

   Remove the USB stick, then press Enter to power off.
   ```

   Take a photo of this screen or keep the stick; you will want that host
   key line if the records do not make it back to your computer.

4. Remove the stick, press Enter, and turn the unit back on. Within about
   a minute it shows the cameras (if you gave it a layout and credentials)
   or a dark screen with its name and address.

When you are back at your desk, copy the `records` folder from the stick
into `ca/records`. Enrollment uses it to recognise the units you imaged.

---

## Step 4: Enroll the kiosk (from your desk)

Connect to the VPN. Sign your key for the day:

```
./kiosk-admin.sh login
```

Then enroll the unit by its address (the DHCP reservation):

```
./kiosk-admin.sh enroll 10.20.30.40
```

What happens, in order:

1. It fetches the kiosk's host key and checks it against the records from
   the stick. If the record is missing, it refuses. You can then pass the
   fingerprint from the installer's final screen:
   `--fingerprint SHA256:UbXLddLubJAGMo3oQvdJ9akMg//D/wkM+FHQ9gN4U6A`
2. It sets the kiosk's clock from your computer.
3. It asks for the camera user and password unless the kiosk already has
   them (press Enter to keep those), or you pass `--no-creds`.
4. It signs the kiosk's host key with your host CA and installs the
   certificate. From now on your computer recognises this kiosk by its
   certificate.
5. It saves everything on the kiosk and adds or updates that unit's line in
   `ca/inventory.csv` (matched by hostname).

You can also set things during enrollment:

```
./kiosk-admin.sh enroll 10.20.30.40 layouts/default.conf       # install a layout
./kiosk-admin.sh --hostname dty7-cakio-dock enroll 10.20.30.40 # rename
```

---

## Everyday tasks

All of these need a valid login (`./kiosk-admin.sh login`, good for 12
hours; running it again while the certificate is still valid does nothing)
and the VPN. One rule for every command: options such as `--port`
or `--key` go *before* the command name.

### See what a kiosk is doing

```
./kiosk-admin.sh status 10.20.30.40
```

Shows the hostname, release, uptime, memory, network state, the layout, and
one line per camera tile: `live`, `Connecting to camera`, or `No signal
since 14:32`. Also whether the X display and the camera wall are running,
and the recent log.

### See the screen itself

```
./kiosk-admin.sh shot 10.20.30.40
```

Saves `10.20.30.40.png`, a screenshot of what is on the kiosk's monitor
right now. Give a file name as a second argument to choose where it goes.

### Change the cameras on a kiosk

Edit or create a layout file (see "Writing a layout" below), then:

```
./kiosk-admin.sh layout 10.20.30.40 layouts/dock.conf   # your site copy of default.conf
```

The kiosk checks the file, switches to it within a few seconds, and saves
it. If the file has a mistake, nothing changes and you get a message
pointing at the line.

### Change the camera password

When the camera password rotates:

```
./kiosk-admin.sh creds 10.20.30.40 10.20.30.41 10.20.30.42
```

It asks for the user and password once and pushes them to every kiosk
listed, saving each. Add the new password on the cameras *before* running
this, and remove the old one *after* every kiosk reports success.

### Open a shell on a kiosk

```
./kiosk-admin.sh ssh 10.20.30.40
```

You arrive as the administrator account. Put `doas` in front of a command
to run it as root, for example `doas kiosk-apply show` or
`doas tail -n 50 /var/log/messages`.

### Restart the camera wall

```
./kiosk-admin.sh ssh 10.20.30.40 doas kiosk-apply restart
```

Useful after swapping the monitor: the wall measures the screen when it
starts.

### Change the daily reboot time

```
./kiosk-admin.sh reboot-time 10.20.30.40 04:30
./kiosk-admin.sh reboot-time 10.20.30.40 none
```

Every kiosk restarts itself once a day at the time chosen during
installation (03:00 unless you changed it), in its own local time. The
restart clears anything that has gone wrong during the day and applies
whatever is staged on the disk for the next boot. `status` shows the
current time and whether the scheduler is running.

### Update the software on a kiosk

Not yet, and not by itself. A kiosk's only source of packages is its own
internal disk, by design: it never reaches out to the internet for
software, so a nightly "apply all updates" job would have nothing to apply
and a bad update could never take a wall down at 3 in the morning.
Updates will come as a `kiosk-admin.sh update` command that pushes a new
release over SSH and lets the nightly reboot switch to it. Until then, a
new release means booting the unit from a new stick.

### Re-image or replace a unit

Boot it from the stick and run the installer again. It warns that a kiosk
is already installed and asks for YES. A re-imaged or replacement unit gets
a new host key, so enroll it again afterwards.

If the unit shows the camera wall instead of the installer, see "The
installer never appears" under "When something goes wrong".

---

## Writing a layout

Start from `layouts/default.conf`: it explains the file format, the
optional settings, and includes a starter 2x2 wall. Copy it to a new name
for the site (for example `layouts/dock.conf`), then edit the grid and
camera lines.

A layout is a small text file. Draw the screen as a grid of letters, then
list the cameras. The grid stretches to fill the whole screen, whatever its
resolution. A letter that covers several cells makes a bigger tile; a dot
is an empty cell.

```
# Example wall
layout
A B
C D
end

# tile|camera number|name|address
A|1001|Entrance|10.0.136.11
B|1002|Yard|10.0.136.12
C|1003|Parking|10.0.136.13
D|1004|Dock|10.0.136.14
```

Each tile shows its label in the bottom-left corner: the number, a dash,
and the name (or just the number if there is no name).

Things you can add:

- `fit fill` (default), `fit fit`, or `fit stretch` on its own line: whether
  video is cropped to fill its tile, letterboxed, or stretched.
- `fps 10` on its own line: frames per second (default 10, which is plenty
  for a wall and easy on the hardware).
- Per-camera options after a fifth `|`, for example
  `A|1001|Entrance|10.0.136.11|stream=main,fit=fit`. Small tiles use the
  camera's second, lower-resolution stream automatically; `stream=main`
  forces the full one.

Preview a layout on your own computer before pushing it (needs ffmpeg and a
font, see "What you need"):

```
./kiosk-mosaic.sh --test-pattern --snapshot preview.png layouts/default.conf
```

Open `preview.png`. Test patterns stand in for the cameras, labels are
real. `./kiosk-mosaic.sh --help` lists everything the wall can do.

---

## What the screen is telling you

| You see | It means | What to do |
|---------|----------|------------|
| Cameras, with a label on each | All good. | Nothing. |
| A dark tile saying **Connecting to camera** | The kiosk is trying that camera for the first time since it started. | Wait a few seconds. |
| A dark tile saying **No signal since 14:32** | That camera stopped responding at that time. The kiosk retries every few seconds. | Check the camera and its network. The tile recovers by itself. |
| Dark tiles saying **No camera credentials** | The kiosk has no camera user and password. | `./kiosk-admin.sh creds ADDRESS` |
| **Connect the ethernet cable to view the cameras** | No link on the network port. | Check the cable and the switch port. |
| **Network cable connected, waiting for a network address** | Link is up, DHCP has not answered yet. | Wait. If it stays, check the DHCP reservation. |
| **No camera layout installed**, with a name and address | The unit has no layout yet. | `./kiosk-admin.sh enroll ADDRESS layouts/NAME.conf` |
| White boot text that never goes away | The display session did not start. | `./kiosk-admin.sh status ADDRESS` shows the X server errors. |
| Nothing at all | No power, no monitor signal, or the monitor is on the wrong input. | Check power and the monitor. |

---

## When something goes wrong

**`cannot log in ... is your login still valid?`**
Your 12-hour pass expired. Run `./kiosk-admin.sh login` again.

**`the host key of ... is not in ca/records`**
Enrollment did not find the record for that unit. Copy the `records` folder
from the stick into `ca/records`, or pass `--fingerprint SHA256:...` from
the installer's final screen.

**`Permission denied` from ssh**
Either your login expired, or you are using a different SSH key than the
one you signed. `./kiosk-admin.sh --key ~/.ssh/other_key login` signs
another key. Options always go before the command.

**Connections go somewhere strange**
`kiosk-admin.sh` ignores your personal `~/.ssh/config` on purpose, because
corporate configs often route everything through a jump host. If you really
need one for a site, write a small config file and pass `--ssh-config FILE`.

**A kiosk is unreachable over SSH**
Check it is on and has an address (the DHCP server's lease list, or the
screen if it shows one). If the unit is up but SSH never answers, the last
resort is to boot it from the stick and re-image it. Nothing of value is
lost; the settings take a minute to re-enter.

**The installer never appears: the unit boots straight to the camera wall**
Two different causes, easy to tell apart.

If you never see the one-second menu that says "Install the camera kiosk",
the unit did not boot from the stick: it has the internal disk first in its
boot order (which is what we recommend after imaging). Press **F9** at
power-on and pick the USB device, or put USB first again in the BIOS.

If you do see that menu and the camera wall comes up anyway, the stick is
from a release older than 20261001-1844 (the release is printed on the
installer's first screen and in `release.txt` on the stick). Those sticks let
the unit choose which saved settings to load, and a unit that already holds
a kiosk finds its own before the stick's. Build a new image and write a new
stick; the installer now carries its settings with it. The unit is fine.

**I plugged in a USB stick while the kiosk was running and nothing happened**
Correct. USB storage is ignored on a running kiosk. The stick only does
something when the unit boots from it.

**Trying it without a thin client**
`./kiosk-build.sh boot` starts the stick image in a virtual machine on your
computer with a blank virtual internal disk, so you can walk through the
installer. Run it again with `--disk-only` to boot the installed virtual
kiosk, and enroll it with `./kiosk-admin.sh --port 2222 enroll 127.0.0.1`.

---

## Where things live on a kiosk

For when you are in a shell on a unit:

| Path | What |
|------|------|
| `/etc/kiosk/layout.conf` | The layout in use |
| `/etc/kiosk/camera.env` | Camera user and password (readable by root and the display user only) |
| `/etc/kiosk/unit.conf` | Serial number, MAC, release, imaging date |
| `/etc/crontabs/root` | Scheduled jobs, including the daily reboot line (`kiosk-nightly`) |
| `/media/cakio` | The internal disk: boot files, packages, saved settings |
| `/var/log/messages` | The log, including the camera wall's messages |
| `kiosk-apply` | Root tool that changes settings and saves them (`doas kiosk-apply --help`) |
| `kiosk-status`, `kiosk-shot` | What `status` and `shot` run for you |

Changes made by hand on a kiosk are lost at the next reboot unless you run
`doas kiosk-apply commit`. That is deliberate: the saved settings are the
only thing that survives, so a unit can never drift into an unknown state.

---

## Security, honestly

- Only the administrator account can log in, only over SSH, only with a
  certificate from your user CA. There are no passwords on the unit at all.
- The camera password is stored on each unit's internal disk. Someone who
  removes the eMMC module could read it. Use a camera account that can only
  view, and set the BIOS administrator password, which prevents booting
  anything else on the unit.
- Everything in `ca/` is sensitive: `user_ca` and `host_ca` are the ID-card
  printers, `cakio-build.rsa` signs the software on the stick. Keep the
  folder on an encrypted disk and back it up the same way.
- A stick written with camera credentials holds the camera password in
  plain text (`kiosk/defaults.conf`), and whoever has any stick can image a
  unit. Keep sticks with the keys, and rewrite one with an empty camera user
  before it goes into a drawer.

---

## Status and known limits

- Tested end to end in a virtual machine: build, install, boot, enroll,
  status, screenshot. The first real t640 is the hardware test; the GPU and
  network firmware it needs is present in the image.
- Updating the software on an enrolled kiosk currently means re-imaging it
  from a new stick and re-entering its settings. An `update` command that
  does this over SSH while keeping the settings is the planned next step;
  the daily reboot is already the moment such an update would take effect.
- Memory: the whole system runs from RAM, with a compressed swap area in
  RAM (zram, half the memory) as a safety net for busy walls. `status`
  shows how much of it is in use; a value that keeps growing on a unit is
  worth a look.
- The Bosch cameras' second stream is assumed at `/rtsp_tunnel?inst=2`.
  If your cameras use a different address, set `sub_path` in the layout.

---

## Command reference

```
kiosk-admin.sh [options] command
  init-ca                    create the ca folder (once)
  login                      sign your SSH key for 12 hours (--hours N);
                               skips signing when the certificate is still valid
  enroll HOST [LAYOUT]       trust and set up a newly imaged kiosk
                               (updates the inventory row for that hostname)
  layout HOST FILE           install a new layout and save
  creds HOST...              set the camera credentials and save
  reboot-time HOST TIME      daily restart at TIME (HH:MM) or none, and save
  status HOST                what the kiosk is doing
  shot HOST [FILE]           screenshot of the kiosk screen
  ssh HOST [COMMAND...]      shell or command on the kiosk
  options: -c/--ca-dir DIR, -p/--port N, -i/--key FILE, --records DIR,
           --fingerprint SHA256:..., --hostname NAME, --no-creds, --hours N

kiosk-build.sh [options] command
  image (default)            build the stick image
  write [DEVICE]             write it to a USB stick (finds the stick itself)
  boot                       try it in a virtual machine
  options: -o/--output FILE, --timezone ZONE, -c/--ca-dir DIR,
           --update, --no-update, --image FILE, --disk FILE, --disk-only,
           --ssh-port N

kiosk-mosaic.sh [options] LAYOUT
  --print                    show the commands it would run
  --snapshot FILE            render one frame to a PNG
  --test-pattern             use test patterns instead of cameras
```

Every tool answers `--help` with the full list.
