#include "CSMC.h"
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <os/log.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key; Version version; Limits limits; KeyInfo info;
    uint8_t result, status, command; uint32_t data; uint8_t bytes[32];
} Packet;
_Static_assert(sizeof(Packet) == 80, "SMC packet ABI changed");
static uint32_t fourcc(const char *s) {
    return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16 | (uint32_t)(uint8_t)s[2]<<8 | (uint8_t)s[3];
}
static int32_t call(uint32_t connection, Packet *in, Packet *out) {
    size_t size = sizeof(*out);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, in, sizeof(*in), out, &size);
    if (result != KERN_SUCCESS) return result;
    if (size == sizeof(*out) && out->result == 0x84) return kIOReturnNotFound;
    return size == sizeof(*out) && out->result == 0 ? 0 : kIOReturnError;
}
int32_t lookout_smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}
typedef struct { uint32_t connection, key; KeyInfo info; } CachedKey;
static CachedKey metadata[64];
static pthread_mutex_t metadata_lock = PTHREAD_MUTEX_INITIALIZER;
void lookout_smc_close(uint32_t connection) {
    if (!connection) return;
    pthread_mutex_lock(&metadata_lock);
    for (int i=0;i<64;i++) if (metadata[i].connection == connection) metadata[i].connection=0;
    pthread_mutex_unlock(&metadata_lock);
    if (connection) IOServiceClose(connection);
}
static int32_t read_packet(uint32_t connection, const char *key, Packet *value) {
    if (!key || strlen(key) != 4) return kIOReturnBadArgument;
    Packet in = {0}, out = {0};
    in.key = fourcc(key);
    pthread_mutex_lock(&metadata_lock);
    for (int i=0;i<64;i++) if (metadata[i].connection == connection && metadata[i].key == in.key) { in.info=metadata[i].info; break; }
    pthread_mutex_unlock(&metadata_lock);
    int32_t result = 0;
    if (!in.info.size) {
        in.command = 9; result = call(connection, &in, &out);
        if (result) return result;
        if (!out.info.size || out.info.size > 32) return kIOReturnUnsupported;
        in.info = out.info;
        pthread_mutex_lock(&metadata_lock);
        for (int i=0;i<64;i++) if (!metadata[i].connection) { metadata[i]=(CachedKey){connection,in.key,in.info}; break; }
        pthread_mutex_unlock(&metadata_lock);
    }
    in.command = 5;
    result = call(connection, &in, &out);
    if (result) return result;
    out.key = in.key; out.info = in.info; *value = out;
    return 0;
}
int32_t lookout_smc_read(uint32_t connection, const char *key, uint32_t *type, uint32_t *size, uint8_t bytes[32]) {
    Packet value = {0}; int32_t result = read_packet(connection, key, &value);
    if (result) return result;
    *type = value.info.type; *size = value.info.size; memcpy(bytes, value.bytes, 32); return 0;
}
static int32_t write_packet(uint32_t connection, Packet value) {
    if (geteuid() != 0) return kIOReturnNotPrivileged;
    Packet input = {0}, out = {0};
    input.key = value.key; input.info.size = value.info.size; input.command = 6;
    memcpy(input.bytes, value.bytes, sizeof(input.bytes));
    size_t size = sizeof(out);
    int32_t result = IOConnectCallStructMethod(connection, 2, &input, sizeof(input), &out, &size);
    if (result || (size && out.result)) {
        os_log_error(OS_LOG_DEFAULT, "Lookout SMC write key=%{public}x result=%{public}d device=%{public}u size=%{public}zu", value.key, result, out.result, size);
        return result ? result : kIOReturnError;
    }
    return 0;
}
static int32_t mode_packet(uint32_t connection, int fan, Packet *value) {
    char key[5]; snprintf(key, sizeof(key), "F%dMd", fan);
    int32_t result = read_packet(connection, key, value);
    if (result) { snprintf(key, sizeof(key), "F%dmd", fan); result = read_packet(connection, key, value); }
    return result;
}
int32_t lookout_smc_fan_target(uint32_t connection, int fan, double rpm) {
    if (fan < 0 || fan > 1 || !isfinite(rpm) || rpm < 0 || rpm > 12000) return kIOReturnBadArgument;
    // Only M1 Pro mode/target keys are writable. The Swift controller validates hardware bounds too.
    Packet mode = {0}; int32_t result = mode_packet(connection, fan, &mode);
    if (result || mode.info.size != 1) return result ? result : kIOReturnUnsupported;
    if (mode.bytes[0] != 1) {
        mode.bytes[0] = 1; result = write_packet(connection, mode);
        if (result) return result;
        // Firmware can acknowledge before the mode changes. Do not send a target yet.
        for (int attempt = 0; attempt < 20; attempt++) {
            usleep(100000);
            Packet check = {0}; result = mode_packet(connection, fan, &check);
            if (!result && check.bytes[0] == 1) break;
            if (attempt == 19) return result ? result : kIOReturnError;
        }
    }
    char key[5]; snprintf(key, sizeof(key), "F%dTg", fan);
    Packet target = {0}; result = read_packet(connection, key, &target);
    if (result) return result;
    if (target.info.type != fourcc("flt ") || target.info.size != 4) return kIOReturnUnsupported;
    float number = (float)rpm; memcpy(target.bytes, &number, 4);
    result = write_packet(connection, target);
    if (result) return result;
    Packet check = {0}; float actual = 0;
    for (int attempt = 0; attempt < 20; attempt++) {
        usleep(100000);
        result = read_packet(connection, key, &check); memcpy(&actual, check.bytes, 4);
        if (!result && isfinite(actual) && fabs(actual-rpm) < 100) break;
    }
    Packet mode_check = {0}; int32_t mode_result = mode_packet(connection, fan, &mode_check);
    if (!result && !mode_result && mode_check.bytes[0] == 1 && isfinite(actual) && fabs(actual-rpm) < 100) return 0;
    os_log_error(OS_LOG_DEFAULT, "Lookout SMC verification fan=%{public}d target=%{public}.0f actual=%{public}.0f mode=%{public}u read=%{public}d modeRead=%{public}d", fan, rpm, (double)actual, mode_check.bytes[0], result, mode_result);
    return kIOReturnError;
}
int32_t lookout_smc_fan_auto(uint32_t connection, int fan) {
    if (fan < 0 || fan > 1) return kIOReturnBadArgument;
    Packet mode = {0}; int32_t first = mode_packet(connection, fan, &mode);
    // Always cancel a pending manual write, even if a read still reports automatic.
    if (!first && mode.info.size == 1) { mode.bytes[0] = 0; first = write_packet(connection, mode); }
    char key[5]; snprintf(key, sizeof(key), "F%dTg", fan);
    Packet target = {0}; int32_t second = read_packet(connection, key, &target);
    if (!second && target.info.type == fourcc("flt ") && target.info.size == 4) {
        memset(target.bytes, 0, 4); second = write_packet(connection, target);
    }
    Packet check = {0}; int32_t verify = kIOReturnError;
    int stable = 0;
    for (int attempt = 0; attempt < 30; attempt++) {
        usleep(100000);
        verify = mode_packet(connection, fan, &check);
        if (!verify && (check.bytes[0] == 0 || check.bytes[0] == 3)) stable++;
        else { stable = 0; if (!verify) verify = kIOReturnError; }
        if (stable >= 5) return 0;
    }
    // The actual mode is authoritative: macOS may already update its target after takeover.
    if (!verify) verify = kIOReturnError;
    return first ? first : second ? second : verify;
}
