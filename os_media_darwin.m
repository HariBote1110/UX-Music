#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AppKit/AppKit.h>

extern void ux_on_media_command(int command);

enum {
    UXMediaCommandPlay = 1,
    UXMediaCommandPause = 2,
    UXMediaCommandToggle = 3,
    UXMediaCommandNext = 4,
    UXMediaCommandPrevious = 5,
    UXMediaCommandStop = 6,
};

@interface UXMediaCommandTarget : NSObject
@end

@implementation UXMediaCommandTarget

- (MPRemoteCommandHandlerStatus)handlePlay:(MPRemoteCommandEvent *)event {
    ux_on_media_command(UXMediaCommandPlay);
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handlePause:(MPRemoteCommandEvent *)event {
    ux_on_media_command(UXMediaCommandPause);
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleToggle:(MPRemoteCommandEvent *)event {
    ux_on_media_command(UXMediaCommandToggle);
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleNext:(MPRemoteCommandEvent *)event {
    ux_on_media_command(UXMediaCommandNext);
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handlePrevious:(MPRemoteCommandEvent *)event {
    ux_on_media_command(UXMediaCommandPrevious);
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleStop:(MPRemoteCommandEvent *)event {
    ux_on_media_command(UXMediaCommandStop);
    return MPRemoteCommandHandlerStatusSuccess;
}

@end

static UXMediaCommandTarget *gMediaCommandTarget = nil;
static BOOL gIsRegistered = NO;

static NSString *ux_string_or_empty(const char *value) {
    if (value == NULL) {
        return @"";
    }

    NSString *stringValue = [NSString stringWithUTF8String:value];
    if (stringValue == nil) {
        return @"";
    }

    return stringValue;
}

static MPMediaItemArtwork *ux_create_artwork(NSString *artworkPath) {
    if (artworkPath.length == 0) {
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:artworkPath];
    if (!image) {
        return nil;
    }

    if (@available(macOS 10.13.2, *)) {
        NSSize imageSize = image.size;
        if (imageSize.width <= 0 || imageSize.height <= 0) {
            imageSize = NSMakeSize(512, 512);
        }
        return [[MPMediaItemArtwork alloc] initWithBoundsSize:imageSize requestHandler:^NSImage * _Nonnull(CGSize requestedSize) {
            return image;
        }];
    }

    return nil;
}

void ux_register_media_commands(void) {
    @autoreleasepool {
        if (gIsRegistered) {
            return;
        }

        gMediaCommandTarget = [UXMediaCommandTarget new];

        MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
        center.playCommand.enabled = YES;
        center.pauseCommand.enabled = YES;
        center.togglePlayPauseCommand.enabled = YES;
        center.nextTrackCommand.enabled = YES;
        center.previousTrackCommand.enabled = YES;

        [center.playCommand addTarget:gMediaCommandTarget action:@selector(handlePlay:)];
        [center.pauseCommand addTarget:gMediaCommandTarget action:@selector(handlePause:)];
        [center.togglePlayPauseCommand addTarget:gMediaCommandTarget action:@selector(handleToggle:)];
        [center.nextTrackCommand addTarget:gMediaCommandTarget action:@selector(handleNext:)];
        [center.previousTrackCommand addTarget:gMediaCommandTarget action:@selector(handlePrevious:)];

        if ([center respondsToSelector:@selector(stopCommand)]) {
            center.stopCommand.enabled = YES;
            [center.stopCommand addTarget:gMediaCommandTarget action:@selector(handleStop:)];
        }

        gIsRegistered = YES;
    }
}

void ux_set_now_playing(const char *title, const char *artist, const char *album, const char *artworkPath, int isPlaying) {
    @autoreleasepool {
        NSString *titleValue = ux_string_or_empty(title);
        NSString *artistValue = ux_string_or_empty(artist);
        NSString *albumValue = ux_string_or_empty(album);
        NSString *artworkPathValue = ux_string_or_empty(artworkPath);
        if (titleValue.length == 0) {
            titleValue = @"UX-Music";
        }

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[MPMediaItemPropertyTitle] = titleValue;
        if (artistValue.length > 0) {
            info[MPMediaItemPropertyArtist] = artistValue;
        }
        if (albumValue.length > 0) {
            info[MPMediaItemPropertyAlbumTitle] = albumValue;
        }
        MPMediaItemArtwork *artwork = ux_create_artwork(artworkPathValue);
        if (artwork) {
            info[MPMediaItemPropertyArtwork] = artwork;
        }

        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        center.nowPlayingInfo = info;

        if (@available(macOS 10.13.2, *)) {
            center.playbackState = isPlaying ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
        }
    }
}

void ux_clear_now_playing(void) {
    @autoreleasepool {
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        center.nowPlayingInfo = nil;
        if (@available(macOS 10.13.2, *)) {
            center.playbackState = MPNowPlayingPlaybackStateStopped;
        }
    }
}
