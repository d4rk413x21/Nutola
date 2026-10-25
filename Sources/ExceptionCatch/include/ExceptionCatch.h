#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block inside an ObjC @try/@catch. Swift's `do/catch` cannot catch
/// `NSException`s raised by the ObjC runtime (AVFoundation throws one when an
/// `AVAudioNode` tap is installed with a format that no longer matches the live
/// audio route — e.g. Bluetooth headphones connecting mid-recording). Uncaught,
/// that becomes `SIGABRT` and kills the process.
///
/// Returns the thrown exception, or `nil` if the block completed normally.
/// The block is allowed to be nil (returns nil).
FOUNDATION_EXPORT NSException *_Nullable NutolaTryBlock(void (^_Nullable block)(void));

/// Bridges the immutable Accessibility prompt key, which the C SDK imports as a mutable global in Swift.
FOUNDATION_EXPORT BOOL NutolaRequestAccessibilityTrust(void);

NS_ASSUME_NONNULL_END
