[← Back to the README](../README.md)

# How iSH+ works

- **The app** (`app/`) runs QEMU (`deps/qemu`, a fork of UTM's QEMU) inside
  its own process: `VirtualMachine.swift`. Each terminal session is a virtio
  console of the VM.
- **JIT.** iOS only lets a process run code it generates if a debugger
  attached to it allocates that memory. The JIT helper extension
  (`app/JITHelper`) uses [StikJIT](https://github.com/StikDebug/StikJIT) to
  attach to iSH+ through LocalDevVPN and serve QEMU's requests for executable
  memory (`brk #0xf00d`, as in Madeira and StikDebug). Pairing on the device
  is `ffi/rppairing`, around [idevice](https://github.com/jkcoxson/idevice).
- **The guest.** Every distribution boots Debian's 16 KB-page kernel (or,
  with 4K Pages in Settings, Alpine's `linux-virt`) with iSH+'s initramfs
  (`tools/guest/boot/init`), which installs distributions on first boot and
  then starts the distribution's own init system, with iSH+'s part as one of
  its services (`tools/guest/boot/native.sh`): network, FEX, the shared
  folder, swap, and a shell on each console (`tools/guest/boot/main.sh`).
  With `ishplus.init=own`, `main.sh` is process 1 itself.
- **The desktop.** `tools/guest/boot/desktop.sh` starts Xorg or a Wayland
  compositor on virtio-gpu, with seat access from logind or seatd; iSH+ shows
  virtio-gpu's screen and cursor and sends input to an absolute tablet (touch
  mode) or a relative mouse (trackpad mode, a captured mouse).
- **Laptop mode** (`app/LaptopMode.swift`): the monitor is an external
  display scene (declared in `Info.plist`, which is enough on iOS 26; on iOS
  27 also registered as a scene accessory of the terminal's view controller,
  `registerSceneAccessory`, as MeloNX does), and the iPhone Duo's fold comes from `UIHingeInteraction` and
  the screen's division region.
- **Talking to iOS.** virtio-serial ports carry the clipboard, Shortcuts
  commands and the open ports (`tools/guest/agent`); DNS goes through iOS's
  resolver (`DNSProxy.swift`, with a small libslirp patch); the shared folder
  is virtio-9p.
- **Memory donors.** iOS ends a process whose memory passes its limit. Before
  QEMU starts, iSH+ starts its helper extension as a separate process, which
  allocates Linux's RAM and shares it over XPC; iSH+ maps it and ends the
  helper, after which the memory counts toward neither (`RamDonor.m`,
  `app/JITHelper/HelperHandler.m`, and a hook in QEMU's RAM allocation).
