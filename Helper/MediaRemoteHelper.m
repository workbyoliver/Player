// MediaRemoteHelper: reads system-wide Now Playing info for every app that is playing
// (or has something paused), and sends playback commands, through Apple's private
// MediaRemote framework.
//
// It runs inside /usr/bin/perl (see helper.pl): MediaRemote only answers
// Apple-signed processes, so the Player app cannot call it directly.
//
// stdout: one JSON object per line
//   {"type":"ready"}
//   {"type":"sources","selected":"com.apple.Music","pinned":false,"sources":[
//     {"id":"com.apple.WebKit.GPU","parentBundleId":"com.apple.Safari","name":"Safari",
//      "playing":true,"active":true,"pid":98421}, ...]}
//     Apps that are registered but have nothing loaded (e.g. Messages after a voice
//     message) are left out.
//   {"type":"empty"}                                   nothing is playing
//   {"type":"track","playing":true,"title":"…","artist":"…","album":"…",
//    "duration":215.3,"elapsed":42.1,"timestamp":1762428000.5,"rate":1,
//    "bundleId":"com.apple.WebKit.GPU","parentBundleId":"com.apple.Safari",
//    "artwork":"<base64>"}                             describes the selected source
//   "artwork" appears only when it changed: base64 data, or null when cleared.
//
// stdin: one command per line
//   play | pause | toggle | next | prev | seek <seconds>   (go to the system's active player;
//                                                           MediaRemote routes them there anyway)
//   select <source id> | select auto                       (which source "track" describes)
//   refresh
//   EOF on stdin (the app quit or crashed) exits the helper.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef NSString *(*MRClientStringFn)(id);
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

enum { kMRPlay = 0, kMRPause = 1, kMRTogglePlayPause = 2, kMRNextTrack = 4, kMRPreviousTrack = 5 };

static struct {
    MRRegisterFn registerForNotifications;
    MRGetClientFn getActiveClient;
    MRGetClientsFn getClients;
    MRClientStringFn clientBundleId;
    MRClientStringFn clientParentBundleId;
    MRClientStringFn clientDisplayName;
    MRSendCommandFn sendCommand;
    MRSetElapsedFn setElapsed;
} MR;

static Class MROrigin, MRPlayerPath, MRNowPlayingRequest;
static NSString *pinnedSourceID;                       // the user's pick; nil = follow the active app
static NSDictionary<NSString *, NSNumber *> *wasPlaying; // per source, to notice playback starting
static NSMutableDictionary<NSString *, NSData *> *lastEmitted; // per message type
static NSData *lastArtwork;
static NSString *lastTrackKey;
static BOOL forceArtwork = YES; // the first track message always states the artwork
static uint64_t updateGeneration;
static dispatch_source_t stdinSource;
static NSMutableData *stdinBuffer;

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    NSString *type = object[@"type"];
    if (!json || [json isEqualToData:lastEmitted[type]]) return; // MediaRemote repeats itself; skip duplicates
    lastEmitted[type] = json;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// MARK: - Per-source requests (MRNowPlayingRequest for one app's player path)

static id requestForClient(id client) {
    id origin = ((id (*)(id, SEL))objc_msgSend)(MROrigin, sel_registerName("localOrigin"));
    id path = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        [MRPlayerPath alloc], sel_registerName("initWithOrigin:client:player:"), origin, client, nil);
    return ((id (*)(id, SEL, id))objc_msgSend)([MRNowPlayingRequest alloc], sel_registerName("initWithPlayerPath:"), path);
}

static void requestIsPlaying(id request, void (^completion)(BOOL)) {
    ((void (*)(id, SEL, dispatch_queue_t, id))objc_msgSend)(
        request, sel_registerName("requestIsPlayingOnQueue:completion:"), dispatch_get_main_queue(),
        ^(BOOL playing, __unused id error) { completion(playing); });
}

static void requestInfo(id request, void (^completion)(NSDictionary *)) {
    ((void (*)(id, SEL, dispatch_queue_t, id))objc_msgSend)(
        request, sel_registerName("requestNowPlayingInfoOnQueue:completion:"), dispatch_get_main_queue(),
        ^(NSDictionary *info, __unused id error) { completion([info isKindOfClass:NSDictionary.class] ? info : nil); });
}

static void requestArtwork(id request, void (^completion)(NSData *)) {
    ((void (*)(id, SEL, dispatch_queue_t, id))objc_msgSend)(
        request, sel_registerName("requestNowPlayingItemArtworkOnQueue:completion:"), dispatch_get_main_queue(),
        ^(id artwork, __unused id error) {
            NSData *data = [artwork respondsToSelector:sel_registerName("imageData")] ? [artwork valueForKey:@"imageData"] : nil;
            completion([data isKindOfClass:NSData.class] && data.length ? data : nil);
        });
}

// MARK: - Track

static void emitEmpty(void) {
    lastArtwork = nil;
    lastTrackKey = nil;
    forceArtwork = YES;
    emit(@{@"type": @"empty"});
}

// Whether the info describes something (a title or an artist), not an empty session.
static BOOL hasItem(NSDictionary *info) {
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    return ([title isKindOfClass:NSString.class] && title.length > 0)
        || ([artist isKindOfClass:NSString.class] && artist.length > 0);
}

static void emitTrack(NSDictionary *info, BOOL playing, NSData *artwork, NSString *bundleId, NSString *parentBundleId) {
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    if (!hasItem(info)) {
        emitEmpty();
        return;
    }

    NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
    NSMutableDictionary *out = [@{
        @"type": @"track",
        @"playing": @(playing),
        @"title": title ?: @"",
        @"artist": artist ?: @"",
        @"album": album,
    } mutableCopy];

    NSNumber *duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    NSNumber *elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([duration isKindOfClass:NSNumber.class]) out[@"duration"] = duration;
    if ([elapsed isKindOfClass:NSNumber.class]) out[@"elapsed"] = elapsed;
    if ([rate isKindOfClass:NSNumber.class]) out[@"rate"] = rate;
    out[@"timestamp"] = @(([timestamp isKindOfClass:NSDate.class] ? timestamp : [NSDate date]).timeIntervalSince1970);
    if (bundleId.length) out[@"bundleId"] = bundleId;
    if (parentBundleId.length) out[@"parentBundleId"] = parentBundleId;

    // Players often send a new track's info before its artwork, and some briefly
    // drop the artwork mid-track. So artwork is only cleared on a track change.
    NSString *trackKey = [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%@", bundleId, title ?: @"", artist ?: @"", album];
    BOOL trackChanged = ![trackKey isEqualToString:lastTrackKey];
    if (artwork.length > 0) {
        if (forceArtwork || ![artwork isEqualToData:lastArtwork]) {
            out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            lastArtwork = artwork;
        }
    } else if (forceArtwork || (trackChanged && lastArtwork)) {
        out[@"artwork"] = [NSNull null];
        lastArtwork = nil;
    }
    forceArtwork = NO;
    lastTrackKey = trackKey;
    emit(out);
}

static void emitTrackForClient(id client) {
    id request = requestForClient(client);
    NSString *bundleId = MR.clientBundleId(client);
    NSString *parent = MR.clientParentBundleId ? MR.clientParentBundleId(client) : nil;
    requestInfo(request, ^(NSDictionary *info) {
        requestIsPlaying(request, ^(BOOL playing) {
            requestArtwork(request, ^(NSData *artwork) {
                @autoreleasepool { emitTrack(info, playing, artwork, bundleId, parent); }
            });
        });
    });
}

// MARK: - Sources

static void finishRefresh(NSArray *clients, NSString *activeID, NSDictionary<NSString *, NSNumber *> *playing,
                          NSSet<NSString *> *loaded) {
    // An app is listed while it's playing or has something loaded (paused). Apps that
    // didn't answer in time are left out until the next refresh.
    BOOL (^isListed)(NSString *) = ^BOOL(NSString *sourceID) {
        return sourceID && (playing[sourceID].boolValue || (playing[sourceID] && [loaded containsObject:sourceID]));
    };

    // Keep the user's pick until that app goes away or a different app starts playing.
    if (pinnedSourceID && !isListed(pinnedSourceID)) pinnedSourceID = nil;
    if (pinnedSourceID && wasPlaying) {
        for (NSString *sourceID in playing) {
            if (playing[sourceID].boolValue && !wasPlaying[sourceID].boolValue && ![sourceID isEqualToString:pinnedSourceID]) {
                pinnedSourceID = nil;
                break;
            }
        }
    }
    wasPlaying = [playing copy];

    NSString *selectedID = pinnedSourceID ?: (isListed(activeID) ? activeID : nil);
    id selectedClient = nil;
    NSMutableArray *sources = [NSMutableArray array];
    for (id client in clients) {
        NSString *sourceID = MR.clientBundleId(client);
        if (!isListed(sourceID)) continue;
        if (!selectedID) selectedID = sourceID;
        if ([sourceID isEqualToString:selectedID]) selectedClient = client;
        NSMutableDictionary *entry = [@{
            @"id": sourceID,
            @"name": (MR.clientDisplayName ? MR.clientDisplayName(client) : nil) ?: sourceID,
            @"playing": playing[sourceID],
            @"active": @([sourceID isEqualToString:activeID]),
        } mutableCopy];
        NSString *parent = MR.clientParentBundleId ? MR.clientParentBundleId(client) : nil;
        if (parent.length) entry[@"parentBundleId"] = parent;
        // The process making the sound (for Safari, its WebKit audio process), so the app
        // can tap exactly that process for per-app volume.
        if ([client respondsToSelector:sel_registerName("processIdentifier")]) {
            NSNumber *pid = [client valueForKey:@"processIdentifier"];
            if ([pid isKindOfClass:NSNumber.class] && pid.intValue > 0) entry[@"pid"] = pid;
        }
        [sources addObject:entry];
    }

    emit(@{
        @"type": @"sources",
        @"sources": sources,
        @"selected": selectedID ?: [NSNull null],
        @"pinned": pinnedSourceID ? @YES : @NO,
    });
    if (selectedClient) {
        emitTrackForClient(selectedClient);
    } else {
        emitEmpty();
    }
}

static void refresh(void) {
    dispatch_queue_t main = dispatch_get_main_queue();
    MR.getActiveClient(main, ^(id activeClient) {
        NSString *activeID = activeClient ? MR.clientBundleId(activeClient) : nil;
        MR.getClients(main, ^(NSArray *clients) {
            NSMutableDictionary<NSString *, NSNumber *> *playing = [NSMutableDictionary dictionary];
            NSMutableSet<NSString *> *loaded = [NSMutableSet set];
            dispatch_group_t group = dispatch_group_create();
            for (id client in clients) {
                NSString *sourceID = MR.clientBundleId(client);
                if (!sourceID) continue;
                id request = requestForClient(client);
                dispatch_group_enter(group);
                requestIsPlaying(request, ^(BOOL isPlaying) { // main queue: no data race
                    playing[sourceID] = @(isPlaying);
                    dispatch_group_leave(group);
                });
                dispatch_group_enter(group);
                requestInfo(request, ^(NSDictionary *info) {
                    if (hasItem(info)) [loaded addObject:sourceID];
                    dispatch_group_leave(group);
                });
            }
            // Don't hang forever if an app never answers.
            __block BOOL finished = NO;
            void (^finish)(void) = ^{
                if (finished) return;
                finished = YES;
                @autoreleasepool { finishRefresh(clients, activeID, [playing copy], [loaded copy]); }
            };
            dispatch_group_notify(group, main, finish);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), main, finish);
        });
    });
}

// Notifications arrive in bursts (info + playing state + app change); coalesce.
static void scheduleUpdate(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        uint64_t generation = ++updateGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (generation == updateGeneration) refresh();
        });
    });
}

// MARK: - Commands

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *command = parts.firstObject;
    if ([command isEqualToString:@"play"]) MR.sendCommand(kMRPlay, nil);
    else if ([command isEqualToString:@"pause"]) MR.sendCommand(kMRPause, nil);
    else if ([command isEqualToString:@"toggle"]) MR.sendCommand(kMRTogglePlayPause, nil);
    else if ([command isEqualToString:@"next"]) MR.sendCommand(kMRNextTrack, nil);
    else if ([command isEqualToString:@"prev"]) MR.sendCommand(kMRPreviousTrack, nil);
    else if ([command isEqualToString:@"seek"] && parts.count > 1 && MR.setElapsed) MR.setElapsed(parts[1].doubleValue);
    else if ([command isEqualToString:@"select"] && parts.count > 1) {
        pinnedSourceID = [parts[1] isEqualToString:@"auto"] ? nil : parts[1];
        refresh();
    } else if ([command isEqualToString:@"refresh"]) {
        [lastEmitted removeAllObjects];
        refresh();
    }
}

static void readStdin(void) {
    char chunk[4096];
    ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
    if (count == 0) exit(0); // the app went away
    if (count < 0) {
        if (errno == EAGAIN || errno == EINTR) return;
        exit(0);
    }
    @autoreleasepool {
        [stdinBuffer appendBytes:chunk length:(NSUInteger)count];
        const char *bytes = stdinBuffer.bytes;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < stdinBuffer.length; i++) {
            if (bytes[i] != '\n') continue;
            NSString *line = [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSUTF8StringEncoding];
            if (line.length) handleCommand(line);
            start = i + 1;
        }
        [stdinBuffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
}

// MARK: - Entry point

__attribute__((visibility("default")))
void mrh_run(void) {
    @autoreleasepool {
        void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!framework) {
            emit(@{@"type": @"error", @"message": @"MediaRemote framework not found"});
            exit(1);
        }
        MR.registerForNotifications = (MRRegisterFn)dlsym(framework, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MR.getActiveClient = (MRGetClientFn)dlsym(framework, "MRMediaRemoteGetNowPlayingClient");
        MR.getClients = (MRGetClientsFn)dlsym(framework, "MRMediaRemoteGetNowPlayingClients");
        MR.clientBundleId = (MRClientStringFn)dlsym(framework, "MRNowPlayingClientGetBundleIdentifier");
        MR.clientParentBundleId = (MRClientStringFn)dlsym(framework, "MRNowPlayingClientGetParentAppBundleIdentifier");
        MR.clientDisplayName = (MRClientStringFn)dlsym(framework, "MRNowPlayingClientGetDisplayName");
        MR.sendCommand = (MRSendCommandFn)dlsym(framework, "MRMediaRemoteSendCommand");
        MR.setElapsed = (MRSetElapsedFn)dlsym(framework, "MRMediaRemoteSetElapsedTime");
        MROrigin = objc_getClass("MROrigin");
        MRPlayerPath = objc_getClass("MRPlayerPath");
        MRNowPlayingRequest = objc_getClass("MRNowPlayingRequest");
        if (!MR.registerForNotifications || !MR.getActiveClient || !MR.getClients || !MR.clientBundleId
            || !MR.sendCommand || !MROrigin || !MRPlayerPath || !MRNowPlayingRequest) {
            emit(@{@"type": @"error", @"message": @"MediaRemote API missing on this macOS version"});
            exit(1);
        }

        lastEmitted = [NSMutableDictionary dictionary];
        MR.registerForNotifications(dispatch_get_main_queue());
        // Any MediaRemote change (info, playing state, players coming and going, for any app).
        [NSNotificationCenter.defaultCenter addObserverForName:nil object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSString *name = note.name;
            if ([name hasPrefix:@"kMR"] || [name hasPrefix:@"MRPlayer"] || [name hasPrefix:@"MRNowPlaying"]) scheduleUpdate();
        }];

        stdinBuffer = [NSMutableData data];
        stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(stdinSource, ^{ readStdin(); });
        dispatch_resume(stdinSource);

        emit(@{@"type": @"ready"});
        refresh();
    }
    CFRunLoopRun();
}
