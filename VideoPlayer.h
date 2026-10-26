#import <Foundation/Foundation.h>

@class MPMoviePlayerController;
@class UIWindow;

@interface RAVideoPlayer : NSObject {
    MPMoviePlayerController *plr;
    UIWindow *window;
    UIWindow *prevWindow;
}

+ (BOOL)playFile:(NSString *)path;

@end