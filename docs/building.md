[← Back to the README](../README.md)

# Building iSH+

You need a Mac with Xcode 27 and [Homebrew](https://brew.sh):

```sh
brew install meson ninja pkg-config glib squashfs patchelf llvm
rustup target add aarch64-apple-ios
git clone --recurse-submodules https://github.com/johnnydevelops/ish-plus.git
cd ish-plus
tools/build-qemu-ios.sh      # QEMU and its libraries for iOS (deps/qemu),
                             # with GPU acceleration (ANGLE, virglrenderer,
                             # MoltenVK); without it: ... fetch deps qemu qemu-tci
tools/fetch-stikjit.sh       # StikJIT, for the JIT helper
tools/make-guest-kernel.sh   # the 4 KB-page kernel (Alpine's), initramfs and modules
tools/make-guest-kernel-16k.sh  # the default kernel, Debian's with 16 KB pages
tools/make-guest-support.sh  # the guest support disk (FEX, iSH+'s init and tools)
```

Then set `ROOT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` in `app/iSH.xcconfig`
to your own, open `iSH.xcodeproj` and run the iSH scheme on a device, or run
`tools/package-ipa.sh` for a `.ipa` that sideloaders sign.
