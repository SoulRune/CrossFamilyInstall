# CrossFamilyInstall

Cross-**device-family** IPA installer for jailbroken iOS 14+ (rootless and rootful).

Bypasses the installer's device-family check (`UIDeviceFamily`) so you can install an
IPA built for a different Apple platform - iPhone/iPad/tvOS - on your device,
via a toggle in **Settings → CrossFamilyInstall**.
Created mainly for encrypted (license) ipa's with direct install

## How it works

Hooks `MIIsApplicableToCurrentDeviceFamilyWithError` inside **`installd`** (found via
reverse engineering - module `InstalledContentLibrary`;
see [REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md) for the full trace log and method).
When the toggle is on, the hook always reports the app as compatible, skipping Apple's
family check entirely; when off, it calls through to the original implementation,
so normal installs are unaffected.

## Install

Grab a `.deb` from the [Releases](https://github.com/SoulRune/CrossFamilyInstall/releases), [Actions artifacts](https://github.com/SoulRune/CrossFamilyInstall/actions).
OR build your own - see [BUILD.md](docs/BUILD.md).
Requires **PreferenceLoader** (a common jailbreak dependency
for Settings panels - usually already installed if you have other tweaks with a settings screen;
your package manager will pull it in automatically if available in an
enabled repo).

```bash
# rootless                                # rootful
make package                              make package THEOS_PACKAGE_SCHEME=
```

Then: **Settings → CrossFamilyInstall** → turn the switch on → **Apply (Restart installd)**.
If the panel doesn't show up, respring (PreferenceLoader panels are
registered at SpringBoard/Preferences launch, not by `dpkg -i` alone).

## Apply button

`installd` is a long-running daemon - a freshly installed/updated tweak dylib, and any
internal per-package verdict cache installd itself keeps in memory, only get picked up
after the process restarts. Tapping **Apply** posts a Darwin notification
(`com.soulrune.crossfamilyinstall/restart`); the tweak, already injected into installd,
receives it and calls `exit(0)` on itself. `launchd` then relaunches the daemon using
its own privilege - no privilege elevation needed on the Settings-panel side at all,
unlike an earlier version of this button that tried to `posix_spawn` `launchctl
kickstart` directly (that crosses a real `mobile` → `root` privilege boundary and turned
out to be unreliable). Posting a Darwin notification, by contrast, is UID-independent -
exactly how the preferences reload already worked, and how most jailbreak
respring/reload buttons work under the hood.

If, for some reason, the notification isn't received (e.g. right after a fresh install,
before the tweak has ever run once), the next install attempt still gets correct
behavior regardless - `installd` re-reads the preferences file from disk on every check,
there's no caching layer to go stale.

## Compatibility

For now confirmed working on: iPhone 8 / 16.7.10 / Rootless. The hooked symbol lives in an undocumented private
framework (`InstalledContentLibrary`) - Apple gives no stability guarantee for it across
major iOS versions. The tweak fails safe: if the symbol isn't found on your version, it
logs `NOT FOUND` and does nothing (installd behaves exactly as stock), rather than
crashing anything. Check `syslog`/`oslog` for `[CrossFamilyInstall]` after install to
see the hook status and the iOS version it was tested against - see
[REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md) if you need to re-run the symbol hunt
on a different iOS version.

## Known limits

- **tvOS installs will very likely crash on launch** even after a successful install.
  tvOS binaries link against platform-specific frameworks (confirmed: `dyld` refuses to
  load an embedded framework built for a different platform - "wrong platform to load
  into process"). This tweak only clears the *installer*-level check; it can't make a
  tvOS binary run on iOS. iPad ↔ iPhone shares the same underlying platform/UIKit, so
  those installs have a real chance of working end to end.
- tvOS apps may also show no icon on SpringBoard (different icon asset format).
