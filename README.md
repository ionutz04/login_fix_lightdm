> [!TIP]
> **Project Leader**
> Ionut Ionescu

# Description

On a multiseat machine, the lightdm login screen of one seat goes dark after being idle and **never
wakes up**, no matter how many keys are pressed. The machine itself is fine and the other seats keep
working.

Cause: the greeter's Xorg deadlocks in the kernel (`vga_get`) when it tries to turn the screen back on
(DPMS wake) on a GPU that is **not** the boot VGA device.

Workaround: give that seat's greeter an Xorg config with **screen blanking and DPMS disabled**, so the
wake commit never happens. The trade-off is that the greeter screen no longer sleeps while nobody is
logged in.

```bash
sudo install -m 644 files/xorg-seat2.conf /etc/X11/xorg-seat2.conf
sudo install -m 644 files/50-seat2.conf   /etc/lightdm/lightdm.conf.d/50-seat2.conf
# replace "seat2" with your seat everywhere, then restart lightdm or reboot
```

> [!WARNING]
> Restarting lightdm ends every graphical session on **every** seat.

# Required hardware

This is the machine the fix was found and tested on. Nothing needs to be bought.

| Part | Qty | Role |
|---|---|---|
| Intel Arc B580 (`xe` driver), **boot VGA device** | 1 | seat0 |
| Intel integrated GPU (`i915` driver) | 1 | seat1 |
| Intel Arc B580 (`xe` driver), not boot VGA | 1 | seat2, the seat that hung |

Software: lightdm with `lightdm-webkit2-greeter` (greeters run on X), KDE Plasma and Hyprland as
Wayland sessions. Seat1 already had this workaround; seat2 did not.

# Evidence

Run `scripts/diagnose.sh` (read-only, needs sudo to read `/proc/<pid>/stack`) to collect all of this.

## 1. The greeter's Xorg is stuck in uninterruptible sleep

`ps` showed state `D<` for about 14 hours, with kernel wait channel `vga_get`. A second Xorg thread was
blocked on `drm_modeset_lock`, queued behind it.

## 2. The kernel stack is the wake-up path

```
vga_get
intel_vga_reset_io_mem               [xe]
hsw_power_well_enable                [xe]
intel_power_well_enable
__intel_display_power_get_domain
intel_modeset_get_crtc_power_domains
intel_atomic_commit_tail
intel_atomic_commit
drm_atomic_commit
drm_atomic_connector_commit_dpms     <-- X switching the connector's DPMS state back on
drm_mode_obj_set_property_ioctl
```

## 3. The VGA arbiter showed a lock on the boot VGA device

While wedged, `/dev/vga_arbiter` reported `PCI:<boot-vga>, locks=io+mem(2:2)`. On a healthy system it
reports `locks=none(0:0)`. Only two processes had the arbiter open, both Xorg servers: the wedged one
and seat1's, which was healthy.

## 4. Timing

The wedged server's `Xorg.0.log` stopped about 637 s after the server started, consistent with the
default 10-minute screen blank followed by the first wake attempt. The DPMS timers could not be read
directly because `xset` was not installed.

# Why it happens

- `vga_get()` takes the legacy VGA resource lock. The `xe` display code calls it while powering the
  display up (`intel_vga_reset_io_mem`), and it blocks while another party holds the lock on the boot
  VGA device.
- The seat whose GPU is the boot VGA device (seat0) is not affected. The others are.
- **Not established:** which process held the lock on the boot VGA device. Seat1's Xorg was healthy,
  so the wedged Xorg may have been waiting on a lock it held itself. That was not proven, and no
  kernel- or driver-level fix was tested. This is a workaround, not a root-cause fix.

# The fix

Two small files, in `files/`:

| File | Content |
|---|---|
| `/etc/X11/xorg-seat2.conf` | `BlankTime`, `StandbyTime`, `SuspendTime`, `OffTime` set to `0`, and `Extension "DPMS" "Disable"` |
| `/etc/lightdm/lightdm.conf.d/50-seat2.conf` | `[Seat:seat2]` with `xserver-command=X -config /etc/X11/xorg-seat2.conf` |

Seat1's own config also has a `Device` section pinning the GPU by bus ID and `AutoAddGPU off`. They are
not needed for this fix and were deliberately left out for seat2.

The fix takes effect the next time lightdm starts an X server for that seat. A wedged Xorg in `D` state
cannot be killed with signals, so if you are already in the stuck state you need to restart lightdm or
reboot to clear it. The config only stops it from happening again.

# Verification

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

Verified on **one machine**, in one afternoon.

# Not covered

- **Logged-in sessions.** After login the greeter's X server stops and the session (Plasma or Hyprland)
  handles screen power. Both go through the same `xe` display code, so a session that blanks the display
  and wakes it may hit the same `vga_get` path. **Not tested.**
- **Other seats and GPUs.** Seat0's greeter (boot VGA GPU) runs with the default config and showed no
  problem, but it was only observed running, not left idle for hours.
- **Other drivers.** Only `xe` (plus `i915` for seat1) was involved.
- A proper fix belongs in the kernel/driver or the arbiter handling. If you reproduce this, a bug report
  to the `xe` maintainers with the stack above would be worth filing.

# Repository layout

```
README.md
files/xorg-seat2.conf     greeter Xorg config: no blanking, no DPMS
files/50-seat2.conf       lightdm drop-in that applies it to one seat
scripts/diagnose.sh       read-only: detects the wedge, prints stack, arbiter and config
```

# Licensing

_Not chosen yet. Add a licence before publishing._

# Sources

- Linux kernel documentation, `Documentation/gpu/vgaarbiter.rst` (VGA arbiter)
- `man xorg.conf` (`ServerFlags`, `Extensions` sections)
- `lightdm --show-config` and `man lightdm` (per-seat `xserver-command`)
