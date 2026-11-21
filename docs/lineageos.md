[← Back to the README](../README.md)

# LineageOS 17.1 (Android 10) on iSH+

iSH+ can boot a real **Android 10 (LineageOS 17.1, vanilla / no-GApps)**
inside the guest Linux VM, using **Waydroid + LXC** containerization on top
of the existing Debian 6.12 ARM64 kernel. Android's SurfaceFlinger is
routed through iSH+'s existing **virglrenderer + ANGLE (Metal) + MoltenVK**
GPU pipeline, so 3D apps render on the device's GPU the same way Linux
desktops do.

This is the lightest path to Android on an Apple A13 Bionic device
(iPhone 11 / iPhone SE 2nd Gen / iPad 9th Gen, 3 GB – 4 GB RAM).

## Why LineageOS 17.1 (Android 10)

| Android version | RAM at idle | AOT-compile churn | ART heap pressure | Notes |
| --- | --- | --- | --- | --- |
| **10 (LineageOS 17.1)** | **~450 MB** | none on first boot | low | **picked** |
| 11 (LineageOS 18.1) | ~600 MB | medium | medium | scoped storage enforcement breaks legacy apps |
| 13 (LineageOS 20) | ~900 MB | high on first boot | high | too much for a 3 GB A13 device |

Android 10 is the last release Waydroid supports without aggressive
memory-tuning hacks, and the last one whose `lmkd` policy can keep a 1.4 GB
slice stable under iOS `jetsam`.

## Architecture

```
            ┌─────────────────── iSH+ (iOS app, A13) ──────────────────┐
            │                                                            │
            │  QEMU (libqemu-aarch64-softmmu.dylib, JIT via StikJIT)     │
            │    │                                                       │
            │    ├─ 16 KB-page ARM64 Debian 6.12 kernel                  │
            │    │    (binderfs, ashmem, zram, uinput, sync_file kept)   │
            │    │                                                       │
            │    ├─ Debian/Alpine guest rootfs (host Linux)               │
            │    │    ├─ /dev/binderfs           (binder IPC)            │
            │    │    ├─ /var/lib/waydroid/images                          │
            │    │    │    ├─ system.img  (LineageOS 17.1 squashfs, ro)   │
            │    │    │    └─ vendor.img  (LineageOS 17.1 squashfs, ro)   │
            │    │    ├─ waydroid session + container (LXC)              │
            │    │    └─ wlroots compositor (sway / labwc / weston)       │
            │    │         │ EGL → Mesa virgl → virglrenderer             │
            │    │         │                                   │          │
            │    │         │ SurfaceFlinger ◀── gralloc=gbm, egl=mesa    │
            │    │         │ hwcomposer blits Android's layer to a       │
            │    │         │ Wayland surface on the compositor            │
            │    │                                                         │
            │    └─ virtio-gpu  →  ANGLE (Metal)  →  A13 GPU              │
            │                       (MoltenVK for Vulkan / Venus)         │
            │                                                            │
            └──────────── 3 GB / 4 GB device RAM ────────────────────────┘
```

There is no SwiftShader anywhere on the path: every GL call from an
Android app hits the Metal GPU.

## Memory budget on an A13 device (3 GB / 4 GB)

iOS `jetsam` kills any app whose resident footprint grows past its limit.
With the `com.apple.developer.kernel.increased-memory-limit` +
`extended-virtual-addressing` entitlements (kept in this build), iSH+
gets roughly 1.85 GB on a 3 GB device. Of that, ~450 MB is QEMU's
translated-code cache and the app's own footprint.

The LineageOS container is sized to fit:

| Component | 3 GB device | 4 GB device |
| --- | --- | --- |
| Linux VM RAM (MeloNX donor) | 1436 MB | 1740 MB |
| Android (LineageOS 17.1 idle) | ~450 MB | ~450 MB |
| zram compressed swap (lz4) | ~700 MB | ~870 MB |
| iOS + iSH+ app + QEMU cache | ~1.6 GB | ~2.3 GB |
| `jetsam` headroom | ~150 MB | ~150 MB |

The cap is enforced in `app/VMSettings.swift::maximumMemoryMB` when
`Documents/VM/android` contains `1`. Without that flag the VM picks its
size as before, so the Android container is opt-in.

### `lmkd` + `zram` interaction

Android 10's `lmkd` uses PSI (Pressure Stall Information) to free pages
before the host runs out. iSH+ ships `CONFIG_PSI=y` in the kernel config
fragment (`deps/android-waydroid.config`), and the Android build.prop
overrides (written by `tools/guest/boot/android.sh` on every start) set:

```
ro.lmk.critical=15          # free memory below 15% triggers kills
ro.lmk.low=80               # below 80% starts reclaim
ro.lmk.kill_heaviest_task=true
dalvik.vm.heapsize=256m      # ART heap ceiling
dalvik.vm.heapgrowthlimit=128m
```

`zram` (lz4) runs at half the VM's RAM and a `swappiness` of 60 — the
Android working set compresses 2–3×, so a 700 MB swap device absorbs a
~1.5 GB working set without ever paging out to iOS storage.

## Kernel requirements

The guest kernel needs these subsystems enabled. `deps/android-waydroid.config`
is the manifest; `tools/make-guest-kernel-16k.sh` keeps the corresponding
modules in the trimmed `modloop`:

- `CONFIG_ANDROID_BINDER_IPC=y`, `CONFIG_ANDROID_BINDERFS=y` — Android IPC
- `CONFIG_ASHMEM=y`, `CONFIG_MEMFD_CREATE=y` — shared memory (Android 10
  uses both; ashmem is removed in 11+)
- `CONFIG_PSI=y` — `lmkd` pressure source
- Namespaces (`UTS`, `IPC`, `PID`, `NET`, `USER`, `CGROUP`) + cgroups v2
  controllers (`MEMCG`, `CPUACCT`, `PIDS`, `DEVICE`, `BPF`) — LXC backend
- `CONFIG_ZRAM=y` + `CONFIG_ZSMALLOC=y` + lz4 — compressed swap in RAM
- `CONFIG_OVERLAY_FS=y`, `CONFIG_SQUASHFS=y`, `CONFIG_BLK_DEV_LOOP=y` —
  the LineageOS image-set is mounted as squashfs and overlaid
- `CONFIG_DRM_VIRTIO_GPU=y`, `CONFIG_SYNC_FILE=y`, `CONFIG_SW_SYNC=y` —
  the dma-buf fence path SurfaceFlinger uses against virtio-gpu
- `CONFIG_INPUT_UINPUT=y` — input injection into the container
- `CONFIG_BINFMT_MISC=y` — FEX x86_64 emulation (still useful for some
  Android NDK binaries)

Debian's stock `linux-image-arm64-16k` (6.12.y) already builds these as
modules; the `make-guest-kernel-16k.sh` trim pass keeps them. If you
build a custom kernel, merge `deps/android-waydroid.config` as a kconfig
fragment with `scripts/kconfig/merge_config.sh`.

## Waydroid image-set

`tools/waydroid/fetch-lineagos-17.sh` downloads the vanilla (no-GApps)
LineageOS 17.1 ARM64 `system.img` + `vendor.img` from Waydroid's
SourceForge release. They are **not** bundled into the `.ipa` (the file
would blow past AltStore's sideload size limit); the guest fetches them on
first Android start via `tools/guest/boot/android.sh`.

If you are building for an offline device, pre-place the images at
`build-guest/android/system.img` and `vendor.img`; `make-guest-support.sh`
will pick them up and bundle them as a squashfs on the support disk.

## Starting Android

Once iSH+ boots Linux, run inside the guest terminal:

```sh
# One-time install of Waydroid + LXC, and the image-set fetch
/opt/ishplus/boot/android.sh install

# Start the Android session (SurfaceFlinger attaches to the active
# Wayland desktop; start a desktop first with the Desktop button)
/opt/ishplus/boot/android.sh start
```

Or enable the container permanently by writing `1` to the file
`~/iOS/VM/android` from the Files app — the VM will then boot with the
Android-tuned memory cap described above.

## Building the .ipa

The CI workflow at `.github/workflows/build-ipa.yml` builds everything
end-to-end on `macos-15`:

1. Submodule checkout (`deps/qemu`, `deps/SwiftTerm`)
2. Homebrew deps (cmake, ninja, meson, pkg-config, rust, squashfs, ...)
3. QEMU + GPU stack: ANGLE, libepoxy, virglrenderer, MoltenVK
4. Guest kernel (4 KB Alpine + 16 KB Debian with Android modules)
5. Support disk (Waydroid installer, `android.sh`)
6. `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`
7. `tools/package-ipa.sh` → `iSH-Plus-LineageOS17-Android10-A13.ipa`

The .ipa is ad-hoc signed and sideloadable via SideStore / AltStore /
Feather. NFC Tag Reading is omitted (paid-account entitlement); opt back
in by triggering the workflow with the `include_nfc` input, or by running
`ISH_INCLUDE_NFC=1 ./tools/package-ipa.sh` locally.

## Limitations

- **No Google services.** LineageOS 17.1 vanilla ships without GApps.
  Install [F-Droid](https://f-droid.org) or [Aurora Store](https://auroraoss.com)
  inside the container for app distribution.
- **No camera, no telephony, no GPS.** Waydroid has no HALs for these on
  a virtio-gpu-only guest.
- **Single-user.** The container boots straight to the launcher; no lock
  screen. (Add one with a third-party lockscreen app if you need it.)
- **Background pause.** iOS suspends GPU work when iSH+ is in the
  background; Android freezes too. Resuming is instant (no GPU state
  to restore, unlike a saved Linux state).
- **A13-only Vulkan caveat.** A13 has no Metal mesh shaders, so zink
  draws flat-shaded faces with the first vertex's colour. OpenGL ES 2/3
  apps are unaffected.
