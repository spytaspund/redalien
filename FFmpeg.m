#import <unistd.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <errno.h>
#import <signal.h>
#include "FFmpeg.h"
#include "Video.h"

#define FF_LOG(fmt, ...) NSLog(@"[RedAlien][FFMpeg] " fmt, ##__VA_ARGS__)

static NSString *quote(NSString *value) {
    if (!value) { value = @""; }
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *formatTime(double seconds) {
    if (seconds < 0.0) { seconds = 0.0; }
    int total = (int)seconds;
    int hours = total / 3600;
    int minutes = (total % 3600) / 60;
    double secs = seconds - (hours * 3600) - (minutes * 60);
    return [NSString stringWithFormat:@"%02d:%02d:%05.2f", hours, minutes, secs];
}

NSString *bakeFFCmd(NSString *videoURL, NSString *audioURL, NSString *tempPath, NSString *logPath, BOOL copy, NSInteger dim, NSInteger fps) {
    NSMutableString *cmd = [NSMutableString string];

    [cmd appendString:@"ffmpeg -nostdin -hide_banner -loglevel warning -nostats -stats_period 0.5 -progress pipe:1 -y "];
    [cmd appendFormat:@"-i %@ -i %@ ", quote(videoURL), quote(audioURL)];
    [cmd appendString:@"-map 0:v:0 -map 1:a:0 "];

    if (copy) {
        [cmd appendString:@"-c:v copy -c:a copy -avoid_negative_ts make_zero "];
    } else {
        NSString *filter = [NSString stringWithFormat:@"fps=%ld,scale='if(gte(iw,ih),%ld,-2)':'if(gte(iw,ih),-2,%ld)'", (long)fps, (long)dim, (long)dim];
        [cmd appendString:@"-skip_loop_filter all "];
        [cmd appendFormat:@"-vf %@ -sws_flags fast_bilinear ", quote(filter)];
        [cmd appendString:@"-c:v mpeg4 -profile:v 0 -q:v 5 -pix_fmt yuv420p -c:a copy -tag:v mp4v "];
    }

    [cmd appendFormat:@"-movflags +faststart -f mp4 %@ 2> %@", quote(tempPath), quote(logPath)];
    return cmd;
}

static void parseFFLine(char *buf, NSString *dir, double duration, double *seconds, NSString **speed, int *lastProgress) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *line = [NSString stringWithUTF8String:buf];
    NSRange eq = [line rangeOfString:@"="];

    if (eq.location != NSNotFound) {
        NSString *key = [line substringToIndex:eq.location];
        NSString *value = [line substringFromIndex:eq.location + 1];

        if ([key isEqualToString:@"out_time_us"]) {
            *seconds = [value doubleValue] / 1000000.0;
        }
        else if ([key isEqualToString:@"speed"]) {
            [*speed release];
            *speed = [value copy];
        }
        else if ([key isEqualToString:@"progress"]) {
            double fraction = *seconds / duration;

            if (fraction < 0.0) fraction = 0.0;
            if (fraction > 1.0) fraction = 1.0;

            int progress = 5 + (int)(fraction * 89.0);
            if (progress < *lastProgress) progress = *lastProgress;

            NSString *statusText;

            if ([value isEqualToString:@"end"]) {
                progress = 95;
                statusText = @"FFmpeg done!";
            } else {
                statusText = [NSString stringWithFormat:
                    @"Transcoding: %d%% (%@ / %@, %@)",
                    (int)(fraction * 100.0),
                    formatTime(*seconds),
                    formatTime(duration),
                    *speed
                ];
            }

            *lastProgress = progress;
            status_log(dir, progress, statusText, NO);
        }
    }

    [pool drain];
}

BOOL runFFmpeg(NSString *cmd, NSString *dir, double duration) {
    const char *command = [cmd UTF8String];
    if (!command) { return NO; }
    if (duration <= 0.0) {
        status_log(dir, 0, @"Invalid video duration", YES);
        return NO;
    }
    FF_LOG(@"FFmpeg command: %@", cmd);

    int fds[2];
    if (pipe(fds) != 0) {
        status_log(dir, 0, @"Unable to create pipe", YES);
        return NO;
    }

    pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0) { _exit(126); }
        close(fds[1]);
        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        _exit(127);
    }

    close(fds[1]);
    if (pid < 0) {
        close(fds[0]);
        status_log(dir, 0, @"Unable to start FFmpeg", YES);
        return NO;
    }

    char input[1024];
    char line[512];
    size_t used = 0;
    double seconds = 0;
    NSString *speed = [@"?" retain];
    int lastProgress = 4;
    int readError = 0;

    for (;;) {
        ssize_t n = read(fds[0], input, sizeof(input));
        if (n < 0) {
            if (errno == EINTR) { continue; }
            readError = errno;
            break;
        }
        if (n == 0) { break; }

        for (ssize_t i = 0; i < n; i++) {
            if (input[i] == '\n') {
                line[used] = '\0';
                if (used > 0) { parseFFLine(line, dir, duration, &seconds, &speed, &lastProgress); }
                used = 0;
            } else if (used < sizeof(line) - 1) {
                line[used++] = input[i];
            }
        }
    }

    if (used > 0) {
        line[used] = '\0';
        parseFFLine(line, dir, duration, &seconds, &speed, &lastProgress);
    }

    close(fds[0]);
    [speed release];

    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, 0); }
    while (result < 0 && errno == EINTR);

    return readError == 0 && result == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}