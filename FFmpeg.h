#import <Foundation/Foundation.h>

BOOL runFFmpeg(NSString *cmd, NSString *dir, double duration);
NSString *bakeFFCmd(NSString *videoURL, NSString *audioURL, NSString *tempPath, NSString *logPath, BOOL copy, NSInteger dim, NSInteger fps);