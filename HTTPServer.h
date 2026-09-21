#import <Foundation/Foundation.h>

@interface HTTPServer : NSObject
+ (void)startOnPort:(uint16_t)port;
+ (uint16_t)currentPort;
@end