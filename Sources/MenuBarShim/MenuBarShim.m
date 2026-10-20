#import "MenuBarShim.h"
#import <dlfcn.h>
#import <objc/message.h>

static Class configurationClass(void) { return NSClassFromString(@"MBAssessmentModeConfiguration"); }
static Class assertionClass(void) { return NSClassFromString(@"MBAssessmentModeAssertion"); }
static SEL initSelector(void) { return NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"); }
static SEL activateSelector(void) { return NSSelectorFromString(@"activateWithConfiguration:completionHandler:"); }
static SEL invalidateSelector(void) { return NSSelectorFromString(@"invalidate"); }

BOOL DIMenuBarRestrictionAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // A platform binary in the shared cache: dlopen by path needs no
        // entitlement, and a release that drops it reads as "unavailable".
        if (!dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL)) {
            return;
        }
        available = [configurationClass() instancesRespondToSelector:initSelector()]
            && [assertionClass() instancesRespondToSelector:activateSelector()]
            && [assertionClass() instancesRespondToSelector:invalidateSelector()];
    });
    return available;
}

id DIMenuBarRestrict(NSArray<NSNumber *> *systemItems,
                     NSArray<NSString *> *bundleIDs,
                     void (^completion)(NSError *error)) {
    if (!DIMenuBarRestrictionAvailable()) {
        return nil;
    }
    @try {
        // Both must be NSArrays - the framework indexes into them.
        id configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            [configurationClass() alloc], initSelector(), [systemItems copy], [bundleIDs copy]);
        id assertion = [[assertionClass() alloc] init];
        if (!configuration || !assertion) {
            return nil;
        }
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            assertion, activateSelector(), configuration, completion);
        return assertion;
    } @catch (NSException *exception) {
        NSLog(@"menu bar restriction raised %@: %@", exception.name, exception.reason);
        return nil;
    }
}

void DIMenuBarRestrictionRelease(id assertion) {
    @try {
        ((void (*)(id, SEL))objc_msgSend)(assertion, invalidateSelector());
    } @catch (NSException *exception) {
        NSLog(@"menu bar release raised %@: %@", exception.name, exception.reason);
    }
}
