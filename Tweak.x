#include <Foundation/Foundation.h>
#include "Auth.h"
#include "RAProtocol.h"
#include "HTTPServer.h"

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSURLProtocol registerClass:[RAProtocol class]];
    [Auth shared];
    [HTTPServer startOnPort:8080];
    NSLog(@"[RedAlien] ============ RedAlien landed! ============");
    [pool drain];
}