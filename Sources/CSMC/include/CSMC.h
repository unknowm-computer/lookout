#ifndef LOOKOUT_CSMC_H
#define LOOKOUT_CSMC_H
#include <stdint.h>
// Apple's SMC user-client wire format. No arbitrary write API is exposed to Swift.
int32_t lookout_smc_open(uint32_t *connection);
void lookout_smc_close(uint32_t connection);
int32_t lookout_smc_read(uint32_t connection, const char *key, uint32_t *type, uint32_t *size, uint8_t bytes[32]);
int32_t lookout_smc_fan_target(uint32_t connection, int fan, double rpm);
int32_t lookout_smc_fan_auto(uint32_t connection, int fan);
#endif
