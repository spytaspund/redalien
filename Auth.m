#include "Auth.h"
#include "Misc.h"
#import "JSONKit.h"

#define AUTH_LOG(fmt, ...) NSLog(@"[RedAlien][Auth] " fmt, ##__VA_ARGS__)

@implementation Auth

- (id)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleUserNotif:) name:@"RAGoGetUToken" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRedditNotif:) name:@"RAGoGetRToken" object:nil];

        NSDictionary *savedTokens = readFromPrefs(@"tokens");
        if (savedTokens && [savedTokens isKindOfClass:[NSDictionary class]]) {
            tokens = [savedTokens mutableCopy];
        } else {
            tokens = [[NSMutableDictionary alloc] init];
        }
    }
    return self;
}

- (void)dealloc {
    [tokens release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

+ (Auth *)shared {
    static Auth *manager = nil;
    if (manager == nil) {
        @synchronized(self) {
            if (manager == nil) {
                manager = [[Auth alloc] init];
            }
        }
    }
    return manager;
}

- (void)handleUserNotif:(NSNotification *)note {
    NSString *authCode = nil;
    NSString *username = nil;
    
    if ([note.object isKindOfClass:[NSDictionary class]]) {
        authCode = [(NSDictionary *)note.object objectForKey:@"code"];
        username = [(NSDictionary *)note.object objectForKey:@"username"];
    } else if ([note.object isKindOfClass:[NSString class]]) {
        authCode = (NSString *)note.object;
    }

    if (!username || username.length == 0) { username = [self currentUser]; }
    if (authCode && username) {
        AUTH_LOG(@"Responding to notification, getting token for %@!", username);
        [self setUser:username];
        [self setAuthCode:authCode forUser:username];
        [self performSelectorInBackground:@selector(grabToken:) withObject:username];
    }
}

- (void)handleRedditNotif:(NSNotification *)note {
    [self performSelectorInBackground:@selector(grabRedditToken) withObject:nil];
}

- (NSString *)rClientID {
    return decodeBase64(rClientID64);
}

- (NSString *)uClientID {
    return decodeBase64(uClientID64);
}

- (NSString *)uClientSecret {
    return decodeBase64(uClientSecret64);
}

- (NSDictionary *)accountDict:(NSString *)username {
    if (!username || username.length == 0) return nil;
    @synchronized(tokens) {
        return [tokens objectForKey:username];
    }
}

- (void)saveAccountDict:(NSDictionary *)dict forUser:(NSString *)username {
    if (!username || username.length == 0) return;
    @synchronized(tokens) {
        if (dict) { [tokens setObject:dict forKey:username]; }
        else { [tokens removeObjectForKey:username]; }
        saveToPrefs(tokens, @"tokens");
    }
}

- (void)setAuthCode:(NSString *)code forUser:(NSString *)username {
    if (!username || username.length == 0) return;
    
    NSDictionary *oldAccount = [self accountDict:username];
    NSMutableDictionary *newAccount = oldAccount ? [[oldAccount mutableCopy] autorelease] : [NSMutableDictionary dictionary];
    
    if (code) { [newAccount setObject:code forKey:@"authCode"]; }
    else { [newAccount removeObjectForKey:@"authCode"]; }
    
    [self saveAccountDict:newAccount forUser:username];
}

- (NSString *)currentUser {
    NSString *user = readFromPrefs(@"currentUser");
    return (user && [user isKindOfClass:[NSString class]]) ? user : nil;
}

- (void)setUser:(NSString *)username {
    saveToPrefs(username ? username : @"", @"currentUser");
}

- (NSString *)grabCurrentToken {
    NSString *current = [self currentUser];
    if (current.length > 0) {
        NSString *uToken = [self grabToken:current];
        if (uToken.length > 0) {
            return uToken;
        }
    }
    return [self grabRedditToken];
}

- (NSString *)grabRedditToken {
    return [self grabToken:@"_REDDIT"];
}

- (NSString *) grabToken:(NSString *)username {
    if (!username || username.length == 0) { username = @"_REDDIT"; }
    if (![username isEqualToString:@"_REDDIT"]) { [self setUser:username ]; }
    @synchronized(self) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        NSDictionary *account = [self accountDict:username];
        NSString *lastToken = [account objectForKey:@"token"];
        double expiry = [[account objectForKey:@"expiry"] doubleValue];
        
        if (lastToken.length > 0 && expiry > 0) {
            NSDate *expireDate = [NSDate dateWithTimeIntervalSince1970:expiry];
            if ([expireDate timeIntervalSinceNow] > 60) {
                AUTH_LOG(@"Using cached %@ token (active till %@)", username, expireDate);
                NSString *outToken = [[lastToken retain] autorelease];
                [pool release];
                return outToken;
            }
        }

        BOOL isApp = [username isEqualToString:@"_REDDIT"];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/api/v1/access_token"]];
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"script:RedAlien:v1.0 (by /u/spez)" forHTTPHeaderField:@"User-Agent"]; // hehe
        [request setHTTPMethod:@"POST"];
        NSString *body = nil;

        if (isApp) {
            NSString *clientID = [self rClientID];
            NSString *deviceID = genUUIDv4();
            NSString *rawAuth = [NSString stringWithFormat:@"%@:", clientID];
            NSData *utf8Auth = [rawAuth dataUsingEncoding:NSUTF8StringEncoding];
            
            [request setValue:[NSString stringWithFormat:@"Basic %@", encodeBase64(utf8Auth)] forHTTPHeaderField:@"Authorization"];
            body = [NSString stringWithFormat:@"grant_type=https://oauth.reddit.com/grants/installed_client&device_id=%@", deviceID];
        } else {
            NSString *clientID = [self uClientID];
            NSString *clientSecret = [self uClientSecret];
            NSString *refreshToken = [account objectForKey:@"refreshToken"];
            NSString *authCode = [account objectForKey:@"authCode"];

            NSString *rawAuth = [NSString stringWithFormat:@"%@:%@", clientID, clientSecret];
            NSData *utf8Auth = [rawAuth dataUsingEncoding:NSUTF8StringEncoding];
            [request setValue:[NSString stringWithFormat:@"Basic %@", encodeBase64(utf8Auth)] forHTTPHeaderField:@"Authorization"];

            if (refreshToken.length > 0) {
                body = [NSString stringWithFormat:@"grant_type=refresh_token&refresh_token=%@", urlEncode(refreshToken)];
            } else if (authCode.length > 0) {
                body = [NSString stringWithFormat:@"grant_type=authorization_code&code=%@&redirect_uri=%@", urlEncode(authCode), urlEncode(@"http://127.0.0.1:65010/authorize_callback")];
            } else {
                AUTH_LOG(@"No credentials to refresh token for user '%@'", username);
                [pool release];
                return nil;
            }
        }

        [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];

        NSError *error = nil;
        NSHTTPURLResponse *response = nil;
        [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"4thKindContact" inRequest:request];
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];

        if (error || !data || response.statusCode != 200) {
            NSString *errorBody = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
            AUTH_LOG(@"ERROR GETTING TOKEN FOR %@! status=%ld, body=%@", username, (long)response.statusCode, errorBody);
            [pool release];
            return nil;
        }

        NSDictionary *json = [data objectFromJSONData];

        if (!json || ![json isKindOfClass:[NSDictionary class]]) {
            AUTH_LOG(@"ERROR: JSONKit failed to parse response for '%@'", username);
            [pool release];
            return nil;
        }

        NSString *accessToken = [json objectForKey:@"access_token"];
        if (accessToken.length > 0) {
            double expiresIn = [[json objectForKey:@"expires_in"] doubleValue];
            if (expiresIn <= 0) expiresIn = 86400.0;

            NSDate *newExpireDate = [NSDate dateWithTimeIntervalSinceNow:expiresIn];
            NSMutableDictionary *newAccount = account ? [[account mutableCopy] autorelease] : [NSMutableDictionary dictionary];

            [newAccount setObject:accessToken forKey:@"token"];
            [newAccount setObject:[NSNumber numberWithDouble:[newExpireDate timeIntervalSince1970]] forKey:@"expiry"];

            NSString *freshRefresh = [json objectForKey:@"refresh_token"];
            if (freshRefresh && freshRefresh.length > 0) {
                [newAccount setObject:freshRefresh forKey:@"refreshToken"];
            }

            [newAccount removeObjectForKey:@"authCode"];
            [self saveAccountDict:newAccount forUser:username];

            AUTH_LOG(@"Successfully updated token for %@, expires: %@", username, newExpireDate);
            if (![username isEqualToString:@"_REDDIT"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"RALoginSuccess" object:nil];
                });
            }

            NSString *result = [[accessToken retain] autorelease];
            [pool release];
            return result;
        }

        [pool release];
        return nil;
    }
}

@end