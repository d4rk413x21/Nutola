#import "ExceptionCatch.h"
#import <ApplicationServices/ApplicationServices.h>

NSException *_Nullable NutolaTryBlock(void (^_Nullable block)(void)) {
    @try {
        if (block) block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

BOOL NutolaRequestAccessibilityTrust(void) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}
