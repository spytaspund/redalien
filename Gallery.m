#import "Gallery.h"
#import "Misc.h"
#import "JSONKit.h"

NSString* optimalURL(NSDictionary *media) {
    if (![media isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *previews = [media objectForKey:@"p"];
    NSString *url = nil;

    if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
        NSDictionary *targetRes = [previews lastObject];
        for (NSDictionary *res in previews) {
            if ([res isKindOfClass:[NSDictionary class]]) {
                NSInteger width = [[res objectForKey:@"x"] integerValue];
                if (width >= 960 && width <= 1080) {
                    targetRes = res;
                    break;
                }
            }
        }
        url = [targetRes objectForKey:@"u"];
    }

    if (!url) {
        NSDictionary *sDict = [media objectForKey:@"s"];
        if ([sDict isKindOfClass:[NSDictionary class]]) {
            url = [sDict objectForKey:@"u"];
        }
    }

    return removeAmp(url);
}

NSArray* getImageURLs(NSString *galleryID) {
    if (!galleryID || galleryID.length == 0) return [NSArray array];

    NSString *urlStr = [NSString stringWithFormat:@"https://www.reddit.com/comments/%@/.json", galleryID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    
    if (userAgent) { [request setValue:userAgent forHTTPHeaderField:@"User-Agent"]; }

    NSError *error = nil;
    NSHTTPURLResponse *response = nil;
    NSData *rawData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    if (error || !rawData) { return [NSArray array]; }

    JSONDecoder *decoder = [JSONDecoder decoder];
    id json = [decoder objectWithData:rawData error:&error];
    if (![json isKindOfClass:[NSArray class]] || [(NSArray *)json count] == 0) { return [NSArray array]; }

    NSDictionary *postListing = [json objectAtIndex:0];
    NSDictionary *data = [postListing objectForKey:@"data"];
    NSArray *children = [data objectForKey:@"children"];
    if (![children isKindOfClass:[NSArray class]] || children.count == 0) { return [NSArray array]; }

    NSDictionary *firstObj = [children objectAtIndex:0];
    NSDictionary *postData = [firstObj objectForKey:@"data"];
    if (![postData isKindOfClass:[NSDictionary class]]) { return [NSArray array]; }

    NSDictionary *mediaMeta = [postData objectForKey:@"media_metadata"];
    NSDictionary *galleryData = [postData objectForKey:@"gallery_data"];
    NSArray *galleryItems = [galleryData objectForKey:@"items"];
    if (![mediaMeta isKindOfClass:[NSDictionary class]]) { return [NSArray array]; }

    NSMutableArray *urls = [NSMutableArray array];

    if ([galleryItems isKindOfClass:[NSArray class]] && galleryItems.count > 0) {
        for (NSDictionary *item in galleryItems) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            
            NSString *mediaID = [item objectForKey:@"media_id"];
            NSDictionary *media = [mediaMeta objectForKey:mediaID];

            if (media && [[media objectForKey:@"status"] isEqualToString:@"valid"]) {
                NSString *parsedURL = optimalURL(media);
                if (parsedURL) { [urls addObject:parsedURL]; }
            }
        }
    } else {
        for (NSDictionary *media in [mediaMeta allValues]) {
            if ([media isKindOfClass:[NSDictionary class]] && [[media objectForKey:@"status"] isEqualToString:@"valid"]) {
                NSString *imgURL = optimalURL(media);
                if (imgURL) { [urls addObject:imgURL]; }
            }
        }
    }

    return urls;
}

NSData* downloadImage(NSString *urlStr) {
    if (!urlStr) return nil;
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0];
    return [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
}

NSString* processGalleryRequest(NSString *galleryID) {
    NSArray *urls = getImageURLs(galleryID);
    NSUInteger count = urls.count;

    if (count == 0) {
        return @"<html><body style='background:#000;color:#fff;text-align:center;padding-top:50px;font-family:sans-serif;'>Cannot parse gallery.</body></html>";
    }

    NSMutableString *slidesHTML = [NSMutableString string];
    NSMutableString *thumbsHTML = [NSMutableString string];

    for (NSUInteger i = 0; i < count; i++) {
        NSString *url = [urls objectAtIndex:i];

        [slidesHTML appendFormat:
         @"<div class='slide'>"
            @"<img src='%@' id='img-%lu' />"
         @"</div>", url, (unsigned long)i];

        NSString *activeClass = (i == 0) ? @" active" : @"";
        [thumbsHTML appendFormat:
         @"<div class='thumb%@' style='background-image:url(\"%@\")'></div>",
         activeClass, url];
    }

    double sliderWidth = count * 100.0;
    double slideWidth = 100.0 / (double)count;

    NSError *err = nil;
    NSString *htmlTemplate = [NSString stringWithContentsOfFile:@"/Library/Application Support/RedAlien/gallery.html" encoding:NSUTF8StringEncoding error:&err];

    if (!htmlTemplate || err) {
        return @"<html><body style='background:#000;color:#fff;text-align:center;padding-top:50px;font-family:sans-serif;'>gallery.html not found.</body></html>";
    }

    NSString *html = [htmlTemplate stringByReplacingOccurrencesOfString:@"{{SLIDER_WIDTH}}" withString:[NSString stringWithFormat:@"%.2f", sliderWidth]];
    html = [html stringByReplacingOccurrencesOfString:@"{{SLIDE_WIDTH}}" withString:[NSString stringWithFormat:@"%.2f", slideWidth]];
    html = [html stringByReplacingOccurrencesOfString:@"{{SLIDES_HTML}}" withString:slidesHTML];
    html = [html stringByReplacingOccurrencesOfString:@"{{THUMBS_HTML}}" withString:thumbsHTML];
    html = [html stringByReplacingOccurrencesOfString:@"{{COUNT}}" withString:[NSString stringWithFormat:@"%lu", (unsigned long)count]];

    return html;
}