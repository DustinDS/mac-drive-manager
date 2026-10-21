# Mac Drive Manager

Read **and write** a Mac-formatted (HFS+) external drive from Windows 11, without
reformatting it — plus a fast local working copy that syncs back automatically
when you eject.

Built for a video-editing workflow: the drive holds camera footage and an Adobe
Premiere project, the Mac is the authoring machine, and the PC needs to edit the
same files without the drive being erased or corrupted.

---

## The problem

Windows has no HFS+ support at all. A Mac-formatted drive shows up as a disk with
no readable volume and no drive letter — Disk Management sees hardware, Explorer
sees nothing.

The paid options (Paragon HFS+, MacDrive) work fine. This project is the free
route, and it costs a kernel build.

## How it works

```
Windows  ──usbipd──►  WSL2  ──hfsplus.ko──►  /mnt/mac  ──\\wsl.localhost──►  Explorer
```

1. **usbipd-win** forwards the physical USB device into WSL2.
2. A **custom-built `hfsplus` kernel module** mounts the volume read-write.
3. Windows reaches it over `\\wsl.localhost\<distro>\mnt\mac`.
4. A **local working copy** on a fast internal disk is where you actually edit;
   it syncs back to the drive before every eject.

### Why a custom kernel and not just a module

Microsoft's stock WSL2 kernel ships `CONFIG_HFSPLUS_FS` **unset**. The Kconfig
symbol still exists, so the source is there and can be compiled — but two things
bite:

- `CONFIG_MODVERSIONS=y` means symbol CRCs must match, and those only come from
  `Module.symvers`, which requires a **full** kernel build. A
  `modules_prepare`-only build produces a module that dies with
  `disagrees about version of symbol module_layout`.
- Rebuilding from the same source with a *different compiler* produces different
  CRCs than Microsoft's prebuilt binary, so the module still won't load into the
  stock kernel.

So the build installs the kernel it compiled and points WSL at it via
`.wslconfig`. Kernel and modules then match by construction and nothing needs
force-loading.

`install/02-build-hfsplus-module.sh` automates all of it, including deleting
`.git` from the source tree — otherwise `scripts/setlocalversion` appends `+` to
the version string and the kernel looks for modules in a directory that doesn't
exist.

---

## Requirements

- Windows 10/11 with virtualization **enabled in BIOS**
  (AMD: `SVM Mode`; Intel: `Intel VT-x`)
- Administrator access for the one-time setup
- ~30 GB free for the kernel build (reclaimable afterwards)
- An internal disk with room for the working copy

## Install

```powershell
# 1. Elevated PowerShell - features, WSL, Ubuntu, usbipd-win
.\install\01-install-wsl-and-usbipd.ps1
# reboot
```

```bash
# 2. Inside WSL, as root - builds and installs the kernel + hfsplus module
sudo bash install/02-build-hfsplus-module.sh
```

Follow the printed `.wslconfig` instructions, then `wsl --shutdown`.

```powershell
# 3. Configure, then bind the drive (elevated, once - the binding persists)
copy macdrive.conf.example macdrive.conf   # edit it first
.\install\03-bind-drive.ps1
```

Find your drive's `VID:PID` for `macdrive.conf` with `usbipd list`.

## Use

Run `app\MacDriveManager.vbs` (make a Desktop shortcut to it).

| Button | Does |
|---|---|
| Check Status | Refreshes, and compares local copy vs drive |
| Mount Read/Write | Attaches + mounts; pulls to local if auto-sync is on |
| Get from Drive | Manual pull |
| Send to Drive | Manual push |
| Open Project | Opens the newest `.prproj` from the **local** copy |
| Eject Safely | Syncs back, unmounts, releases the drive |

The **auto-sync toggle** (top right) controls whether mounting pulls and ejecting
pushes automatically. The setting persists in `settings.json`.

---

## Safety

**Always use Eject Safely.** This is the one rule that matters.

Journaled HFS+ has to be mounted `-o force`, because Linux does not maintain
Apple's journal. A clean unmount sets the volume's `kHFSVolumeUnmounted` flag and
clears `kHFSVolumeInconsistent`, which is what macOS checks on the next mount.
Yanking the cable while mounted leaves it flagged inconsistent.

Measured, on a volume written from Linux:

```
while mounted : attributes 0x80002800  Unmounted=False  Inconsistent=True
after unmount : attributes 0x80002100  Unmounted=True   Inconsistent=False
```

Sync behaviour is deliberately conservative:

- **Newer wins** in both directions (`rsync -au`)
- **Deletions never propagate.** Delete a file locally and it stays on the drive.
- **Every overwrite is archived** to a timestamped folder, never discarded.

If you go back and forth often, consider disabling the journal from the Mac —
non-destructive, keeps every file, and removes the only real fragility here:

```bash
sudo diskutil disableJournal "/Volumes/Your Drive"
```

## Known limitations

- **Trailing spaces in names.** macOS allows `Back Up `; Win32 strips the space,
  so such a folder becomes unreachable from normal Windows paths (and recursive
  listings double-count it). Rename it on the Mac. Leading spaces are fine.
- **Premiere relinks on every platform switch.** The project stores paths, and
  `/Volumes/Drive/...` can't be `D:\Working\...`. Identical relative layout means
  Premiere usually auto-matches all but one clip. Unavoidable, not a bug here.
- **Preview/render files rebuild per platform.**
- **The mount dies if WSL idles out.** The app holds a keep-alive process; if you
  mount from the shell instead, keep a WSL process running.
- **Accented filenames** were verified byte-identical across the HFS+/NTFS hop
  (composed form, no NFD/NFC drift), but this was tested on one dataset.

## Layout

```
app/        GUI (PowerShell + WinForms) and its no-console launcher
install/    One-time host setup and the kernel module build
scripts/    mount / umount / sync, shared config loader
macdrive.conf.example
```

## License

MIT — see [LICENSE](LICENSE).
