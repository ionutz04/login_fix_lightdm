# lightdm greeter never wakes up on a multiseat machine (Xorg stuck in `vga_get`)

A short write-up of a bug and its workaround. **Symptom:** on one seat of a multiseat machine, the
login screen (lightdm greeter) goes dark after being idle and **never comes back**, however many keys
you press. The machine itself is fine and other seats keep working.

## TL;DR

The greeter's Xorg deadlocks in the kernel when it tries to turn the screen back on (DPMS wake), on a
GPU that is **not** the boot VGA device. Workaround: give that seat's greeter an Xorg config with
**screen blanking and DPMS disabled**, so the wake commit never happens.

```bash
sudo install -m 644 files/xorg-seat2.conf /etc/X11/xorg-seat2.conf
sudo install -m 644 files/50-seat2.conf   /etc/lightdm/lightdm.conf.d/50-seat2.conf
# replace "seat2" with your seat everywhere, then restart lightdm or reboot
```

Trade-off: the greeter screen no longer sleeps, it stays lit while nobody is logged in.

## The machine

Multiseat, three seats, lightdm with `lightdm-webkit2-greeter` (greeters run on X; KDE Plasma and
Hyprland are used as Wayland sessions), Intel graphics:

| Seat | GPU | Driver | Boot VGA? |
|---|---|---|---|
| seat0 | Intel Arc B580 | `xe` | **yes** |
| seat1 | integrated GPU | `i915` | no |
| seat2 | Intel Arc B580 | `xe` | no |

Seat1 already had this workaround (its config says "DPMS wake deadlocks in `vga_get()`"). Seat2 did
not, and was the one that hung.

## Evidence

Run `scripts/diagnose.sh` (read-only, needs sudo to read `/proc/<pid>/stack`) to collect all of this.

**1. The greeter's Xorg is stuck in uninterruptible sleep.** `ps` showed `D<` for ~14 hours, kernel
wait channel `vga_get`. A second Xorg thread was blocked on `drm_modeset_lock`, queued behind it.

**2. The kernel stack is the wake-up path.**

```
vga_get
intel_vga_reset_io_mem          [xe]
hsw_power_well_enable           [xe]
intel_power_well_enable         [xe]
__intel_display_power_get_domain
intel_modeset_get_crtc_power_domains
intel_atomic_commit_tail
intel_atomic_commit
drm_atomic_commit
drm_atomic_connector_commit_dpms     <-- X switching the connector's DPMS state back on
drm_mode_obj_set_property_ioctl
```

**3. The VGA arbiter showed a lock on the boot VGA device.** While wedged, `/dev/vga_arbiter`
reported `PCI:<boot-vga>, locks=io+mem(2:2)`. On a healthy system it reports `locks=none(0:0)`.
Only two processes had the arbiter open, both Xorg servers (the wedged one and seat1's, which was
healthy).

**4. Timing.** The wedged server's `Xorg.0.log` stopped about 637 s after the server started,
consistent with the default 10-minute screen blank followed by the first wake attempt. (I could not
read the DPMS timers directly: `xset` was not installed.)

## Why it happens (what is established, and what is not)

- `vga_get()` takes the legacy VGA resource lock. The `xe` display code calls it while powering the
  display up (`intel_vga_reset_io_mem`), and it blocks while another party holds the lock on the boot
  VGA device.
- The seat whose GPU is the boot VGA device (seat0) is not affected; the ones that are not are.
- **Not established:** *which* process held the lock on the boot VGA device. Seat1's Xorg was healthy,
  so the wedged Xorg may have been waiting on a lock it held itself. I did not prove that, and I did
  not test a kernel/driver-level fix. This is a workaround, not a root-cause fix.

## The fix

Two small files (see `files/`):

- `/etc/X11/xorg-seat2.conf`: `BlankTime`, `StandbyTime`, `SuspendTime`, `OffTime` = `0`, and
  `Extension "DPMS" "Disable"`.
- `/etc/lightdm/lightdm.conf.d/50-seat2.conf`: `[Seat:seat2]` with
  `xserver-command=X -config /etc/X11/xorg-seat2.conf`.

Seat1's own config additionally has a `Device` section pinning the GPU by bus ID and
`AutoAddGPU off`. They are not needed for this fix and were deliberately left out for seat2.

Takes effect the next time lightdm starts an X server for that seat (restart lightdm, or reboot).
Note that **restarting lightdm ends every graphical session on every seat**.

A wedged Xorg in `D` state cannot be killed with signals. If you are already in the stuck state, you
need to restart lightdm or reboot to clear it; the config only prevents it from recurring.

## Verification

After the reboot:

- `Xorg.0.log` shows `Using config file: "/etc/X11/xorg-seat2.conf"`, the four timeouts as `0`, and
  `Extension "DPMS" is disabled`.
- A query to the live server (`python-xlib`, `get_screen_saver()`) returned `timeout=0`, and the DPMS
  extension was absent.
- The Xorg was in state `S` (`do_epoll_wait`), not `D`.
- **The decisive check was done by hand on the machine:** after the greeter had been idle past the
  10-minute point, the login screen was still up and responsive, and logging in worked. An automated
  check at that point was started but stopped before it reported, so there is no scripted result for
  the 10-minute mark.

Verified on **one machine** and one afternoon.

## Not covered

- **Logged-in sessions.** After login the greeter's X server stops and the session (Plasma or
  Hyprland) handles screen power. Both go through the same `xe` display code, so a session that blanks
  the display and wakes it may hit the same `vga_get` path. That was **not tested**.
- **Other seats and GPUs.** Seat0's greeter (boot VGA GPU) runs with the default config and showed no
  problem, but it was only observed running, not idled for hours.
- **Other drivers.** Only the `xe` driver (plus `i915` for seat1) was involved.
- A proper fix belongs in the kernel/driver or the arbiter handling. If you reproduce this, a bug
  report to the `xe` maintainers with the stack above would be worth filing.

## Layout

```
README.md
files/xorg-seat2.conf     greeter Xorg config: no blanking, no DPMS
files/50-seat2.conf       lightdm drop-in that applies it to one seat
scripts/diagnose.sh       read-only: detects the wedge, prints stack/arbiter/config
```
