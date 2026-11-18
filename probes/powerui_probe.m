// Read-only PowerUI probe: lists methods, calls only getters. No setters.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
static void dump(Class c, BOOL meta){
  unsigned n; Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
  for (unsigned i = 0; i < n; i++) printf("  %c%s  %s\n", meta?'+':'-', sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]));
  free(m);
}
static void call(id obj, NSString *name, BOOL hasErr){
  SEL s = NSSelectorFromString(name);
  if (![obj respondsToSelector:s]) { printf("%s: not available\n", name.UTF8String); return; }
  NSMethodSignature *sig = [obj methodSignatureForSelector:s];
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  inv.target = obj; inv.selector = s; NSError *err = nil; __autoreleasing NSError *err2 = nil; NSError *__autoreleasing *ep = &err2;
  if (hasErr && sig.numberOfArguments > 2) [inv setArgument:&ep atIndex:2];
  @try { [inv invoke]; } @catch (NSException *e) { printf("%s: exception %s\n", name.UTF8String, e.reason.UTF8String); return; }
  const char *rt = sig.methodReturnType; char buf[64] = {0};
  if (sig.methodReturnLength && sig.methodReturnLength <= sizeof buf) [inv getReturnValue:buf];
  printf("%s -> type %s ", name.UTF8String, rt);
  if (rt[0]=='@') { __unsafe_unretained id o; memcpy(&o, buf, sizeof o); printf("%s", [[o description] UTF8String]); }
  else if (rt[0]=='B' || rt[0]=='c' || rt[0]=='C') printf("%d", (int)buf[0]);
  else if (rt[0]=='q' || rt[0]=='Q') { long long v; memcpy(&v, buf, 8); printf("%lld", v); }
  else if (rt[0]=='i' || rt[0]=='I') { int v; memcpy(&v, buf, 4); printf("%d", v); }
  else if (rt[0]=='d') { double v; memcpy(&v, buf, 8); printf("%f", v); }
  if (err2) printf("  error: %s", err2.description.UTF8String);
  printf("\n");
}
int main(void){ @autoreleasepool {
  void *h = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
  printf("dlopen: %s\n", h ? "ok" : dlerror());
  Class c = NSClassFromString(@"PowerUISmartChargeClient");
  if (!c) { printf("class missing\n"); return 1; }
  printf("methods:\n"); dump(c, YES); dump(c, NO);
  id client = [[c alloc] performSelector:NSSelectorFromString(@"initWithClientName:") withObject:@"brim-probe"];
  printf("client: %s\n", [[client description] UTF8String]);
  call(client, @"isMCLSupported", NO);
  call(client, @"getMCLLimitWithError:", YES);
  call(client, @"isMCLCurrentlyEnabled", NO);
  call(client, @"isSmartChargingCurrentlyEnabled:", YES);
  call(client, @"isOBCSupported", NO);
  call(client, @"isMCLCurrentlyEnabled:", YES);
  call(client, @"availableChargeLimitsWithError:", YES);
  call(client, @"currentChargeLimit:", YES);
  call(client, @"currentRecommendedChargeLimitWithError:", YES);
  call(client, @"fullChargeDeadline:", YES);
  call(client, @"isDEoCSupported", NO);
  call(client, @"status", NO);
} return 0; }
