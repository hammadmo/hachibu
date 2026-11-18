// Root write test: cut wall power via CHIE for a few seconds, then restore.
// Always restores CHIE=00, including on SIGINT/SIGTERM.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct { UInt32 key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32]; } smc_t;
static io_connect_t conn;
static UInt32 fcc(const char *s){ return ((UInt32)s[0]<<24)|((UInt32)s[1]<<16)|((UInt32)s[2]<<8)|(UInt32)s[3]; }
static int rd(const char *k, unsigned char *buf, UInt32 n){
  smc_t in, out; size_t sz = sizeof out; memset(&in,0,sizeof in); memset(&out,0,sizeof out);
  in.key = fcc(k); in.keyInfo.dataSize = n; in.data8 = 5;
  kern_return_t kr = IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &sz);
  memcpy(buf, out.bytes, n); return kr ? (int)kr : (unsigned char)out.result;
}
static int wr(const char *k, unsigned char v){
  smc_t in, out; size_t sz = sizeof out; memset(&in,0,sizeof in); memset(&out,0,sizeof out);
  in.key = fcc(k); in.keyInfo.dataSize = 1; in.data8 = 6; in.bytes[0] = v;
  kern_return_t kr = IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &sz);
  printf("write %s=%02x kr=0x%x result=0x%02x\n", k, v, kr, (unsigned char)out.result);
  return kr ? (int)kr : (unsigned char)out.result;
}
static void restore(int sig){ wr("CHIE", 0x00); if (sig) _exit(1); }
static void show(const char *label){
  unsigned char c = 0xff, p[4]; float w = 0; rd("CHIE", &c, 1); rd("PDTR", p, 4); memcpy(&w, p, 4);
  printf("%s CHIE=%02x adapter_in=%.2fW | ", label, c, w); fflush(stdout);
  system("pmset -g batt | head -1 | cut -c1-40");
}
int main(void){
  setvbuf(stdout, NULL, _IOLBF, 0);
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
  if (IOServiceOpen(svc, mach_task_self(), 0, &conn)) { printf("open failed\n"); return 1; }
  signal(SIGINT, restore); signal(SIGTERM, restore); signal(SIGHUP, restore);
  show("before:");
  if (wr("CHIE", 0x08) != 0) { printf("write refused, nothing changed\n"); restore(0); return 2; }
  for (int i = 1; i <= 6; i++) { sleep(1); show("cut:   "); }
  restore(0);
  for (int i = 1; i <= 4; i++) { sleep(1); show("after: "); }
  return 0;
}
