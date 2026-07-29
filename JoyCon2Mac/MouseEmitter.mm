#import "MouseEmitter.h"
#import <ApplicationServices/ApplicationServices.h>
#include <algorithm>
#include <cstdlib>
#include <cmath>
#include <cstdint>
#include <ctime>

// Structurally a port of the single-Right-JoyCon mouse handler from
// joycon2cpp/testapp/src/testapp.cpp, extended so the left Joy-Con 2 can
// also drive the mouse. joycon2cpp's reference only wires it up for the
// right side, but both Joy-Con 2 halves carry the same optical sensor at
// packet offset 0x10..0x13 and distance flag at 0x17, so the same decode
// logic applies verbatim.
//
// Constants kept byte-for-byte with joycon2cpp:
//   scroll deadzone 4000, scroll cap 40 per packet, 120 units per wheel
//   click, XY side-button threshold 28000, sensitivities 1.0/0.6/0.3.

@interface MouseEmitter ()
// Per-side optical history. When the active side switches (either the user
// changed the picker or auto-detection flipped because the other Joy-Con
// just landed on a surface) we use the captured LAST value for *that* side,
// not the other side's last value. Using the wrong side's last value is
// where the "spazz out" came from — the delta was effectively (thisX -
// otherX) which is a random huge number.
@property (nonatomic, assign) BOOL firstOpticalReadLeft;
@property (nonatomic, assign) BOOL firstOpticalReadRight;
@property (nonatomic, assign) int16_t lastOpticalXLeft;
@property (nonatomic, assign) int16_t lastOpticalYLeft;
@property (nonatomic, assign) int16_t lastOpticalXRight;
@property (nonatomic, assign) int16_t lastOpticalYRight;
@property (nonatomic, assign) float scrollAccumulator;

// Per-side rolling state used by Auto to decide which Joy-Con owns the
// pointer. `lastDistance*` is the latest surface-distance reading; `airFrames*`
// counts consecutive packets where the side is airborne.
//
// Why: without hysteresis Auto ping-pongs every packet when both Joy-Cons
// rest on the same surface (both report distance > 0). The old rule —
// "switch to whatever side just reported distance > 0" — flipped ownership
// every BLE notification, so the cursor moved roughly 30 ns at a time before
// the other side took over. Hysteresis fixes it: only consider switching
// after the currently-active side has been airborne for a few packets, or
// when the other side's distance is *lower* (i.e. closer to the surface).
@property (nonatomic, assign) uint16_t lastDistanceLeft;
@property (nonatomic, assign) uint16_t lastDistanceRight;
@property (nonatomic, assign) BOOL hasDistanceLeft;
@property (nonatomic, assign) BOOL hasDistanceRight;
@property (nonatomic, assign) uint8_t airFramesLeft;
@property (nonatomic, assign) uint8_t airFramesRight;

// Shared click / scroll / side-button state. The mouse pointer is a single
// macOS object; it doesn't matter which Joy-Con clicked. We don't want
// clicks to stick down if you switch sides mid-press, so releasing a side
// releases all sticky state (handled in the Auto-switchover branch).
@property (nonatomic, assign) BOOL leftBtnPressed;
@property (nonatomic, assign) BOOL rightBtnPressed;
@property (nonatomic, assign) BOOL middleBtnPressed;
@property (nonatomic, assign) BOOL mb4Pressed;
@property (nonatomic, assign) BOOL mb5Pressed;
@property (nonatomic, assign) uint8_t hidButtons;

@property (nonatomic, assign) JoyConSide lastActiveSide;

- (void)sendMouseButton:(uint8_t)bit down:(BOOL)down;
- (void)postMouseReportDeltaX:(int)dx deltaY:(int)dy scroll:(int)scroll;
- (void)sendXButton:(int)which;
- (void)releaseAllMouseButtons;
- (BOOL)isSideOnSurface:(JoyConSide)side;
- (JoyConSide)resolvedActiveSide;
- (void)emitGyroPointerTick;
- (void)updateGyroCalibration:(GyroPointerSample &)sample now:(double)now;
- (void)updateGyroCalibrationState;
- (void)updateGyroMouseButtons;
- (void)resetOpticalGesture;
- (void)routeOpticalGestureDeltaX:(int)dx deltaY:(int)dy;
- (void)emitControlArrowUsage:(uint8_t)usage;
@end

static double MonotonicSeconds() {
    struct timespec time = {};
    clock_gettime(CLOCK_MONOTONIC, &time);
    return static_cast<double>(time.tv_sec) + static_cast<double>(time.tv_nsec) / 1000000000.0;
}

static MotionData CanonicalGyroMotion(MotionData motion, JoyConSide side) {
    // Joy-Con 2 hardware captures show both halves already use the same
    // upright grip frame. Keep this explicit transform boundary so a future
    // firmware revision can be corrected per-side without touching fusion.
    (void)side;
    return motion;
}

static uint32_t ToggleMaskForBinding(NSString *binding, JoyConSide side) {
    if (side == JoyConSide::Left) {
        if ([binding isEqualToString:@"minus"]) return BTN_LEFT_MINUS;
        if ([binding isEqualToString:@"sl"]) return BTN_LEFT_SLL;
        if ([binding isEqualToString:@"sr"]) return BTN_LEFT_SRL;
        if ([binding isEqualToString:@"stick"]) return BTN_LEFT_L3;
        return BTN_LEFT_CAPTURE;
    }
    if ([binding isEqualToString:@"home"]) return BTN_RIGHT_HOME;
    if ([binding isEqualToString:@"plus"]) return BTN_RIGHT_PLUS;
    if ([binding isEqualToString:@"sl"]) return BTN_RIGHT_SLR;
    if ([binding isEqualToString:@"sr"]) return BTN_RIGHT_SRR;
    if ([binding isEqualToString:@"stick"]) return BTN_RIGHT_R3;
    return BTN_RIGHT_CHAT;
}

static int16_t ClampMouseDelta(int value) {
    return static_cast<int16_t>(std::clamp(value, -32768, 32767));
}

static int8_t ClampMouseWheel(int value) {
    return static_cast<int8_t>(std::clamp(value, -127, 127));
}

static int ExtractWholeMouseDelta(double value) {
    constexpr double epsilon = 1e-9;
    return value >= 0
        ? static_cast<int>(std::floor(value + epsilon))
        : static_cast<int>(std::ceil(value - epsilon));
}

static double GyroCountsPerDegree(MouseMode mode) {
    // Relative HID counts are subsequently transformed by macOS pointer
    // acceleration. Keep device gain independent of display geometry.
    if (mode == MouseModeSlow) return 80.0;
    if (mode == MouseModeFast) return 160.0;
    return 120.0;
}

static bool NormalizeVector(double &x, double &y, double &z) {
    const double length = std::sqrt(x * x + y * y + z * z);
    if (length < 0.0001) return false;
    x /= length;
    y /= length;
    z /= length;
    return true;
}

static void UpdateFusedGravity(GyroPointerSample &sample, double previousTimestamp) {
    double accelX = sample.motion.accelX;
    double accelY = sample.motion.accelY;
    double accelZ = sample.motion.accelZ;
    const double accelMagnitude = std::sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);
    const bool accelValid = NormalizeVector(accelX, accelY, accelZ);

    if (!sample.gravityValid) {
        if (!accelValid) return;
        sample.gravityX = accelX;
        sample.gravityY = accelY;
        sample.gravityZ = accelZ;
        sample.gravityValid = true;
        return;
    }

    double dt = sample.timestamp - previousTimestamp;
    if (previousTimestamp <= 0 || dt <= 0 || dt > 0.05) return;

    const double degreesToRadians = M_PI / 180.0;
    const double omegaX = (sample.motion.gyroX - sample.biasX) * degreesToRadians;
    const double omegaY = (sample.motion.gyroY - sample.biasY) * degreesToRadians;
    const double omegaZ = (sample.motion.gyroZ - sample.biasZ) * degreesToRadians;
    const double crossX = omegaY * sample.gravityZ - omegaZ * sample.gravityY;
    const double crossY = omegaZ * sample.gravityX - omegaX * sample.gravityZ;
    const double crossZ = omegaX * sample.gravityY - omegaY * sample.gravityX;
    sample.gravityX -= crossX * dt;
    sample.gravityY -= crossY * dt;
    sample.gravityZ -= crossZ * dt;
    NormalizeVector(sample.gravityX, sample.gravityY, sample.gravityZ);

    if (!accelValid || std::fabs(accelMagnitude - 1.0) >= 0.10) return;
    const double alignment = std::clamp(sample.gravityX * accelX
                                      + sample.gravityY * accelY
                                      + sample.gravityZ * accelZ, -1.0, 1.0);
    const double errorAngle = std::acos(alignment);
    const double correctionLimit = 10.0 * degreesToRadians;
    if (errorAngle >= correctionLimit) return;

    // Correct integration drift only when acceleration agrees with predicted
    // gravity. Translational hand acceleration must not steer the pointer.
    const double confidence = 1.0 - errorAngle / correctionLimit;
    const double correction = std::clamp(dt * 4.0 * confidence, 0.0, 1.0);
    sample.gravityX += (accelX - sample.gravityX) * correction;
    sample.gravityY += (accelY - sample.gravityY) * correction;
    sample.gravityZ += (accelZ - sample.gravityZ) * correction;
    NormalizeVector(sample.gravityX, sample.gravityY, sample.gravityZ);
}

static void UpdatePointerRates(GyroPointerSample &sample) {
    if (!sample.gravityValid) return;
    const double gyroX = sample.motion.gyroX - sample.biasX;
    const double gyroY = sample.motion.gyroY - sample.biasY;
    const double gyroZ = sample.motion.gyroZ - sample.biasZ;
    const double worldYaw = gyroY * sample.gravityY + gyroZ * sample.gravityZ;
    const double relaxedYaw = std::min(std::fabs(worldYaw) * std::sqrt(2.0),
                                       std::hypot(gyroY, gyroZ));
    const double playerYaw = worldYaw == 0 ? 0 : std::copysign(relaxedYaw, worldYaw);

    if (sample.rateHistoryCount == 4) {
        for (uint8_t index = 1; index < 4; ++index) {
            sample.rateHistory[index - 1] = sample.rateHistory[index];
        }
        sample.rateHistoryCount = 3;
    }
    sample.rateHistory[sample.rateHistoryCount++] = {sample.timestamp, gyroX, playerYaw};
}

struct PointerRates {
    double pitch;
    double yaw;
};

static PointerRates PointerRatesAt(const GyroPointerSample &sample, double timestamp) {
    if (sample.rateHistoryCount == 0) return {0, 0};
    const GyroPointerRate &oldest = sample.rateHistory[0];
    if (timestamp <= oldest.timestamp) return {oldest.pitch, oldest.yaw};
    for (uint8_t index = 1; index < sample.rateHistoryCount; ++index) {
        const GyroPointerRate &previous = sample.rateHistory[index - 1];
        const GyroPointerRate &current = sample.rateHistory[index];
        if (timestamp > current.timestamp) continue;
        const double span = current.timestamp - previous.timestamp;
        if (span <= 0) return {current.pitch, current.yaw};
        const double amount = (timestamp - previous.timestamp) / span;
        return {
            previous.pitch + (current.pitch - previous.pitch) * amount,
            previous.yaw + (current.yaw - previous.yaw) * amount,
        };
    }
    const GyroPointerRate &newest = sample.rateHistory[sample.rateHistoryCount - 1];
    return {newest.pitch, newest.yaw};
}

@implementation MouseEmitter

- (instancetype)initWithDriverClient:(DriverKitClient *)client {
    self = [super init];
    if (self) {
        _driverClient = client;
        _currentMode = MouseModeNormal;
        _source = MouseSourceAuto;
        _pointerMethod = PointerMethodOptical;
        _gyroSource = GyroMouseSourceFused;
        _gyroAimingEnabled = NO;
        _leftGyroToggleBinding = @"capture";
        _rightGyroToggleBinding = @"chat";
        _gyroActiveSourceName = @"none";
        _gyroCalibrating = YES;
        _opticalGestureChordActive = NO;
        _opticalGestureTriggered = NO;
        _opticalGestureX = 0;
        _opticalGestureY = 0;
        _gyroLastTick = MonotonicSeconds();
        _gyroFractionX = 0;
        _gyroFractionY = 0;
        _gyroTogglePressedLeft = NO;
        _gyroTogglePressedRight = NO;
        _gyroLastToggleTapLeft = 0;
        _gyroLastToggleTapRight = 0;
        _gyroButtonStateLeft = 0;
        _gyroButtonStateRight = 0;
        _gyroButtonTimestampLeft = 0;
        _gyroButtonTimestampRight = 0;
        _gyroStickLeft = {0, 0, 0, 0};
        _gyroStickRight = {0, 0, 0, 0};
        _gyroStickTimestampLeft = 0;
        _gyroStickTimestampRight = 0;
        _gyroScrollAccumulator = 0;
        _lastActiveSide = JoyConSide::Right;
        _lastDistanceLeft = 0;
        _lastDistanceRight = 0;
        _hasDistanceLeft = NO;
        _hasDistanceRight = NO;
        _airFramesLeft = 0;
        _airFramesRight = 0;
        _firstOpticalReadLeft = YES;
        _firstOpticalReadRight = YES;
        _lastOpticalXLeft = 0;
        _lastOpticalYLeft = 0;
        _lastOpticalXRight = 0;
        _lastOpticalYRight = 0;
        _scrollAccumulator = 0.0f;
        _leftBtnPressed = NO;
        _rightBtnPressed = NO;
        _middleBtnPressed = NO;
        _mb4Pressed = NO;
        _mb5Pressed = NO;
        _hidButtons = 0;

        __weak MouseEmitter *weakSelf = self;
        _gyroTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
        dispatch_source_set_timer(_gyroTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 8333333ULL),
                                  8333333ULL,
                                  2083333ULL);
        dispatch_source_set_event_handler(_gyroTimer, ^{
            [weakSelf emitGyroPointerTick];
        });
        dispatch_resume(_gyroTimer);
    }
    return self;
}

- (void)dealloc {
    if (_gyroTimer) {
        dispatch_source_cancel(_gyroTimer);
        _gyroTimer = nullptr;
    }
}

- (void)setCurrentMode:(MouseMode)currentMode {
    if (_currentMode == currentMode) return;
    _currentMode = currentMode;
    // Any transition resets the per-side optical history so the first
    // sample after re-enabling doesn't produce a giant delta (the "pointer
    // teleports across the screen" bug when you toggled OFF -> SLOW).
    _firstOpticalReadLeft = YES;
    _firstOpticalReadRight = YES;
    _scrollAccumulator = 0.0f;
    [self resetOpticalGesture];
    if (currentMode == MouseModeOff) {
        self.gyroAimingEnabled = NO;
        [self releaseAllMouseButtons];
    }
}

- (void)setPointerMethod:(PointerMethod)pointerMethod {
    if (_pointerMethod == pointerMethod) return;
    _pointerMethod = pointerMethod;
    [self resetGyroAiming];
    _firstOpticalReadLeft = YES;
    _firstOpticalReadRight = YES;
    [self releaseAllMouseButtons];
    [self resetOpticalGesture];
}

- (void)setGyroSource:(GyroMouseSource)gyroSource {
    if (_gyroSource == gyroSource) return;
    _gyroSource = gyroSource;
    [self resetGyroAiming];
    [self updateGyroCalibrationState];
}

- (void)setGyroAimingEnabled:(BOOL)gyroAimingEnabled {
    if (_gyroAimingEnabled == gyroAimingEnabled) return;
    _gyroAimingEnabled = gyroAimingEnabled;
    _gyroLastTick = MonotonicSeconds();
    _gyroFractionX = 0;
    _gyroFractionY = 0;
    _gyroScrollAccumulator = 0;
    if (!gyroAimingEnabled) {
        _gyroActiveSourceName = @"none";
        [self releaseAllMouseButtons];
    }
}

- (void)setLeftGyroToggleBinding:(NSString *)binding {
    _leftGyroToggleBinding = [binding copy];
    _gyroTogglePressedLeft = NO;
    _gyroLastToggleTapLeft = 0;
}

- (void)setRightGyroToggleBinding:(NSString *)binding {
    _rightGyroToggleBinding = [binding copy];
    _gyroTogglePressedRight = NO;
    _gyroLastToggleTapRight = 0;
}

- (void)resetGyroAiming {
    self.gyroAimingEnabled = NO;
    _gyroTogglePressedLeft = NO;
    _gyroTogglePressedRight = NO;
    _gyroLastToggleTapLeft = 0;
    _gyroLastToggleTapRight = 0;
    _gyroButtonStateLeft = 0;
    _gyroButtonStateRight = 0;
    _gyroButtonTimestampLeft = 0;
    _gyroButtonTimestampRight = 0;
    _gyroStickTimestampLeft = 0;
    _gyroStickTimestampRight = 0;
    _gyroScrollAccumulator = 0;
}

- (void)requestGyroCalibration {
    @synchronized (self) {
        self.gyroAimingEnabled = NO;
        const double now = MonotonicSeconds();
        const bool leftFresh = _gyroLeft.valid && now - _gyroLeft.timestamp <= 0.0455;
        const bool rightFresh = _gyroRight.valid && now - _gyroRight.timestamp <= 0.0455;
        _gyroLeft.manualPending = leftFresh;
        _gyroRight.manualPending = rightFresh;
        if (_gyroLeft.manualPending) {
            _gyroLeft.stationaryStart = 0;
            _gyroLeft.stationarySamples = 0;
            _gyroLeft.sumX = _gyroLeft.sumY = _gyroLeft.sumZ = 0;
        }
        if (_gyroRight.manualPending) {
            _gyroRight.stationaryStart = 0;
            _gyroRight.stationarySamples = 0;
            _gyroRight.sumX = _gyroRight.sumY = _gyroRight.sumZ = 0;
        }
        [self updateGyroCalibrationState];
    }
}

- (uint32_t)processGyroMotion:(MotionData)motion
                         side:(JoyConSide)side
                  buttonState:(uint32_t)buttonState
                 stickReading:(StickData)stickReading {
    const double now = MonotonicSeconds();
    uint32_t consumedMask = 0;
    @synchronized (self) {
        GyroPointerSample &sample = side == JoyConSide::Left ? _gyroLeft : _gyroRight;
        const double previousTimestamp = sample.timestamp;
        sample.motion = CanonicalGyroMotion(motion, side);
        sample.timestamp = now;
        sample.valid = true;
        [self updateGyroCalibration:sample now:now];
        UpdateFusedGravity(sample, previousTimestamp);
        UpdatePointerRates(sample);

        if (sample.rearmPending && !sample.onSurface) {
            const MotionData &m = sample.motion;
            const double accelMagnitude = std::sqrt(m.accelX * m.accelX
                                                  + m.accelY * m.accelY
                                                  + m.accelZ * m.accelZ);
            const double gyroMagnitude = std::sqrt(m.gyroX * m.gyroX
                                                 + m.gyroY * m.gyroY
                                                 + m.gyroZ * m.gyroZ);
            const bool settled = std::fabs(accelMagnitude - 1.0) < 0.18
                              && gyroMagnitude < 8.0;
            if (settled) {
                if (sample.rearmStillStart == 0) sample.rearmStillStart = now;
                if (now - sample.rearmStillStart >= 0.15) {
                    sample.rearmPending = false;
                    sample.rearmStillStart = 0;
                }
            } else {
                sample.rearmStillStart = 0;
            }
        }

        if (_pointerMethod == PointerMethodGyro) {
            uint32_t mask = ToggleMaskForBinding(side == JoyConSide::Left
                                                  ? _leftGyroToggleBinding
                                                  : _rightGyroToggleBinding,
                                                  side);
            BOOL pressed = (buttonState & mask) != 0;
            BOOL *wasPressed = side == JoyConSide::Left
                                 ? &_gyroTogglePressedLeft
                                 : &_gyroTogglePressedRight;
            double *lastTap = side == JoyConSide::Left
                                ? &_gyroLastToggleTapLeft
                                : &_gyroLastToggleTapRight;
            if (pressed && !*wasPressed) {
                static const double DOUBLE_TAP_SECONDS = 0.35;
                if (*lastTap > 0 && now - *lastTap <= DOUBLE_TAP_SECONDS) {
                    *lastTap = 0;
                    self.gyroAimingEnabled = !self.gyroAimingEnabled;
                } else {
                    *lastTap = now;
                }
            }
            *wasPressed = pressed;
            if (pressed) consumedMask = mask;
            buttonState &= ~mask;
        }
        if (side == JoyConSide::Left) {
            _gyroButtonStateLeft = buttonState;
            _gyroButtonTimestampLeft = now;
            _gyroStickLeft = stickReading;
            _gyroStickTimestampLeft = now;
        } else {
            _gyroButtonStateRight = buttonState;
            _gyroButtonTimestampRight = now;
            _gyroStickRight = stickReading;
            _gyroStickTimestampRight = now;
        }
        if (_pointerMethod == PointerMethodGyro) {
            [self updateGyroMouseButtons];
        }
        [self updateGyroCalibrationState];
    }
    return consumedMask;
}

- (void)updateGyroCalibration:(GyroPointerSample &)sample now:(double)now {
    const MotionData &m = sample.motion;
    const double accelMagnitude = std::sqrt(m.accelX * m.accelX
                                          + m.accelY * m.accelY
                                          + m.accelZ * m.accelZ);
    const double gyroMagnitude = std::sqrt(m.gyroX * m.gyroX
                                         + m.gyroY * m.gyroY
                                         + m.gyroZ * m.gyroZ);
    const double gyroLimit = sample.manualPending ? 5.0 : 0.5;
    const bool stationary = std::fabs(accelMagnitude - 1.0) < 0.12
                         && gyroMagnitude < gyroLimit;
    if (sample.biasValid && !sample.manualPending
        && (!sample.surfaceKnown || !sample.onSurface)) {
        sample.stationaryStart = 0;
        sample.stationarySamples = 0;
        sample.sumX = sample.sumY = sample.sumZ = 0;
        return;
    }
    if (!stationary) {
        sample.stationaryStart = 0;
        sample.stationarySamples = 0;
        sample.sumX = sample.sumY = sample.sumZ = 0;
        return;
    }

    if (sample.stationaryStart == 0) sample.stationaryStart = now;
    sample.sumX += m.gyroX;
    sample.sumY += m.gyroY;
    sample.sumZ += m.gyroZ;
    sample.stationarySamples += 1;

    if (now - sample.stationaryStart < 0.75 || sample.stationarySamples < 20) return;

    const float averageX = static_cast<float>(sample.sumX / sample.stationarySamples);
    const float averageY = static_cast<float>(sample.sumY / sample.stationarySamples);
    const float averageZ = static_cast<float>(sample.sumZ / sample.stationarySamples);
    if (sample.biasValid && !sample.manualPending) {
        sample.biasX = sample.biasX * 0.9f + averageX * 0.1f;
        sample.biasY = sample.biasY * 0.9f + averageY * 0.1f;
        sample.biasZ = sample.biasZ * 0.9f + averageZ * 0.1f;
    } else {
        sample.biasX = averageX;
        sample.biasY = averageY;
        sample.biasZ = averageZ;
    }
    sample.biasValid = true;
    sample.manualPending = false;
    sample.stationaryStart = now;
    sample.stationarySamples = 0;
    sample.sumX = sample.sumY = sample.sumZ = 0;
}

- (void)updateGyroCalibrationState {
    const bool anySample = _gyroLeft.valid || _gyroRight.valid;
    bool needsLeft = _gyroSource != GyroMouseSourceRight && _gyroLeft.valid;
    bool needsRight = _gyroSource != GyroMouseSourceLeft && _gyroRight.valid;
    _gyroCalibrating = (needsLeft && (!_gyroLeft.biasValid || _gyroLeft.manualPending))
                    || (needsRight && (!_gyroRight.biasValid || _gyroRight.manualPending))
                    || !anySample;
}

- (void)updateGyroMouseButtons {
    if (_pointerMethod != PointerMethodGyro || !_gyroAimingEnabled) {
        [self releaseAllMouseButtons];
        return;
    }
    const double now = MonotonicSeconds();
    const bool useLeft = _gyroSource != GyroMouseSourceRight;
    const bool useRight = _gyroSource != GyroMouseSourceLeft;
    const bool leftFresh = now - _gyroButtonTimestampLeft <= 0.0455;
    const bool rightFresh = now - _gyroButtonTimestampRight <= 0.0455;
    const BOOL leftClick = (useLeft && leftFresh && (_gyroButtonStateLeft & BTN_LEFT_L))
                        || (useRight && rightFresh && (_gyroButtonStateRight & BTN_RIGHT_R));
    const BOOL rightClick = (useLeft && leftFresh && (_gyroButtonStateLeft & BTN_LEFT_ZL))
                         || (useRight && rightFresh && (_gyroButtonStateRight & BTN_RIGHT_ZR));
    const BOOL middleClick = (useLeft && leftFresh && (_gyroButtonStateLeft & BTN_LEFT_L3))
                          || (useRight && rightFresh && (_gyroButtonStateRight & BTN_RIGHT_R3));
    if (leftClick != _leftBtnPressed) {
        [self sendMouseButton:0x01 down:leftClick];
        _leftBtnPressed = leftClick;
    }
    if (rightClick != _rightBtnPressed) {
        [self sendMouseButton:0x02 down:rightClick];
        _rightBtnPressed = rightClick;
    }
    if (middleClick != _middleBtnPressed) {
        [self sendMouseButton:0x04 down:middleClick];
        _middleBtnPressed = middleClick;
    }
}

- (void)emitGyroPointerTick {
    @synchronized (self) {
        const double now = MonotonicSeconds();
        if (_pointerMethod == PointerMethodGyro) {
            [self updateGyroMouseButtons];
        }
        double dt = now - _gyroLastTick;
        _gyroLastTick = now;
        if (_pointerMethod != PointerMethodGyro || !_gyroAimingEnabled
            || _currentMode == MouseModeOff || !_driverClient || ![_driverClient isRunning]) {
            _gyroFractionX = _gyroFractionY = 0;
            return;
        }
        dt = std::clamp(dt, 0.0, 0.025);
        int scroll = 0;
        const bool useLeftStick = _gyroSource != GyroMouseSourceRight
                               && now - _gyroStickTimestampLeft <= 0.0455;
        const bool useRightStick = _gyroSource != GyroMouseSourceLeft
                                && now - _gyroStickTimestampRight <= 0.0455;
        int stickY = 0;
        if (useLeftStick) stickY = _gyroStickLeft.y;
        if (useRightStick && std::abs((int)_gyroStickRight.y) > std::abs(stickY)) {
            stickY = _gyroStickRight.y;
        }
        static const int SCROLL_DEADZONE = 4000;
        if (std::abs(stickY) > SCROLL_DEADZONE) {
            const double intensity = (std::abs(stickY) - SCROLL_DEADZONE)
                                   / (32767.0 - SCROLL_DEADZONE);
            // Matches the optical path's 40 units/report at 66.67 Hz and
            // 120 units per wheel click, but remains stable at the 120 Hz timer.
            static const double MAX_SCROLL_CLICKS_PER_SECOND = 22.222222222222225;
            _gyroScrollAccumulator += std::copysign(intensity * MAX_SCROLL_CLICKS_PER_SECOND * dt,
                                                    static_cast<double>(stickY));
            scroll = ExtractWholeMouseDelta(_gyroScrollAccumulator);
            _gyroScrollAccumulator -= scroll;
        } else {
            _gyroScrollAccumulator = 0;
        }
        const bool leftFresh = _gyroLeft.valid && _gyroLeft.surfaceKnown
                            && !_gyroLeft.onSurface && !_gyroLeft.rearmPending
                            && now - _gyroLeft.timestamp <= 0.0455;
        const bool rightFresh = _gyroRight.valid && _gyroRight.surfaceKnown
                             && !_gyroRight.onSurface && !_gyroRight.rearmPending
                             && now - _gyroRight.timestamp <= 0.0455;

        const GyroPointerSample *a = nullptr;
        const GyroPointerSample *b = nullptr;
        if (_gyroSource == GyroMouseSourceLeft) {
            if (leftFresh) a = &_gyroLeft;
        } else if (_gyroSource == GyroMouseSourceRight) {
            if (rightFresh) a = &_gyroRight;
        } else {
            if (leftFresh) a = &_gyroLeft;
            if (rightFresh) {
                if (a) b = &_gyroRight;
                else a = &_gyroRight;
            }
        }
        if (!a) {
            _gyroActiveSourceName = @"none";
            _gyroFractionX = _gyroFractionY = 0;
            if (scroll != 0) [self postMouseReportDeltaX:0 deltaY:0 scroll:scroll];
            return;
        }

        double alignedTimestamp = a->timestamp;
        if (b) alignedTimestamp = std::min(a->timestamp, b->timestamp);
        PointerRates rates = PointerRatesAt(*a, alignedTimestamp);
        double pitch = rates.pitch;
        double yaw = rates.yaw;
        if (b) {
            const PointerRates secondRates = PointerRatesAt(*b, alignedTimestamp);
            pitch = (pitch + secondRates.pitch) * 0.5;
            yaw = (yaw + secondRates.yaw) * 0.5;
            _gyroActiveSourceName = @"fused";
        } else {
            _gyroActiveSourceName = a == &_gyroLeft ? @"left" : @"right";
        }

        const double countsPerDegree = GyroCountsPerDegree(_currentMode);
        _gyroFractionX += -yaw * dt * countsPerDegree;
        _gyroFractionY += -pitch * dt * countsPerDegree;
        const int dx = ExtractWholeMouseDelta(_gyroFractionX);
        const int dy = ExtractWholeMouseDelta(_gyroFractionY);
        _gyroFractionX -= dx;
        _gyroFractionY -= dy;
        if (dx != 0 || dy != 0 || scroll != 0) {
            [self postMouseReportDeltaX:dx deltaY:dy scroll:scroll];
        }
    }
}

- (void)setSource:(MouseSource)source {
    if (_source == source) return;
    _source = source;
    // Switching between Left / Right / Auto wipes the pending delta history
    // for both sides so we don't compute a stale-vs-fresh delta.
    _firstOpticalReadLeft = YES;
    _firstOpticalReadRight = YES;
    _scrollAccumulator = 0.0f;
    // Snap the active side to the picker's choice right away so the GUI's
    // "Active" badge flips the moment the user makes the selection, instead
    // of waiting for the next BLE packet to arrive from the chosen side.
    if (source == MouseSourceLeft) {
        _lastActiveSide = JoyConSide::Left;
    } else if (source == MouseSourceRight) {
        _lastActiveSide = JoyConSide::Right;
    }
    // Reset the airborne counters on explicit switches so hysteresis does
    // not immediately flip us back to the side we were on before.
    _airFramesLeft = 0;
    _airFramesRight = 0;
    [self resetOpticalGesture];
    [self releaseAllMouseButtons];
}

- (BOOL)processBuffer:(std::vector<uint8_t> &)buffer
                 side:(JoyConSide)side
          buttonState:(uint32_t)btnState
         stickReading:(StickData)stickData
        mouseDistance:(uint16_t)mouseDistance {

    // Always record per-side distance + airborne-frame state, even when the
    // mouse is OFF. Two reasons:
    //   1. The GUI's "Active" badge (lastActiveSide) needs to reflect the
    //      real current owner whether or not the pointer is being driven —
    //      otherwise users see the badge stuck on the init default (Right),
    //      while the controllers tab clearly shows Left is on a surface.
    //   2. When the user *does* turn mouse mode on, we want the hysteresis
    //      counters to already be accurate so the very first packet picks
    //      the right side instead of taking ~120 ms to catch up.
    //
    // Byte 0x17 (MouseData.distance) semantic, confirmed on hardware:
    //   distance == 0  → Joy-Con is TOUCHING a surface (distance is zero)
    //   distance >  0  → Joy-Con is airborne, typical value ~12
    // `airFrames*` is "how many consecutive packets have shown this side
    // in the air", so it increments when distance > 0 and resets on 0.
    if (side == JoyConSide::Left) {
        _hasDistanceLeft = YES;
        _lastDistanceLeft = mouseDistance;
        if (mouseDistance > 0) {
            if (_airFramesLeft < 255) _airFramesLeft += 1;
        } else {
            _airFramesLeft = 0;
        }
    } else {
        _hasDistanceRight = YES;
        _lastDistanceRight = mouseDistance;
        if (mouseDistance > 0) {
            if (_airFramesRight < 255) _airFramesRight += 1;
        } else {
            _airFramesRight = 0;
        }
    }

    GyroPointerSample &gyroSample = side == JoyConSide::Left ? _gyroLeft : _gyroRight;
    static const uint8_t GYRO_SURFACE_CONFIRM_FRAMES = 3;
    if (mouseDistance == 0) {
        gyroSample.airFrames = 0;
        if (gyroSample.surfaceFrames < GYRO_SURFACE_CONFIRM_FRAMES) {
            gyroSample.surfaceFrames += 1;
        }
        if (gyroSample.surfaceFrames >= GYRO_SURFACE_CONFIRM_FRAMES
            && (!gyroSample.surfaceKnown || !gyroSample.onSurface)) {
            gyroSample.surfaceKnown = true;
            gyroSample.onSurface = true;
            gyroSample.rearmPending = true;
            gyroSample.rearmStillStart = 0;
        }
    } else {
        gyroSample.surfaceFrames = 0;
        if (gyroSample.airFrames < GYRO_SURFACE_CONFIRM_FRAMES) {
            gyroSample.airFrames += 1;
        }
        if (gyroSample.airFrames >= GYRO_SURFACE_CONFIRM_FRAMES
            && (!gyroSample.surfaceKnown || gyroSample.onSurface)) {
            const bool wasOnSurface = gyroSample.surfaceKnown && gyroSample.onSurface;
            gyroSample.surfaceKnown = true;
            gyroSample.onSurface = false;
            gyroSample.rearmPending = wasOnSurface;
            gyroSample.rearmStillStart = 0;
        }
    }

    // Update `lastActiveSide` in Auto mode so the UI badge is correct
    // regardless of the mouse emitter's on/off state. With manual Left /
    // Right, lastActiveSide is already pinned by setSource.
    if (_source == MouseSourceAuto) {
        // A side is "on surface" iff its last distance reading is 0 AND
        // it hasn't just been airborne for a single blip frame. We adopt
        // whichever side is on the surface exclusively; if both are on
        // or neither is, we keep the current choice (stickiness kills
        // the per-packet ping-pong).
        BOOL leftOn  = [self isSideOnSurface:JoyConSide::Left];
        BOOL rightOn = [self isSideOnSurface:JoyConSide::Right];

        if (leftOn && !rightOn) {
            _lastActiveSide = JoyConSide::Left;
        } else if (rightOn && !leftOn) {
            _lastActiveSide = JoyConSide::Right;
        } else if (leftOn && rightOn) {
            // Both on surface — keep current choice to avoid ping-pong.
        } else {
            // Neither on a surface. Only hand over once the active side
            // has clearly been lifted for a sustained window, to avoid
            // snap-backs when the sensor blips. Actual handover happens
            // in the leftOn/rightOn branches above when the next
            // on-surface packet arrives.
            static const uint8_t AIR_HYST = 8; // ~120 ms at 66 Hz
            BOOL activeIsLeft = (_lastActiveSide == JoyConSide::Left);
            uint8_t activeAir = activeIsLeft ? _airFramesLeft  : _airFramesRight;
            (void)activeAir;
            (void)AIR_HYST;
        }
    }

    if (_currentMode == MouseModeOff) {
        // Emitter is off: surface tracking above keeps the UI badge accurate,
        // but we don't drive the cursor or consume the packet.
        return NO;
    }
    if (_pointerMethod != PointerMethodOptical) {
        return NO;
    }
    if (!_driverClient || ![_driverClient isRunning]) {
        return NO;
    }

    // Resolve the active side for THIS packet's processing using the same
    // data the badge-update block just refreshed. Manual picks short-circuit
    // to the forced side.
    JoyConSide activeSide = [self resolvedActiveSide];

    if (side != activeSide) {
        // Not the active side — don't consume the packet. Update the
        // inactive side's optical baseline so if we switch to it later the
        // first delta is sane, and leave the gamepad path untouched.
        if (side == JoyConSide::Left) {
            _firstOpticalReadLeft = YES;
        } else {
            _firstOpticalReadRight = YES;
        }
        return NO;
    }

    if (![self isSideOnSurface:activeSide]) {
        if (side == JoyConSide::Left) {
            _firstOpticalReadLeft = YES;
        } else {
            _firstOpticalReadRight = YES;
        }
        _scrollAccumulator = 0.0f;
        [self resetOpticalGesture];
        [self releaseAllMouseButtons];
        return NO;
    }

    if (activeSide != _lastActiveSide) {
        // Auto just promoted a different side. Drop any sticky clicks so
        // a press that never released on the old side doesn't leak over.
        [self releaseAllMouseButtons];
        _lastActiveSide = activeSide;
    }

    BOOL isLeft = (activeSide == JoyConSide::Left);

    // --- 1. Optical mouse movement (joycon2cpp testapp.cpp) ---
    std::pair<int16_t, int16_t> raw = GetRawOpticalMouse(buffer);
    int16_t rawX = raw.first;
    int16_t rawY = raw.second;

    BOOL *firstReadPtr  = isLeft ? &_firstOpticalReadLeft  : &_firstOpticalReadRight;
    int16_t *lastXPtr   = isLeft ? &_lastOpticalXLeft      : &_lastOpticalXRight;
    int16_t *lastYPtr   = isLeft ? &_lastOpticalYLeft      : &_lastOpticalYRight;
    int moveX = 0;
    int moveY = 0;

    if (*firstReadPtr) {
        *lastXPtr = rawX;
        *lastYPtr = rawY;
        *firstReadPtr = NO;
    } else {
        int16_t dx = (int16_t)(rawX - *lastXPtr);
        int16_t dy = (int16_t)(rawY - *lastYPtr);
        *lastXPtr = rawX;
        *lastYPtr = rawY;

        if (dx != 0 || dy != 0) {
            float sensitivity = 1.0f;
            switch (_currentMode) {
                case MouseModeFast:   sensitivity = 1.0f; break;
                case MouseModeNormal: sensitivity = 0.6f; break;
                case MouseModeSlow:   sensitivity = 0.3f; break;
                default: break;
            }
            moveX = static_cast<int>(std::lrintf(dx * sensitivity));
            moveY = static_cast<int>(std::lrintf(dy * sensitivity));
        }
    }

    // --- 2. Mouse buttons ---
    // joycon2cpp maps R (0x004000) → left, ZR (0x008000) → right, R3
    // (0x000004) → middle on the RIGHT Joy-Con. The left Joy-Con's
    // matching buttons live in the lower 16 bits: L (0x0040), ZL (0x0080),
    // L3 (0x0800).
    uint32_t leftMask, rightMask, middleMask;
    if (isLeft) {
        leftMask   = 0x0040;    // L
        rightMask  = 0x0080;    // ZL
        middleMask = 0x0800;    // L3
    } else {
        leftMask   = 0x004000;  // R
        rightMask  = 0x008000;  // ZR
        middleMask = 0x000004;  // R3
    }

    BOOL mouseLeftNow   = (btnState & leftMask)   != 0;
    BOOL mouseRightNow  = (btnState & rightMask)  != 0;
    BOOL mouseMiddleNow = (btnState & middleMask) != 0;

    // Optical-only system gesture chord. A normal mouse HID cannot produce
    // multitouch contacts, so translate the completed direction to macOS's
    // documented Control+Arrow navigation shortcuts through our keyboard HID.
    BOOL gestureChordNow = mouseLeftNow && mouseRightNow;
    if (gestureChordNow && !_opticalGestureChordActive) {
        _opticalGestureChordActive = YES;
        _opticalGestureTriggered = NO;
        _opticalGestureX = 0;
        _opticalGestureY = 0;
        [self releaseAllMouseButtons];
    } else if (!gestureChordNow && _opticalGestureChordActive) {
        [self resetOpticalGesture];
    }

    if (_opticalGestureChordActive) {
        mouseLeftNow = NO;
        mouseRightNow = NO;
        mouseMiddleNow = NO;
    }

    if (mouseLeftNow != _leftBtnPressed) {
        [self sendMouseButton:0x01 down:mouseLeftNow];
        _leftBtnPressed = mouseLeftNow;
    }
    if (mouseRightNow != _rightBtnPressed) {
        [self sendMouseButton:0x02 down:mouseRightNow];
        _rightBtnPressed = mouseRightNow;
    }
    if (mouseMiddleNow != _middleBtnPressed) {
        [self sendMouseButton:0x04 down:mouseMiddleNow];
        _middleBtnPressed = mouseMiddleNow;
    }

    // --- 3. Stick scrolling + side buttons (joycon2cpp constants) ---
    int scroll = 0;
    const int SCROLL_DEADZONE = 4000;
    if (!_opticalGestureChordActive && std::abs((int)stickData.y) > SCROLL_DEADZONE) {
        float intensity = (std::abs((int)stickData.y) - SCROLL_DEADZONE) /
                          (32767.0f - SCROLL_DEADZONE);
        float speed = intensity * 40.0f;
        if (stickData.y > 0) _scrollAccumulator += speed; // Up
        else                 _scrollAccumulator -= speed; // Down

        if (std::fabs(_scrollAccumulator) >= 120.0f) {
            scroll = static_cast<int>(_scrollAccumulator / 120.0f);
            _scrollAccumulator -= scroll * 120.0f;
        }
    } else {
        _scrollAccumulator = 0.0f;
    }

    if (_opticalGestureChordActive) {
        [self routeOpticalGestureDeltaX:moveX deltaY:moveY];
    } else if (moveX != 0 || moveY != 0 || scroll != 0) {
        [self postMouseReportDeltaX:moveX deltaY:moveY scroll:scroll];
    }

    const int BUTTON_THRESHOLD = 28000;
    if (!_opticalGestureChordActive && stickData.x < -BUTTON_THRESHOLD) {
        if (!_mb4Pressed) {
            [self sendXButton:1]; // Back
            _mb4Pressed = YES;
        }
    } else {
        _mb4Pressed = NO;
    }
    if (!_opticalGestureChordActive && stickData.x > BUTTON_THRESHOLD) {
        if (!_mb5Pressed) {
            [self sendXButton:2]; // Forward
            _mb5Pressed = YES;
        }
    } else {
        _mb5Pressed = NO;
    }

    // --- 4. Suppress consumed inputs in the buffer for the gamepad path ---
    //     The caller will re-extract buttons/stick from this stripped
    //     buffer, so the virtual gamepad never sees the mouse clicks.
    //     Per-side: left Joy-Con's bit layout is in the low byte (buffer[6]
    //     for L/ZL, buffer[5] for L3 which is 0x0800 = buffer[5] & 0x08).
    //     Right's bits live in buffer[4]/buffer[5] per joycon2cpp.
    if (isLeft) {
        if (buffer.size() >= 7) {
            buffer[6] &= ~0x40;   // L
            buffer[6] &= ~0x80;   // ZL
            buffer[5] &= ~0x08;   // L3 (0x0800 in the 24-bit state)
        }
        if (buffer.size() >= 13) {
            // Left stick bytes at 10..12, neutral = 00 08 80 (same pattern
            // joycon2cpp uses for the right stick at 13..15 — the byte
            // layout is identical, only the offset differs).
            buffer[10] = 0x00;
            buffer[11] = 0x08;
            buffer[12] = 0x80;
        }
    } else {
        if (buffer.size() >= 6) {
            buffer[4] &= ~0x40;   // R
            buffer[4] &= ~0x80;   // ZR
            buffer[5] &= ~0x04;   // R3
        }
        if (buffer.size() >= 16) {
            buffer[13] = 0x00;
            buffer[14] = 0x08;
            buffer[15] = 0x80;
        }
    }

    return YES;
}

// MARK: - HID mouse helpers

- (JoyConSide)resolvedActiveSide {
    if (_source == MouseSourceLeft) {
        return JoyConSide::Left;
    }
    if (_source == MouseSourceRight) {
        return JoyConSide::Right;
    }
    return _lastActiveSide;
}

- (BOOL)isSideOnSurface:(JoyConSide)side {
    if (side == JoyConSide::Left) {
        return _hasDistanceLeft && _lastDistanceLeft == 0 && _airFramesLeft == 0;
    }
    return _hasDistanceRight && _lastDistanceRight == 0 && _airFramesRight == 0;
}

- (BOOL)isSideMouseOwned:(JoyConSide)side {
    if (_pointerMethod != PointerMethodOptical || _currentMode == MouseModeOff) {
        return NO;
    }
    if (!_driverClient || ![_driverClient isRunning]) {
        return NO;
    }
    if (side != [self resolvedActiveSide]) {
        return NO;
    }
    return [self isSideOnSurface:side];
}

- (void)postMouseReportDeltaX:(int)dx deltaY:(int)dy scroll:(int)scroll {
    if (!_driverClient || ![_driverClient isRunning]) {
        return;
    }

    uint8_t buttons = 0;
    @synchronized (self) {
        buttons = _hidButtons & 0x1F;
    }

    struct JoyConMouseReportData report = {};
    report.buttons = buttons;
    report.deltaX = ClampMouseDelta(dx);
    report.deltaY = ClampMouseDelta(dy);
    report.scroll = ClampMouseWheel(scroll);
    [_driverClient postMouseReport:report];
}

- (void)sendMouseButton:(uint8_t)bit down:(BOOL)down {
    bit &= 0x1F;
    uint8_t oldButtons = _hidButtons;
    if (down) {
        _hidButtons |= bit;
    } else {
        _hidButtons &= ~bit;
    }
    if (_hidButtons != oldButtons) {
        [self postMouseReportDeltaX:0 deltaY:0 scroll:0];
    }
}

- (void)sendXButton:(int)which {
    uint8_t bit = (which == 1) ? 0x08 : 0x10;
    uint8_t savedButtons = _hidButtons;
    _hidButtons = savedButtons | bit;
    [self postMouseReportDeltaX:0 deltaY:0 scroll:0];
    _hidButtons = savedButtons;
    [self postMouseReportDeltaX:0 deltaY:0 scroll:0];
}

- (void)releaseAllMouseButtons {
    if (_hidButtons != 0) {
        _hidButtons = 0;
        [self postMouseReportDeltaX:0 deltaY:0 scroll:0];
    }
    _leftBtnPressed = NO;
    _rightBtnPressed = NO;
    _middleBtnPressed = NO;
    _mb4Pressed = NO;
    _mb5Pressed = NO;
}

- (void)resetOpticalGesture {
    _opticalGestureChordActive = NO;
    _opticalGestureTriggered = NO;
    _opticalGestureX = 0;
    _opticalGestureY = 0;
}

- (void)routeOpticalGestureDeltaX:(int)dx deltaY:(int)dy {
    if (!_opticalGestureChordActive || _opticalGestureTriggered) return;

    _opticalGestureX += dx;
    _opticalGestureY += dy;
    constexpr double threshold = 60.0;
    if (std::fabs(_opticalGestureX) < threshold &&
        std::fabs(_opticalGestureY) < threshold) {
        return;
    }

    uint8_t usage = 0;
    if (std::fabs(_opticalGestureX) >= std::fabs(_opticalGestureY)) {
        usage = _opticalGestureX < 0 ? 0x50 : 0x4F; // Left / Right Arrow
    } else {
        usage = _opticalGestureY < 0 ? 0x52 : 0x51; // Up / Down Arrow
    }
    _opticalGestureTriggered = YES;
    [self emitControlArrowUsage:usage];
}

- (void)emitControlArrowUsage:(uint8_t)usage {
    if (!_driverClient || ![_driverClient isRunning]) return;

    struct JoyConKeyboardReportData pressed = {};
    pressed.modifiers = 0x01; // Left Control
    pressed.keys[0] = usage;
    [_driverClient postKeyboardReport:pressed];

    // Keep the chord down long enough for the HID event system to observe it
    // as a real key press instead of coalescing adjacent press/release reports.
    __weak MouseEmitter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        MouseEmitter *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.driverClient ||
            ![strongSelf.driverClient isRunning]) {
            return;
        }
        struct JoyConKeyboardReportData released = {};
        [strongSelf.driverClient postKeyboardReport:released];
    });
}

@end
