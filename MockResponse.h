#import <Foundation/Foundation.h>

@interface MockResponse : NSHTTPURLResponse {
    NSInteger _statusCode;
    NSDictionary *_headers;
    NSURL *_url;
}
- (id)initWithURL:(NSURL *)url statusCode:(NSInteger)statusCode headers:(NSDictionary *)headers;
@end