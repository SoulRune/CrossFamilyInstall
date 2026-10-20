# CrossFamilyInstall

Installs IPAs built for a different device family (iPhone / iPad / tvOS) on jailbroken
iOS 14+, rootless and rootful, and lets installed apps see a different device.
Made mainly for directly installing encrypted (licensed) IPAs.

## Installation checks

Three switches in **Settings -> CrossFamilyInstall**, each skipping one `installd` check:

- **Allow Other Device Family** - `UIDeviceFamily`. Hooks
  `MIIsApplicableToCurrentDeviceFamilyWithError` in `InstalledContentLibrary`
  (see [REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md)).
- **Ignore Device Model** - `UIRequiredDeviceCapabilities`, `UISupportedDevices`.
- **Ignore iOS Version** - `MinimumOSVersion`.

The last two hook Objective-C methods found at load time: methods named
`isApplicable...` / `isCompatible...` whose type encoding is exactly
`- (BOOL)...WithError:(NSError **)` or `- (BOOL)...:(id) error:(NSError **)`. Each candidate
is logged (`candidate -[Class selector] ... -> hooked (os)`); if nothing matches, the log
says `0 method(s) hooked` and the switch does nothing.

This only gets an app installed. An app that needs newer iOS APIs or hardware the device
lacks will still crash at launch.

## Per-App Spoofing

Sets what an installed app sees about the device. **Apps** lists the installed apps;
**App Store** and its product sheets are right below.

Each app's page has two modes: **Simple** (family, device, iOS; picking a device also
fills in its CPU, cores, RAM and GPU) and **Advanced** (every value separately). Both
edit the same values.

| Setting | What the app gets |
|---|---|
| **Device Family** | `UIDevice.userInterfaceIdiom` (+ `UIDevice.model` if no device is set) |
| **Device** (`iPad13,16`) | `hw.machine` (`sysctlbyname`, `sysctl`), `uname().machine`, `UIDevice.model` |
| **iOS Version** (`17.4.1`) | `UIDevice.systemVersion`, `NSProcessInfo` version methods, `kern.osproductversion` |
| **CPU** (`Apple A16 Bionic`) | `machdep.cpu.brand_string` |
| **CPU Cores** | `hw.ncpu` and the other core counts, `NSProcessInfo` processor counts, `host_info` |
| **RAM** (MB) | `NSProcessInfo.physicalMemory`, `hw.memsize` / `physmem` / `memsize_usable`, `host_info` |
| **GPU** (`Apple A16 GPU`) | `-[MTLDevice name]` |
| **GPU Memory** (MB) | `-[MTLDevice recommendedMaxWorkingSetSize]` (iOS 16+) |

The hardware values are for games that check the device before they start (Unity logs
lines like `GameSupportChecker: Memory not supported! got 1975MB, expected 3100MB+`).
Devices report a bit less RAM than their nominal size, so pick the next step up.

What stays real: `#available` / `@available`, since a newer version there makes apps call
APIs that don't exist; `UITraitCollection`, which UIKit lays itself out from; the real
memory limit, so an app told it has more RAM still gets killed at the real one; and GPU
feature sets, only the GPU name changes.

In the app list: search, swipe to enable or disable, and **Select** to set the same
values on several apps at once.

### App Store

The App Store entry lets the store offer and download apps it would call "not supported
on this device". That takes getting past three checks:

- The App Store app asks MobileGestalt for performance gates
  (`iphone-ipad-minimum-performance-a12` and up, `iphone-performance-gaming-tier`).
  They are answered for the chosen device's chip, and `ProductType` /
  `HardwarePlatform` report its model and chip.
- Apple's servers look at the `User-Agent` of store requests
  (`iOS/16.7 model/iPhone10,1 hwp/t8015`). It's rewritten in the App Store apps, and in
  `appstored` for purchases only, so other apps' updates stay for the real device. This
  is the approach of [appstoretroller](https://github.com/mineek/appstoretroller), which
  rewrites the iOS version only.
- Before the download, `appstored` asks `installd` whether the device has the app's
  required capabilities. The answer is corrected only if every mismatch is a performance
  gate the chosen chip passes; a missing hardware capability keeps the refusal. The
  install itself is covered by **Ignore Device Model**.

The iOS version can only be raised. Apple ties the store's sign-in to the device's real
version, and a lower one ends in repeated password prompts and
`MZCommerce.ASN.Redownload.BadPasswordToken`. That's why the App Store entry only offers
newer versions. To get an older build that runs on the device, get the app with a raised
version, then turn the App Store entry off: the store then offers the last compatible
version, if there is one.

## Apply

One **Apply (Restart installd)** button on the main page makes everything live: the
install switches and every app's values. Apps pick up their values on their next launch,
so close a running app in the app switcher first.

`installd` has to restart to load changes. Apply posts a Darwin notification, the tweak
inside `installd` exits, and `launchd` starts it again. The state also lives in
`/var/tmp/com.soulrune.crossfamilyinstall.state`, which `installd` re-checks on every
install, so it applies even if `installd` wasn't running when a switch changed.
`appstored` gets the App Store values through cfprefsd, without a restart.

## Install

Get a `.deb` from [Releases](https://github.com/SoulRune/CrossFamilyInstall/releases) or
the [Actions artifacts](https://github.com/SoulRune/CrossFamilyInstall/actions), or build
it yourself ([BUILD.md](docs/BUILD.md)). Requires **PreferenceLoader**.

```bash
# rootless                                # rootful
make package                              make package THEOS_PACKAGE_SCHEME=
```

Then **Settings -> CrossFamilyInstall**, set the switches and tap **Apply**. If the panel
doesn't show up, respring.

## Compatibility

Confirmed on iPhone 8, iOS 16.7.10, rootless. The hooks rely on private frameworks with
no stability guarantee across iOS versions, so they fail safe: whatever isn't found on a
given iOS is logged and left alone, and `installd` / the App Store behave as stock. Check
`oslog` for `[CrossFamilyInstall]` and `[CrossFamilySpoof]` to see what was hooked.

## Known limits

- **tvOS apps will most likely crash on launch.** `dyld` refuses frameworks built for
  another platform; the tweak only clears the installer's check. iPad and iPhone share a
  platform, so those apps have a real chance of working.
- tvOS apps may show no icon on the home screen.
