# CrossFamilyInstall - how the hook was found

> **Status: the symbol has already been found and is wired up in `Tweak.xm`**
> (`MIIsApplicableToCurrentDeviceFamilyWithError`, see `README.md`). This file is a
> log of how it was found (frida-trace -> hooking `NSError` creation -> backtrace).
> Kept as a reference in case the symbol turns out to be different on another iOS
> version and the hunt needs to be repeated - the steps below still apply.

## Method A (used, most reliable): hook NSError/CFError creation

Symbol-name guessing via `frida-trace` alone is unreliable - matches are noisy (every
loaded module's exports matching the pattern get instrumented, not just the ones that
actually fire), and `frida-trace`'s per-function handler cache can make it look like
nothing happened on a re-run. A much more targeted approach: don't guess which function
does the check - intercept the moment the resulting error gets created, since `installd`
almost certainly builds an `NSError`/`CFError` with a domain, code, and (often) a
human-readable description in `userInfo` right where the rejection happens.

1. Write a raw Frida script (not `frida-trace`) that hooks
   `+[NSError errorWithDomain:code:userInfo:]`, `-[NSError initWithDomain:code:userInfo:]`,
   and `CFErrorCreate`, logging domain/code/userInfo and a backtrace on every call.
2. Restart `installd` first (`launchctl kickstart -k user/foreground/com.apple.mobile.installd`)
   so you get a "cold" run, not a cached verdict (see the in-memory cache note below).
3. Attach: `frida -H <device-ip>:27042 -n installd -l hook_errors.js > errors.log 2>&1`.
4. Attempt to install an IPA built for a different device family (`UIDeviceFamily = [2]`
   for iPad-only, `[3]` for tvOS) while the script is attached.
5. In `errors.log`, look for the block whose `userInfo`/`NSLocalizedDescription` is
   clearly about device/family compatibility, not something unrelated (networking,
   disk, etc). The backtrace right under that block names the exact function chain -
   the top couple of frames above the error constructor are your hook target.

This is exactly how `MIIsApplicableToCurrentDeviceFamilyWithError` was found:

```
domain: MIInstallerErrorDomain
code:   10
FunctionName = MIIsApplicableToCurrentDeviceFamilyWithError
LegacyErrorString = DeviceFamilyNotSupported
NSLocalizedDescription = "This app was not built to support this device family; app is
  compatible with (3) but this device supports (1)"
```
Backtrace:
```
InstalledContentLibrary!MIIsApplicableToCurrentDeviceFamilyWithError
InstalledContentLibrary!-[MIBundle isApplicableToCurrentDeviceFamilyWithError:]
installd!-[MIInstallableBundle _verifyBundleMetadataWithError:]
installd!-[MIInstaller _installInstallable:containingSymlink:error:]
installd!-[MIInstaller performInstallationWithError:]
```

## Method B (fallback / cross-check): frida-trace + strings

If method A doesn't turn anything up (e.g. the error isn't built via `NSError`/`CFError`
at all), fall back to plain symbol-name tracing plus `strings`:

### Step 1. Get a live failure to work from
Take a known iPad-only or tvOS IPA (`UIDeviceFamily = [2]` or `[3]` in Info.plist) and
try to install it on iPhone by any means:
- `ipainstaller app.ipa` (ships with AppSync Unified via SSH/Filza),
- or straight through `installd` via any GUI manager (Filza -> tap the .ipa).

The install should fail. Note the exact error text/code - it's a `grep` hint for step 5.

### Step 2. Set up frida-server (rootless build)
Add a repo with `frida`/`re.frida.server` for jailbreak (available in most rootless
repos, or build it yourself for rootless). On your computer:

```bash
pip install frida-tools --break-system-packages
frida-ps -U   # confirms it sees the device
```

### Step 3. Trace installd at the moment of install
```bash
frida-trace -U -n installd \
  -i "*Family*" -i "*DeviceClass*" -i "*Constraint*" \
  -i "*Compat*" -i "*Validate*"
```
Keep the trace running and repeat the iPad/tvOS install from step 1 while it's attached.
The output shows which of the instrumented functions actually fired right before the
failure - that's your target.

If nothing gets caught, check the `MobileInstallation` framework specifically instead of
`installd` (validation is sometimes delegated there):
```bash
frida-trace -U -n installd -i "*Family*" -m "*MIInstallable*Validate*"
```

### Step 4. Pin down the exact signature
Once you know the function name, check its export and, where possible, its demangled
signature (Objective-C methods are usually self-explanatory from the name):
```bash
frida -U -n installd -e "
  var m = Module.findExportByName(null, 'FUNCTION_NAME');
  console.log(m);
"
```
For Objective-C methods (`-[Class method:]`), it's easier to inspect via
`ObjC.classes.ClassName['- method:'].implementation`.

### Step 5. Grep for the error string (alternative/confirmation)
The error text from step 1 is often literally embedded right next to the check:
```bash
# over SSH on the device, or scp the framework to your computer
strings -a /System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation \
  | grep -i -E "family|device class|not supported"
```
Once you have the string, look in `nm`/`class-dump` (or jtool2/Hopper if obfuscation
allows) for the function/method that references it.

### Step 6. Wire the symbol into Tweak.xm - already done
As of this file, the found symbol (`MIIsApplicableToCurrentDeviceFamilyWithError`,
`InstalledContentLibrary`) is already wired into `Tweak.xm`. If the function name turns
out different on another iOS version, repeat steps 1-5 (or Method A) and replace
`TARGET_SYMBOL` in `Tweak.xm`.

## In-memory verdict cache

`installd` is a long-running daemon and appears to memoize install verdicts in-process
(keyed by package hash, most likely) - a repeat attempt with the *same* IPA file returns
instantly instead of re-running full validation. This isn't on disk (checked
`PublicStaging`, `installd`'s cache dir, `appstored` - all empty after a "fast" repeat),
so it doesn't survive a daemon restart. Two practical implications:

- Always restart `installd` (`launchctl kickstart -k user/foreground/com.apple.mobile.installd`)
  before a "clean" test - otherwise you might be looking at a stale cached verdict from
  an earlier attempt instead of the hook's actual current behavior.
- When testing hook changes, either restart `installd` between attempts or slightly
  modify the test IPA (even one byte) so its hash differs - otherwise you may think the
  hook isn't working when you're actually just hitting the cache.

## Important tvOS warning

Even after a successful installer-level patch, tvOS binaries link against a different
set of system frameworks - they will most likely just crash on launch on iOS. Confirmed
via crash log: `dyld` refuses to load an embedded framework built for tvOS into an iOS
process ("wrong platform to load into process"), which is a separate, deeper check than
`UIDeviceFamily` and lives inside `dyld` itself, not `installd`. The family patch only
answers "does it install", not "does it run". iPhone and iPad shares the same underlying
platform/UIKit, so the odds of a fully working result are much better there.
