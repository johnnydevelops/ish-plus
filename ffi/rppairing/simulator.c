// Stand-ins for the simulator, which has no device to pair with (and no
// JIT): tools/build-rppairing.sh builds these instead of the Rust library
// for simulator builds. Same interface as include/ishplus_rppairing.h.
#include <stddef.h>
#include <stdint.h>
#include "include/ishplus_rppairing.h"

int32_t ishplus_pairing_run(const char *name, const char *model,
                            ishplus_pairing_ready_cb ready, ishplus_pairing_pin_cb pin, void *ctx,
                            uint8_t **out_file, size_t *out_len, char **out_device, char **out_error) {
    return -1;
}
void ishplus_pairing_cancel(void) {}
void ishplus_pairing_free(uint8_t *data, size_t len) {}
void ishplus_pairing_free_string(char *s) {}
