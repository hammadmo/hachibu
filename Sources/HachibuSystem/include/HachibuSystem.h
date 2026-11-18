#ifndef HACHIBU_SYSTEM_H
#define HACHIBU_SYSTEM_H

#include <stdbool.h>
#include <stdint.h>

// The two places Hachibu reaches below public macOS APIs. Both were probed
// on macOS 27.2 (docs/research/charge-control.md).

/// Reads one key from the SMC (the battery controller). No root needed.
/// Returns the number of bytes read, or 0 when the key is missing or locked.
/// `type` receives the key's four-character type, for example "flt ".
int hb_smc_read(const char *key, uint8_t *bytes, int capacity, char type[5]);

/// True when this macOS can hold a charge limit (PowerUI's "MCL").
bool hb_limit_supported(void);

/// The limit macOS is holding. Returns false when it cannot be read.
bool hb_limit_get(int *limit, bool *enabled);

/// The limits macOS offers without administrator rights. Returns how many.
int hb_limit_available(int *limits, int capacity);

/// Asks macOS to hold `limit`, turning the limit on first when it is off.
/// On failure returns false and writes why into `error`.
bool hb_limit_set(int limit, char *error, int error_capacity);

/// Turns the limit off, so charging goes to 100%.
bool hb_limit_disable(char *error, int error_capacity);

/// True while macOS charges to 100% on its own to keep its estimates accurate.
bool hb_full_charge_override(void);

#endif
