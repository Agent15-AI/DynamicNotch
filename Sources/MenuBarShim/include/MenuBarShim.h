#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The one boundary to macOS 27's private `MenuBarClientCore` framework.
///
/// macOS 27 draws the whole menu bar as a single window owned by
/// `MenuBarAgent`, so the per-icon windows every menu bar manager used to move
/// are gone. What it has instead is a visibility restriction: give it the
/// system items and app bundle ids that may stay, and it hides every other
/// status item and reflows the bar. It is the mechanism behind assessment
/// (exam lockdown) mode, and the one Pelmet, Hidden Bar and Thaw drive on 27.
///
/// Objective-C so an exception from a changed private API is caught here
/// instead of crashing the app, and so the alloc/init dance stays under ARC.

/// Whether the framework, both classes and every selector used resolve.
BOOL DIMenuBarRestrictionAvailable(void);

/// Keeps only `systemItems` (raw MBSystemItemIdentifier values) and the
/// status items of `bundleIDs` visible. Returns the assertion to hold - hiding
/// lasts until `DIMenuBarRestrictionRelease` or until this process exits - or
/// nil when the API is missing. `completion` reports activation, on any queue.
id _Nullable DIMenuBarRestrict(NSArray<NSNumber *> *systemItems,
                               NSArray<NSString *> *bundleIDs,
                               void (^completion)(NSError *_Nullable error));

void DIMenuBarRestrictionRelease(id assertion);

NS_ASSUME_NONNULL_END
