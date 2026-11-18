// Write test for the native charge limit.
//   powerui_set get        read limit
//   powerui_set set N      setMCLLimit:N (official values, no root)
//   powerui_set pref N     root only: write mclLimitValue + notify (1-99)
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <notify.h>
#include <unistd.h>
static id mk(void){
  dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW);
  Class c = NSClassFromString(@"PowerUISmartChargeClient");
  return ((id(*)(id,SEL,id))objc_msgSend)([c alloc], sel_registerName("initWithClientName:"), @"brim-probe");
}
static void show(id c){
  NSError *e = nil;
  unsigned char v = ((unsigned char(*)(id,SEL,NSError**))objc_msgSend)(c, sel_registerName("getMCLLimitWithError:"), &e);
  NSError *e2 = nil;
  unsigned long long on = ((unsigned long long(*)(id,SEL,NSError**))objc_msgSend)(c, sel_registerName("isMCLCurrentlyEnabled:"), &e2);
  printf("limit=%d enabled=%llu%s\n", v, on, (e||e2) ? " (error)" : "");
  if (e) printf("  %s\n", e.description.UTF8String);
}
int main(int argc, char **argv){ @autoreleasepool {
  id c = mk(); if (!c) { printf("no client\n"); return 1; }
  if (argc >= 3 && !strcmp(argv[1], "set")) {
    NSError *e = nil;
    BOOL ok = ((BOOL(*)(id,SEL,unsigned char,NSError**))objc_msgSend)(c, sel_registerName("setMCLLimit:error:"), (unsigned char)atoi(argv[2]), &e);
    printf("setMCLLimit(%d) ok=%d %s\n", atoi(argv[2]), ok, e ? e.description.UTF8String : "");
  } else if (argc >= 3 && !strcmp(argv[1], "pref")) {
    int n = atoi(argv[2]);
    if (geteuid() != 0 || n < 1 || n > 99) { printf("pref needs root and 1-99\n"); return 1; }
    CFStringRef d = CFSTR("com.apple.smartcharging.topoffprotection");
    CFPreferencesSetValue(CFSTR("MCLFeatureState"), (__bridge CFNumberRef)@1, d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue(CFSTR("mclLimitValue"), (__bridge CFNumberRef)@(n), d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    Boolean ok = CFPreferencesSynchronize(d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    uint32_t st = notify_post("com.apple.smartcharging.defaultschanged");
    printf("pref write %d sync=%d notify=%u\n", n, ok, st);
    sleep(3);
  }
  show(c);
} return 0; }
