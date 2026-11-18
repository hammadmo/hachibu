// Read-only SMC probe: key info + read. No writes. Runs as a normal user.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct { UInt32 key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32]; } smc_t;
static UInt32 fcc(const char *s){ return ((UInt32)s[0]<<24)|((UInt32)s[1]<<16)|((UInt32)s[2]<<8)|(UInt32)s[3]; }
int main(int argc, char **argv){
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
  io_connect_t conn; kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
  if (kr) { printf("open failed 0x%x\n", kr); return 1; }
  for (int i = 1; i < argc; i++) {
    smc_t in, out; size_t sz = sizeof(out);
    memset(&in,0,sizeof in); memset(&out,0,sizeof out);
    in.key = fcc(argv[i]); in.data8 = 9; // key info
    kr = IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &sz);
    printf("%s  info: kr=0x%x result=0x%02x", argv[i], kr, (unsigned char)out.result);
    if (kr || out.result) { printf("\n"); continue; }
    UInt32 t = out.keyInfo.dataType, n = out.keyInfo.dataSize;
    printf(" size=%u type=%c%c%c%c attr=0x%02x", n, t>>24, t>>16, t>>8, t, (unsigned char)out.keyInfo.dataAttributes);
    memset(&in,0,sizeof in); in.key = fcc(argv[i]); in.keyInfo.dataSize = n; in.data8 = 5; // read
    memset(&out,0,sizeof out); sz = sizeof out;
    kr = IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &sz);
    printf(" | read: kr=0x%x result=0x%02x bytes=", kr, (unsigned char)out.result);
    for (UInt32 b = 0; b < n && b < 32; b++) printf("%02x", out.bytes[b]);
    if (n == 4 && t == fcc("flt ")) { float f; memcpy(&f, out.bytes, 4); printf(" (%.3f)", f); }
    printf("\n");
  }
  IOServiceClose(conn); return 0;
}
