[← Back to the README](../README.md)

# GPU acceleration

With **GPU Acceleration** on (Settings > Linux VM > Graphics), Linux gets a
virtual GPU (virtio-gpu with [VirGL](https://docs.mesa3d.org/drivers/virgl/)):
its OpenGL runs on the iPad's GPU through ANGLE and Metal, the desktop's X
server draws with it (glamor), and the screen goes to iSH+ as GPU surfaces,
with no copies. OpenGL programs (`glxgears`, `glxinfo -B` from `mesa-utils`)
use it as they are.

**Vulkan** (experimental, a second switch) adds Venus: Linux's Vulkan runs on
the GPU through [MoltenVK](https://github.com/KhronosGroup/MoltenVK), and
OpenGL 3.1 is also available through it with zink
(`MESA_LOADER_DRIVER_OVERRIDE=zink`). Install `mesa-vulkan-drivers` and
`vulkan-tools` (`vulkaninfo`, `vkcube`) in Linux. On A13 and older chips,
which have no Metal mesh shaders, Vulkan has no geometry shaders, so zink
draws flat-shaded faces with the first vertex's colour rather than the last
one's.

Instant resume is not available with GPU acceleration, and iSH+ pauses the
GPU while it is in the background. Both switches take effect when Linux
restarts.
