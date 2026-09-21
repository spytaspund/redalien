#import <Foundation/Foundation.h>

@interface RAProtocol : NSURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request;

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request;
- (void)startLoading;
- (void)stopLoading;

- (void)patchRequest:(NSMutableURLRequest *)request;
@end