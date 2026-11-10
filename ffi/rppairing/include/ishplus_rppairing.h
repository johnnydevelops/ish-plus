// Pairs iSH+ with the device it runs on (iOS 27+). See src/lib.rs.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef void (*ishplus_pairing_ready_cb)(void *ctx, const char *service_name, uint16_t port,
                                         const char *const *txt_keys, const char *const *txt_values, size_t txt_count);
typedef void (*ishplus_pairing_pin_cb)(void *ctx, const char *pin);

int32_t ishplus_pairing_run(const char *name, const char *model,
                            ishplus_pairing_ready_cb ready, ishplus_pairing_pin_cb pin, void *ctx,
                            uint8_t **out_file, size_t *out_len, char **out_device, char **out_error);
void ishplus_pairing_cancel(void);
void ishplus_pairing_free(uint8_t *data, size_t len);
void ishplus_pairing_free_string(char *s);
