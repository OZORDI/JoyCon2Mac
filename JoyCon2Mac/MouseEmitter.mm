#import "MouseEmitter.h"
#include <algorithm>
#include <cstdlib>
#include <cmath>
#include <cstdint>

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
@end

static int16_t ClampMouseDelta(int value) {
    return static_cast<int16_t>(std::clamp(value, -32768, 32767));
}

static int8_t ClampMouseWheel(int value) {
    return static_cast<int8_t>(std::clamp(value, -127, 127));
}

@implementation MouseEmitter

- (instancetype)initWithDriverClient:(DriverKitClient *)client {
    self = [super init];
    if (self) {
        _driverClient = client;
        _currentMode = MouseModeNormal;
        _source = MouseSourceAuto;
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
    }
    return self;
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
    if (currentMode == MouseModeOff) {
        [self releaseAllMouseButtons];
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
    if (std::abs((int)stickData.y) > SCROLL_DEADZONE) {
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

    if (moveX != 0 || moveY != 0 || scroll != 0) {
        [self postMouseReportDeltaX:moveX deltaY:moveY scroll:scroll];
    }

    const int BUTTON_THRESHOLD = 28000;
    if (stickData.x < -BUTTON_THRESHOLD) {
        if (!_mb4Pressed) {
            [self sendXButton:1]; // Back
            _mb4Pressed = YES;
        }
    } else {
        _mb4Pressed = NO;
    }
    if (stickData.x > BUTTON_THRESHOLD) {
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
    if (_currentMode == MouseModeOff) {
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

@end
