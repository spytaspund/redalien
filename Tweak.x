#include <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#import <substrate.h>
#include "Auth.h"
#include "RAProtocol.h"
#include "HTTPServer.h"

static void setupRelease(void) {
    NSString *home = NSHomeDirectory();
    NSString *support = @"/Library/Application Support/RedAlien/release02";
    NSString *caches = [home stringByAppendingPathComponent:@"Library/Caches"];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *r01 = [caches stringByAppendingPathComponent:@"release01"];
    NSString *r02 = [caches stringByAppendingPathComponent:@"release02"];

    if ([fm fileExistsAtPath:r02])
        [fm removeItemAtPath:r02 error:nil];

    if (![fm copyItemAtPath:support toPath:r02 error:nil]) {
        NSLog(@"[RedAlien] Failed to copy release02");
        return;
    }

    struct stat st;
    if (lstat([r01 UTF8String], &st) == 0) {
        if (S_ISLNK(st.st_mode))
            unlink([r01 UTF8String]);
        else
            [fm removeItemAtPath:r01 error:nil];
    }

    symlink([r02 UTF8String], [r01 UTF8String]);

    NSLog(@"[RedAlien] release01 -> release02");
}

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *cfg = %orig;
    NSLog(@"[RedAlien][NSURLSession] defaultSessionConfiguration");
    Class raProto = NSClassFromString(@"RAProtocol");

    if (raProto) {
        NSMutableArray *protocols = [[cfg protocolClasses] mutableCopy];
        if (!protocols) { protocols = [[NSMutableArray alloc] init]; }

        if (![protocols containsObject:raProto]) {
            [protocols insertObject:raProto atIndex:0];
            [cfg setProtocolClasses:protocols];
            NSLog(@"[RedAlien][NSURLSession] injected RAProtocol into default");
        }
    }

    return cfg;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *cfg = %orig;
    NSLog(@"[RedAlien][NSURLSession] ephemeralSessionConfiguration");
    Class raProto = NSClassFromString(@"RAProtocol");

    if (raProto) {
        NSMutableArray *protocols = [[cfg protocolClasses] mutableCopy];
        if (!protocols) { protocols = [[NSMutableArray alloc] init]; }

        if (![protocols containsObject:raProto]) {
            [protocols insertObject:raProto atIndex:0];
            [cfg setProtocolClasses:protocols];
            NSLog(@"[RedAlien][NSURLSession] injected RAProtocol into ephemeral");
        }
    }

    return cfg;
}

%end

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

    [NSURLProtocol registerClass:[RAProtocol class]];
    [Auth shared];

    if ([processName isEqualToString:@"com.apple.WebKit.Networking"]) {
        NSLog(@"[RedAlien] ============ WebKit conquered! ============"); // don't start the http server
    } else {
        [HTTPServer startOnPort:8080];
        NSLog(@"[RedAlien] ============ RedAlien landed! ============");
        //if ([bundleID isEqualToString:@"com.reddit.Reddit"]) { setupRelease(); }
    }

    [pool drain];
}