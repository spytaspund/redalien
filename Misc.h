#import <Foundation/Foundation.h>

static NSString * const prefsID = @"dev.spytaspund.redalien";

static NSString * const userAgent = @"Mozilla/5.0 (X11; Linux x86_64; rv:153.0) Gecko/20100101 Firefox/153.0";
static NSString * const ffFlags = @"-y -c:v copy -bsf:v h264_mp4toannexb -c:a copy -bsf:a aac_adtstoasc -hls_time 4 -hls_list_size 0";

// i <3 github dorks
static NSString * const rClientID64 = @"b2hYcG9xclpZdWIxa2c=";
static NSString * const uClientID64 = @"RlA0c2o2RmdQVm9XWkE=";
static NSString * const uClientSecret64 = @"N2pfVFFiX00ydFJUSUNsLW5YdmdVa1RvYkxB"; // needed only for "script" or "web app"

static inline NSString* removeAmp(NSString *url) {
    if (!url) return nil;
    url = [url stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    if ([url hasPrefix:@"https:/"] && ![url hasPrefix:@"https://"]) {
        url = [url stringByReplacingOccurrencesOfString:@"https:/" withString:@"https://"];
    } else if ([url hasPrefix:@"http:/"] && ![url hasPrefix:@"http://"]) {
        url = [url stringByReplacingOccurrencesOfString:@"http:/" withString:@"http://"];
    }
    return url;
}

static inline NSString* urlEncode(NSString *string) {
    NSString *encoded = [string stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return encoded;
}

static inline NSString* genUUIDv4() {
    CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
    if (!uuidRef) return nil;
    CFStringRef uuidStringRef = CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
    CFRelease(uuidRef);
    if (!uuidStringRef) return nil;
    NSString *uuidString = [(NSString *)uuidStringRef autorelease];
    return [uuidString lowercaseString];
}

static inline NSString* encodeBase64(NSData *data) {
    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];
    static char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    NSMutableString *result = [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];

    NSUInteger i = 0;
    while (i + 3 <= length) {
        uint32_t chunk = (bytes[i] << 16) | (bytes[i+1] << 8) | bytes[i+2];
        [result appendFormat:@"%c%c%c%c",
            table[(chunk >> 18) & 0x3F],
            table[(chunk >> 12) & 0x3F],
            table[(chunk >> 6) & 0x3F],
            table[chunk & 0x3F]];
        i += 3;
    }

    if (length - i == 1) {
        uint32_t chunk = bytes[i] << 16;
        [result appendFormat:@"%c%c==",
            table[(chunk >> 18) & 0x3F],
            table[(chunk >> 12) & 0x3F]];
    } else if (length - i == 2) {
        uint32_t chunk = (bytes[i] << 16) | (bytes[i+1] << 8);
        [result appendFormat:@"%c%c%c=",
            table[(chunk >> 18) & 0x3F],
            table[(chunk >> 12) & 0x3F],
            table[(chunk >> 6) & 0x3F]];
    }
    return result;
}

static inline NSString* decodeBase64(NSString *input) {
    const char *src = [input UTF8String];
    NSInteger len = [input length];
    NSMutableData *data = [NSMutableData dataWithCapacity:len];
    
    static const char dec[] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1
    };

    int state = 0;
    int val = 0;
    for (int i = 0; i < len; i++) {
        unsigned char c = src[i];
        if (c >= 128 || dec[c] == -1) continue;
        val = (val << 6) | dec[c];
        state += 6;
        if (state >= 8) {
            state -= 8;
            unsigned char b = (val >> state) & 0xFF;
            [data appendBytes:&b length:1];
        }
    }
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

static inline id readFromPrefs(NSString *key) {
    CFPreferencesAppSynchronize((CFStringRef)prefsID);
    
    CFPropertyListRef cfValue = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)prefsID);
    if (cfValue) {
        return [(id)cfValue autorelease];
    }

    NSString *plistPath = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", prefsID];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    return [prefs objectForKey:key];
}

static inline void saveToPrefs(id value, NSString *key) {
    if (!value) {
        CFPreferencesSetAppValue((CFStringRef)key, NULL, (CFStringRef)prefsID);
    } else {
        CFPreferencesSetAppValue((CFStringRef)key, (CFPropertyListRef)value, (CFStringRef)prefsID);
    }
    CFPreferencesAppSynchronize((CFStringRef)prefsID);
}

#define videoQualities [NSArray arrayWithObjects: @"CMAF_1080.mp4", @"CMAF_720.mp4", @"CMAF_480.mp4", @"CMAF_360.mp4", @"CMAF_270.mp4", @"CMAF_220.mp4", nil]
#define audioQualities [NSArray arrayWithObjects: @"CMAF_AUDIO_128.mp4", @"CMAF_AUDIO_64.mp4", nil]