#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#include "VideoPlayer.h"
#include "Video.h"

#define PLAYER_LOG(fmt, ...) NSLog(@"[RedAlien][VideoPlayer] " fmt, ##__VA_ARGS__)

static NSString * const movieFinishedNotif = @"MPMoviePlayerPlaybackDidFinishNotification";

@interface RAVideoPlayer (Private)
- (void)playPath:(NSString *)path;
- (BOOL)showWindow;
- (void)playbackFinished:(NSNotification *)notification;
- (void)cleanup;
@end

@implementation RAVideoPlayer

+ (RAVideoPlayer *)shared {
    static RAVideoPlayer *plr = nil;
    @synchronized(self) {
        if (plr == nil) { plr = [[RAVideoPlayer alloc] init]; }
    }
    return plr;
}

+ (BOOL)playFile:(NSString *)path {
    if (supportsCopy()) { return NO; } // iOS 5+ uses webview player
    if ([path length] == 0) { return NO; }

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        PLAYER_LOG(@"File not found: %@", path);
        return NO;
    }

    NSString *queuedPath = [path copy];
    [[self shared] performSelectorOnMainThread:@selector(playPath:) withObject:queuedPath waitUntilDone:NO];

    return YES;
}

- (id)init {
    self = [super init];
    if (self) {
        plr = nil;
        window = nil;
        prevWindow = nil;
    }
    return self;
}

- (void)playPath:(NSString *)path {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [self cleanup];
    NSURL *fileURL = [NSURL fileURLWithPath:path];

    if (fileURL != nil) {
        plr = [[MPMoviePlayerController alloc] initWithContentURL:fileURL];
        if (plr != nil) {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackFinished:) name:movieFinishedNotif object:plr];
            if (![plr respondsToSelector:@selector(view)]) { PLAYER_LOG(@"Legacy playback mode"); }
            else if (![self showWindow]) { PLAYER_LOG(@"Using system playback fallback"); }
            if (![plr respondsToSelector:@selector(view)]) {
                UIDevice *device = [UIDevice currentDevice];
                SEL selector = @selector(setOrientation:);

                if ([device respondsToSelector:selector]) {
                    PLAYER_LOG(@"Forcing device portrait");

                    NSMethodSignature *signature = [device methodSignatureForSelector:selector];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                    [invocation setTarget:device];
                    [invocation setSelector:selector];

                    UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
                    [invocation setArgument:&orientation atIndex:2];
                    [invocation invoke];
                } else {
                    PLAYER_LOG(@"setOrientation: unavailable");
                }
            }
            [plr play];
        }
    }

    [path release];
    [pool drain];
}

- (BOOL)showWindow {
    UIView *playerView = (UIView *)[plr performSelector:@selector(view)];
    if (playerView == nil) { return NO; }

    UIApplication *app = [UIApplication sharedApplication];
    prevWindow = [[app keyWindow] retain];

    window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    window.bounds = CGRectMake(0, 0, width, height);

    if (window == nil) {
        [prevWindow release];
        prevWindow = nil;
        return NO;
    }

    window.backgroundColor = [UIColor blackColor];
    window.windowLevel = UIWindowLevelAlert + 1.0;

    playerView.frame = window.bounds;
    playerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [window addSubview:playerView];
    [window makeKeyAndVisible];

    return YES;
}


- (void)playbackFinished:(NSNotification *)notification {
    PLAYER_LOG(@"Playback finished");
    if ([NSThread isMainThread]) { [self cleanup]; }
    else { [self performSelectorOnMainThread:@selector(cleanup) withObject:nil waitUntilDone:NO]; }
}

- (void)cleanup {
    MPMoviePlayerController *oldPlr = plr;
    UIView *playerView = nil;
    plr = nil;

    if (oldPlr != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:movieFinishedNotif object:oldPlr];
        if ([oldPlr respondsToSelector:@selector(view)]) {
            playerView = (UIView *)[oldPlr performSelector:@selector(view)];
        }
        [oldPlr stop];
    }

    [playerView removeFromSuperview];

    if (window != nil) {
        [window setHidden:YES];
        [window release];
        window = nil;
    }

    if (prevWindow != nil) {
        [prevWindow makeKeyAndVisible];
        [prevWindow release];
        prevWindow = nil;
    }

    [oldPlr release];
}

- (void)dealloc {
    [self cleanup];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

@end