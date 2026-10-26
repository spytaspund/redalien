#import <pthread.h>
#include "Video.h"
#include "VideoPlayer.h"
#include "HTTPServer.h"
#include "FFmpeg.h"
#include "Misc.h"

#define VIDEO_LOG(fmt, ...) NSLog(@"[RedAlien][Video] " fmt, ##__VA_ARGS__)

static NSMutableSet *transcodingVideos = nil; // stores videoIDs that are being recoded atm

static void transcodeVideo(NSString *videoID);
static void *transcodeWorker(void *arg);

BOOL supportsCopy(void) {
    const char *version = [[[UIDevice currentDevice] systemVersion] UTF8String];
    int major = 3;
    if (version) sscanf(version, "%d", &major);
    return (NSInteger)major >= 5;
}

NSString *videoDir(NSString *videoID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:tempDir]) {
        [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *dir = [tempDir stringByAppendingPathComponent:videoID];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *htmlToString(NSString *filename) {
    NSString *filePath = [appSupportDir stringByAppendingPathComponent:filename];
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];
    if (error || !content) { return @"<html><body><h3>Error loading <b>.html</b> template</h3></body></html>"; }
    return content;
}

NSString *statusByID(NSString *videoID) {
    NSString *path = [[tempDir stringByAppendingPathComponent:videoID] stringByAppendingPathComponent:@"status.js"];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

static BOOL isValidMP4(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return NO;
    NSData *data = [handle readDataOfLength:16];
    [handle closeFile];
    if (!data || [data length] < 12) return NO;

    const uint8_t *bytes = (const uint8_t *)[data bytes];
    return (bytes[4] == 'f' && bytes[5] == 't' && bytes[6] == 'y' && bytes[7] == 'p');
}

static NSArray *filterVideos(BOOL isCopy) {
    BOOL pad = isPad(); BOOL retina = isRetina();
    if (!isCopy) {
        if (pad) { return [NSArray arrayWithObjects:@"CMAF_360", @"CMAF_270", @"CMAF_220", nil]; }
        if (retina) { return [NSArray arrayWithObjects:@"CMAF_270", @"CMAF_220", nil]; }
        return [NSArray arrayWithObject:@"CMAF_220"];
    }

    if (pad && retina) { return [NSArray arrayWithObjects:@"CMAF_1080", @"CMAF_720", @"CMAF_480", @"CMAF_360", @"CMAF_270", @"CMAF_220", nil]; }
    if (pad) { return [NSArray arrayWithObjects:@"CMAF_720", @"CMAF_480", @"CMAF_360", @"CMAF_270", @"CMAF_220", nil]; }
    if (retina) { return [NSArray arrayWithObjects:@"CMAF_480", @"CMAF_360", @"CMAF_270", @"CMAF_220", nil]; }
    return [NSArray arrayWithObjects:@"CMAF_270", @"CMAF_220", @"CMAF_360", nil];
}

static NSArray *filterAudios(BOOL isCopy) {
    if (isCopy) {
        return [NSArray arrayWithObjects: @"CMAF_AUDIO_128", @"CMAF_AUDIO_64", nil];
    }

    return [NSArray arrayWithObject:@"CMAF_AUDIO_64"];
}

static NSString *playlistURL(NSString *vid, NSString *quality) {
    return [NSString stringWithFormat:@"http://v.redd.it/%@/%@.m3u8", vid, quality];
}

static double getDuration(NSString *initURL) {
    NSURL *url = [NSURL URLWithString:initURL];
    if (!url) { return 0.0; }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];

    NSError *error = nil;
    NSURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    if (!data || error) { return 0.0; }

    NSString *manifest = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!manifest) { return 0.0; }

    double total = 0.0;
    NSArray *lines = [manifest componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"#EXTINF:"]) {
            NSArray *durationParts = [[line substringFromIndex:8] componentsSeparatedByString:@","];
            NSString *durationText = ([durationParts count] > 0) ? [durationParts objectAtIndex:0] : @"0";
            double value = [durationText doubleValue];
            if (value > 0.0) { total += value; }
        }
    }
    return total;
}

void status_log(NSString *dir, int progress, NSString *text, BOOL error) {
    if (progress < 0) progress = 0; if (progress > 100) progress = 100;

    NSString *status = jsonEscapedString(text);
    NSString *jsString = [NSString stringWithFormat:@"window.statusData = {\"progress\":%d,\"text\":\"%@\",\"error\":%@};", progress, status, error ? @"true" : @"false"];
    NSString *jsPath = [dir stringByAppendingPathComponent:@"status.js"];

    [jsString writeToFile:jsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void *transcodeWorker(void *arg) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *videoID = (NSString *)arg;
    transcodeVideo(videoID);
    [videoID release];
    [pool drain];
    return NULL;
}

NSString* videoResponse(NSString *videoID) {
    @synchronized([NSString class]) { if (!transcodingVideos) { transcodingVideos = [[NSMutableSet alloc] init]; } }

    NSString *dir = videoDir(videoID);
    NSString *mp4Path = [dir stringByAppendingPathComponent:@"video.mp4"];

    if (isValidMP4(mp4Path)) {
        NSString *nonPrivatePath = [mp4Path stringByReplacingOccurrencesOfString:@"/private" withString:@""];
        if (supportsCopy()) { // .html method IS better than separate UIWindow. it allows iPad users to have video opened in the post media panel.
            NSString *videoURL = [NSString stringWithFormat:@"http://127.0.0.1:%d%@", [HTTPServer currentPort], nonPrivatePath];
            NSString *template = htmlToString(@"vPlayer.html");
            return [template stringByReplacingOccurrencesOfString:@"{{VIDEO_URL}}" withString:videoURL];
        }

        [RAVideoPlayer playFile:nonPrivatePath];
        NSString *template = htmlToString(@"vNativePlayer.html");
        template = [template stringByReplacingOccurrencesOfString:@"{{HTTP_PORT}}" withString:[NSString stringWithFormat:@"%d", [HTTPServer currentPort]]];
        template = [template stringByReplacingOccurrencesOfString:@"{{VIDEO_ID}}" withString:videoID];
        return template;
    }

    BOOL isProcessing = NO;
    @synchronized([NSString class]) {
        isProcessing = [transcodingVideos containsObject:videoID];
        if (!isProcessing) { [transcodingVideos addObject:videoID]; }
    }

    if (!isProcessing) {
        status_log(dir, 1, @"Queued video...", NO);
        pthread_t thread;
        int statusCode = pthread_create(&thread, NULL, transcodeWorker, (void *)[videoID retain]);

        if (statusCode == 0) { pthread_detach(thread); } 
        else {
            @synchronized([NSString class]) { [transcodingVideos removeObject:videoID]; }
            [videoID release];
            status_log(dir, 0, @"Could not start video worker.", YES);
        }
    }

    NSString *statusPath = [[dir stringByAppendingPathComponent:@"status.js"] stringByReplacingOccurrencesOfString:@"/private" withString:@""];
    NSString *statusURL = [NSString stringWithFormat:@"/%@/status.js", videoID];
    NSString *template = htmlToString(@"vLoading.html");
    return [template stringByReplacingOccurrencesOfString:@"{{STATUS_URL}}" withString:statusURL];
}

static void transcodeVideo(NSString *videoID) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *dir = videoDir(videoID);
    NSString *videoPath = [dir stringByAppendingPathComponent:@"video.mp4"];
    NSString *tempPath = [dir stringByAppendingPathComponent:@"temp.mp4"];
    NSString *logPath = [dir stringByAppendingPathComponent:@"ffmpeg.log"];
    BOOL copy = supportsCopy();

    status_log(dir, 2, @"Checking video streams", NO);

    NSArray *videoPlaylists = filterVideos(copy);
    NSArray *audioPlaylists = filterAudios(copy);

    NSString *statusError = @"No compatible audio/video found";
    BOOL recodeDone = NO;

    for (NSString *vPlaylist in videoPlaylists) {
        for (NSString *aPlaylist in audioPlaylists) {
            NSString *videoURL = playlistURL(videoID, vPlaylist);
            NSString *audioURL = playlistURL(videoID, aPlaylist);
            double duration = getDuration(videoURL);

            removeIfExists(tempPath);
            NSInteger dim = copy ? 0 : (isPad() ? 480 : (isRetina() ? 320 : 240));
            NSInteger fps = copy ? 0 : (isPad() ? 10 : 12);
            NSString *command = bakeFFCmd(videoURL, audioURL, tempPath, logPath, copy, dim, fps);

            status_log(dir, 5, [NSString stringWithFormat:@"Starting %@ profile (%@)", copy ? @"copy" : @"mpeg4", vPlaylist], NO);

            BOOL ffSuccess = runFFmpeg(command, dir, duration);
            if (ffSuccess && isValidMP4(tempPath)) {
                NSError *moveError = nil;
                removeIfExists(videoPath);
                if ([[NSFileManager defaultManager] moveItemAtPath:tempPath toPath:videoPath error:&moveError]) {
                    status_log(dir, 100, @"Done!", NO);
                    recodeDone = YES;
                    VIDEO_LOG(@"Cached MP4: %@", videoPath);
                    break;
                }
                statusError = [NSString stringWithFormat:@"Could write final .mp4: %@", moveError ? [moveError localizedDescription] : @"unknown error"];
            } else {
                statusError = [NSString stringWithFormat:@"FFmpeg failed for %@ & %@. Refer to ffmpeg.log", vPlaylist, aPlaylist];
                removeIfExists(tempPath);
            }
        }
        if (recodeDone) { break; }
    }

    if (!recodeDone) {
        removeIfExists(tempPath);
        status_log(dir, 0, statusError, YES);
    }

    @synchronized([NSString class]) { if (transcodingVideos) [transcodingVideos removeObject:videoID]; }
    [pool drain]; 
}