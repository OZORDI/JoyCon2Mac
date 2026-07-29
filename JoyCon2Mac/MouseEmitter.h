#ifndef MOUSE_EMITTER_H
#define MOUSE_EMITTER_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "DriverKitClient.h"
#include "JoyConDecoder.h"

// Mouse mode cycle matches joycon2cpp/testapp/src/testapp.cpp exactly:
//   0 = OFF, 1 = FAST (sens 1.0), 2 = NORMAL (sens 0.6), 3 = SLOW (sens 0.3)
// Do not reorder these — main.mm and the GUI depend on these raw values.
typedef NS_ENUM(NSInteger, MouseMode) {
    MouseModeOff    = 0,
    MouseModeFast   = 1,
    MouseModeNormal = 2,
    MouseModeSlow   = 3
};

// Which Joy-Con drives the mouse. joycon2cpp only implements Right, but the
// Joy-Con 2 (L) also carries an optical sensor and reports distance at the
// same packet offset. Auto picks whichever side is currently reading distance
// zero (resting on a surface), falling back to the last-active side if both are
// on surfaces.
typedef NS_ENUM(NSInteger, MouseSource) {
    MouseSourceAuto  = 0,
    MouseSourceLeft  = 1,
    MouseSourceRight = 2
};

typedef NS_ENUM(NSInteger, PointerMethod) {
    PointerMethodOptical = 0,
    PointerMethodGyro    = 1
};

typedef NS_ENUM(NSInteger, GyroMouseSource) {
    GyroMouseSourceFused = 0,
    GyroMouseSourceLeft  = 1,
    GyroMouseSourceRight = 2
};

struct GyroPointerSample {
    MotionData motion = {0, 0, 0, 0, 0, 0};
    double timestamp = 0;
    float biasX = 0;
    float biasY = 0;
    float biasZ = 0;
    double stationaryStart = 0;
    double sumX = 0;
    double sumY = 0;
    double sumZ = 0;
    uint32_t stationarySamples = 0;
    bool valid = false;
    bool biasValid = false;
    bool manualPending = false;
    bool surfaceKnown = false;
    bool onSurface = false;
    bool rearmPending = false;
    double rearmStillStart = 0;
};

@interface MouseEmitter : NSObject {
@private
    GyroPointerSample _gyroLeft;
    GyroPointerSample _gyroRight;
    dispatch_source_t _gyroTimer;
    double _gyroLastTick;
    double _gyroFractionX;
    double _gyroFractionY;
    BOOL _gyroTogglePressedLeft;
    BOOL _gyroTogglePressedRight;
    uint32_t _gyroButtonStateLeft;
    uint32_t _gyroButtonStateRight;
    double _gyroButtonTimestampLeft;
    double _gyroButtonTimestampRight;
    NSString *_gyroActiveSourceName;
    BOOL _gyroCalibrating;
    BOOL _opticalGestureChordActive;
    BOOL _opticalGestureTriggered;
    double _opticalGestureX;
    double _opticalGestureY;
}

@property (nonatomic, assign) MouseMode currentMode;
@property (nonatomic, assign) MouseSource source;
@property (nonatomic, assign) PointerMethod pointerMethod;
@property (nonatomic, assign) GyroMouseSource gyroSource;
@property (nonatomic, assign, getter=isGyroAimingEnabled) BOOL gyroAimingEnabled;
@property (nonatomic, copy) NSString *leftGyroToggleBinding;
@property (nonatomic, copy) NSString *rightGyroToggleBinding;
@property (nonatomic, assign) DriverKitClient *driverClient;

// The side the last optical sample was actually consumed from. Exposed so
// main.mm can emit it as telemetry (the GUI shows "Active: Left/Right").
@property (nonatomic, readonly, assign) JoyConSide lastActiveSide;
@property (nonatomic, readonly, copy) NSString *gyroActiveSourceName;
@property (nonatomic, readonly, assign, getter=isGyroCalibrating) BOOL gyroCalibrating;

- (instancetype)initWithDriverClient:(DriverKitClient *)client;

// Feed a fresh Joy-Con input buffer. Replaces the Right-only method. The
// emitter decides whether this packet is from the active side (using
// `source` + auto detection based on mouseDistance) and only then runs the
// mouse logic on it. If consumed, `buffer` is mutated to clear the HID bits
// the mouse used so the virtual gamepad doesn't see them either, mirroring
// joycon2cpp/testapp/src/testapp.cpp's suppression step.
//
// Returns YES if this packet was consumed as mouse input (so callers can
// re-decode buttons/stick from the stripped buffer before handing it to the
// DS4/HID report path). Returns NO otherwise — use the untouched buffer for
// the gamepad report.
- (BOOL)processBuffer:(std::vector<uint8_t> &)buffer
                 side:(JoyConSide)side
          buttonState:(uint32_t)btnState
         stickReading:(StickData)stickData
        mouseDistance:(uint16_t)mouseDistance;

// Feed the latest per-side IMU and buttons into the free-air pointer path.
// Returns the physical button bit consumed as the gyro activation toggle,
// or zero when no gamepad button needs suppressing.
- (uint32_t)processGyroMotion:(MotionData)motion
                         side:(JoyConSide)side
                  buttonState:(uint32_t)buttonState;

- (void)requestGyroCalibration;
- (void)resetGyroAiming;

// True when mouse mode is enabled and this side is the current on-surface
// mouse owner. The gamepad path uses this to remove that Joy-Con from the
// virtual DualSense report until it is lifted again.
- (BOOL)isSideMouseOwned:(JoyConSide)side;

@end

#endif // MOUSE_EMITTER_H
