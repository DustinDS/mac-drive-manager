# Mac Drive Manager

**Read and write Mac-formatted (HFS+) drives on Windows — free, without
reformatting, and without buying a driver.**

Plug a Mac drive into Windows and nothing happens. Disk Management sees the
hardware; Explorer sees nothing. Windows has no HFS+ support at all, so the
drive has no volume and no letter.

The usual fix is to buy a commercial filesystem driver — MacDrive runs around
**$50**, Paragon HFS+ for Windows around **$20** (check current pricing; these
are ballpark). They work well. This does the same job for **$0**, using parts
you already have a licence to: WSL2, the Linux kernel's own HFS+ driver, and
Microsoft's `usbipd-win`.

```
Windows  ──usbipd──►  WSL2  ──hfsplus.ko──►  /mnt/mac  ──\\wsl.localhost──►  Explorer
```

1. **usbipd-win** forwards the physical USB device into WSL2.
2. A **custom-built `hfsplus` kernel module** mounts the volume read-write.
3. Windows reaches it at `\\wsl.localhost\<distro>\mnt\mac`.
4. A **local working copy** on a fast internal disk is where you actually edit;
   it syncs back to the drive before every eject.

What you give up versus the paid tools: a one-time ~20 minute setup including a
kernel compile, and the drive appears at a UNC path rather than as a drive
letter. What you get: the same read-write access, a sync workflow the paid tools
don't have, and the source.

Built for a video-editing workflow — camera footage and a Premiere project
authored on a Mac, edited on a PC — but nothing here is specific to video.

> **Free, and staying free.** If it saves you a licence fee, you can
> [buy me a coffee on Venmo](https://venmo.com/u/Dustin-DivineSicherman) — completely
> optional, nothing is gated. See [Donate](#donate).

---

## Quickstart

**The short version: run three scripts, reboot twice, done.**

**Before anything:** enable CPU virtualization in your BIOS. It is off by default
on a lot of machines and nothing here works without it.
- AMD → **SVM Mode** (often under *OC*, or *Advanced → CPU Features*)
- Intel → **Intel VT-x** / *Virtualization Technology*
- Verify in Task Manager → Performance → CPU → **Virtualization: Enabled**

**1. Install the host side** — elevated PowerShell, then reboot:
```powershell
.\install\01-install-wsl-and-usbipd.ps1
```

**2. Build the HFS+ driver** — inside WSL, takes 15–25 minutes:
```bash
sudo bash install/02-build-hfsplus-module.sh
```
It prints a `.wslconfig` snippet at the end. Add it, then `wsl --shutdown`.

**3. Point it at your drive.** Plug the drive in and find its ID:
```powershell
usbipd list
```
Copy the `VID:PID` (looks like `0781:55af`). Then:
```powershell
copy macdrive.conf.example macdrive.conf
notepad macdrive.conf
```
Set `HWID` to your `VID:PID`, and set `LOCAL_WIN` / `LOCAL_WSL` to where you want
the working copy (same folder, two spellings). Then, elevated once:
```powershell
.\install\03-bind-drive.ps1
```

**4. Run it.** Double-click **`Start.cmd`** (or `app\MacDriveManager.exe`). Press
**Mount Read/Write**. That's it.

> **The one rule: always use *Eject Safely* before unplugging.** It flushes
> writes, syncs your work back, and sets the flag macOS checks on the next
> mount. Pulling the cable while mounted is the one thing that can hurt you.

---

## Download

Grab the latest build from [**Releases**](../../releases) — a zip with
everything in it.

| Run it as | How |
|---|---|
| **`.exe`** | `app\MacDriveManager.exe` — double-click |
| **`.cmd`** | `Start.cmd` in the root — double-click, no console window |
| **`.ps1`** | `powershell -ExecutionPolicy Bypass -File app\MacDriveManager.ps1` |

All three run the same code. The `.exe` is the `.ps1` wrapped by
[ps2exe](https://github.com/MScholtes/PS2EXE) — it is unsigned, so SmartScreen
may warn on first run (*More info → Run anyway*), and some antivirus engines are
twitchy about PowerShell-derived executables. If you would rather not trust a
binary from a stranger, use `Start.cmd`; it is three lines you can read.

Make a Desktop shortcut to whichever you pick.

---

## Using it

| Button | Does |
|---|---|
| Check Status | Refreshes, and compares local copy vs drive |
| Mount Read/Write | Attaches + mounts; pulls to local if auto-sync is on |
| Get from Drive | Manual pull |
| Send to Drive | Manual push |
| Open Project | Opens the newest `.prproj` from the **local** copy |
| Open Local Folder | Explorer, at the working copy |
| Eject Safely | Syncs back, unmounts, releases the drive |

The **auto-sync toggle** (top right) decides whether mounting pulls and ejecting
pushes automatically. It persists in `settings.json`.

Edit from the **local working copy**, not the drive. The drive is reachable over
a network-style share, which is fine for copying but slow for scrubbing a
timeline. Eject syncs your changes back.

---

## Safety

Journaled HFS+ has to be mounted `-o force`, because Linux does not maintain
Apple's journal. A clean unmount sets `kHFSVolumeUnmounted` and clears
`kHFSVolumeInconsistent`, which is what macOS checks next time. Measured on a
volume written from Linux:

```
while mounted : attributes 0x80002800  Unmounted=False  Inconsistent=True
after unmount : attributes 0x80002100  Unmounted=True   Inconsistent=False
```

Sync is deliberately conservative:

- **Newer wins** in both directions (`rsync -au`)
- **Deletions never propagate.** Delete a file locally and it stays on the drive.
- **Every overwrite is archived** to a timestamped folder, never discarded.

If you hop between machines often, consider turning the journal off from the Mac
— non-destructive, keeps every file, removes the only real fragility here:

```bash
sudo diskutil disableJournal "/Volumes/Your Drive"
```

## Known limitations

- **Trailing spaces in names.** macOS allows `Back Up `; Win32 strips the space,
  so such a folder is unreachable from normal Windows paths and recursive
  listings double-count it. Rename it on the Mac. Leading spaces are fine.
- **Premiere relinks on every platform switch.** The project stores paths, and
  `/Volumes/Drive/...` cannot be `D:\Working\...`. Identical relative layout
  means Premiere usually auto-matches all but one clip. Not specific to this
  tool; it happens with the paid drivers too.
- **Preview/render files rebuild per platform.**
- **The mount dies if WSL idles out.** The app holds a keep-alive process; if you
  mount from a shell instead, keep a WSL process running.
- **Rebuild the module after a WSL kernel update.** Re-run
  `install/02-build-hfsplus-module.sh`.

## Why the kernel build is necessary

Microsoft's stock WSL2 kernel ships `CONFIG_HFSPLUS_FS` **unset**. The Kconfig
symbol still exists, so the source is there — but:

- `CONFIG_MODVERSIONS=y` means symbol CRCs must match, and those only come from
  `Module.symvers`, which requires a **full** kernel build. A
  `modules_prepare`-only build dies with
  `disagrees about version of symbol module_layout`.
- Rebuilding with a different compiler than Microsoft used produces different
  CRCs anyway, so the module still will not load into the stock kernel.

So the installer builds the kernel, installs it, and points WSL at it via
`.wslconfig`. Kernel and modules then match by construction and nothing is
force-loaded. The script also deletes `.git` from the source tree first —
otherwise `scripts/setlocalversion` appends `+` to the version string and the
kernel looks for modules in a directory that does not exist.

## Layout

```
app/        GUI (PowerShell + WinForms), launcher, compiled exe
install/    One-time host setup and the kernel module build
scripts/    mount / umount / sync, shared config loader
Start.cmd   Double-click launcher
macdrive.conf.example
```

---

## Donate

This does the job of a driver that costs **$20–$50**. It is free, it is MIT
licensed, and it stays that way — there is no paid tier, no nag screen, and
nothing is held back.

If it saved you a licence fee and you want to send some of that back, that is
genuinely appreciated. It is entirely optional and nothing here is gated behind
it.

### 💸 Venmo

> ### **[@Dustin-DivineSicherman](https://venmo.com/u/Dustin-DivineSicherman)**

**Other ways to help, which are worth just as much:** open an issue when
something breaks, send a pull request, or tell someone who has been staring at a
Mac drive that Windows refuses to mount.

## License

MIT — see [LICENSE](LICENSE).
