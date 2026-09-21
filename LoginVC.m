#import "LoginVC.h"
#import "HTTPServer.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

@interface UIViewController (RACompat)
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion;
- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion;
@end

@interface UIWebView (RACompat)
- (UIScrollView *)scrollView;
@end

static NSString *getLocalIP() {
    NSString *addr = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = getifaddrs(&interfaces);

    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                if ([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                    addr = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return addr;
}

@interface LoginVC () <UIAlertViewDelegate>
@end

@implementation LoginVC

+ (void)presentVC {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    UIViewController *topVC = nil;

    for (UIView *subview in keyWindow.subviews) {
        id nextResponder = [subview nextResponder];
        if ([nextResponder isKindOfClass:[UIViewController class]]) {
            topVC = (UIViewController *)nextResponder;
            break;
        }
    }

    while (topVC.modalViewController) {
        topVC = topVC.modalViewController;
    }

    if (!topVC) return;

    LoginVC *loginVC = [[LoginVC alloc] init];
    loginVC.modalTransitionStyle = UIModalTransitionStyleCoverVertical;

    if ([topVC respondsToSelector:@selector(presentViewController:animated:completion:)]) {
        [topVC presentViewController:loginVC animated:YES completion:nil];
    } else {
        [topVC presentModalViewController:loginVC animated:YES];
    }

    [loginVC release];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLoginSuccess) name:@"RALoginSuccess" object:nil];
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];

    UIWebView *webView = [[UIWebView alloc] initWithFrame:self.view.bounds];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    webView.delegate = self;

    if ([webView respondsToSelector:@selector(scrollView)]) {
        UIScrollView *sv = [webView scrollView];
        [sv setBounces:NO];
    } else {
        for (UIView *subview in webView.subviews) {
            if ([subview isKindOfClass:[UIScrollView class]]) {
                [(UIScrollView *)subview setBounces:NO];
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

    [webView loadHTMLString:htmlString baseURL:nil];
    [self.view addSubview:webView];
    [webView release];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)handleLoginSuccess {
    if ([self respondsToSelector:@selector(dismissViewControllerAnimated:completion:)]) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self dismissModalViewControllerAnimated:YES];
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