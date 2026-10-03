#import "LoginVC.h"
#import "RAProtocol.h"
#import "HTTPServer.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

@interface UIViewController (RACompat)
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion;
- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion;
@end

static NSString *getLocalIP() {
    NSString *addr = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = getifaddrs(&interfaces);

    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                if ([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                    addr = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    return addr;
}

static UIWindow *loginWindow = nil;
static UIWindow *prevWindow = nil;
static LoginVC *currentLoginVC = nil;

@interface LoginVC () <UIAlertViewDelegate, UIWebViewDelegate>
@property (nonatomic, retain) UIWebView *webView;
@end

@implementation LoginVC

@synthesize webView = _webView;

+ (void)presentVC {
    if (loginWindow != nil) return;

    prevWindow = [[[UIApplication sharedApplication] keyWindow] retain];

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGRect startFrame = CGRectMake(0, screenBounds.size.height, screenBounds.size.width, screenBounds.size.height);

    loginWindow = [[UIWindow alloc] initWithFrame:startFrame];
    loginWindow.windowLevel = UIWindowLevelNormal + 10.0;
    loginWindow.backgroundColor = [UIColor clearColor];

    currentLoginVC = [[LoginVC alloc] init];
    
    if ([loginWindow respondsToSelector:@selector(setRootViewController:)]) {
        [loginWindow performSelector:@selector(setRootViewController:) withObject:currentLoginVC];
    } else {
        currentLoginVC.view.frame = loginWindow.bounds;
        [loginWindow addSubview:currentLoginVC.view];
    }

    [loginWindow makeKeyAndVisible];

    [UIView beginAnimations:@"presentLoginVC" context:NULL];
    [UIView setAnimationDuration:0.35];
    [UIView setAnimationCurve:UIViewAnimationCurveEaseOut];
    loginWindow.frame = screenBounds;
    [UIView commitAnimations];
}

+ (void)showVC {
    if (![NSThread isMainThread]) { 
        [self performSelectorOnMainThread:@selector(presentVC) withObject:nil waitUntilDone:NO]; 
    } else { 
        [self presentVC]; 
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLoginSuccess) name:@"RALoginSuccess" object:nil];
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];

    self.webView = [[[UIWebView alloc] initWithFrame:self.view.bounds] autorelease];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.delegate = self;

    if ([self.webView respondsToSelector:@selector(scrollView)]) {
        id sv = [self.webView performSelector:@selector(scrollView)];
        if ([sv respondsToSelector:@selector(setBounces:)]) {
            [sv setBounces:NO];
        }
    } else {
        for (UIView *subview in self.webView.subviews) {
            if ([subview respondsToSelector:@selector(setBounces:)]) {
                [(id)subview setBounces:NO];
            }
        }
    }

    NSString *htmlPath = @"/Library/Application Support/RedAlien/login.html";
    NSError *error = nil;
    NSString *htmlString = [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:&error];

    if (!htmlString || error) {
        htmlString = [NSString stringWithFormat:@"<h1>Error loading HTML</h1><p>%@</p>", error ? error.localizedDescription : @"unknown"];
    } else {
        NSString *localIP = getLocalIP();
        NSString *submitURL = [NSString stringWithFormat:@"http://%@:%d/auth", localIP, [HTTPServer currentPort]];
        htmlString = [htmlString stringByReplacingOccurrencesOfString:@"{{SUBMIT_URL}}" withString:submitURL];
    }

    [self.webView loadHTMLString:htmlString baseURL:nil];
    [self.view addSubview:self.webView];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (_webView) {
        _webView.delegate = nil;
        [_webView stopLoading];
        [_webView release];
        _webView = nil;
    }

    [super dealloc];
}

- (void)dismissVC {
    if (!loginWindow) {
        [RAProtocol unfreezeLoginReq];
        return;
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGRect endFrame = CGRectMake(0, screenBounds.size.height, screenBounds.size.width, screenBounds.size.height);

    [UIView beginAnimations:@"dismissLoginVC" context:NULL];
    [UIView setAnimationDuration:0.35];
    [UIView setAnimationCurve:UIViewAnimationCurveEaseIn];
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(dismissAnimDidStop:finished:context:)];
    loginWindow.frame = endFrame;
    [UIView commitAnimations];
}

- (void)dismissAnimDidStop:(NSString *)animationID finished:(NSNumber *)finished context:(void *)context {
    loginWindow.hidden = YES;

    if (prevWindow) {
        [prevWindow makeKeyWindow];
        [prevWindow release];
        prevWindow = nil;
    }

    [loginWindow release];
    loginWindow = nil;

    if (currentLoginVC) {
        [currentLoginVC release];
        currentLoginVC = nil;
    }

    [RAProtocol unfreezeLoginReq];
}

- (void)handleLoginSuccess {
    if (![NSThread isMainThread]) { 
        [self performSelectorOnMainThread:@selector(dismissVC) withObject:nil waitUntilDone:NO]; 
    } else { 
        [self dismissVC]; 
    }
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {
    if ([request.URL.scheme isEqualToString:@"redalien"]) {
        if ([request.URL.host isEqualToString:@"close"]) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Skip authorization?"
                                                            message:@"You didn't provide an auth code. Exiting now won't log you in, and you'll be browsing reddit anonymously. Are you sure?"
                                                           delegate:self
                                                  cancelButtonTitle:@"Back"
                                                  otherButtonTitles:@"Exit anyway", nil];
            [alert show];
            [alert release];
        }
        return NO;
    }
    return YES;
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 1) { // 1 stands for "Exit anyway"
        [self handleLoginSuccess];
    }
}

@end