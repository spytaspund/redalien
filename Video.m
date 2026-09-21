#import <pthread.h>
#import "Video.h"
#import "HTTPServer.h"
#import "Misc.h"

static NSMutableSet *recodeIDs = nil;
static void recodeVideo(NSString *videoID);

static NSString* loadHTMLTemplate(NSString *filename) {
    NSString *basePath = @"/Library/Application Support/RedAlien";
    NSString *filePath = [basePath stringByAppendingPathComponent:filename];
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];
    
    if (error || !content) {
        return @"<html><body><h3>Error loading HTML template</h3></body></html>";
    }
    return content;
}

static void updateStatus(NSString *dir, int progress, NSString *statusText, BOOL isReady, BOOL isError) {
    NSString *jsonString = [NSString stringWithFormat:
        @"{\"progress\": %d, \"status\": \"%@\", \"ready\": %@, \"error\": %@}",
        progress, statusText, isReady ? @"true" : @"false", isError ? @"true" : @"false"];
    
    NSString *jsString = [NSString stringWithFormat:@"window.statusData = %@;", jsonString];
    
    NSString *statusJSPath = [dir stringByAppendingPathComponent:@"status.js"];
    NSString *statusJSONPath = [dir stringByAppendingPathComponent:@"status.json"];
    
    [jsString writeToFile:statusJSPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [jsonString writeToFile:statusJSONPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *appSupportDir = @"/Library/Application Support/RedAlien";
    [[NSFileManager defaultManager] createDirectoryAtPath:appSupportDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *appSupportJSPath = [appSupportDir stringByAppendingPathComponent:@"status.js"];
    [jsString writeToFile:appSupportJSPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void* recodeWorker(void *arg) {
    NSString *videoID = (NSString *)arg;
    recodeVideo(videoID);

    [videoID release];
    return NULL;
}

NSString* downloadHighestRes(NSString *id, NSString *dir, NSString *filename, BOOL isVideo) {
    NSArray *qualities = isVideo ? videoQualities : audioQualities;

    for (NSUInteger i = 0; i < [qualities count]; i++) {
        NSString *qualPath = [qualities objectAtIndex:i];
        NSString *url = [NSString stringWithFormat:@"https://v.redd.it/%@/%@", id, qualPath];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

        NSURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (data && !error && [data length] > 0) {
            NSString *path = [dir stringByAppendingPathComponent:filename];
            if ([data writeToFile:path atomically:YES]) {
                return path;
            }
        }
    }
    
    return nil;
}

static void recodeVideo(NSString *videoID) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:videoID];
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];

    updateStatus(tempDir, 10, @"Downloading video...", NO, NO);
    NSString *videoPath = downloadHighestRes(videoID, tempDir, @"video.mp4", YES);

    updateStatus(tempDir, 40, @"Downloading audio...", NO, NO);
    NSString *audioPath = downloadHighestRes(videoID, tempDir, @"audio.mp4", NO);

    if (videoPath && audioPath) {
        updateStatus(tempDir, 70, @"Recoding video, ffmpeg is working hard...", NO, NO);
        
        NSString *playlistPath = [tempDir stringByAppendingPathComponent:@"playlist.m3u8"];
        NSString *ffCommand = [NSString stringWithFormat:@"ffmpeg -i '%@' -i '%@' %@ '%@' > /tmp/ffmpeg.log 2>&1", videoPath, audioPath, ffFlags, playlistPath];

        system([ffCommand UTF8String]);

        [[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:audioPath error:nil];

        updateStatus(tempDir, 100, @"Done!", YES, NO);
    } else {
        updateStatus(tempDir, 0, @"Error downloading media.", NO, YES);
    }

    @synchronized(recodeIDs) {
        [recodeIDs removeObject:videoID];
    }
    [pool drain];
}

NSString* processVidRequest(NSString *path) {
    if (!recodeIDs) {
        @synchronized([NSString class]) {
            if (!recodeIDs) { recodeIDs = [[NSMutableSet alloc] init]; }
        }
    }
    NSString *videoID = [path stringByTrimmingCharactersInSet: [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (!videoID || videoID.length == 0) {
        NSString *filePath = @"/Library/Application Support/RedAlien/success.html";
        return [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
    }

    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:videoID];
    NSString *playlistPath = [tempDir stringByAppendingPathComponent:@"playlist.m3u8"];

    if ([[NSFileManager defaultManager] fileExistsAtPath:playlistPath]) {
        NSString *nonPrivatePath = [playlistPath stringByReplacingOccurrencesOfString:@"/private" withString:@""];
        NSString *playlistURL = [NSString stringWithFormat:@"http://localhost:%d%@", [HTTPServer currentPort], nonPrivatePath];
        
        NSString *template = loadHTMLTemplate(@"vPlayer.html");
        return [template stringByReplacingOccurrencesOfString:@"{{PLAYLIST_URL}}" withString:playlistURL];
    }

    BOOL isProcessing = NO;
    @synchronized(recodeIDs) {
        isProcessing = [recodeIDs containsObject:videoID];
        if (!isProcessing) {
            [recodeIDs addObject:videoID];
        }
    }

    if (!isProcessing) {
        pthread_t thread;
        pthread_create(&thread, NULL, recodeWorker, (void *)[videoID retain]);
        pthread_detach(thread);
    }

    NSString *nonPrivateTempDir = [tempDir stringByReplacingOccurrencesOfString:@"/private" withString:@""];
    NSString *statusURL = [NSString stringWithFormat:@"http://localhost:%d%@/status.js", [HTTPServer currentPort], nonPrivateTempDir];

    NSString *template = loadHTMLTemplate(@"vLoading.html");
    return [template stringByReplacingOccurrencesOfString:@"{{STATUS_URL}}" withString:statusURL];
}