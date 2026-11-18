#include "HachibuSystem.h"
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <string.h>

// SMC access through the AppleSMC user client. Reads need no rights; the
// one write (the charger cut, key CHIE) needs root.

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } smc_version_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } smc_keyinfo_t;
typedef struct {
    UInt32 key;
    smc_version_t vers;
    smc_plimit_t pLimitData;
    smc_keyinfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    unsigned char bytes[32];
} smc_param_t;

enum { kSMCUserClient = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCKeyInfo = 9 };

static io_connect_t connection(void) {
    static io_connect_t shared = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (service == 0) return;
        if (IOServiceOpen(service, mach_task_self(), 0, &shared) != kIOReturnSuccess) shared = 0;
        IOObjectRelease(service);
    });
    return shared;
}

static UInt32 code(const char *key) {
    return ((UInt32)key[0] << 24) | ((UInt32)key[1] << 16) | ((UInt32)key[2] << 8) | (UInt32)key[3];
}

int hb_smc_read(const char *key, uint8_t *bytes, int capacity, char type[5]) {
    io_connect_t conn = connection();
    if (conn == 0 || key == NULL || strlen(key) != 4 || capacity <= 0) return 0;

    smc_param_t in, out;
    size_t size = sizeof(out);
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = code(key);
    in.data8 = kSMCKeyInfo;
    if (IOConnectCallStructMethod(conn, kSMCUserClient, &in, sizeof(in), &out, &size) != kIOReturnSuccess
        || out.result != 0) return 0;

    UInt32 length = out.keyInfo.dataSize;
    UInt32 kind = out.keyInfo.dataType;
    if (length == 0 || length > 32 || (int)length > capacity) return 0;
    if (type != NULL) {
        type[0] = (char)(kind >> 24); type[1] = (char)(kind >> 16);
        type[2] = (char)(kind >> 8); type[3] = (char)kind; type[4] = 0;
    }

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    size = sizeof(out);
    in.key = code(key);
    in.keyInfo.dataSize = length;
    in.data8 = kSMCReadKey;
    if (IOConnectCallStructMethod(conn, kSMCUserClient, &in, sizeof(in), &out, &size) != kIOReturnSuccess
        || out.result != 0) return 0;
    memcpy(bytes, out.bytes, length);
    return (int)length;
}

// CHIE: 08 cuts power from the charger, 00 restores it. Proven on macOS 27.2
// (docs/research/charge-control.md, "Write test results").
bool hb_root_adapter_set(bool cut) {
    io_connect_t conn = connection();
    if (conn == 0) return false;
    smc_param_t in, out;
    size_t size = sizeof(out);
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = code("CHIE");
    in.keyInfo.dataSize = 1;
    in.data8 = kSMCWriteKey;
    in.bytes[0] = cut ? 0x08 : 0x00;
    return IOConnectCallStructMethod(conn, kSMCUserClient, &in, sizeof(in), &out, &size) == kIOReturnSuccess
        && out.result == 0;
}

bool hb_adapter_is_cut(bool *cut) {
    uint8_t value[32];
    if (hb_smc_read("CHIE", value, 32, NULL) != 1) return false;
    *cut = value[0] != 0;
    return true;
}
