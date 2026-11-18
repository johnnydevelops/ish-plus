[← Back to the README](../README.md)

# Installing and setup

1. Download the `.ipa` from the [releases](https://github.com/johnnydevelops/ish-plus/releases) and sideload it
   (AltStore, SideStore, iloader, Feather...). JIT works with any of them:
   nothing to set up.
   Security keys over NFC (on iPhone) also need the signing profile to have
   the **NFC Tag Reading** capability: see below.
2. Install and connect [LocalDevVPN](https://apps.apple.com/search?term=LocalDevVPN),
   with Developer Mode on.
3. Open iSH+ and follow the setup: pair it with your device, then choose a
   distribution and create your account. On iOS 27, Pair With This Device does
   it on the device. Before iOS 27, make a pairing file on a computer with
   [iloader](https://iloader.app) (connect the device by USB, then **Manage
   Pairing File**) or StikPair, and import it.

LocalDevVPN only needs to be connected while iSH+ enables JIT, when Linux
starts; JIT stays on without it. If you use another VPN, such as Tailscale,
add the **iSH+ JIT** shortcut during setup (or in Settings > JIT Setup), on
iOS 27: when Linux starts, it switches to LocalDevVPN, and back to your VPN
once JIT is on (like Madeira's JIT shortcut).

Requires iOS 18 or later (iOS 27 to pair on the device; iOS 27.1 for the
iPhone Duo's laptop mode). Laptop mode on a monitor is tested on iOS 26 and
later, over a cable or AirPlay. Before iOS 26, iSH+ looks the same but without
Liquid Glass.

## Jailbroken devices

On a jailbroken device iSH+ also gets JIT from the jailbreak, with no
LocalDevVPN or pairing file: it starts Linux right away when the jailbreak
lets apps run JIT code (Dopamine does), or when iSH+ is installed with the
`dynamic-codesigning` entitlement (for example through TrollStore). After a
reboot without the jailbreak, the normal setup above applies.

## iSH+'s own init

Distributions boot with their own init system. For the least memory (it
saves about 10 MB on Alpine and 60 MB on Ubuntu), iSH+'s own init can start
them instead, as earlier versions did, without services: put
`ishplus.init=own` in the file **VM/append** in iSH+'s folder (Files > iSH+),
and restart Linux.

## Sideloaders and entitlements

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
