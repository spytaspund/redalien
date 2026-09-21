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

@implementation RAProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"4thKindContact" inRequest:request]) { return NO; }

    NSURL *url = [NSURL URLWithString:removeAmp([request.URL absoluteString])];
    if (![url.scheme isEqualToString:@"http"] && ![url.scheme isEqualToString:@"https"]) { return NO; }

    NSString *host = [url.host lowercaseString];
    if ([host isEqualToString:@"www.reddit.com"] && [url.path hasPrefix:@"/api/v1/access_token"]) {
        PROTO_LOG(@"Skipping Auth token request: %@", url);
        return NO; 
    }

    if ([host isEqualToString:@"www.reddit.com"] || [host isEqualToString:@"ssl.reddit.com"] || [host isEqualToString:@"reddit.com"] ||
        [host isEqualToString:@"oauth.reddit.com"] || [host hasSuffix:@"redd.it"] || [host isEqualToString:@"i.imgur.com"] ||
        [host isEqualToString:@"alienblue-static.s3.amazonaws.com"] || [host isEqualToString:@"alienblue.s3.amazonaws.com"]) {
        return YES;
    }
    if (![host hasPrefix:@"thumbs"] && ![host hasPrefix:@"ab-thumbs"]) {
        PROTO_LOG(@"Non-standard request: %@", url);
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *request = [self.request mutableCopy];
    [self performSelectorInBackground:@selector(patchRequest:) withObject:request];
    [request release];
}

- (void)stopLoading {}

- (void)patchRequest:(NSMutableURLRequest *)request {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSURL *url = [NSURL URLWithString:removeAmp([request.URL absoluteString])];
    if (url && ![url isEqual:request.URL]) { [request setURL:url]; }
    if (!url) url = request.URL;

    NSString *host = [url.host lowercaseString];
    NSString *path = url.path;
    NSString *query = url.query;

    if ([host isEqualToString:@"v.redd.it"]) {
        if (![path hasSuffix:@"/favicon.ico"] && ![path hasSuffix:@"/favicon.png"] && ![path hasSuffix:@".mp4"]) {
            NSData *vidData = [processVidRequest(path) dataUsingEncoding:NSUTF8StringEncoding];
            [self respondWithStatus:200 headers:@{@"Content-Type": @"text/html"} body:vidData];
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
        [pool release];
        return;
    }

    if ([request.HTTPMethod isEqualToString:@"POST"] && [path hasPrefix:@"/api/login"]) {
        NSString *username = [path lastPathComponent];
        if ([username isEqualToString:@"login"] || username.length == 0) { username = nil; }

        NSString *accessToken = [[Auth shared] grabToken:username];
        if (accessToken.length > 0) {
            NSString *cookie = [NSString stringWithFormat:@"reddit_session=%@; Domain=.reddit.com; Path=/", accessToken];
            NSString *json = [NSString stringWithFormat:@"{\"json\":{\"errors\":[],\"data\":{\"modhash\":\"oauth_session\",\"cookie\":\"%@\"}}}", accessToken];
            [self respondWithStatus:200 headers:@{@"Content-Type": @"application/json; charset=utf-8", @"Set-Cookie": cookie} body:[json dataUsingEncoding:NSUTF8StringEncoding]];
        } else {
            [[LoginVC class] performSelectorOnMainThread:@selector(presentVC) withObject:nil waitUntilDone:NO];
            NSString *json = @"{\"json\":{\"errors\":[],\"data\":{\"modhash\":\"oauth_session\",\"cookie\":\"\"}}}";
            [self respondWithStatus:200 headers:@{@"Content-Type": @"application/json; charset=utf-8"} body:[json dataUsingEncoding:NSUTF8StringEncoding]];
        }
        [pool release];
        return;
    }

    NSString *newQuery = [self processJSON:path originalQuery:query];

    if ([host isEqualToString:@"www.reddit.com"] || [host isEqualToString:@"ssl.reddit.com"] || [host isEqualToString:@"reddit.com"]) {
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