#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <pthread.h>
#import <fcntl.h>
#import <errno.h>
#import <sys/types.h>
#include "HTTPServer.h"
#include "Auth.h"
#include "VideoPlayer.h"
#include "Video.h"
#include "Misc.h"

#define HTTP_LOG(fmt, ...) NSLog(@"[RedAlien][HTTPServer] " fmt, ##__VA_ARGS__)

static void *httpWorker(void *arg);
static void *handleClient(void *arg);
static void sendResponse(int sock, int code, NSString *mime, NSData *body);
static void sendHeaders(int sock, int code, NSString *statusText, NSString *mime, long long contentLength, long long rangeStart, long long rangeEnd, long long totalLength);

static uint16_t port = 8080;
static BOOL serverActive = NO;

@implementation HTTPServer

+ (uint16_t) currentPort { return port; }

+ (void)startOnPort:(uint16_t)p {
    signal(SIGPIPE, SIG_IGN);
    
    @synchronized(self) {
        if (serverActive) return;
        serverActive = YES;
    }
    
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    
    if (pthread_create(&thread, &attr, httpWorker, (void *)(long)p) != 0) {
        @synchronized(self) { serverActive = NO; }
    }
    pthread_attr_destroy(&attr);
    
    static BOOL initialized = NO;
    @synchronized(self) {
        if (!initialized) {
            initialized = YES;
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkAndRestart) name:UIApplicationDidBecomeActiveNotification object:nil];
        }
    }
}

+ (void)checkAndRestart {
    if (!serverActive) {
        HTTP_LOG(@"App is running again, starting server...");
        [self startOnPort:8080];
    }
}

static void sendResponse(int sock, int code, NSString *mime, NSData *body) {
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %d OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", code, mime, (unsigned long)[body length]];
    write(sock, [header UTF8String], [header length]);
    if (body && [body length] > 0) {
        write(sock, [body bytes], [body length]);
    }
}

static void sendHeaders(int sock, int code, NSString *statusText, NSString *mime, long long contentLength, long long rangeStart, long long rangeEnd, long long totalLength) {
    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"HTTP/1.1 %d %@\r\n", code, statusText];
    [header appendFormat:@"Content-Type: %@\r\n", mime];
    [header appendFormat:@"Content-Length: %lld\r\n", contentLength];
    [header appendString:@"Accept-Ranges: bytes\r\n"];
    [header appendString:@"Connection: close\r\n"];
    
    if (code == 206) { [header appendFormat:@"Content-Range: bytes %lld-%lld/%lld\r\n", rangeStart, rangeEnd, totalLength]; }
    
    [header appendString:@"\r\n"];
    write(sock, [header UTF8String], [header length]);
}

static void *handleClient(void *arg) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    int sock = (int)(long)arg;
    char buf[4096] = {0};

    read(sock, buf, sizeof(buf) - 1);
    NSString *request = [NSString stringWithUTF8String:buf];
    NSArray *lines = [request componentsSeparatedByString:@"\n"];

    if ([lines count] > 0) {
        NSArray *parts = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
        if ([parts count] >= 2) {
            NSString *route = [parts objectAtIndex:0];
            NSString *path = [parts objectAtIndex:1];
            NSString *cleanPath = path;
            NSRange queryRange = [cleanPath rangeOfString:@"?"];
            if (queryRange.location != NSNotFound) {
                cleanPath = [cleanPath substringToIndex:queryRange.location];
            }
            NSString *urlTempDir = tempDir;
            if ([urlTempDir hasPrefix:@"/private/"]) {
                urlTempDir = [urlTempDir substringFromIndex:8];
            }

            NSString *openPrefix = [urlTempDir stringByAppendingString:@"/"];

            HTTP_LOG(@"%@ %@", route, path);

            if ([path hasPrefix:@"/auth"]) {
                NSString *filePath = @"/Library/Application Support/RedAlien/auth.html";
                NSData *htmlData = [NSData dataWithContentsOfFile:filePath];
                if (htmlData) { sendResponse(sock, 200, @"text/html; charset=utf-8", htmlData); }
                else { sendResponse(sock, 500, @"text/plain", [@"auth.html not found in /Library/Application Support/RedAlien/" dataUsingEncoding:NSUTF8StringEncoding]); }
            } else if ([path hasPrefix:@"/submit?url="]) {
                NSString *param = [[path substringFromIndex:12] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                NSRange codeRange = [param rangeOfString:@"code="];

                if (codeRange.location != NSNotFound) {
                    NSString *authCode = [param substringFromIndex:codeRange.location + 5];
                    NSRange hashRange = [authCode rangeOfString:@"#"];
                    if (hashRange.location != NSNotFound) { authCode = [authCode substringToIndex:hashRange.location]; }

                    HTTP_LOG(@"Got OAuth code: %@", authCode);
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"RAGoGetUToken" object:authCode];
                    
                    NSString *filePath = @"/Library/Application Support/RedAlien/success.html";
                    NSData *htmlData = [NSData dataWithContentsOfFile:filePath];

                    if (htmlData) {  sendResponse(sock, 200, @"text/html; charset=utf-8", htmlData); }
                    else { sendResponse(sock, 200, @"text/html; charset=utf-8", [@"<h2>Success!</h2>" dataUsingEncoding:NSUTF8StringEncoding]); }
                } else { sendResponse(sock, 400, @"text/plain", [@"Invalid URL pasted" dataUsingEncoding:NSUTF8StringEncoding]); }
            } else if ([cleanPath hasPrefix:openPrefix] && [cleanPath hasSuffix:@"/open"]) {
                NSString *relative = [cleanPath substringFromIndex:[openPrefix length]];
                NSArray *components = [relative componentsSeparatedByString:@"/"];

                if ([components count] == 2 &&
                    [[components objectAtIndex:1] isEqualToString:@"open"]) {
                    NSString *videoID = [components objectAtIndex:0];
                    NSCharacterSet *invalidChars = [[NSCharacterSet characterSetWithCharactersInString: @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
                    if ([videoID length] > 0 && [videoID rangeOfCharacterFromSet:invalidChars].location == NSNotFound) {
                        NSString *dir = videoDir(videoID);
                        NSString *videoPath = [dir stringByAppendingPathComponent:@"video.mp4"];

                        BOOL isDirectory = NO;
                        if ([[NSFileManager defaultManager] fileExistsAtPath:videoPath isDirectory:&isDirectory] && !isDirectory) {
                            [RAVideoPlayer playFile:videoPath];
                        }
                    }
                }
                sendResponse(sock, 200, @"text/plain", [NSData data]);
            } else if ([path hasPrefix:@"/var/"] || [path hasPrefix:@"/private/"]) {
                NSString *filePath = [cleanPath stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                if ([filePath hasPrefix:@"/var/"] && ![[NSFileManager defaultManager] fileExistsAtPath:filePath] && [[NSFileManager defaultManager] fileExistsAtPath:[@"/private" stringByAppendingString:filePath]]) {
                    filePath = [@"/private" stringByAppendingString:filePath];
                }
                
                while ([filePath hasPrefix:@"//"]) { filePath = [filePath substringFromIndex:1]; }
                
                NSRange qRange = [filePath rangeOfString:@"?"];
                if (qRange.location != NSNotFound) { filePath = [filePath substringToIndex:qRange.location]; }
                
                NSFileManager *fm = [NSFileManager defaultManager];
                NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
                
                if (attrs) {
                    long long fileSize = [[attrs objectForKey:NSFileSize] longLongValue];
                    
                    NSString *mime = @"application/octet-stream";
                    if ([filePath hasSuffix:@".m3u8"]) mime = @"application/vnd.apple.mpegurl";
                    else if ([filePath hasSuffix:@".ts"]) mime = @"video/MP2T";
                    else if ([filePath hasSuffix:@".mp4"]) mime = @"video/mp4";
                    else if ([filePath hasSuffix:@".js"]) mime = @"application/javascript";
                    else if ([filePath hasSuffix:@".json"]) mime = @"application/json";
                    
                    long long start = 0;
                    long long end = fileSize - 1;
                    BOOL isRangeRequest = NO;
                    
                    NSRange rangeHeaderPos = [request rangeOfString:@"Range: bytes="];
                    if (rangeHeaderPos.location != NSNotFound) {
                        isRangeRequest = YES;
                        NSString *rangeStr = [request substringFromIndex:rangeHeaderPos.location + 13];
                        NSString *rangeLine = [[rangeStr componentsSeparatedByString:@"\r\n"] objectAtIndex:0];
                        NSArray *bytes = [rangeLine componentsSeparatedByString:@"-"];
                        
                        if ([bytes count] > 0 && [[bytes objectAtIndex:0] length] > 0) {
                            start = [[bytes objectAtIndex:0] longLongValue];
                        }
                        if ([bytes count] > 1 && [[bytes objectAtIndex:1] length] > 0) {
                            end = [[bytes objectAtIndex:1] longLongValue];
                        }
                    }
                    
                    if (end >= fileSize) end = fileSize - 1;
                    long long contentLength = (end - start) + 1;
                    
                    int fd = open([filePath fileSystemRepresentation], O_RDONLY);
                    if (fd >= 0) {
                        if (isRangeRequest) {
                            sendHeaders(sock, 206, @"Partial Content", mime, contentLength, start, end, fileSize);
                            lseek(fd, (off_t)start, SEEK_SET);
                        } else { sendHeaders(sock, 200, @"OK", mime, fileSize, 0, 0, 0); }

                        char fileBuf[65536];
                        long long bytesLeft = contentLength;
                        while (bytesLeft > 0) {
                            size_t toRead = bytesLeft < sizeof(fileBuf) ? (size_t)bytesLeft : sizeof(fileBuf);
                            ssize_t n = read(fd, fileBuf, toRead);
                            if (n <= 0) break;

                            ssize_t offset = 0;
                            while (offset < n) {
                                ssize_t written = write(sock, fileBuf + offset, n - offset);
                                if (written < 0 && errno == EINTR) continue;
                                if (written <= 0) break;
                                offset += written;
                            }

                            if (offset < n) break;
                            bytesLeft -= n;
                        }
                        close(fd);
                    } else {
                        sendResponse(sock, 403, @"text/plain", [@"Forbidden" dataUsingEncoding:NSUTF8StringEncoding]);
                    }
                } else {
                    sendResponse(sock, 404, @"text/plain", [@"File Not Found" dataUsingEncoding:NSUTF8StringEncoding]);
                }
            }
            else { 
                sendResponse(sock, 404, @"text/plain", [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding]); 
            }
        }
    }

    close(sock);
    [pool drain];
    return NULL;
}

static void *httpWorker(void *arg) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    uint16_t start_port = (uint16_t)(long)arg;

    int server_fd;
    struct sockaddr_in address;
    int opt = 1;

    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
        HTTP_LOG(@"Socket creation failed");
        [pool drain];
        return NULL;
    }

    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);

    uint16_t prt = start_port;
    while (1) {
        address.sin_port = htons(prt);
        if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
            break;
        }
        prt++;
        if (prt > start_port + 50) {
            HTTP_LOG(@"Bind failed on all ports!");
            close(server_fd);
            [pool drain];
            return NULL;
        }
    }
    
    if (listen(server_fd, 10) < 0) {
        HTTP_LOG(@"Listen failed");
        close(server_fd);
        [pool drain];
        return NULL;
    }

    port = prt;
    HTTP_LOG(@"Server successfully running on port %d", prt);

    while (1) {
        int client_socket = accept(server_fd, NULL, NULL);
        if (client_socket >= 0) {
            int nosig = 1;
            setsockopt(client_socket, SOL_SOCKET, SO_NOSIGPIPE, (void *)&nosig, sizeof(int));

            pthread_t client_thread;
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            
            pthread_create(&client_thread, &attr, handleClient, (void *)(long)client_socket);
            pthread_attr_destroy(&attr);
        } else {
            if (errno == EINTR) continue;
            if (errno == EBADF || errno == EINVAL) {
                HTTP_LOG(@"Server socket died. Exiting worker.");
                break; 
            }
            usleep(100000);
        }
    }
    
    serverActive = NO;
    close(server_fd);
    [pool drain];
    return NULL;
}

@end