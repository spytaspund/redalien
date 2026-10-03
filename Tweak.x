#include <Foundation/Foundation.h>
#import <substrate.h>
#include "Auth.h"
#include "RAProtocol.h"
#include "HTTPServer.h"

%hook NSURLSessionConfiguration

- (NSArray *)protocolClasses {
    NSArray *stock = %orig;

    Class raProto = NSClassFromString(@"RAProtocol");
    if (raProto && ![stock containsObject:raProto]) {
        NSMutableArray *mutable = [stock mutableCopy];
        [mutable insertObject:raProto atIndex:0];
        return [mutable copy];
    }

    return stock;
}

%end

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSURLProtocol registerClass:[RAProtocol class]];
    [Auth shared];
    [HTTPServer startOnPort:8080];
    NSLog(@"[RedAlien] ============ RedAlien landed! ============");
    [pool drain];
}