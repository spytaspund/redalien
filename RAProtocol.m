#import "RAProtocol.h"
#import "Auth.h"
#import "Video.h"
#import "SubIcon.h"
#import "Gallery.h"
#import "LoginVC.h"
#import "JSONKit.h"
#import "MockResponse.h"
#import "Misc.h"

#define PROTO_LOG(fmt, ...) NSLog(@"[RedAlien][Protocol] " fmt, ##__VA_ARGS__)

// sometimes reddit sends httpbodystream
static NSData *extractBody(NSURLRequest *request) {
    if (request.HTTPBody) { return request.HTTPBody; }
    
    if (request.HTTPBodyStream) {
        NSInputStream *stream = request.HTTPBodyStream;
        [stream open];
        
        NSMutableData *data = [NSMutableData data];
        uint8_t buffer[1024];
        
        while ([stream hasBytesAvailable]) {
            NSInteger len = [stream read:buffer maxLength:sizeof(buffer)];
            if (len > 0) {
                [data appendBytes:buffer length:len];
            } else if (len < 0) {
                break;
            }
        }
        
        [stream close];
        return data;
    }
    
    return nil;
}

static NSDictionary *parseFormBody(NSData *data) {
    if (!data || data.length == 0) return nil;

    NSString *bodyStr = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!bodyStr) return nil;

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    NSArray *pairs = [bodyStr componentsSeparatedByString:@"&"];

    for (NSString *pair in pairs) {
        NSArray *elements = [pair componentsSeparatedByString:@"="];
        if (elements.count == 2) {
            NSString *key = [[elements objectAtIndex:0] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            NSString *value = [[elements objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            if (key && value) {
                [dict setObject:value forKey:key];
            }
        }
    }
    return dict;
}

static NSCondition *loginCondition = nil;

@implementation RAProtocol

+ (void)initialize {
    if (self == [RAProtocol class]) {
        loginCondition = [[NSCondition alloc] init];
    }
}

+ (void)unfreezeLoginReq {
    [loginCondition lock];
    [loginCondition signal];
    [loginCondition unlock];
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"4thKindContact" inRequest:request]) { return NO; }

    NSURL *url = [NSURL URLWithString:removeAmp([request.URL absoluteString])];
    NSString *host = [url.host lowercaseString];

    if (![url.scheme isEqualToString:@"http"] && ![url.scheme isEqualToString:@"https"]) { return NO; }

    /*if ([host isEqualToString:@"www.reddit.com"] && [url.path hasPrefix:@"/api/v1/access_token"]) {
        PROTO_LOG(@"Skipping Auth token request: %@", url);
        return NO; 
    }*/

    if (![host hasPrefix:@"thumbs"] && ![host hasPrefix:@"ab-thumbs"] && ![host hasPrefix:@"preview"] && ![host hasPrefix:@"external-preview"] && ![host hasPrefix:@"localhost"]) {
        PROTO_LOG(@"Non-standard request: %@", url, url.query);
    }

    if ([host isEqualToString:@"www.reddit.com"] || [host isEqualToString:@"ssl.reddit.com"] || [host isEqualToString:@"reddit.com"] ||
        [host isEqualToString:@"gateway.reddit.com"] || [host isEqualToString:@"oauth.reddit.com"] || [host hasSuffix:@"redd.it"] || 
        [host isEqualToString:@"i.imgur.com"] || [host isEqualToString:@"alienblue-static.s3.amazonaws.com"] || [host isEqualToString:@"alienblue.s3.amazonaws.com"] ) {
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    [self performSelectorInBackground:@selector(patchRequest:) withObject:self.request];
}

- (void)stopLoading {}

- (void)patchRequest:(NSMutableURLRequest *)stockRequest {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableURLRequest *request = [stockRequest mutableCopy];

    NSURL *url = [NSURL URLWithString:removeAmp([request.URL absoluteString])];
    if (url && ![url isEqual:request.URL]) { [request setURL:url]; }
    if (!url) url = request.URL;

    NSString *host = [url.host lowercaseString];
    NSString *path = url.path;
    NSString *query = url.query;

    if ([path isEqualToString:@"/redditmobile/1/ios/config"]) {
        NSString *json = @"{\"reddit_url\": \"https://www.reddit.com\"}";
        [self respondWithStatus:200 headers:@{@"Content-Type": @"application/json"} body:[json dataUsingEncoding:NSUTF8StringEncoding]];
        [request release];
        [pool release];
        return;
    }
    
    if ([host isEqualToString:@"i.redd.it"]) {
        PROTO_LOG(@"IMAGE REQUEST: %@%@%@", host, path, query);
        [request setValue:@"image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5" forHTTPHeaderField:@"Accept"];
    }

    if ([host isEqualToString:@"v.redd.it"]) {
        if (![path hasSuffix:@"/favicon.ico"] && ![path hasSuffix:@"/favicon.png"] && ![path hasSuffix:@".mp4"]) {
            NSData *vidData = [processVidRequest(path) dataUsingEncoding:NSUTF8StringEncoding];
            [self respondWithStatus:200 headers:@{@"Content-Type": @"text/html"} body:vidData];
            [request release];
            [pool release];
            return;
        }
    }

    if ([path rangeOfString:@"/gallery/"].location != NSNotFound) {
        NSString *galleryID = [[path lastPathComponent] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        NSData *htmlData = [processGalleryRequest(galleryID) dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *headers = @{
            @"Content-Type": @"text/html; charset=utf-8",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)htmlData.length],
            @"Cache-Control": @"no-cache, no-store, must-revalidate"
        };
        [self respondWithStatus:200 headers:headers body:htmlData];
        [request release];
        [pool release];
        return;
    }

    if (([host isEqualToString:@"alienblue-static.s3.amazonaws.com"] || [host isEqualToString:@"alienblue.s3.amazonaws.com"]) && [path hasPrefix:@"/subreddit-icons/"]) {
        NSData *iconData = processIconRequest(path);
        if (iconData && iconData.length > 0) {
            NSDictionary *headers = @{
                @"Content-Type": @"image/png",
                @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)iconData.length],
                @"Cache-Control": @"no-cache, no-store, must-revalidate"
            };
            [self respondWithStatus:200 headers:headers body:iconData];
        } else {
            [self respondWithStatus:302 headers:@{@"Location": @"https://www.redditstatic.com/avatars/avatar_default_03_EA0027.png"} body:nil];
        }
        [request release];
        [pool release];
        return;
    }

    if ([request.HTTPMethod isEqualToString:@"POST"] && [path hasPrefix:@"/api/login"]) {
        NSString *lastComponent = [path lastPathComponent];
        NSString *username = nil;
        NSData *body = extractBody(request);

        if (![lastComponent isEqualToString:@"login"] && ![lastComponent isEqualToString:@"authorize"] && ![lastComponent isEqualToString:@"v1"] && lastComponent.length > 0) {
            username = lastComponent;
        } else {
            NSDictionary *params = parseFormBody(body);
            username = [params objectForKey:@"user"];
            PROTO_LOG(@"Username parsed from body: %@", username);
        }

        NSString *accessToken = username ? [[Auth shared] grabToken:username] : [[Auth shared] grabCurrentToken];

        if (accessToken.length > 0) {
            NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObject:@"application/json; charset=utf-8" forKey:@"Content-Type"];
            [headers setObject:[NSString stringWithFormat:@"reddit_session=%@; Domain=.reddit.com; Path=/", accessToken] forKey:@"Set-Cookie"];
            
            NSString *json = [NSString stringWithFormat:@"{\"json\":{\"errors\":[],\"data\":{\"modhash\":\"oauth_session\",\"cookie\":\"%@\"}}}", accessToken];
            [self respondWithStatus:200 headers:headers body:[json dataUsingEncoding:NSUTF8StringEncoding]];
        } else {
            PROTO_LOG(@"No token found for '%@'. Displaying LoginVC and freezing thread...", username ? username : @"current user");

            [[LoginVC class] performSelectorOnMainThread:@selector(presentVC) withObject:nil waitUntilDone:YES];

            [loginCondition lock];
            [loginCondition wait];
            [loginCondition unlock];

            PROTO_LOG(@"Thread unfrozen! Re-checking token for '%@'...", username ? username : @"current user");

            accessToken = username ? [[Auth shared] grabToken:username] : [[Auth shared] grabCurrentToken];

            if (accessToken.length > 0) {
                NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObject:@"application/json; charset=utf-8" forKey:@"Content-Type"];
                [headers setObject:[NSString stringWithFormat:@"reddit_session=%@; Domain=.reddit.com; Path=/", accessToken] forKey:@"Set-Cookie"];
                
                NSString *json = [NSString stringWithFormat:@"{\"json\":{\"errors\":[],\"data\":{\"modhash\":\"oauth_session\",\"cookie\":\"%@\"}}}", accessToken];
                [self respondWithStatus:200 headers:headers body:[json dataUsingEncoding:NSUTF8StringEncoding]];
            } else {
                NSString *errorJson = @"{\"json\":{\"errors\":[[\"WRONG_PASSWORD\",\"OAuth authorization required\",\"passwd\"]]}}";
                NSDictionary *headers = @{@"Content-Type": @"application/json; charset=utf-8"};
                [self respondWithStatus:200 headers:headers body:[errorJson dataUsingEncoding:NSUTF8StringEncoding]];
            }
        }

        [request release];
        [pool release];
        return;
    }

    if ([path isEqualToString:@"/api/fp/1/auth/access_token"]) {
        NSString *token = [[Auth shared] grabCurrentToken];
        NSInteger expiresIn = [[Auth shared] tokenExpiry:nil];
        
        if (!token) { token = @""; }

        NSDictionary *responseDict = @{
            @"access_token": token,
            @"token_type": @"bearer",
            @"expires_in": [NSNumber numberWithInteger:expiresIn],
            @"scope": @"*"
        };
        
        NSData *jsonData = [responseDict JSONData];

        NSDictionary *headers = @{
            @"Content-Type": @"application/json",
            @"Cache-Control": @"no-cache"
        };
        
        [self respondWithStatus:200 headers:headers body:jsonData];
        [request release];
        [pool release];
        return;
    }


    if ([path isEqualToString:@"/api/v1/authorize"] &&
        [request.HTTPMethod isEqualToString:@"POST"]) {

        NSData *body = extractBody(request);
        NSDictionary *params = parseFormBody(body);

        NSString *authorize = [params objectForKey:@"authorize"];
        NSString *redirectURI = [params objectForKey:@"redirect_uri"];
        NSString *responseType = [params objectForKey:@"response_type"];
        NSString *state = [params objectForKey:@"state"];

        NSString *accessToken = [[Auth shared] grabCurrentToken];

        if ([authorize isEqualToString:@"allow"] && [responseType isEqualToString:@"code"] && accessToken.length > 0 && redirectURI.length > 0 && state.length > 0) {

            NSString *fakeCode = [NSString stringWithFormat:@"redalien-%@", [[NSProcessInfo processInfo] globallyUniqueString]];
            NSString *separator = [redirectURI rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
            NSString *location = [NSString stringWithFormat:@"%@%@code=%@&state=%@", redirectURI, separator, fakeCode, state];
            NSURL *redirectURL = [NSURL URLWithString:location];

            if (redirectURL) {
                NSDictionary *headers = @{
                    @"Location": location,
                    @"Content-Type": @"text/html; charset=UTF-8"
                };

                MockResponse *response = [[MockResponse alloc] initWithURL:self.request.URL statusCode:302 headers:headers];
                NSURLRequest *redirectRequest = [NSURLRequest requestWithURL:redirectURL];
                [self.client URLProtocol:self wasRedirectedToRequest:redirectRequest redirectResponse:response];

                [response release];
                [request release];
                [pool release];
                return;
            }
        }

        NSString *errorHTML = @"OAuth authorization failed";
        [self respondWithStatus:400 headers:@{@"Content-Type": @"text/plain; charset=UTF-8"} body:[errorHTML dataUsingEncoding:NSUTF8StringEncoding]];

        [request release];
        [pool release];
        return;
    }

    if ([path isEqualToString:@"/api/v1/access_token"] &&
        [request.HTTPMethod isEqualToString:@"POST"]) {

        NSString *accessToken = [[Auth shared] grabCurrentToken];
        NSInteger expiresIn = [[Auth shared] tokenExpiry:nil];

        if (!accessToken.length) {
            NSDictionary *headers = @{
                @"Content-Type": @"application/json; charset=UTF-8"
            };

            NSString *error = @"{\"error\":\"invalid_grant\"}";

            [self respondWithStatus:400 headers:headers body:[error dataUsingEncoding:NSUTF8StringEncoding]];

            [request release];
            [pool release];
            return;
        }

        NSDictionary *responseDict = @{
            @"access_token": accessToken,
            @"token_type": @"bearer",
            @"expires_in": [NSNumber numberWithInteger:expiresIn],
            @"scope": @"identity,read,vote,report,submit,edit,history,flair,modconfig,modflair,modlog,modposts,modwiki,save,mysubreddits,wikiedit,wikiread,account,creddits,subscribe,privatemessages"
        };

        NSData *jsonData = [responseDict JSONData];

        NSDictionary *headers = @{
            @"Content-Type": @"application/json",
            @"Cache-Control": @"no-cache"
        };

        PROTO_LOG(@"[TOKEN] Returning cached Reddit token");

        [self respondWithStatus:200
                        headers:headers
                        body:jsonData];

        [request release];
        [pool release];
        return;
    }

    NSString *newQuery = [self processJSON:path originalQuery:query];

    if ([host isEqualToString:@"www.reddit.com"] || [host isEqualToString:@"ssl.reddit.com"] || [host isEqualToString:@"reddit.com"] || [host isEqualToString:@"oauth.reddit.com"] && ![path isEqualToString:@"/api/v1/authorize"]) {
        NSString *accessToken = [[Auth shared] grabCurrentToken];

        if (accessToken.length > 0) {
            NSString *newURLString = [NSString stringWithFormat:@"https://oauth.reddit.com%@%@", path, newQuery.length > 0 ? [NSString stringWithFormat:@"?%@", newQuery] : @""];
            NSURL *newURL = [NSURL URLWithString:newURLString];
            
            if (newURL) {
                [request setURL:newURL];
                [request setValue:@"oauth.reddit.com" forHTTPHeaderField:@"Host"];
                [request setValue:[NSString stringWithFormat:@"bearer %@", accessToken] forHTTPHeaderField:@"Authorization"];
            }
        } else if (![newQuery isEqualToString:query]) {
            PROTO_LOG(@"TF?!?!?!?!? NO TOKENS AT ALL???");
            NSString *newAbsolute = [NSString stringWithFormat:@"%@://%@%@?%@", url.scheme, url.host, path, newQuery];
            NSURL *newURL = [NSURL URLWithString:newAbsolute];
            if (newURL) [request setURL:newURL];
        }
    }

    // ========= Actual request sending wow =========
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"4thKindContact" inRequest:request];

    NSError *error = nil;
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];

    if (error || !response) {
        [self.client URLProtocol:self didFailWithError:error ?: [NSError errorWithDomain:@"RedAlien" code:-1 userInfo:nil]];
        [request release];
        [pool release];
        return;
    }

    if (data) {
        NSString *respString = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        
        if ([respString rangeOfString:@"redditmaturecontent"].location != NSNotFound) {            
            NSString *redditToken = [[Auth shared] grabRedditToken];
            if (redditToken.length > 0) {
                [request setValue:[NSString stringWithFormat:@"bearer %@", redditToken] forHTTPHeaderField:@"Authorization"];
                error = nil;
                response = nil;
                data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
            }
        }
    }

    if ([request.HTTPMethod isEqualToString:@"POST"] && [request.URL.path rangeOfString:@"/api/comment"].location != NSNotFound && data) {
        NSError *parseError = nil;
        id jsonObj = [data objectFromJSONDataWithParseOptions:JKParseOptionNone error:&parseError];
        
        if (!parseError && jsonObj && [jsonObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *jsonDict = [jsonObj objectForKey:@"json"];
            if (jsonDict && [jsonDict isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dataDict = [jsonDict objectForKey:@"data"];
                NSArray *things = [dataDict objectForKey:@"things"];
                
                if (things && [things isKindOfClass:[NSArray class]] && things.count > 0) {
                    NSDictionary *firstThing = [things objectAtIndex:0];
                    id commentData = [firstThing objectForKey:@"data"];
                    if (commentData) {
                        data = [commentData JSONData];
                    }
                }
            }
        }
    }

    [self respondWithStatus:response.statusCode headers:response.allHeaderFields body:data];
    [request release];
    [pool release];
}

- (void)respondWithStatus:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body {
    MockResponse *response = [[MockResponse alloc] initWithURL:self.request.URL statusCode:status headers:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body && body.length > 0) { [self.client URLProtocol:self didLoadData:body]; }
    [self.client URLProtocolDidFinishLoading:self];
    [response release];
}

- (NSString *)processJSON:(NSString *)path originalQuery:(NSString *)query {
    NSMutableString *newQuery = [NSMutableString stringWithString:(query ? query : @"")];
    
    if ([path hasSuffix:@".json"] && [newQuery rangeOfString:@"raw_json=1"].location == NSNotFound) {
        if (newQuery.length > 0) [newQuery appendString:@"&"];
        [newQuery appendString:@"raw_json=1"];
    }
    
    if ([path rangeOfString:@"search.json"].location != NSNotFound && [newQuery rangeOfString:@"include_over_18="].location == NSNotFound) {
        if (newQuery.length > 0) [newQuery appendString:@"&"];
        [newQuery appendString:@"include_over_18=on"];
    }
    
    return newQuery;
}

@end