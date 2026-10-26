#import <Foundation/Foundation.h>

NSString* videoResponse(NSString *videoID);
void status_log(NSString *dir, int progress, NSString *text, BOOL error);
BOOL supportsCopy(void);
NSString *videoDir(NSString *videoID);
NSString *statusByID(NSString *videoID);