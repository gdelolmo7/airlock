#import "ALExceptionCatcher.h"

NSErrorDomain const ALExceptionErrorDomain = @"com.airlock.app.objc-exception";
NSString *const ALExceptionNameKey = @"ALExceptionName";
NSString *const ALExceptionReasonKey = @"ALExceptionReason";

@implementation ALExceptionCatcher

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            // A nil reason is legal, and a nil inside a dictionary literal
            // raises — here, in the one place that must not.
            NSString *name = exception.name ?: @"NSException";
            NSString *reason = exception.reason ?: @"";
            *error = [NSError errorWithDomain:ALExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                ALExceptionNameKey: name,
                ALExceptionReasonKey: reason,
                NSLocalizedDescriptionKey: reason.length > 0 ? reason : name,
            }];
        }
        return NO;
    }
}

@end
