#import <Foundation/Foundation.h>

@interface Auth : NSObject {
    NSMutableDictionary *tokens;
}

+ (Auth *)shared;

- (NSString *)grabToken:(NSString *)username;
- (NSString *)grabRedditToken;
- (NSString *)grabCurrentToken;

- (void)setAuthCode:(NSString *)code forUser:(NSString *)username;
- (NSString *)currentUser;
- (void)setUser:(NSString *)username;

- (NSString *)rClientID;
- (NSString *)uClientID;
- (NSString *)uClientSecret;

@end