#import <UIKit/UIKit.h>
#import "SubIcon.h"
#import "Misc.h"
#import "JSONKit.h"
#import <dlfcn.h>

#define ICON_LOG(fmt, ...) NSLog(@"[RedAlien][SubIcon] " fmt, ##__VA_ARGS__)

static NSString *getIconURL(id value) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return (NSString *)value;
    }
    return nil;
}

static NSString *getAvatarURL(NSString *subredditName) {
    NSString *aboutURL = [NSString stringWithFormat:@"https://www.reddit.com/r/%@/about.json", subredditName];
    NSMutableURLRequest *aboutReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:aboutURL]];
    
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"4thKindContact" inRequest:aboutReq];
    if (userAgent) { [aboutReq setValue:userAgent forHTTPHeaderField:@"User-Agent"]; }
    [aboutReq setValue:nil forHTTPHeaderField:@"Authorization"];

    NSError *error = nil;
    NSHTTPURLResponse *response = nil;
    NSData *aboutData = [NSURLConnection sendSynchronousRequest:aboutReq returningResponse:&response error:&error];
    NSString *iconURL = nil;

    if (error) {
        ICON_LOG(@"Error fetching about.json for r/%@: %@", subredditName, [error localizedDescription]);
        return nil;
    }

    NSInteger statusCode = response ? response.statusCode : 0;
    ICON_LOG(@"Fetched about.json for r/%@ [Status: %ld, Size: %lu bytes]", subredditName, (long)statusCode, (unsigned long)(aboutData ? aboutData.length : 0));

    if (aboutData && statusCode == 200) {
        JSONDecoder *decoder = [JSONDecoder decoder];
        id json = [decoder objectWithData:aboutData error:&error];

        if (error) { ICON_LOG(@"JSONKit parsing error for r/%@: %@", subredditName, [error localizedDescription]); }

        if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *data = [json objectForKey:@"data"];
            if ([data isKindOfClass:[NSDictionary class]]) {
                iconURL = getIconURL([data objectForKey:@"community_icon"]);
                if (!iconURL) iconURL = getIconURL([data objectForKey:@"icon_img"]);
                if (!iconURL) iconURL = getIconURL([data objectForKey:@"banner_img"]);
                
                if (iconURL) {
                    iconURL = [iconURL stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
                } else {
                    ICON_LOG(@"No icon fields found in 'data' for r/%@", subredditName);
                }
            }
        }
    }

    return iconURL;
}

static UIImage *resizeImage(UIImage *image, CGSize targetSize) {
    if (&UIGraphicsBeginImageContextWithOptions != NULL) {
        UIGraphicsBeginImageContextWithOptions(targetSize, NO, 1.0);
    } else {
        UIGraphicsBeginImageContext(targetSize);
    }

    [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    UIImage *outImg = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return outImg;
}

NSData *processIconRequest(NSString *path) {
    NSString *filename = [[path lastPathComponent] stringByDeletingPathExtension];
    if (filename.length == 0) return nil;

    BOOL isRetina = NO;
    NSString *subName = filename;

    if ([subName hasSuffix:@"@2x"] || [subName hasSuffix:@"@3x"]) {
        isRetina = YES;
        subName = [subName substringToIndex:subName.length - 3];
    }
    
    int randNum = (int)(arc4random() % 20) + 1;
    NSString *defaultIconURL = [NSString stringWithFormat:@"https://www.redditstatic.com/avatars/avatar_default_%02d_0079D3.png", randNum];
    NSString *targetURL = defaultIconURL;

    ICON_LOG(@"Processing icon request: '%@' (Subreddit: '%@', Retina: %@)", path, subName, isRetina ? @"YES" : @"NO");

    if (subName && subName.length > 0 && ![subName isEqualToString:@"default"]) {
        NSString *fetchedURL = getAvatarURL(subName);
        if (fetchedURL && fetchedURL.length > 0) {
            targetURL = fetchedURL;
        }
    }

    ICON_LOG(@"Downloading image from: %@", targetURL);

    NSMutableURLRequest *imgReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:targetURL]];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"4thKindContact" inRequest:imgReq];
    if (userAgent) [imgReq setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [imgReq setValue:nil forHTTPHeaderField:@"Authorization"];

    NSError *error = nil;
    NSHTTPURLResponse *response = nil;
    NSData *imgData = [NSURLConnection sendSynchronousRequest:imgReq returningResponse:&response error:&error];

    if ((error || !imgData || response.statusCode != 200) && ![targetURL isEqualToString:defaultIconURL]) {
        ICON_LOG(@"Failed custom icon for r/%@ (Status %ld). Falling back to default avatar.", subName, (long)(response ? response.statusCode : 0));
        imgReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:defaultIconURL]];
        [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"4thKindContact" inRequest:imgReq];
        if (userAgent) [imgReq setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        
        error = nil;
        response = nil;
        imgData = [NSURLConnection sendSynchronousRequest:imgReq returningResponse:&response error:&error];
    }

    if (!error && imgData) {
        UIImage *sourceImg = [UIImage imageWithData:imgData];
        if (sourceImg) {
            CGSize targetSize = isRetina ? CGSizeMake(74.0, 74.0) : CGSizeMake(36.0, 37.0);
            UIImage *resizedImage = resizeImage(sourceImg, targetSize);
            NSData *imgData = UIImagePNGRepresentation(resizedImage);
            ICON_LOG(@"Successfully processed icon for r/%@ (%lu bytes)", subName, (unsigned long)imgData.length);
            return imgData;
        }
    }

    ICON_LOG(@"ERROR: Icon download failed for r/%@!", subName);
    return nil;
}