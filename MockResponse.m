#import "MockResponse.h"

@implementation MockResponse

- (id)initWithURL:(NSURL *)url statusCode:(NSInteger)statusCode headers:(NSDictionary *)headers {
    self = [super initWithURL:url MIMEType:nil expectedContentLength:-1 textEncodingName:nil];
    if (self) {
        _url = [url retain];
        _statusCode = statusCode;
        _headers = [headers retain];
    }
    return self;
}

- (NSInteger)statusCode { return _statusCode; }
- (NSDictionary *)allHeaderFields { return _headers; }
- (NSURL *)URL { return _url; }

- (void)dealloc {
    [_url release];
    [_headers release];
    [super dealloc];
}

@end