//
//  SteamController.m
//  Moonlight
//
//  Bluetooth LE driver for the Valve Steam Controller (2026 model).
//
//  The GATT layout, report formats and setting numbers used here were learned
//  from SDL's open source Steam Controller support (src/hidapi/ios/hid.m and
//  src/joystick/hidapi/SDL_hidapi_steam_triton.c, zlib license).
//

#import "SteamController.h"
#import "Logger.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdarg.h>
#import <math.h>

@import CoreBluetooth;

// Valve's controller service. Each HID report gets its own characteristic.
static NSString * const kValveServiceUUID              = @"100F6C32-1735-4313-B402-38567131E5F3";
static NSString * const kLegacyInputCharacteristicUUID = @"100F6C33-1735-4313-B402-38567131E5F3"; // 2015 Steam Controller
static NSString * const kReportCharacteristicUUID      = @"100F6C34-1735-4313-B402-38567131E5F3"; // Feature reports
static NSString * const kInput45CharacteristicUUID     = @"100F6C7A-1735-4313-B402-38567131E5F3"; // Input report 0x45
static NSString * const kInput47CharacteristicUUID     = @"100F6C7C-1735-4313-B402-38567131E5F3"; // Input report 0x47
static NSString * const kRumbleCharacteristicUUID      = @"100F6CB5-1735-4313-B402-38567131E5F3"; // Output report 0x80
static NSString * const kDeviceInformationServiceUUID  = @"180A";

static NSString * const kSeenDefaultsKey = @"steamControllerSeen";
static NSString * const kLogFileName = @"steam-controller-log.txt";

enum {
    kInputReportLength   = 45,
    kFeatureReportLength = 64,
    kRumblePayloadLength = 9,

    kInputReport45 = 0x45,
    kInputReport47 = 0x47,

    kMessageSetSettings = 0x87,
    kSettingLizardMode  = 9,
    kSettingMotionMode  = 48,
    kMotionModeRawAccelAndGyro = 0x18,
};

// The controller falls back to keyboard and mouse emulation ("lizard mode") by
// itself a few seconds after it stops being told otherwise. SDL repeats the
// setting every 3 seconds, so this leaves some room for a late timer.
static const CFTimeInterval kSettingsInterval = 1.5;

// How often the periodic work in -tick runs
static const uint64_t kTickIntervalMs = 500;
static const int kTicksPerRateLog = 60;

// The controller stops rumbling about 50 ms after the last rumble report
static const uint64_t kRumbleResendIntervalMs = 40;

static const CFTimeInterval kScanDuration = 20.0;
static const CFTimeInterval kConnectTimeout = 30.0;
static const unsigned long long kMaxLogFileSize = 512 * 1024;

#pragma mark - Logging

static NSFileHandle *sLogHandle;
static NSDateFormatter *sLogDateFormatter;
static BOOL sLogOpenAttempted;

static dispatch_queue_t SCLogQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.moonlight-stream.steamcontroller.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void SCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Logs to the regular Moonlight log and to a text file in the Documents folder,
// which is the only log a user can get at without a Mac.
static void SCLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    Log(LOG_I, @"Steam Controller: %@", message);

    NSDate *now = [NSDate date];
    dispatch_async(SCLogQueue(), ^{
        if (!sLogOpenAttempted) {
            sLogOpenAttempted = YES;

            sLogDateFormatter = [[NSDateFormatter alloc] init];
            sLogDateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            sLogDateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

            NSString *directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            if (directory != nil) {
                NSString *path = [directory stringByAppendingPathComponent:kLogFileName];
                NSFileManager *fileManager = [NSFileManager defaultManager];

                // Start over when the log gets large
                NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:path error:nil];
                if (attributes != nil && [attributes fileSize] > kMaxLogFileSize) {
                    [fileManager removeItemAtPath:path error:nil];
                }
                if (![fileManager fileExistsAtPath:path]) {
                    [fileManager createFileAtPath:path contents:nil attributes:nil];
                }

                sLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
                if (sLogHandle != nil && ![sLogHandle seekToEndReturningOffset:NULL error:NULL]) {
                    sLogHandle = nil;
                }
            }
        }

        if (sLogHandle != nil) {
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", [sLogDateFormatter stringFromDate:now], message];
            if (![sLogHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding] error:NULL]) {
                sLogHandle = nil;
            }
        }
    });
}

static NSString *SCHexString(NSData *data)
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSMutableString *string = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [string appendFormat:@"%02x", bytes[i]];
    }
    return string;
}

// Valve's characteristic UUIDs only differ in their first 8 digits
static NSString *SCShortUUID(CBUUID *uuid)
{
    NSString *string = uuid.UUIDString;
    return string.length > 8 ? [string substringToIndex:8] : string;
}

static CBUUID *SCUUID(NSString *string)
{
    return [CBUUID UUIDWithString:string];
}

#pragma mark - Little endian readers

static inline uint16_t SCReadU16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static inline int16_t SCReadS16(const uint8_t *p)
{
    return (int16_t)SCReadU16(p);
}

static inline uint32_t SCReadU32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

#pragma mark - SteamControllerManager

@interface SteamControllerManager () <CBCentralManagerDelegate, CBPeripheralDelegate>

@property (atomic, readwrite) BOOL controllerReady;
@property (atomic, copy, readwrite) NSString *statusDescription;

@end

// Everything below runs on _queue unless noted otherwise
@implementation SteamControllerManager {
    dispatch_queue_t _queue;
    CBCentralManager *_central;
    dispatch_source_t _tickTimer;
    dispatch_source_t _rumbleTimer;

    // The controller we are connecting to or talking to
    CBPeripheral *_peripheral;
    CBCharacteristic *_inputCharacteristic;
    CBCharacteristic *_reportCharacteristic;
    CBCharacteristic *_rumbleCharacteristic;
    uint8_t _inputReportId;
    BOOL _ready;
    CFTimeInterval _adoptTime;
    NSMutableSet<NSUUID *> *_ignoredPeripherals;

    BOOL _scanning;
    CFTimeInterval _scanDeadline;

    BOOL _sessionActive;
    BOOL _motionEnabled;
    BOOL _motionNeedsDisable;
    CFTimeInterval _lastSettingsTime;

    uint16_t _rumbleLow;
    uint16_t _rumbleHigh;
    BOOL _rumbleWritePending;
    CFTimeInterval _rumbleWriteTime;

    uint32_t _lastMotionTimestamp;
    BOOL _haveMotionTimestamp;

    // Diagnostics
    NSUInteger _reportCount;
    CFTimeInterval _rateSampleTime;
    int _reportRateHz;
    int _ticksSinceRateLog;
    NSUInteger _loggedReports;
    NSUInteger _shortReports;
    NSUInteger _loggedWriteErrors;
    NSUInteger _loggedNotifyErrors;
    BOOL _loggedNotifyState;
    BOOL _loggedSettingsAck;
}

// Any queue
+ (instancetype)sharedManager
{
    static SteamControllerManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [[SteamControllerManager alloc] init];
    });
    return manager;
}

// Any queue
+ (BOOL)isBluetoothAuthorized
{
    if (@available(iOS 13.1, tvOS 13.0, *)) {
        return CBManager.authorization == CBManagerAuthorizationAllowedAlways;
    }
    return NO;
}

// Any queue
+ (BOOL)controllerSeenBefore
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSeenDefaultsKey];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        // Reports must be consumed promptly. iOS can quietly stop delivering
        // notifications to an app that is slow to pick them up.
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _queue = dispatch_queue_create("com.moonlight-stream.steamcontroller.ble", attributes);
        _ignoredPeripherals = [[NSMutableSet alloc] init];
        _statusDescription = @"Steam Controller: Bluetooth not started";
    }
    return self;
}

#pragma mark - Public API (any queue)

- (void)start
{
    dispatch_async(_queue, ^{
        if (self->_central != nil) {
            [self checkConnectedPeripherals];
            return;
        }

        SCLog(@"starting Bluetooth");
        [self setStatus:@"starting Bluetooth"];

        self->_central = [[CBCentralManager alloc] initWithDelegate:self
                                                              queue:self->_queue
                                                            options:@{ CBCentralManagerOptionShowPowerAlertKey : @NO }];
        [self startTickTimer];

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(applicationDidBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(applicationDidEnterBackground:)
                       name:UIApplicationDidEnterBackgroundNotification
                     object:nil];
    });
}

- (void)setSessionActive:(BOOL)active
{
    dispatch_async(_queue, ^{
        if (self->_sessionActive == active) {
            return;
        }

        self->_sessionActive = active;
        SCLog(@"streaming session %@", active ? @"started" : @"ended");

        if (active) {
            // Scanning shares the radio with Wi-Fi, so never do it while streaming
            [self stopScan];
            [self checkConnectedPeripherals];

            if (self->_ready) {
                [self writeSettingsWithLizardMode:NO];
            }
        }
        else {
            BOOL wasRumbling = (self->_rumbleLow != 0 || self->_rumbleHigh != 0);
            self->_rumbleLow = 0;
            self->_rumbleHigh = 0;
            [self stopRumbleTimer];

            if (self->_motionEnabled) {
                self->_motionEnabled = NO;
                self->_motionNeedsDisable = YES;
            }

            if (self->_ready) {
                if (wasRumbling) {
                    [self writeRumble];
                }

                // Hand keyboard and mouse emulation back right away rather
                // than leaving it to the controller's watchdog
                [self writeSettingsWithLizardMode:YES];
            }
        }
    });
}

- (void)setMotionSensorsEnabled:(BOOL)enabled
{
    dispatch_async(_queue, ^{
        if (self->_motionEnabled == enabled) {
            return;
        }

        self->_motionEnabled = enabled;
        self->_motionNeedsDisable = !enabled;
        self->_haveMotionTimestamp = NO;
        SCLog(@"motion sensors %@", enabled ? @"enabled" : @"disabled");

        if (self->_ready && self->_sessionActive) {
            [self writeSettingsWithLizardMode:NO];
        }
    });
}

- (void)setRumbleLowFrequency:(uint16_t)lowFrequency highFrequency:(uint16_t)highFrequency
{
    dispatch_async(_queue, ^{
        BOOL wasRumbling = (self->_rumbleLow != 0 || self->_rumbleHigh != 0);
        BOOL rumbling = (lowFrequency != 0 || highFrequency != 0);

        self->_rumbleLow = lowFrequency;
        self->_rumbleHigh = highFrequency;

        if (!self->_ready || !self->_sessionActive) {
            return;
        }

        if (rumbling || wasRumbling) {
            [self writeRumble];
        }

        if (rumbling) {
            [self startRumbleTimer];
        }
        else {
            [self stopRumbleTimer];
        }
    });
}

#pragma mark - App lifecycle (main queue)

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    dispatch_async(_queue, ^{
        [self->_ignoredPeripherals removeAllObjects];
        [self checkConnectedPeripherals];

        if (!self->_sessionActive) {
            [self scanForSeconds:kScanDuration];
        }
    });
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    dispatch_async(_queue, ^{
        [self stopScan];

        // We can't service the controller while suspended, and a subscription
        // left open across a suspension may never deliver reports again.
        // We reconnect when the app becomes active.
        if (self->_peripheral != nil) {
            SCLog(@"app entered the background; releasing the controller");
            [self dropPeripheralAndCancelConnection:YES];
        }
    });
}

#pragma mark - Status

- (void)setStatus:(NSString *)status
{
    self.statusDescription = [@"Steam Controller: " stringByAppendingString:status];
}

- (void)updateReadyStatus
{
    [self setStatus:[NSString stringWithFormat:@"connected, %d reports/s", _reportRateHz]];
}

#pragma mark - Finding the controller

- (BOOL)isCandidatePeripheral:(CBPeripheral *)peripheral name:(NSString *)name
{
    // The controller names itself "Steam Ctrl (BT) ..." in Bluetooth mode
    return name != nil && [name hasPrefix:@"Steam"] && ![_ignoredPeripherals containsObject:peripheral.identifier];
}

// A controller that was paired in Settings is already connected to iOS as a
// keyboard and mouse. It doesn't advertise in that state, so it can't be found
// by scanning. We have to ask for it.
- (void)checkConnectedPeripherals
{
    if (_central == nil || _central.state != CBManagerStatePoweredOn || _peripheral != nil) {
        return;
    }

    NSArray<CBUUID *> *services = @[ SCUUID(kValveServiceUUID), SCUUID(kDeviceInformationServiceUUID) ];
    for (CBPeripheral *peripheral in [_central retrieveConnectedPeripheralsWithServices:services]) {
        if ([self isCandidatePeripheral:peripheral name:peripheral.name]) {
            [self adoptPeripheral:peripheral how:@"already connected to this device"];
            return;
        }
    }
}

// Finds controllers in pairing mode that haven't been paired with this device yet
- (void)scanForSeconds:(CFTimeInterval)seconds
{
    if (_central == nil || _central.state != CBManagerStatePoweredOn || _peripheral != nil) {
        return;
    }

    _scanDeadline = CACurrentMediaTime() + seconds;

    if (!_scanning) {
        _scanning = YES;
        SCLog(@"scanning for controllers in pairing mode");
        [_central scanForPeripheralsWithServices:nil options:nil];
    }
}

- (void)stopScan
{
    if (!_scanning) {
        return;
    }

    _scanning = NO;
    if (_central.state == CBManagerStatePoweredOn) {
        [_central stopScan];
    }
}

- (void)adoptPeripheral:(CBPeripheral *)peripheral how:(NSString *)how
{
    if (_peripheral != nil) {
        return;
    }

    [self stopScan];

    SCLog(@"found \"%@\" (%@); connecting", peripheral.name, how);
    [self setStatus:@"connecting"];

    _peripheral = peripheral;
    _peripheral.delegate = self;
    _adoptTime = CACurrentMediaTime();

    [_central connectPeripheral:peripheral options:nil];
}

- (void)dropPeripheralAndCancelConnection:(BOOL)cancelConnection
{
    CBPeripheral *peripheral = _peripheral;
    BOOL wasReady = _ready;

    [self stopRumbleTimer];

    _peripheral = nil;
    _inputCharacteristic = nil;
    _reportCharacteristic = nil;
    _rumbleCharacteristic = nil;
    _inputReportId = 0;
    _ready = NO;
    _rumbleWritePending = NO;
    _haveMotionTimestamp = NO;
    _reportCount = 0;
    _reportRateHz = 0;
    _ticksSinceRateLog = 0;
    _loggedReports = 0;
    _shortReports = 0;
    _loggedWriteErrors = 0;
    _loggedNotifyErrors = 0;
    _loggedNotifyState = NO;
    _loggedSettingsAck = NO;

    self.controllerReady = NO;

    if (peripheral != nil) {
        peripheral.delegate = nil;

        if (cancelConnection && _central.state == CBManagerStatePoweredOn) {
            // This only ends our use of the controller. iOS keeps its own
            // connection to a paired controller.
            [_central cancelPeripheralConnection:peripheral];
        }
    }

    [self setStatus:@"searching"];

    if (wasReady) {
        id<SteamControllerDelegate> delegate = self.delegate;
        [delegate steamControllerDidDisconnect:self];
    }
}

- (void)ignoreAndDropPeripheral
{
    if (_peripheral != nil) {
        [_ignoredPeripherals addObject:_peripheral.identifier];
    }

    [self dropPeripheralAndCancelConnection:YES];
}

#pragma mark - Periodic work

- (void)startTickTimer
{
    if (_tickTimer != nil) {
        return;
    }

    _tickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_tickTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTickIntervalMs * NSEC_PER_MSEC)),
                              kTickIntervalMs * NSEC_PER_MSEC,
                              50 * NSEC_PER_MSEC);

    __weak SteamControllerManager *weakSelf = self;
    dispatch_source_set_event_handler(_tickTimer, ^{
        [weakSelf tick];
    });
    dispatch_resume(_tickTimer);
}

- (void)tick
{
    if (_central.state != CBManagerStatePoweredOn) {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();

    if (_scanning && now >= _scanDeadline) {
        [self stopScan];
    }

    if (_peripheral == nil) {
        // Picks up a controller that was switched on after we started
        [self checkConnectedPeripherals];
        return;
    }

    if (!_ready) {
        if (_inputCharacteristic != nil && _peripheral.state == CBPeripheralStateConnected) {
            // Subscribing quietly fails until the user accepts the pairing
            // request, and CoreBluetooth doesn't tell us when they do.
            [_peripheral setNotifyValue:YES forCharacteristic:_inputCharacteristic];
        }

        if (now - _adoptTime > kConnectTimeout) {
            SCLog(@"no input after %d seconds; starting over", (int)kConnectTimeout);
            [self dropPeripheralAndCancelConnection:YES];
        }
        return;
    }

    CFTimeInterval elapsed = now - _rateSampleTime;
    if (elapsed >= 1.0) {
        _reportRateHz = (int)lround((double)_reportCount / elapsed);
        _reportCount = 0;
        _rateSampleTime = now;
        [self updateReadyStatus];
    }

    if (++_ticksSinceRateLog >= kTicksPerRateLog) {
        _ticksSinceRateLog = 0;
        SCLog(@"receiving %d reports per second%@", _reportRateHz, _sessionActive ? @" (streaming)" : @"");
    }

    if (_sessionActive && now - _lastSettingsTime >= kSettingsInterval) {
        [self writeSettingsWithLizardMode:NO];
    }
}

#pragma mark - Writing to the controller

- (void)writeSettingsWithLizardMode:(BOOL)lizardMode
{
    if (_peripheral == nil || _reportCharacteristic == nil) {
        return;
    }

    // A "set settings" feature report: message type, payload length, then one
    // (setting number, 16-bit little endian value) entry per setting.
    uint8_t message[kFeatureReportLength] = { 0 };
    uint8_t length = 0;

    message[0] = kMessageSetSettings;

    message[2 + length++] = kSettingLizardMode;
    message[2 + length++] = lizardMode ? 1 : 0;
    message[2 + length++] = 0;

    if (_motionEnabled || _motionNeedsDisable) {
        uint16_t motionMode = _motionEnabled ? kMotionModeRawAccelAndGyro : 0;

        message[2 + length++] = kSettingMotionMode;
        message[2 + length++] = (uint8_t)(motionMode & 0xFF);
        message[2 + length++] = (uint8_t)(motionMode >> 8);

        _motionNeedsDisable = NO;
    }

    message[1] = length;

    [_peripheral writeValue:[NSData dataWithBytes:message length:sizeof(message)]
          forCharacteristic:_reportCharacteristic
                       type:CBCharacteristicWriteWithResponse];

    _lastSettingsTime = CACurrentMediaTime();
}

- (void)writeRumble
{
    if (_peripheral == nil || _rumbleCharacteristic == nil) {
        return;
    }

    // Output report 0x80 without its report ID: effect type, intensity, then
    // a (16-bit speed, gain) pair for the left and the right actuator.
    uint8_t payload[kRumblePayloadLength] = { 0 };
    payload[3] = (uint8_t)(_rumbleLow & 0xFF);
    payload[4] = (uint8_t)(_rumbleLow >> 8);
    payload[6] = (uint8_t)(_rumbleHigh & 0xFF);
    payload[7] = (uint8_t)(_rumbleHigh >> 8);

    NSData *data = [NSData dataWithBytes:payload length:sizeof(payload)];

    if (_rumbleCharacteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) {
        [_peripheral writeValue:data forCharacteristic:_rumbleCharacteristic type:CBCharacteristicWriteWithoutResponse];
    }
    else {
        _rumbleWritePending = YES;
        _rumbleWriteTime = CACurrentMediaTime();
        [_peripheral writeValue:data forCharacteristic:_rumbleCharacteristic type:CBCharacteristicWriteWithResponse];
    }
}

- (void)startRumbleTimer
{
    if (_rumbleTimer != nil) {
        return;
    }

    _rumbleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_rumbleTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRumbleResendIntervalMs * NSEC_PER_MSEC)),
                              kRumbleResendIntervalMs * NSEC_PER_MSEC,
                              5 * NSEC_PER_MSEC);

    __weak SteamControllerManager *weakSelf = self;
    dispatch_source_set_event_handler(_rumbleTimer, ^{
        [weakSelf rumbleTimerFired];
    });
    dispatch_resume(_rumbleTimer);
}

- (void)stopRumbleTimer
{
    if (_rumbleTimer != nil) {
        dispatch_source_cancel(_rumbleTimer);
        _rumbleTimer = nil;
    }
}

- (void)rumbleTimerFired
{
    if (!_ready || (_rumbleLow == 0 && _rumbleHigh == 0)) {
        [self stopRumbleTimer];
        return;
    }

    // Don't queue writes faster than the controller acknowledges them
    if (_rumbleWritePending && CACurrentMediaTime() - _rumbleWriteTime < 0.5) {
        return;
    }

    [self writeRumble];
}

#pragma mark - Reading from the controller

- (void)parseReport:(const uint8_t *)report intoState:(SteamControllerState *)state
{
    memset(state, 0, sizeof(*state));

    // Byte 0 is a sequence number
    state->buttons = SCReadU32(report + 1);
    state->leftTrigger = SCReadS16(report + 5);
    state->rightTrigger = SCReadS16(report + 7);
    state->leftStickX = SCReadS16(report + 9);
    state->leftStickY = SCReadS16(report + 11);
    state->rightStickX = SCReadS16(report + 13);
    state->rightStickY = SCReadS16(report + 15);

    // Report 0x47 puts a 16-bit trackpad timestamp ahead of the trackpad data
    // and shrinks the motion timestamp from 32 to 16 bits to make room for it.
    // The motion samples end up at the same offsets in both formats.
    const uint8_t *pads;
    uint32_t motionTimestamp;
    if (_inputReportId == kInputReport47) {
        pads = report + 19;
        motionTimestamp = SCReadU16(report + 31);
    }
    else {
        pads = report + 17;
        motionTimestamp = SCReadU32(report + 29);
    }

    state->leftPadX = SCReadS16(pads + 0);
    state->leftPadY = SCReadS16(pads + 2);
    state->leftPadPressure = SCReadU16(pads + 4);
    state->rightPadX = SCReadS16(pads + 6);
    state->rightPadY = SCReadS16(pads + 8);
    state->rightPadPressure = SCReadU16(pads + 10);

    state->accelX = SCReadS16(report + 33);
    state->accelY = SCReadS16(report + 35);
    state->accelZ = SCReadS16(report + 37);
    state->gyroX = SCReadS16(report + 39);
    state->gyroY = SCReadS16(report + 41);
    state->gyroZ = SCReadS16(report + 43);

    // The timestamp only moves when the controller has taken a new sample
    state->hasMotionSample = _motionEnabled && (!_haveMotionTimestamp || motionTimestamp != _lastMotionTimestamp);
    _lastMotionTimestamp = motionTimestamp;
    _haveMotionTimestamp = YES;
}

- (void)handleInputReport:(NSData *)data
{
    if (_loggedReports < 3) {
        _loggedReports++;
        SCLog(@"input report 0x%02x (%lu bytes): %@", _inputReportId, (unsigned long)data.length, SCHexString(data));
    }

    if (data.length < kInputReportLength) {
        if (_shortReports++ == 0) {
            SCLog(@"ignoring input reports shorter than %d bytes", kInputReportLength);
        }
        return;
    }

    _reportCount++;

    if (!_ready) {
        // The first report is the only sign we get that pairing has completed
        // and the subscription is live
        _ready = YES;
        _rateSampleTime = CACurrentMediaTime();
        _reportCount = 0;
        self.controllerReady = YES;

        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kSeenDefaultsKey];

        SCLog(@"controller is ready");
        [self setStatus:@"connected"];

        if (_sessionActive) {
            [self writeSettingsWithLizardMode:NO];
        }

        id<SteamControllerDelegate> readyDelegate = self.delegate;
        [readyDelegate steamControllerDidBecomeReady:self];
    }

    if (!_sessionActive) {
        return;
    }

    SteamControllerState state;
    [self parseReport:(const uint8_t *)data.bytes intoState:&state];

    id<SteamControllerDelegate> delegate = self.delegate;
    [delegate steamController:self didUpdateState:&state];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    switch (central.state) {
        case CBManagerStatePoweredOn:
            SCLog(@"Bluetooth is on");
            [self setStatus:@"searching"];
            [self checkConnectedPeripherals];
            if (_peripheral == nil && !_sessionActive) {
                [self scanForSeconds:kScanDuration];
            }
            break;

        case CBManagerStatePoweredOff:
            SCLog(@"Bluetooth is off");
            _scanning = NO;
            [self dropPeripheralAndCancelConnection:NO];
            [self setStatus:@"Bluetooth is turned off"];
            break;

        case CBManagerStateUnauthorized:
            SCLog(@"Bluetooth permission was denied");
            _scanning = NO;
            [self dropPeripheralAndCancelConnection:NO];
            [self setStatus:@"Bluetooth permission is off for Moonlight"];
            break;

        default:
            SCLog(@"Bluetooth is unavailable (state %ld)", (long)central.state);
            _scanning = NO;
            [self dropPeripheralAndCancelConnection:NO];
            [self setStatus:@"Bluetooth is unavailable"];
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI
{
    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey];
    if (name == nil) {
        name = peripheral.name;
    }

    if ([self isCandidatePeripheral:peripheral name:name]) {
        [self adoptPeripheral:peripheral how:@"in pairing mode nearby"];
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    if (peripheral != _peripheral) {
        return;
    }

    SCLog(@"connected; reading services");
    [self setStatus:@"reading controller services"];
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    if (peripheral != _peripheral) {
        return;
    }

    SCLog(@"failed to connect: %@", error.localizedDescription);
    [self dropPeripheralAndCancelConnection:NO];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    if (peripheral != _peripheral) {
        return;
    }

    if (error != nil) {
        SCLog(@"disconnected: %@", error.localizedDescription);
    }
    else {
        SCLog(@"disconnected");
    }
    [self dropPeripheralAndCancelConnection:NO];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    if (peripheral != _peripheral) {
        return;
    }

    if (error != nil) {
        SCLog(@"couldn't read services: %@", error.localizedDescription);
        [self dropPeripheralAndCancelConnection:YES];
        return;
    }

    CBService *valveService = nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (CBService *service in peripheral.services) {
        [names addObject:SCShortUUID(service.UUID)];
        if ([service.UUID isEqual:SCUUID(kValveServiceUUID)]) {
            valveService = service;
        }
    }
    SCLog(@"services: %@", [names componentsJoinedByString:@" "]);

    if (valveService == nil) {
        SCLog(@"no Valve controller service on this device; ignoring it");
        [self ignoreAndDropPeripheral];
        return;
    }

    [peripheral discoverCharacteristics:nil forService:valveService];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    if (peripheral != _peripheral || ![service.UUID isEqual:SCUUID(kValveServiceUUID)]) {
        return;
    }

    if (error != nil) {
        SCLog(@"couldn't read characteristics: %@", error.localizedDescription);
        [self dropPeripheralAndCancelConnection:YES];
        return;
    }

    CBCharacteristic *input45 = nil;
    CBCharacteristic *input47 = nil;
    BOOL isFirstGeneration = NO;
    NSMutableArray<NSString *> *names = [NSMutableArray array];

    for (CBCharacteristic *characteristic in service.characteristics) {
        [names addObject:[NSString stringWithFormat:@"%@/%02lx", SCShortUUID(characteristic.UUID), (unsigned long)characteristic.properties]];

        if ([characteristic.UUID isEqual:SCUUID(kInput47CharacteristicUUID)]) {
            input47 = characteristic;
        }
        else if ([characteristic.UUID isEqual:SCUUID(kInput45CharacteristicUUID)]) {
            input45 = characteristic;
        }
        else if ([characteristic.UUID isEqual:SCUUID(kReportCharacteristicUUID)]) {
            _reportCharacteristic = characteristic;
        }
        else if ([characteristic.UUID isEqual:SCUUID(kRumbleCharacteristicUUID)]) {
            _rumbleCharacteristic = characteristic;
        }
        else if ([characteristic.UUID isEqual:SCUUID(kLegacyInputCharacteristicUUID)]) {
            isFirstGeneration = YES;
        }
    }
    SCLog(@"characteristics (id/properties): %@", [names componentsJoinedByString:@" "]);

    // Newer firmware offers both input reports. Prefer the newer one, like SDL does.
    if (input47 != nil) {
        _inputCharacteristic = input47;
        _inputReportId = kInputReport47;
    }
    else if (input45 != nil) {
        _inputCharacteristic = input45;
        _inputReportId = kInputReport45;
    }
    else {
        SCLog(@"%@", isFirstGeneration ? @"this is a first generation Steam Controller, which isn't supported"
                                       : @"no known input report on this controller; its firmware isn't supported");
        [self ignoreAndDropPeripheral];
        return;
    }

    SCLog(@"using input report 0x%02x; settings %@; rumble %@",
          _inputReportId,
          _reportCharacteristic != nil ? @"available" : @"unavailable",
          _rumbleCharacteristic != nil ? @"available" : @"unavailable");
    [self setStatus:@"waiting for input (accept the pairing request if one appears)"];

    [peripheral setNotifyValue:YES forCharacteristic:_inputCharacteristic];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if (peripheral != _peripheral) {
        return;
    }

    if (error != nil) {
        if (_loggedNotifyErrors < 5) {
            _loggedNotifyErrors++;
            SCLog(@"couldn't subscribe to input yet: %@", error.localizedDescription);
        }
    }
    else if (!_loggedNotifyState) {
        _loggedNotifyState = YES;
        SCLog(@"subscribed to input (notifying: %d)", characteristic.isNotifying ? 1 : 0);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if (peripheral != _peripheral || _inputCharacteristic == nil || ![characteristic.UUID isEqual:_inputCharacteristic.UUID]) {
        return;
    }

    NSData *data = characteristic.value;
    if (error != nil || data == nil) {
        return;
    }

    [self handleInputReport:data];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if (peripheral != _peripheral) {
        return;
    }

    if (_rumbleCharacteristic != nil && [characteristic.UUID isEqual:_rumbleCharacteristic.UUID]) {
        _rumbleWritePending = NO;
    }

    if (error != nil) {
        if (_loggedWriteErrors < 5) {
            _loggedWriteErrors++;
            SCLog(@"write to %@ failed: %@", SCShortUUID(characteristic.UUID), error.localizedDescription);
        }
    }
    else if (!_loggedSettingsAck && _reportCharacteristic != nil && [characteristic.UUID isEqual:_reportCharacteristic.UUID]) {
        _loggedSettingsAck = YES;
        SCLog(@"controller accepted the settings write");
    }
}

@end
