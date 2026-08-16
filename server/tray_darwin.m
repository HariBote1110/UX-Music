// tray_darwin.m implements the menu-bar NSStatusItem for UX-Music. It is
// deliberately independent from NSApplication's delegate: unlike some
// third-party systray libraries, it never calls
// [[NSApplication sharedApplication] setDelegate:...], so it cannot clobber
// the delegate Wails installs for window-close / Cmd+Q handling. See
// progress/menubar-tray-mode.md for the investigation behind this choice.
#import <Cocoa/Cocoa.h>

extern void ux_on_tray_command(int command);

typedef NS_ENUM(NSInteger, UXTrayCommand) {
    UXTrayCommandShowWindow = 1,
    UXTrayCommandPlayPause  = 2,
    UXTrayCommandNext       = 3,
    UXTrayCommandPrevious   = 4,
    UXTrayCommandQuit       = 5,
};

@interface UXTrayTarget : NSObject
- (void)menuItemClicked:(id)sender;
@end

@implementation UXTrayTarget
- (void)menuItemClicked:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    ux_on_tray_command((int)item.tag);
}
@end

static NSStatusItem *uxTrayStatusItem = nil;
static UXTrayTarget *uxTrayTarget = nil;
static NSMenuItem *uxTrayPlayPauseItem = nil;

static NSMenuItem *UXTrayAddItem(NSMenu *menu, NSString *title, NSInteger tag) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                   action:@selector(menuItemClicked:)
                                            keyEquivalent:@""];
    item.target = uxTrayTarget;
    item.tag = tag;
    [menu addItem:item];
    return item;
}

static void UXTrayCreateOnMainThread(const char *iconBytes, int iconLength) {
    if (uxTrayStatusItem != nil) {
        return;
    }

    uxTrayTarget = [[UXTrayTarget alloc] init];

    uxTrayStatusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    NSData *iconData = [NSData dataWithBytes:iconBytes length:iconLength];
    NSImage *icon = [[NSImage alloc] initWithData:iconData];
    icon.template = YES;
    uxTrayStatusItem.button.image = icon;

    NSMenu *menu = [[NSMenu alloc] init];
    [menu setAutoenablesItems:NO];

    UXTrayAddItem(menu, @"ウィンドウを表示", UXTrayCommandShowWindow);
    [menu addItem:[NSMenuItem separatorItem]];
    uxTrayPlayPauseItem = UXTrayAddItem(menu, @"再生/一時停止", UXTrayCommandPlayPause);
    UXTrayAddItem(menu, @"次の曲", UXTrayCommandNext);
    UXTrayAddItem(menu, @"前の曲", UXTrayCommandPrevious);
    [menu addItem:[NSMenuItem separatorItem]];
    UXTrayAddItem(menu, @"UX Musicを終了", UXTrayCommandQuit);

    uxTrayStatusItem.menu = menu;
}

void ux_tray_create(const char *iconBytes, int iconLength) {
    // NSStatusItem creation must happen on the main thread. Wails owns the
    // main thread's Cocoa run loop; dispatch_async queues this block to run
    // there regardless of which goroutine/thread calls ux_tray_create.
    NSData *iconData = [NSData dataWithBytes:iconBytes length:iconLength];
    dispatch_async(dispatch_get_main_queue(), ^{
        UXTrayCreateOnMainThread((const char *)iconData.bytes, (int)iconData.length);
    });
}

void ux_tray_set_playpause_label(const char *label) {
    NSString *nsLabel = [NSString stringWithUTF8String:label];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (uxTrayPlayPauseItem != nil) {
            uxTrayPlayPauseItem.title = nsLabel;
        }
    });
}

void ux_tray_destroy(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (uxTrayStatusItem != nil) {
            [[NSStatusBar systemStatusBar] removeStatusItem:uxTrayStatusItem];
            uxTrayStatusItem = nil;
        }
        uxTrayPlayPauseItem = nil;
    });
}
