//
//  BackgroundKeepAlive.m
//  iSH+
//

@import AVFoundation;
#import "BackgroundKeepAlive.h"
#import "UserPreferences.h"
#import "NSObject+SaneKVO.h"
#import "iSHSwift.h"

@interface BackgroundKeepAlive ()
@property (nonatomic) AVAudioPlayer *player;
@property (nonatomic) BOOL enabled;
@end

@implementation BackgroundKeepAlive

+ (instancetype)shared {
    static BackgroundKeepAlive *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [BackgroundKeepAlive new];
    });
    return shared;
}

+ (void)start {
    BackgroundKeepAlive *keepAlive = [self shared];
    [UserPreferences.shared observe:@[@"keepAliveInBackground"]
                            options:NSKeyValueObservingOptionInitial
                              owner:keepAlive
                         usingBlock:^(typeof(keepAlive) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.enabled = UserPreferences.shared.keepAliveInBackground;
        });
    }];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:keepAlive
               selector:@selector(audioSessionInterrupted:)
                   name:AVAudioSessionInterruptionNotification
                 object:nil];
    [center addObserver:keepAlive
               selector:@selector(mediaServicesReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification
                 object:nil];
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled)
        return;
    _enabled = enabled;
    if (enabled)
        [self startPlaying];
    else
        [self stopPlaying];
}

// One second of 8 kHz mono 16-bit silence as a WAV file.
+ (NSData *)silence {
    const uint32_t sampleRate = 8000;
    const uint32_t dataSize = sampleRate * 2;
    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    void (^append32)(uint32_t) = ^(uint32_t v) { uint32_t le = CFSwapInt32HostToLittle(v); [wav appendBytes:&le length:4]; };
    void (^append16)(uint16_t) = ^(uint16_t v) { uint16_t le = CFSwapInt16HostToLittle(v); [wav appendBytes:&le length:2]; };
    [wav appendBytes:"RIFF" length:4];
    append32(36 + dataSize);
    [wav appendBytes:"WAVEfmt " length:8];
    append32(16);          // fmt chunk size
    append16(1);           // PCM
    append16(1);           // mono
    append32(sampleRate);
    append32(sampleRate * 2); // byte rate
    append16(2);           // block align
    append16(16);          // bits per sample
    [wav appendBytes:"data" length:4];
    append32(dataSize);
    [wav increaseLengthBy:dataSize];
    return wav;
}

- (void)startPlaying {
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // Mix with other audio so music and videos in other apps keep playing.
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error]) {
        NSLog(@"keep alive: could not set audio category: %@", error);
        return;
    }
    if (![session setActive:YES error:&error]) {
        NSLog(@"keep alive: could not activate audio session: %@", error);
        return;
    }
    if (self.player == nil) {
        self.player = [[AVAudioPlayer alloc] initWithData:[BackgroundKeepAlive silence] error:&error];
        if (self.player == nil) {
            NSLog(@"keep alive: could not create player: %@", error);
            return;
        }
        self.player.numberOfLoops = -1;
        self.player.volume = 0;
    }
    [self.player play];
}

- (void)stopPlaying {
    [self.player stop];
    self.player = nil;
    // Linux's sound card plays through the same audio session
    if (ISHVirtualMachine.shared.isRunning)
        return;
    [AVAudioSession.sharedInstance setActive:NO
                                 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                       error:nil];
}

- (void)audioSessionInterrupted:(NSNotification *)notification {
    AVAudioSessionInterruptionType type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeEnded && self.enabled) {
        // Resume after a phone call, Siri, an alarm or another app taking over the audio.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startPlaying];
        });
    }
}

- (void)mediaServicesReset:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.player = nil;
        if (self.enabled)
            [self startPlaying];
    });
}

@end
