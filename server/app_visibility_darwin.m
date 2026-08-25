#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

extern void ux_on_app_visibility_changed(int hidden);

@interface UXAppVisibilityObserver : NSObject
@end

@implementation UXAppVisibilityObserver

- (void)handleDidHide:(NSNotification *)notification {
    ux_on_app_visibility_changed(1);
}

- (void)handleDidUnhide:(NSNotification *)notification {
    ux_on_app_visibility_changed(0);
}

@end

static UXAppVisibilityObserver *gVisibilityObserver = nil;
static BOOL gIsRegistered = NO;

// ux_register_app_visibility_observer subscribes to NSApplicationDidHide/
// DidUnhide on the default NSNotificationCenter. These fire for both
// [NSApp hide:] (the HideWindowOnClose close-button path, see
// progress/background-window-close.md) and Cmd+H — both are what Phase 2
// treats as "the SPA can be parked".
void ux_register_app_visibility_observer(void) {
    @autoreleasepool {
        if (gIsRegistered) {
            return;
        }

        gVisibilityObserver = [UXAppVisibilityObserver new];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:gVisibilityObserver
                    selector:@selector(handleDidHide:)
                        name:NSApplicationDidHideNotification
                      object:nil];
        [center addObserver:gVisibilityObserver
                    selector:@selector(handleDidUnhide:)
                        name:NSApplicationDidUnhideNotification
                      object:nil];

        gIsRegistered = YES;
    }
}
