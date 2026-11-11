# iSH+

A Linux terminal for iPad and iPhone that runs a **real Linux kernel** in a
virtual machine, with the distribution of your choice.

iSH+ is a fork of [iSH](https://github.com/ish-app/ish). iSH emulates an x86
processor and translates Linux system calls itself; iSH+ instead runs Linux
6.18 in [QEMU](https://www.qemu.org) (arm64, with JIT), so programs see a
genuine Linux system. It needs JIT, so it is sideloaded rather than on the App
Store, and iSH+ can enable JIT by itself, without a computer.

**[Add the iSH+ source to SideStore](https://intradeus.github.io/http-protocol-redirector?r=sidestore%3A%2F%2Fsource%3Furl%3Dhttps%3A%2F%2Fraw.githubusercontent.com%2Fjohnnydevelops%2Fish-plus%2Fmain%2Fsource.json)** to get new versions as
updates, or add `https://raw.githubusercontent.com/johnnydevelops/ish-plus/main/source.json` as a source in SideStore, AltStore or Feather.

## Features

- **Any distribution.** Alpine, Debian, Ubuntu, Arch, Artix, Fedora,
  openSUSE, Void, Kali, Rocky, Alma and more, downloaded in the app
  (Settings > Distributions), each with your own user account. Switch between
  them, grow their disks, delete them.
- **Fast.** QEMU's JIT, enabled in the app: iSH+ pairs with your device (iOS
  27, like StikPair) or uses a pairing file, and attaches a debugger to
  itself through LocalDevVPN. StikDebug works as a fallback, and Linux can
  also run without JIT, much more slowly.
- **x86_64 programs** run through [FEX](https://fex-emu.com): just run them.
  `apt-x86 install <package>` adds x86_64 Ubuntu packages and `x86 <command>`
  runs them; glibc and musl programs both work.
- **A native terminal** ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm))
  with Liquid Glass, mouse input for programs that use the mouse, scrolling
  like Termux, several sessions, themes and fonts. Linux keeps running in the
  background.
- **Servers open in your browser.** Start a server in Linux and it is at
  `localhost:<port>` on the iPad (sessions menu > Open in Browser), or on your
  network if you share it (Settings > Linux VM).
- **A desktop.** Install Xorg and a desktop or window manager in Linux (for
  example `apt install xorg xfce4`) and the sessions menu gets a **Desktop
  Session**, with touch controls like UTM's: trackpad or touch mode, tap to
  click, two-finger tap to right-click, two-finger scroll, pinch to zoom.
- **Instant resume.** Without "Keep Running in Background", Linux is saved
  when iSH+ goes to the background; if iOS closes iSH+, you can resume where
  you were.
- **iOS integration.** Files > iSH+ > Shared is `~/iOS` in Linux; `pbcopy`
  and `pbpaste` use the iOS clipboard; the Run Command action runs commands
  from Shortcuts. Tailscale and other VPNs work, names included.
- **More memory for Linux.** Linux's RAM is held by a helper process, so it
  does not count toward the memory iOS lets iSH+ use (MeloNX's RAM donor
  technique): Linux can have up to 60% of the device's RAM.
- **Settings** for memory and CPU cores (automatic for your device), open
  ports, appearance and external keyboards.

## Installing

1. Download the `.ipa` from the [releases](../../releases) and sideload it
   (AltStore, SideStore, iloader, Feather...). JIT works with any of them:
   nothing to set up.
   Security keys over NFC (on iPhone) also need the signing profile to have
   the **NFC Tag Reading** capability: see below.
2. Install and connect [LocalDevVPN](https://apps.apple.com/search?term=LocalDevVPN),
   with Developer Mode on.
3. Open iSH+ and follow the setup: pair it with your device (Pair With This
   Device on iOS 27, or a pairing file such as StikPair's), then choose a
   distribution and create your account.

LocalDevVPN only needs to be connected while iSH+ enables JIT, when Linux
starts; JIT stays on without it. If you use another VPN, such as Tailscale,
add the **iSH+ JIT** shortcut during setup (or in Settings > JIT Setup), on
iOS 27: when Linux starts, it switches to LocalDevVPN, and back to your VPN
once JIT is on (like Madeira's JIT shortcut).

Requires iOS 26 or later (iOS 27 to pair on the device).

### Sideloaders and entitlements

JIT needs nothing special: sideloaders sign with development certificates,
which always allow debugging (`get-task-allow`), and that is all it needs.
Two other features need entitlements, which your sideloader has to apply when
it signs iSH+:

| Feature | Entitlement | Without it |
| --- | --- | --- |
| More memory for Linux | `com.apple.developer.kernel.increased-memory-limit`, `extended-virtual-addressing` | iSH+ measures the limit iOS gives it and picks a smaller VM |
| Security keys over NFC (iPhone) | `com.apple.developer.nfc.readersession.formats` | `ssh` with `sk-` keys fails |

These typically need a paid Apple Developer account. Sideloaders also differ in which entitlements
they apply. iloader, for example, applies the increased memory limit but not
NFC, even with a paid account, so iSH+ installed with it cannot use security
keys. For security keys, sign with a paid account using a sideloader that
keeps the app's entitlements (for example Sideloadly, or Feather with your own
certificate and a provisioning profile that includes NFC Tag Reading).

## Building

You need a Mac with Xcode 27 and [Homebrew](https://brew.sh):

```sh
brew install meson ninja pkg-config glib squashfs patchelf llvm
rustup target add aarch64-apple-ios
git clone --recurse-submodules https://github.com/johnnydevelops/ish-plus.git
cd ish-plus
tools/build-qemu-ios.sh      # QEMU and its libraries for iOS (deps/qemu)
tools/fetch-stikjit.sh       # StikJIT, for the JIT helper
tools/make-guest-kernel.sh   # the Linux kernel, initramfs and modules
tools/make-guest-support.sh  # the guest support disk (FEX, iSH+'s init and tools)
```

Then set `ROOT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` in `app/iSH.xcconfig`
to your own, open `iSH.xcodeproj` and run the iSH scheme on a device, or run
`tools/package-ipa.sh` for a `.ipa` that sideloaders sign.

## How it works

- **The app** (`app/`) runs QEMU (`deps/qemu`, a fork of UTM's QEMU) inside
  its own process: `VirtualMachine.swift`. Each terminal session is a virtio
  console of the VM.
- **JIT.** iOS only lets a process run code it generates if a debugger
  attached to it allocates that memory. The JIT helper extension
  (`app/JITHelper`) uses [StikJIT](https://github.com/StikDebug/StikJIT) to
  attach to iSH+ through LocalDevVPN and serve QEMU's requests for executable
  memory (`brk #0xf00d`, as in Madeira and StikDebug). Pairing on the device
  is `ffi/rppairing`, around [idevice](https://github.com/jkcoxson/idevice).
- **The guest.** Every distribution boots Alpine's `linux-virt` kernel with
  iSH+'s initramfs (`tools/guest/boot/init`), which installs distributions on
  first boot and then starts iSH+'s own init from the support disk
  (`tools/guest/boot/main.sh`): network, FEX, the shared folder, and a shell on
  each console. The distribution's own init system does not run.
- **Talking to iOS.** virtio-serial ports carry the clipboard, Shortcuts
  commands and the open ports (`tools/guest/agent`); DNS goes through iOS's
  resolver (`DNSProxy.swift`, with a small libslirp patch); the shared folder
  is virtio-9p.
- **Memory donors.** iOS ends a process whose memory passes its limit. Before
  QEMU starts, iSH+ starts its helper extension as a separate process, which
  allocates Linux's RAM and shares it over XPC; iSH+ maps it and ends the
  helper, after which the memory counts toward neither (`RamDonor.m`,
  `app/JITHelper/HelperHandler.m`, and a hook in QEMU's RAM allocation).

## Credits and licenses

iSH+ is licensed like iSH, under the GPL version 3 (with the terms in
`LICENSE.IOS`), and version 2 for code since iSH's relicensing, so it can be
used with QEMU and Linux: see `LICENSE.md`. It builds on:

- [iSH](https://github.com/ish-app/ish) by Theodore Dubois and contributors
- [QEMU](https://www.qemu.org) (GPL-2.0) and [UTM](https://github.com/utmapp/UTM)'s
  iOS work on it, [libslirp](https://gitlab.freedesktop.org/slirp/libslirp)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT)
- [StikJIT](https://github.com/StikDebug/StikJIT) (MPL-2.0), downloaded at
  build time, and [idevice](https://github.com/jkcoxson/idevice) (MIT)
- [FEX](https://fex-emu.com) (MIT), with Ubuntu's x86_64 base system
- [Alpine Linux](https://alpinelinux.org)'s kernel, initramfs and tools, and
  the distributions from [Linux Containers](https://images.linuxcontainers.org)
  and [Armtix](https://armtix.artixlinux.org)
- Distribution logos from [Simple Icons](https://simpleicons.org) (CC0); they
  are trademarks of their owners
- [MeloNX](https://starforgejo.dev/projects/MeloNX)'s RAM donor technique, by
  Stossy11 (MIT)
- The ideas of [Madeira](https://github.com/willfaust/Madeira),
  [StikDebug](https://github.com/StikDebug/StikDebug) and StikPair for
  enabling JIT on the device
