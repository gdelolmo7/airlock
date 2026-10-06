#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The domain of every error `ALExceptionCatcher` reports.
FOUNDATION_EXPORT NSErrorDomain const ALExceptionErrorDomain;
/// The exception's `name`.
FOUNDATION_EXPORT NSString *const ALExceptionNameKey;
/// The exception's `reason`, or an empty string when it gave none.
FOUNDATION_EXPORT NSString *const ALExceptionReasonKey;

/// Turns an Objective-C exception into an error Swift can catch.
///
/// Swift's `catch` never sees an `NSException`. The exception unwinds straight
/// through Swift frames and skips their cleanups, and out of an async job on
/// the main actor it skips the runtime's bookkeeping for that job too — so the
/// process dies later, somewhere unrelated. That is how AVFAudio refusing to
/// start the microphone crashed 1.0.12 twice: the raise was inside a hold, and
/// the crash a fraction of a second later, in code that had nothing to do with
/// audio.
///
/// Keep each block to the ONE call that can raise, made on values that already
/// exist. Whatever sits between the raise and this frame is skipped rather than
/// undone, so a block that does two things can leave the first half done.
@interface ALExceptionCatcher : NSObject

/// Runs `block`, and returns NO with `error` filled in if it raised.
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block
                 error:(NSError *_Nullable *_Nullable)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
