# Building CrossFamilyInstall

Builds both a rootless **and** a rootful `.deb` from the same source tree. Theos works
fine on Linux - macOS isn't required for a basic build, **but see the arm64e warning
below - it matters more here than in a typical tweak**. These steps target plain
Debian, including **WSL Debian** on Windows. (GitHub Actions CI does the same thing
automatically - see `.github/workflows/build.yml`.)

## installd is a system daemon, not a regular app

Unlike tweaks that hook regular App Store apps (where an arm64-only build is fine on
any device), the target is **`installd`**, a system daemon. On A12+ devices (iPhone XS
and newer), system processes - SpringBoard, daemons, `Preferences` - run as **arm64e**,
not arm64. A Linux-toolchain arm64-only build **will not inject into `installd` on such
devices** - the tweak will silently do nothing (you'll see "symbol NOT FOUND" in the
log, or nothing at all - no injection happens).

- **A11 or older** (iPhone 8/X, the iOS ceiling for these models) - arm64-only with
  Linux is fine, follow steps 0-3 below.
- **A12 or newer** - an arm64e slice is required; build on macOS (section below) or use
  a prebuilt CI artifact (Actions -> latest run -> artifact).

## 0. (Windows only) Install WSL Debian

In an elevated PowerShell:

```powershell
wsl --install -d Debian
```

Reboot if prompted, launch **Debian**, create a user. Everything below runs **inside**
the Debian shell.

## 1. System packages

```bash
sudo apt update
sudo apt install -y \
    build-essential git perl curl ca-certificates \
    fakeroot zip unzip rsync dpkg-dev \
    libtinfo5 libncurses5 libz3-dev \
    llvm
```

> `llvm` provides Mach-O-compatible `llvm-strip`/`llvm-lipo`/`llvm-install-name-tool`,
> which the Swift toolchain below doesn't ship. `libtinfo5`/`libncurses5` are needed by
> Theos's Linux toolchain (available in Debian 12's standard repos).

## 2. Install Theos (toolchain + SDK)

> The one-line `install-theos` script often fails on Linux with `xz: File format not
> recognized`. The manual steps below are more reliable.

```bash
export THEOS=~/theos
echo 'export THEOS=~/theos' >> ~/.profile

git clone --recursive https://github.com/theos/theos.git $THEOS
rm -rf $THEOS/sdks
git clone --depth=1 https://github.com/theos/sdks.git $THEOS/sdks

# Linux toolchain (clang/lld; enough for Objective-C tweaks).
mkdir -p $THEOS/toolchain/linux/iphone
url=$(curl -fsSL https://api.github.com/repos/kabiroberai/swift-toolchain-linux/releases/latest \
      | grep browser_download_url | grep 'ubuntu22.04.tar.xz' | grep -v aarch64 \
      | head -n1 | cut -d'"' -f4)
curl -L --fail --retry 5 --retry-delay 3 "$url" -o /tmp/toolchain.tar.xz
file /tmp/toolchain.tar.xz   # should say "XZ compressed data"; if it says HTML, retry curl
tar -xf /tmp/toolchain.tar.xz -C $THEOS/toolchain/linux/iphone --strip-components=1

TC=$THEOS/toolchain/linux/iphone
[ -d "$TC/host/bin" ] && ln -sfn host/bin "$TC/bin" && ln -sfn host/lib "$TC/lib"

# clang invokes the linker as "ld"; lld picks ELF vs Mach-O based on argv[0]. Wrap it
# so it re-invokes lld as ld64.lld (Mach-O mode).
rm -f "$TC/host/bin/ld"
printf '#!/bin/sh\nexec "$(dirname "$0")/ld64.lld" "$@"\n' > "$TC/host/bin/ld"
chmod +x "$TC/host/bin/ld"

# Alias the cctools names Theos invokes to the system LLVM tools.
LLVMDIR=$(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -V | tail -1)
for pair in strip:llvm-strip lipo:llvm-lipo install_name_tool:llvm-install-name-tool \
            nm:llvm-nm otool:llvm-otool objcopy:llvm-objcopy ranlib:llvm-ranlib dsymutil:dsymutil; do
  name=${pair%%:*}; src=${pair##*:}
  [ -x "$LLVMDIR/$src" ] && ln -sfn "$LLVMDIR/$src" "$TC/host/bin/$name"
done

$TC/bin/clang --version
source ~/.profile
```

### Signing tool (ldid)

```bash
url=$(curl -fsSL https://api.github.com/repos/ProcursusTeam/ldid/releases/latest \
      | grep browser_download_url | grep 'ldid_linux_x86_64"' | head -n1 | cut -d'"' -f4)
curl -L --fail --retry 5 "$url" -o $THEOS/bin/ldid && chmod +x $THEOS/bin/ldid
```

If `clang` complains about `libtinfo.so.5` (and you only have `libtinfo6`):

```bash
sudo ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
```

## 3. Build (Linux/WSL - A11 and older only, see warning above)

```bash
cd /path/to/CrossFamilyInstall

# rootless .deb (Dopamine, palera1n rootless, ellekit) - iOS 14.0+
make package

# rootful .deb (palera1n rootful, checkra1n, unc0ver) - same source
make package THEOS_PACKAGE_SCHEME=
```

> Building from a Windows checkout under `/mnt/d/...`? Normalize line endings first, or
> `make`/`dpkg` will choke on them:
> `find . -name Makefile -o -name control | xargs sed -i 's/\r$//'`

Built packages land in `./packages/`.

## Building on macOS (arm64 + arm64e) - required for A12+ devices

The Xcode toolchain provides arm64e, and `lipo` merges the slices - this is the only
build that actually injects into `installd` on modern devices. This is exactly what CI
(`.github/workflows/build.yml`) runs on a `macos-15` runner.

```bash
# tools
brew install ldid dpkg make
export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"   # GNU make 4+

# theos (uses the installed Xcode iPhoneOS SDK)
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS

# build both schemes, both slices
make package FINALPACKAGE=1 ARCHS="arm64 arm64e"                          # rootless
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME= ARCHS="arm64 arm64e"    # rootful
```

Don't have a Mac? Not a problem - **GitHub Actions CI does exactly this** on every
push/PR, free for a public repo. Grab the built `.deb`s (arm64+arm64e, both schemes)
from the **Actions -> latest run -> Artifacts** tab, or from **Releases** if a tag was
pushed.

## 4. Install on device

```bash
scp packages/*.deb mobile@<device-ip>:/var/mobile/
ssh root@<device-ip> 'dpkg -i /var/mobile/com.soulrune.crossfamilyinstall_*.deb; launchctl kickstart -k user/foreground/com.apple.mobile.installd'
```

Then: **Settings -> CrossFamilyInstall** -> turn the switch on.

## Troubleshooting

- **Tweak doesn't load / silent or "symbol NOT FOUND" in the log on an A12+ device** -
  almost certainly the arm64e issue, see the warning at the top of this file. Rebuild
  with `ARCHS="arm64 arm64e"` on macOS or CI.
- **`No rule to make target` / odd syntax errors** - almost always CRLF line endings,
  see the `sed` note above.
- **`installd` doesn't pick up a switch change** - tap **Apply** in the settings panel
  (posts a Darwin notification, the tweak exits installd itself so launchd relaunches
  it). If you're testing over SSH instead, you can trigger the same thing directly:
  `killall -9 installd` (as root) - `launchd` will restart it. Either way, `installd`
  re-checks the state file (`/var/tmp/com.soulrune.crossfamilyinstall.state`) on every
  compatibility check, so a change made while it wasn't running is still picked up.
  To inspect it: `cat /var/tmp/com.soulrune.crossfamilyinstall.state` (bitmask:
  1 = family, 2 = device model, 4 = iOS version) and `ls -l` it - it should be `-rw-rw-rw-`.
