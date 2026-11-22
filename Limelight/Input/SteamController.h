//
//  SteamController.h
//  Moonlight
//
//  Bluetooth LE driver for the Valve Steam Controller (2026 model).
//
//  iOS does not expose this controller through the GameController framework,
//  so we talk to Valve's GATT service directly, the same way Steam Link does.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Button bits exactly as the controller reports them
typedef NS_OPTIONS(uint32_t, SteamControllerButton) {
    SteamControllerButtonA                 = 0x00000001,
    SteamControllerButtonB                 = 0x00000002,
    SteamControllerButtonX                 = 0x00000004,
    SteamControllerButtonY                 = 0x00000008,
    SteamControllerButtonQuickAccess       = 0x00000010,
    SteamControllerButtonRightStick        = 0x00000020,
    SteamControllerButtonView              = 0x00000040, // Behaves as Start
    SteamControllerButtonR4                = 0x00000080,
    SteamControllerButtonR5                = 0x00000100,
    SteamControllerButtonRightBumper       = 0x00000200,
    SteamControllerButtonDpadDown          = 0x00000400,
    SteamControllerButtonDpadRight         = 0x00000800,
    SteamControllerButtonDpadLeft          = 0x00001000,
    SteamControllerButtonDpadUp            = 0x00002000,
    SteamControllerButtonMenu              = 0x00004000, // Behaves as Back/Select
    SteamControllerButtonLeftStick         = 0x00008000,
    SteamControllerButtonSteam             = 0x00010000,
    SteamControllerButtonL4                = 0x00020000,
    SteamControllerButtonL5                = 0x00040000,
    SteamControllerButtonLeftBumper        = 0x00080000,
    SteamControllerButtonRightStickTouch   = 0x00100000,
    SteamControllerButtonRightPadTouch     = 0x00200000,
    SteamControllerButtonRightPadClick     = 0x00400000,
    SteamControllerButtonRightTriggerClick = 0x00800000,
    SteamControllerButtonLeftStickTouch    = 0x01000000,
    SteamControllerButtonLeftPadTouch      = 0x02000000,
    SteamControllerButtonLeftPadClick      = 0x04000000,
    SteamControllerButtonLeftTriggerClick  = 0x08000000,
    SteamControllerButtonRightGripTouch    = 0x10000000,
    SteamControllerButtonLeftGripTouch     = 0x20000000,
};

// Raw motion sensor scale factors
#define STEAM_CONTROLLER_ACCEL_UNITS_PER_G   16384.0f
#define STEAM_CONTROLLER_GYRO_UNITS_PER_DPS  16.384f

typedef struct {
    uint32_t buttons;           // SteamControllerButton bits

    int16_t leftTrigger;        // 0 ... 32767
    int16_t rightTrigger;       // 0 ... 32767

    int16_t leftStickX;         // -32768 ... 32767, positive is right
    int16_t leftStickY;         // -32768 ... 32767, positive is up
    int16_t rightStickX;
    int16_t rightStickY;

    int16_t leftPadX;           // -32768 ... 32767, positive is right
    int16_t leftPadY;           // -32768 ... 32767, positive is up
    uint16_t leftPadPressure;   // 0 ... 32767
    int16_t rightPadX;
    int16_t rightPadY;
    uint16_t rightPadPressure;

    BOOL hasMotionSample;       // YES when this report carries a new motion sample
    int16_t accelX;             // Raw, in the controller's own axes
    int16_t accelY;
    int16_t accelZ;
    int16_t gyroX;
    int16_t gyroY;
    int16_t gyroZ;
} SteamControllerState;

@class SteamControllerManager;

// All delegate methods are called on the manager's private Bluetooth queue,
// never on the main queue.
@protocol SteamControllerDelegate <NSObject>

- (void)steamControllerDidBecomeReady:(SteamControllerManager *)manager;
- (void)steamControllerDidDisconnect:(SteamControllerManager *)manager;
- (void)steamController:(SteamControllerManager *)manager didUpdateState:(const SteamControllerState *)state;

@end

@interface SteamControllerManager : NSObject

+ (instancetype)sharedManager;

// YES if Bluetooth can be used without showing the system permission prompt
+ (BOOL)isBluetoothAuthorized;

// Powers up Bluetooth and starts looking for a Steam Controller. This shows the
// system Bluetooth permission prompt the first time it's called. Safe to call again.
- (void)start;

// While a session is active, the controller's built-in keyboard and mouse
// emulation is turned off and input reports are forwarded to the delegate.
- (void)setSessionActive:(BOOL)active;

// Motion samples are only produced while motion sensors are enabled
- (void)setMotionSensorsEnabled:(BOOL)enabled;

// Values use the full 16-bit range. Pass zeros to stop.
- (void)setRumbleLowFrequency:(uint16_t)lowFrequency highFrequency:(uint16_t)highFrequency;

@property (atomic, weak, nullable) id<SteamControllerDelegate> delegate;

// YES once a controller is connected and delivering input
@property (atomic, readonly) BOOL controllerReady;

// YES if a Steam Controller has ever worked with this app on this device
@property (class, nonatomic, readonly) BOOL controllerSeenBefore;

// One-line, human readable connection state for on-screen diagnostics
@property (atomic, copy, readonly) NSString *statusDescription;

// The driver's most recent log lines, oldest first, separated by newlines.
// Empty if nothing has been logged.
- (NSString *)recentLogWithLineLimit:(NSUInteger)lineLimit;

@end

NS_ASSUME_NONNULL_END
