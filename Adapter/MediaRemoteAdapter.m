// MediaRemoteAdapter — мост к приватному MediaRemote для macOS 15.4+.
//
// С macOS 15.4 Apple отдаёт «Сейчас играет» только доверенным процессам. Системный
// /usr/bin/perl доверенный, поэтому эта библиотека загружается ВНУТРИ perl
// (см. mediaremote-adapter.pl) и работает как отдельный процесс:
//   stdout -> JSON-строки со снимком текущего трека (по одной на строку)
//   stdin  <- команды: "cmd <номер MRCommand>" или "seek <секунды>"
// Идея та же, что у ungive/mediaremote-adapter.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*MRSendFn)(unsigned int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
typedef void (*MRRegisterFn)(dispatch_queue_t);

static MRGetInfoFn gGetInfo;
static MRGetPIDFn gGetPID;
static MRIsPlayingFn gIsPlaying;
static MRSendFn gSend;
static MRSetElapsedFn gSetElapsed;
static MRRegisterFn gRegister;

static dispatch_source_t gTimer;
static NSString *gLastLine = @"";
static NSString *gLastArtKey = @"";
static NSString *gLastArtTrack = @"";
static BOOL gBusy = NO;
static CFAbsoluteTime gBusySince = 0;

static void writeData(NSData *data) {
    const char *p = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, p, left);
        if (n <= 0) exit(0); // приложение закрылось
        p += n;
        left -= (size_t)n;
    }
}

static void writeLine(NSDictionary *d) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!json) return;
    NSMutableData *m = [json mutableCopy];
    [m appendBytes:"\n" length:1];
    writeData(m);
}

static NSString *str(id v) {
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
}

static NSNumber *num(id v) {
    if ([v isKindOfClass:[NSNumber class]]) {
        double d = [(NSNumber *)v doubleValue];
        if (isfinite(d)) return @(d);
    }
    return nil;
}

static NSString *artKeyFor(NSData *art) {
    if (art.length == 0) return @"";
    NSUInteger n = MIN(art.length, (NSUInteger)512);
    NSData *head = [art subdataWithRange:NSMakeRange(0, n)];
    NSData *tail = [art subdataWithRange:NSMakeRange(art.length - n, n)];
    return [NSString stringWithFormat:@"%lu-%lu-%lu", (unsigned long)art.length,
            (unsigned long)head.hash, (unsigned long)tail.hash];
}

static void emitSnapshot(void) {
    if (gBusy && CFAbsoluteTimeGetCurrent() - gBusySince < 3) return;
    gBusy = YES;
    gBusySince = CFAbsoluteTimeGetCurrent();
    dispatch_queue_t q = dispatch_get_main_queue();

    gGetInfo(q, ^(CFDictionaryRef cf) {
        NSDictionary *info = cf ? [(__bridge NSDictionary *)cf copy] : @{};

        void (^finish)(int, int) = ^(int pid, int playing) {
            gBusy = NO;
            NSString *title = str(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            NSString *artist = str(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
            NSMutableDictionary *o = [NSMutableDictionary dictionary];
            o[@"title"] = title;
            o[@"artist"] = artist;
            o[@"album"] = str(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
            NSNumber *v;
            if ((v = num(info[@"kMRMediaRemoteNowPlayingInfoDuration"]))) o[@"duration"] = v;
            if ((v = num(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]))) o[@"elapsed"] = v;
            if ((v = num(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]))) o[@"rate"] = v;
            id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([ts isKindOfClass:[NSDate class]]) o[@"timestamp"] = @([(NSDate *)ts timeIntervalSince1970]);
            if (playing >= 0) o[@"playing"] = playing ? @YES : @NO;
            o[@"pid"] = @(pid);

            NSData *json = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
            NSString *line = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"";

            // Обложку шлём только когда она поменялась (или сменился трек) — она большая.
            id artObj = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSData *art = [artObj isKindOfClass:[NSData class]] ? (NSData *)artObj : nil;
            NSString *artKey = artKeyFor(art);
            NSString *track = [NSString stringWithFormat:@"%@|%@", title, artist];
            BOOL sendArt = art.length > 0 && (![artKey isEqualToString:gLastArtKey] || ![track isEqualToString:gLastArtTrack]);

            if (!sendArt && [line isEqualToString:gLastLine]) return;
            gLastLine = line ?: @"";
            if (sendArt) {
                gLastArtKey = artKey;
                gLastArtTrack = track;
                o[@"artwork"] = [art base64EncodedStringWithOptions:0];
            }
            writeLine(o);
        };

        void (^afterPID)(int) = ^(int pid) {
            if (gIsPlaying) gIsPlaying(q, ^(Boolean p) { finish(pid, p ? 1 : 0); });
            else finish(pid, -1);
        };

        if (gGetPID) gGetPID(q, ^(int pid) { afterPID(pid); });
        else afterPID(0);
    });
}

static void handleCommand(NSString *line) {
    if ([line hasPrefix:@"cmd "]) {
        int c = [[line substringFromIndex:4] intValue];
        if (gSend && c >= 0) gSend((unsigned int)c, NULL);
    } else if ([line hasPrefix:@"seek "]) {
        // doubleValue всегда понимает точку, независимо от языка системы
        double s = [[line substringFromIndex:5] doubleValue];
        if (gSetElapsed && isfinite(s) && s >= 0) gSetElapsed(s);
    } else {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        emitSnapshot();
    });
}

static void *stdinLoop(void *arg) {
    (void)arg;
    char buf[512];
    while (fgets(buf, sizeof buf, stdin)) {
        NSString *raw = [NSString stringWithUTF8String:buf];
        if (!raw) continue;
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
    }
    exit(0); // stdin закрыт — приложение завершилось
    return NULL;
}

__attribute__((visibility("default")))
void adapter_stream(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_DFL);

        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { writeLine(@{ @"error": @"dlopen MediaRemote failed" }); exit(2); }

        gGetInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        gGetPID = (MRGetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
        gIsPlaying = (MRIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        gSend = (MRSendFn)dlsym(h, "MRMediaRemoteSendCommand");
        gSetElapsed = (MRSetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
        gRegister = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!gGetInfo) { writeLine(@{ @"error": @"MRMediaRemoteGetNowPlayingInfo not found" }); exit(3); }

        if (gRegister) gRegister(dispatch_get_main_queue());
        writeLine(@{ @"ready": @YES });

        pthread_t t;
        if (pthread_create(&t, NULL, stdinLoop, NULL) == 0) pthread_detach(t);

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) { (void)note; emitSnapshot(); }];
        }

        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(gTimer, ^{
            if (getppid() == 1) exit(0); // родитель умер
            emitSnapshot();
        });
        dispatch_resume(gTimer);

        CFRunLoopRun();
    }
    exit(0);
}
