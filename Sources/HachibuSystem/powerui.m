#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include "HachibuSystem.h"
#include <unistd.h>

// macOS's own charge limit, through the private PowerUI framework. The
// selectors and their types were read from the framework on macOS 27.2;
// the approach was documented by the open-source batt project.
//   getMCLLimitWithError:            C24@0:8^@16
//   setMCLLimit:error:               B28@0:8C16^@20
//   isMCLCurrentlyEnabled:           Q24@0:8^@16
//   availableChargeLimitsWithError:  @24@0:8^@16
//   enableMCL: / disableMCL:         B24@0:8^@16

static BOOL responds(id object, const char *selector) {
    return object != nil && [object respondsToSelector:sel_registerName(selector)];
}

/// One client for the life of the process. nil when this macOS has no PowerUI
/// client with the selectors above, so every call fails safely.
static id client(void) {
    static id shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW) == NULL) return;
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        if (cls == Nil) return;
        id instance = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
        if (!responds(instance, "initWithClientName:")) return;
        instance = ((id (*)(id, SEL, id))objc_msgSend)(instance, sel_registerName("initWithClientName:"), @"hachibu");
        if (!responds(instance, "isMCLSupported") || !responds(instance, "getMCLLimitWithError:")
            || !responds(instance, "setMCLLimit:error:") || !responds(instance, "isMCLCurrentlyEnabled:")
            || !responds(instance, "availableChargeLimitsWithError:") || !responds(instance, "enableMCL:")
            || !responds(instance, "disableMCL:")) return;
        shared = instance;
    });
    return shared;
}

static void explain(char *buffer, int capacity, NSError *error, NSString *fallback) {
    if (buffer == NULL || capacity <= 0) return;
    NSString *text = error != nil ? [error localizedDescription] : fallback;
    strlcpy(buffer, [text UTF8String] ?: "unknown error", (size_t)capacity);
}

bool hb_limit_supported(void) {
    @autoreleasepool {
        id c = client();
        if (c == nil) return false;
        return ((BOOL (*)(id, SEL))objc_msgSend)(c, sel_registerName("isMCLSupported"));
    }
}

bool hb_limit_get(int *limit, bool *enabled) {
    @autoreleasepool {
        id c = client();
        if (c == nil) return false;
        NSError *error = nil;
        unsigned char value = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(
            c, sel_registerName("getMCLLimitWithError:"), &error);
        if (error != nil) return false;
        error = nil;
        unsigned long long on = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(
            c, sel_registerName("isMCLCurrentlyEnabled:"), &error);
        if (error != nil) return false;
        *limit = (int)value;
        *enabled = on != 0;
        return true;
    }
}

int hb_limit_available(int *limits, int capacity) {
    @autoreleasepool {
        id c = client();
        if (c == nil) return 0;
        NSError *error = nil;
        id result = ((id (*)(id, SEL, NSError **))objc_msgSend)(
            c, sel_registerName("availableChargeLimitsWithError:"), &error);
        if (result == nil || ![result isKindOfClass:[NSArray class]]) return 0;
        int count = 0;
        for (id value in (NSArray *)result) {
            if (count >= capacity) break;
            if ([value respondsToSelector:@selector(intValue)]) limits[count++] = [value intValue];
        }
        return count;
    }
}

bool hb_limit_set(int limit, char *error_text, int error_capacity) {
    @autoreleasepool {
        id c = client();
        if (c == nil) { explain(error_text, error_capacity, nil, @"The macOS charge limit is unavailable."); return false; }
        if (limit < 1 || limit > 100) { explain(error_text, error_capacity, nil, @"The limit must be 1 to 100."); return false; }
        NSError *error = nil;
        unsigned long long on = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(
            c, sel_registerName("isMCLCurrentlyEnabled:"), &error);
        // If macOS cannot say whether the limit is on, it is not turned on
        // here: the request below then fails, and that failure is reported.
        if (error == nil && on == 0) {
            BOOL enabled = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(c, sel_registerName("enableMCL:"), &error);
            if (!enabled || error != nil) { explain(error_text, error_capacity, error, @"macOS did not turn the limit on."); return false; }
        }
        error = nil;
        BOOL ok = ((BOOL (*)(id, SEL, unsigned char, NSError **))objc_msgSend)(
            c, sel_registerName("setMCLLimit:error:"), (unsigned char)limit, &error);
        if (!ok || error != nil) { explain(error_text, error_capacity, error, @"macOS did not accept the limit."); return false; }
        return true;
    }
}

bool hb_limit_disable(char *error_text, int error_capacity) {
    @autoreleasepool {
        id c = client();
        if (c == nil) { explain(error_text, error_capacity, nil, @"The macOS charge limit is unavailable."); return false; }
        NSError *error = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(c, sel_registerName("disableMCL:"), &error);
        if (!ok || error != nil) { explain(error_text, error_capacity, error, @"macOS did not turn the limit off."); return false; }
        return true;
    }
}

bool hb_full_charge_override(void) {
    int token = 0;
    if (notify_register_check("com.apple.system.powersources.chargingtofulloverride", &token) != NOTIFY_STATUS_OK) return false;
    uint64_t state = 0;
    uint32_t status = notify_get_state(token, &state);
    notify_cancel(token);
    return status == NOTIFY_STATUS_OK && state != 0;
}

// Limits macOS does not offer by itself. The charging service runs as root
// and reads these two settings from root's own domain; the notification
// makes it read them again. Proven on macOS 27.2 with 75%.
bool hb_root_limit_set(int limit) {
    if (geteuid() != 0 || limit < 1 || limit > 99) return false;
    @autoreleasepool {
        CFStringRef domain = CFSTR("com.apple.smartcharging.topoffprotection");
        CFPreferencesSetValue(CFSTR("MCLFeatureState"), (__bridge CFNumberRef)@1, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("mclLimitValue"), (__bridge CFNumberRef)@(limit), domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (!CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) return false;
        return notify_post("com.apple.smartcharging.defaultschanged") == NOTIFY_STATUS_OK;
    }
}
