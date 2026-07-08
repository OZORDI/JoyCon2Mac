#import <Foundation/Foundation.h>
#import "BLEManager.h"
#import "PairingManager.h"
#import "DriverKitClient.h"
#import "MouseEmitter.h"
#include "JoyConDecoder.h"
#include <iostream>
#include <iomanip>
#include <sstream>
#include <string>
#include <climits>
#include <cmath>
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <signal.h>

// Global state for tracking controller data
struct ControllerState {
    uint32_t buttons = 0;
    uint32_t leftButtons = 0;
    uint32_t rightButtons = 0;
    StickData leftStick = {0, 0, 0, 0};
    StickData rightStick = {0, 0, 0, 0};
    // joycon2cpp emits IMU data per-side (each Joy-Con has its own accel +
    // gyro). Keep the last-seen samples separately so the UI can show stable
    // readouts for each side instead of one struct that flickers between
    // whichever controller pushed the most recent BLE notification.
    MotionData motionLeft  = {0, 0, 0, 0, 0, 0};
    MotionData motionRight = {0, 0, 0, 0, 0, 0};
    // Mouse telemetry per side. Both Joy-Con 2 halves carry the optical
    // sensor at the same packet offsets (0x10..0x13 for XY delta, 0x17 for
    // surface distance). Keeping a separate record per side lets the UI
    // show which controller is on a surface and lets the Auto source
    // picker flip based on which one has distance == 0.
    MouseData mouseLeft  = {0, 0, 0};
    MouseData mouseRight = {0, 0, 0};
    // Single "mouse" field preserved for the legacy printDetailedState().
    MouseData mouse = {0, 0, 0};
    BatteryData battery = {0, 0, 0, -1};
    uint8_t triggerL = 0;
    uint8_t triggerR = 0;
    uint32_t packetCount = 0;
    bool isLeftJoyCon = true;
    JoyConSide lastSide = JoyConSide::Left;
};

static ControllerState g_state;
static bool g_showDetailedOutput = false;
static bool g_emitJSON = false;
static bool g_enableGamepad = true;
static bool g_sdlOnlyMode = false;
static bool g_debugInput = true;    // targeted dpad + right-stick trace, on by default
                                    // (change-triggered — zero output when idle).
                                    // Disable with --no-debug-input.
static FILE *g_debugInputFile = nullptr;    // mirrors trace lines to a file you can tail
static FILE *g_jsonFile = nullptr;
static NSDate *g_lastPrintTime = nil;
static NSDate *g_lastJSONLeftTime = nil;
static NSDate *g_lastJSONRightTime = nil;
static const NSTimeInterval kJSONStateIntervalSeconds = 1.0 / 120.0;
static DriverKitClient *g_driverClient = nil;
static MouseEmitter *g_mouseEmitter = nil;
static BLEManager *g_bleManager = nil;
// Control-file IPC. The GUI writes one JSON command per line into this file
// (e.g. {"cmd":"setMouseMode","value":2}). We poll it on a GCD timer and
// apply any new lines. Kept deliberately simple: no XPC, no Mach ports, no
// signing entitlements — just a file in Application Support the daemon
// already owns exclusively.
static NSString *g_controlFilePath = nil;
static unsigned long long g_controlFileOffset = 0;
static dispatch_source_t g_controlFileTimer = nullptr;
static dispatch_source_t g_rumblePollTimer = nullptr;
static uint32_t g_lastRumbleSequence = 0;
static JoyConReportData g_lastGamepadReport = {};
static bool g_haveLastGamepadReport = false;
static bool g_findLeftActive = false;
static bool g_findRightActive = false;
static CFAbsoluteTime g_findShakeStartLeft = 0;
static CFAbsoluteTime g_findShakeStartRight = 0;
static MotionData g_findLastMotionLeft = {0, 0, 0, 0, 0, 0};
static MotionData g_findLastMotionRight = {0, 0, 0, 0, 0, 0};
static bool g_findHaveLastMotionLeft = false;
static bool g_findHaveLastMotionRight = false;
static std::string g_railBindingLeftSL = "none";
static std::string g_railBindingLeftSR = "none";
static std::string g_railBindingRightSL = "none";
static std::string g_railBindingRightSR = "none";

// Write one formatted debug-input line to stderr AND (if opened) to the
// mirror file so you can just `tail -f` the file without wrangling the
// unified log. Kept __attribute__((format(...))) so the compiler warns
// on format/argument mismatches.
__attribute__((format(printf, 1, 2)))
static void debugInputLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[256];
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    fputs(buf, stderr);
    if (g_debugInputFile) {
        fputs(buf, g_debugInputFile);
        // File is already line-buffered; no need to fflush per line.
    }
}

static bool unpackStickRaw12(const std::vector<uint8_t>& buffer, JoyConSide side, int& rawX, int& rawY) {
    if (buffer.size() < 16) {
        return false;
    }

    const uint8_t *data = (side == JoyConSide::Left) ? &buffer[10] : &buffer[13];
    rawX = ((data[1] & 0x0F) << 8) | data[0];
    rawY = (data[2] << 4) | ((data[1] & 0xF0) >> 4);
    return true;
}

static void traceRightStickDecode(const std::vector<uint8_t>& buffer, uint32_t packetCount, const StickData& decoded) {
    if (!g_debugInput || buffer.size() < 16) {
        return;
    }

    int rawX = 0;
    int rawY = 0;
    if (!unpackStickRaw12(buffer, JoyConSide::Right, rawX, rawY)) {
        return;
    }

    static bool first = true;
    static int lastRawX = 0;
    static int lastRawY = 0;
    static int lastX = 0;
    static int lastY = 0;
    if (!first && rawX == lastRawX && rawY == lastRawY && decoded.x == lastX && decoded.y == lastY) {
        return;
    }

    int deltaX = first ? 0 : int(decoded.x) - lastX;
    int deltaY = first ? 0 : int(decoded.y) - lastY;
    debugInputLog(
            "[RS-DEC] pkt=%u raw13..15=%02x:%02x:%02x raw12=(%4d,%4d) dec=(%6d,%6d) ddec=(%6d,%6d)\n",
            packetCount,
            buffer[13], buffer[14], buffer[15],
            rawX, rawY,
            decoded.x, decoded.y,
            deltaX, deltaY);

    first = false;
    lastRawX = rawX;
    lastRawY = rawY;
    lastX = decoded.x;
    lastY = decoded.y;
}

static void traceRightStickTransmit(uint32_t packetCount, JoyConSide side, const JoyConReportData& report) {
    if (!g_debugInput) {
        return;
    }

    static bool first = true;
    static int lastRX = 0;
    static int lastRY = 0;
    if (!first && report.stickRX == lastRX && report.stickRY == lastRY) {
        return;
    }

    int deltaX = first ? 0 : int(report.stickRX) - lastRX;
    int deltaY = first ? 0 : int(report.stickRY) - lastRY;
    debugInputLog(
            "[RS-TX]  pkt=%u source=%c reportRS=(%6d,%6d) dtx=(%6d,%6d) pairedLS=(%6d,%6d) T=(%3u,%3u)\n",
            packetCount,
            side == JoyConSide::Right ? 'R' : 'L',
            report.stickRX, report.stickRY,
            deltaX, deltaY,
            report.stickLX, report.stickLY,
            (unsigned)report.triggerL, (unsigned)report.triggerR);

    first = false;
    lastRX = report.stickRX;
    lastRY = report.stickRY;
}


static void emitJSONLine(const std::string& line) {
    std::cout << line << std::endl;
    if (g_jsonFile) {
        fprintf(g_jsonFile, "%s\n", line.c_str());
        fflush(g_jsonFile);
    }
}

static std::string jsonEscape(const char *value) {
    std::string input = value ? value : "";
    std::string output;
    output.reserve(input.size());
    for (char c : input) {
        switch (c) {
            case '\\': output += "\\\\"; break;
            case '"': output += "\\\""; break;
            case '\n': output += "\\n"; break;
            case '\r': output += "\\r"; break;
            case '\t': output += "\\t"; break;
            default: output += c; break;
        }
    }
    return output;
}

void onJoyConStatus(JoyConSide side, const char *status, const char *message, const char *name) {
    if (!g_emitJSON) {
        return;
    }

    const char *sideName = side == JoyConSide::Right ? "right" : "left";
    std::string line = std::string("{")
        + "\"event\":\"controller\","
        + "\"side\":\"" + sideName + "\","
        + "\"status\":\"" + jsonEscape(status) + "\","
        + "\"message\":\"" + jsonEscape(message) + "\","
        + "\"name\":\"" + jsonEscape(name) + "\""
        + "}";
    emitJSONLine(line);
}

void onJoyConTelemetry(JoyConSide side, const char *phase, const char *detail, const char *name) {
    if (!g_emitJSON) {
        return;
    }

    const char *sideName = side == JoyConSide::Right ? "right" : "left";
    std::string line = std::string("{")
        + "\"event\":\"telemetry\","
        + "\"side\":\"" + sideName + "\","
        + "\"phase\":\"" + jsonEscape(phase) + "\","
        + "\"detail\":\"" + jsonEscape(detail) + "\","
        + "\"name\":\"" + jsonEscape(name) + "\""
        + "}";
    emitJSONLine(line);
}

static std::string hexCompact(const std::vector<uint8_t>& bytes) {
    std::ostringstream out;
    out << std::hex << std::uppercase << std::setfill('0');
    for (uint8_t byte : bytes) {
        out << std::setw(2) << static_cast<unsigned>(byte);
    }
    return out.str();
}

static const char *nfcTypeName(uint8_t tagType) {
    switch (tagType) {
        case 0x01: return "ISO14443A";
        case 0x02: return "NTAG/Amiibo";
        case 0x03: return "MIFARE";
        case 0x04: return "NFC Tag";
        default: return "Vendor";
    }
}

void onJoyConNFCTag(uint8_t status,
                    uint8_t tagType,
                    const std::vector<uint8_t>& tagId,
                    const std::vector<uint8_t>& payload) {
    if (g_driverClient) {
        JoyConNFCReportData report = {};
        report.status = status;
        size_t tagCopyLength = std::min<size_t>(tagId.size(), sizeof(report.tagId));
        size_t payloadCopyLength = std::min<size_t>(payload.size(), sizeof(report.payload));
        if (tagCopyLength > 0) {
            memcpy(report.tagId, tagId.data(), tagCopyLength);
        }
        if (payloadCopyLength > 0) {
            memcpy(report.payload, payload.data(), payloadCopyLength);
        }
        [g_driverClient postNFCReport:report];
    }

    if (!g_emitJSON) {
        return;
    }

    std::string uidHex = hexCompact(tagId);
    std::string payloadHex = hexCompact(payload);
    std::string line = std::string("{")
        + "\"event\":\"nfc\","
        + "\"side\":\"right\","
        + "\"status\":" + std::to_string(status) + ","
        + "\"type\":\"" + jsonEscape(nfcTypeName(tagType)) + "\","
        + "\"typeCode\":" + std::to_string(static_cast<unsigned>(tagType)) + ","
        + "\"uid\":\"" + uidHex + "\","
        + "\"payload\":\"" + payloadHex + "\""
        + "}";
    emitJSONLine(line);
}

void emitDaemonEvent(const char *status, const char *detail) {
    if (!g_emitJSON) {
        return;
    }

    std::string line = std::string("{")
        + "\"event\":\"daemon\","
        + "\"status\":\"" + jsonEscape(status) + "\","
        + "\"detail\":\"" + jsonEscape(detail) + "\""
        + "}";
    emitJSONLine(line);
}

void toggleMouseMode() {
    if (!g_mouseEmitter) return;

    // Cycle joycon2cpp-style: OFF -> FAST -> NORMAL -> SLOW -> OFF.
    g_mouseEmitter.currentMode = (MouseMode)((g_mouseEmitter.currentMode + 1) % 4);

    // Switch the player-LED pattern to mirror the mode, matching
    // joycon2cpp/testapp/src/testapp.cpp lines 990-1006:
    //   OFF    -> LED 1 (0x01)
    //   FAST   -> LED 2 (0x02)
    //   NORMAL -> LED 3 (0x04)
    //   SLOW   -> LED 4 (0x08)
    uint8_t ledPattern = 0x01;
    const char *modeName = "OFF";
    switch (g_mouseEmitter.currentMode) {
        case MouseModeFast:   modeName = "FAST";   ledPattern = 0x02; break;
        case MouseModeNormal: modeName = "NORMAL"; ledPattern = 0x04; break;
        case MouseModeSlow:   modeName = "SLOW";   ledPattern = 0x08; break;
        default: break;
    }
    std::cout << "[Mouse Mode] " << modeName << std::endl;

    if (g_bleManager) {
        [g_bleManager setPlayerLED:ledPattern];
    }
}

static void applySDLOnlyMode(bool enabled) {
    g_sdlOnlyMode = enabled;

    if (!g_driverClient || !g_driverClient.isRunning) {
        emitDaemonEvent("sdlOnlyMode", enabled ? "pending=1 driver=missing" : "pending=0 driver=missing");
        return;
    }

    BOOL ok = [g_driverClient setSDLOnlyMode:enabled ? YES : NO];
    if (ok && enabled && g_haveLastGamepadReport) {
        [g_driverClient postGamepadReport:g_lastGamepadReport];
    }

    emitDaemonEvent("sdlOnlyMode", ok
        ? (enabled ? "applied=1" : "applied=0")
        : (enabled ? "failed=1" : "failed=0"));
    std::cout << "[Control] SDL Only Mode " << (enabled ? "ON" : "OFF")
              << (ok ? "" : " (driver rejected)") << std::endl;
}

static void applyFindJoyConMode(bool leftActive, bool rightActive, const char *reason) {
    g_findLeftActive = leftActive;
    g_findRightActive = rightActive;
    g_findShakeStartLeft = 0;
    g_findShakeStartRight = 0;
    g_findHaveLastMotionLeft = false;
    g_findHaveLastMotionRight = false;

    if (g_bleManager) {
        [g_bleManager setFindModeLeft:leftActive ? YES : NO
                                right:rightActive ? YES : NO];
    }

    NSString *detail = [NSString stringWithFormat:@"left=%d right=%d reason=%s",
                                                  leftActive ? 1 : 0,
                                                  rightActive ? 1 : 0,
                                                  reason ? reason : "unknown"];
    emitDaemonEvent("findJoyCon", [detail UTF8String]);
}

static void updateFindShakeStop(JoyConSide side, const MotionData& motion) {
    bool *active = side == JoyConSide::Right ? &g_findRightActive : &g_findLeftActive;
    CFAbsoluteTime *shakeStart = side == JoyConSide::Right ? &g_findShakeStartRight : &g_findShakeStartLeft;
    MotionData *lastMotion = side == JoyConSide::Right ? &g_findLastMotionRight : &g_findLastMotionLeft;
    bool *haveLastMotion = side == JoyConSide::Right ? &g_findHaveLastMotionRight : &g_findHaveLastMotionLeft;
    if (!*active) {
        *haveLastMotion = false;
        *shakeStart = 0;
        return;
    }

    float gyroMagnitude = std::sqrt(motion.gyroX * motion.gyroX +
                                    motion.gyroY * motion.gyroY +
                                    motion.gyroZ * motion.gyroZ);
    float accelMagnitude = std::sqrt(motion.accelX * motion.accelX +
                                     motion.accelY * motion.accelY +
                                     motion.accelZ * motion.accelZ);
    float accelJerk = 0.0f;
    if (*haveLastMotion) {
        float deltaX = motion.accelX - lastMotion->accelX;
        float deltaY = motion.accelY - lastMotion->accelY;
        float deltaZ = motion.accelZ - lastMotion->accelZ;
        accelJerk = std::sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ);
    }
    *lastMotion = motion;
    *haveLastMotion = true;

    bool strongShake = gyroMagnitude > 125.0f || accelJerk > 0.45f || std::fabs(accelMagnitude - 1.0f) > 0.55f;
    bool mediumShake = gyroMagnitude > 70.0f && accelJerk > 0.18f;
    const bool shaking = strongShake || mediumShake;
    if (!shaking) {
        *shakeStart = 0;
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (*shakeStart == 0) {
        *shakeStart = now;
        return;
    }
    if ((now - *shakeStart) < 1.0) {
        return;
    }

    if (side == JoyConSide::Right) {
        applyFindJoyConMode(g_findLeftActive, false, "shake-right");
    } else {
        applyFindJoyConMode(false, g_findRightActive, "shake-left");
    }
}

static std::string sanitizedRailTarget(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return "none";
    }
    std::string raw([value UTF8String]);
    static const char *valid[] = {
        "none", "cross", "circle", "square", "triangle",
        "l1", "r1", "l2", "r2",
        "share", "options", "l3", "r3",
        "dpadUp", "dpadDown", "dpadLeft", "dpadRight",
        "home", "capture"
    };
    for (const char *target : valid) {
        if (raw == target) {
            return raw;
        }
    }
    return "none";
}

static void applyRailTarget(const std::string& target, uint32_t& leftButtons, uint32_t& rightButtons) {
    if (target == "cross")         rightButtons |= BTN_RIGHT_X;
    else if (target == "circle")   rightButtons |= BTN_RIGHT_A;
    else if (target == "square")   rightButtons |= BTN_RIGHT_Y;
    else if (target == "triangle") rightButtons |= BTN_RIGHT_B;
    else if (target == "l1")       leftButtons  |= BTN_LEFT_L;
    else if (target == "r1")       rightButtons |= BTN_RIGHT_R;
    else if (target == "l2")       leftButtons  |= BTN_LEFT_ZL;
    else if (target == "r2")       rightButtons |= BTN_RIGHT_ZR;
    else if (target == "share")    leftButtons  |= BTN_LEFT_MINUS;
    else if (target == "options")  rightButtons |= BTN_RIGHT_PLUS;
    else if (target == "l3")       leftButtons  |= BTN_LEFT_L3;
    else if (target == "r3")       rightButtons |= BTN_RIGHT_R3;
    else if (target == "dpadUp")   leftButtons  |= BTN_LEFT_UP;
    else if (target == "dpadDown") leftButtons  |= BTN_LEFT_DOWN;
    else if (target == "dpadLeft") leftButtons  |= BTN_LEFT_LEFT;
    else if (target == "dpadRight") leftButtons |= BTN_LEFT_RIGHT;
    else if (target == "home")     rightButtons |= BTN_RIGHT_HOME;
    else if (target == "capture")  leftButtons  |= BTN_LEFT_CAPTURE;
}

static void applyRailBindingsToReport(uint32_t& leftButtons, uint32_t& rightButtons) {
    bool leftSLPressed = (leftButtons & BTN_LEFT_SLL) != 0;
    bool leftSRPressed = (leftButtons & BTN_LEFT_SRL) != 0;
    bool rightSLPressed = (rightButtons & BTN_RIGHT_SLR) != 0;
    bool rightSRPressed = (rightButtons & BTN_RIGHT_SRR) != 0;

    leftButtons &= ~(BTN_LEFT_SLL | BTN_LEFT_SRL);
    rightButtons &= ~(BTN_RIGHT_SLR | BTN_RIGHT_SRR);

    if (leftSLPressed)  applyRailTarget(g_railBindingLeftSL, leftButtons, rightButtons);
    if (leftSRPressed)  applyRailTarget(g_railBindingLeftSR, leftButtons, rightButtons);
    if (rightSLPressed) applyRailTarget(g_railBindingRightSL, leftButtons, rightButtons);
    if (rightSRPressed) applyRailTarget(g_railBindingRightSR, leftButtons, rightButtons);
}

// Apply one control command from the GUI. Kept as a small dispatch so we
// can extend it later (rumble trigger, re-pair, etc.) without rewriting
// the polling loop.
static void applyControlCommand(NSDictionary *command) {
    NSString *cmd = command[@"cmd"];
    if (![cmd isKindOfClass:[NSString class]]) return;

    if ([cmd isEqualToString:@"setMouseMode"]) {
        if (!g_mouseEmitter) return;
        NSNumber *value = command[@"value"];
        if (![value isKindOfClass:[NSNumber class]]) return;
        int raw = value.intValue;
        if (raw < 0 || raw > 3) return;
        MouseMode target = (MouseMode)raw;
        if (g_mouseEmitter.currentMode == target) {
            emitDaemonEvent("mouseMode", [[NSString stringWithFormat:@"already=%d", raw] UTF8String]);
            return;
        }
        g_mouseEmitter.currentMode = target;
        uint8_t ledPattern = 0x01;
        const char *modeName = "OFF";
        switch (target) {
            case MouseModeFast:   modeName = "FAST";   ledPattern = 0x02; break;
            case MouseModeNormal: modeName = "NORMAL"; ledPattern = 0x04; break;
            case MouseModeSlow:   modeName = "SLOW";   ledPattern = 0x08; break;
            default: break;
        }
        if (g_bleManager) {
            [g_bleManager setPlayerLED:ledPattern];
        }
        emitDaemonEvent("mouseMode",
                        [[NSString stringWithFormat:@"applied=%s (%d)", modeName, raw] UTF8String]);
        std::cout << "[Control] Mouse mode set to " << modeName << std::endl;
    } else if ([cmd isEqualToString:@"toggleMouseMode"]) {
        toggleMouseMode();
    } else if ([cmd isEqualToString:@"setMouseSource"]) {
        if (!g_mouseEmitter) return;
        NSNumber *value = command[@"value"];
        if (![value isKindOfClass:[NSNumber class]]) return;
        int raw = value.intValue;
        if (raw < 0 || raw > 2) return;
        MouseSource target = (MouseSource)raw;
        if (g_mouseEmitter.source == target) {
            emitDaemonEvent("mouseSource",
                            [[NSString stringWithFormat:@"already=%d", raw] UTF8String]);
            return;
        }
        g_mouseEmitter.source = target;
        const char *srcName = "AUTO";
        switch (target) {
            case MouseSourceLeft:  srcName = "LEFT";  break;
            case MouseSourceRight: srcName = "RIGHT"; break;
            default: break;
        }
        emitDaemonEvent("mouseSource",
                        [[NSString stringWithFormat:@"applied=%s (%d)", srcName, raw] UTF8String]);
        std::cout << "[Control] Mouse source set to " << srcName << std::endl;
    } else if ([cmd isEqualToString:@"setSDLOnlyMode"]) {
        NSNumber *value = command[@"value"];
        if (![value isKindOfClass:[NSNumber class]]) return;
        applySDLOnlyMode(value.boolValue);
    } else if ([cmd isEqualToString:@"setFindJoyCon"]) {
        NSNumber *left = command[@"left"];
        NSNumber *right = command[@"right"];
        if (![left isKindOfClass:[NSNumber class]] || ![right isKindOfClass:[NSNumber class]]) return;
        applyFindJoyConMode(left.boolValue, right.boolValue, "command");
    } else if ([cmd isEqualToString:@"scanNFC"]) {
        if (!g_bleManager) {
            emitDaemonEvent("nfc", "scan failed: BLE manager missing");
            return;
        }
        BOOL ok = [g_bleManager startNFCScanning];
        emitDaemonEvent("nfc", ok ? "scan started" : "scan failed: right Joy-Con missing");
    } else if ([cmd isEqualToString:@"probeNFC"]) {
        if (!g_bleManager) {
            emitDaemonEvent("nfc", "probe failed: BLE manager missing");
            return;
        }
        BOOL ok = [g_bleManager runNFCProtocolProbe];
        emitDaemonEvent("nfc", ok ? "probe started" : "probe failed: right Joy-Con missing");
    } else if ([cmd isEqualToString:@"stopNFC"]) {
        if (g_bleManager) {
            [g_bleManager stopNFCScanning];
        }
        emitDaemonEvent("nfc", "scan stopped");
    } else if ([cmd isEqualToString:@"setRailBindings"]) {
        NSDictionary *bindings = command[@"bindings"];
        if (![bindings isKindOfClass:[NSDictionary class]]) return;

        g_railBindingLeftSL = sanitizedRailTarget(bindings[@"leftSL"]);
        g_railBindingLeftSR = sanitizedRailTarget(bindings[@"leftSR"]);
        g_railBindingRightSL = sanitizedRailTarget(bindings[@"rightSL"]);
        g_railBindingRightSR = sanitizedRailTarget(bindings[@"rightSR"]);

        emitDaemonEvent("railBindings", "applied=1");
    } else {
        emitDaemonEvent("controlUnknown",
                        [[NSString stringWithFormat:@"unknown cmd=%@", cmd] UTF8String]);
    }
}

static void pollControlFile() {
    if (!g_controlFilePath) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:g_controlFilePath]) {
        g_controlFileOffset = 0;
        return;
    }
    NSError *err = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:g_controlFilePath error:&err];
    if (!attrs) return;
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size < g_controlFileOffset) {
        // File was truncated or rotated. Rewind.
        g_controlFileOffset = 0;
    }
    if (size <= g_controlFileOffset) return;

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:g_controlFilePath];
    if (!fh) return;
    @try {
        [fh seekToFileOffset:g_controlFileOffset];
        NSData *data = [fh readDataToEndOfFile];
        g_controlFileOffset = [fh offsetInFile];
        [fh closeFile];
        if (data.length == 0) return;
        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *rawLine in [chunk componentsSeparatedByString:@"\n"]) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length == 0) continue;
            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonErr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:lineData
                                                     options:0
                                                       error:&jsonErr];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                applyControlCommand((NSDictionary *)obj);
            }
        }
    } @catch (NSException *e) {
        [fh closeFile];
    }
}

static void startControlFilePolling(NSString *path) {
    if (!path) return;
    g_controlFilePath = [path copy];
    // Ensure the file exists so the GUI's append-open doesn't race us, and
    // so we know where the read cursor is.
    if (![[NSFileManager defaultManager] fileExistsAtPath:g_controlFilePath]) {
        [[NSFileManager defaultManager] createFileAtPath:g_controlFilePath
                                                contents:nil
                                              attributes:nil];
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:g_controlFilePath error:nil];
    g_controlFileOffset = [attrs[NSFileSize] unsignedLongLongValue];

    dispatch_queue_t queue = dispatch_get_main_queue();
    g_controlFileTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(g_controlFileTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                              (uint64_t)(0.1 * NSEC_PER_SEC),
                              (uint64_t)(0.02 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(g_controlFileTimer, ^{
        pollControlFile();
    });
    dispatch_resume(g_controlFileTimer);
    emitDaemonEvent("controlFile", [[NSString stringWithFormat:@"path=%@", path] UTF8String]);
}

static void pollRumbleReport() {
    if (!g_driverClient || !g_bleManager) {
        return;
    }

    JoyConRumbleReportData report = {};
    if (![g_driverClient copyLatestRumbleReport:&report]) {
        return;
    }
    if (report.sequence == g_lastRumbleSequence) {
        return;
    }

    g_lastRumbleSequence = report.sequence;
    [g_bleManager setRumbleLowFrequency:report.lowFrequency
                          highFrequency:report.highFrequency];
}

static void sendSDLOnlyKeepalive() {
    if (!g_sdlOnlyMode || !g_enableGamepad || !g_driverClient || !g_haveLastGamepadReport) {
        return;
    }
    [g_driverClient postGamepadReport:g_lastGamepadReport];
}

static void startRumblePolling() {
    if (g_rumblePollTimer) {
        return;
    }

    dispatch_queue_t queue = dispatch_get_main_queue();
    g_rumblePollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(g_rumblePollTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 16666667ULL),
                              16666667ULL,
                              4000000ULL);
    dispatch_source_set_event_handler(g_rumblePollTimer, ^{
        pollRumbleReport();
        sendSDLOnlyKeepalive();
    });
    dispatch_resume(g_rumblePollTimer);
}

void printControllerState() {
    if (g_emitJSON) {
        return;
    }

    // Throttle output to once per 100ms
    if (g_lastPrintTime && [[NSDate date] timeIntervalSinceDate:g_lastPrintTime] < 0.1) {
        return;
    }
    g_lastPrintTime = [NSDate date];
    
    std::cout << "\r";
    std::cout << "BTN:0x" << std::hex << std::setw(6) << std::setfill('0') << g_state.buttons << std::dec << " ";
    std::cout << "L:(" << std::setw(6) << g_state.leftStick.x << "," << std::setw(6) << g_state.leftStick.y << ") ";
    
    if (g_state.rightStick.x != 0 || g_state.rightStick.y != 0) {
        std::cout << "R:(" << std::setw(6) << g_state.rightStick.x << "," << std::setw(6) << g_state.rightStick.y << ") ";
    }
    
    std::cout << "T:(" << std::setw(3) << (int)g_state.triggerL << "," << std::setw(3) << (int)g_state.triggerR << ") ";
    std::cout << "BAT:" << std::fixed << std::setprecision(2) << g_state.battery.voltage << "V ";
    
    if (g_mouseEmitter && g_mouseEmitter.currentMode != MouseModeOff) {
        const char *modeChars[] = {"", "S", "N", "F"};
        std::cout << "[MOUSE:" << modeChars[g_mouseEmitter.currentMode] << "] ";
    }
    
    std::cout << "#" << g_state.packetCount << std::flush;
}

void printDetailedState() {
    if (g_emitJSON) {
        return;
    }

    std::cout << "\n========== Joy-Con State ==========\n";
    std::cout << "Packet #" << g_state.packetCount << "\n\n";
    std::cout << "Buttons: 0x" << std::hex << g_state.buttons << std::dec << "\n";
    
    std::cout << "\nSticks:\n";
    std::cout << "  Left:  X=" << g_state.leftStick.x << " Y=" << g_state.leftStick.y << "\n";
    std::cout << "  Right: X=" << g_state.rightStick.x << " Y=" << g_state.rightStick.y << "\n";
    
    std::cout << "\nMotion (IMU):\n";
    // Print whichever side pushed the most recent packet. The per-side
    // slots above keep Left and Right separate for the JSON emitter; for
    // the human-readable dump we show the side we just received from so
    // the readout tracks the controller the user is moving.
    const MotionData &motion =
        g_state.lastSide == JoyConSide::Right ? g_state.motionRight : g_state.motionLeft;
    std::cout << "  Gyro:  X=" << std::fixed << std::setprecision(2) << motion.gyroX
              << "° Y=" << motion.gyroY << "° Z=" << motion.gyroZ << "°/s\n";
    std::cout << "  Accel: X=" << motion.accelX
              << "G Y=" << motion.accelY << "G Z=" << motion.accelZ << "G\n";
    
    std::cout << "\nMouse:\n";
    std::cout << "  Delta: X=" << g_state.mouse.deltaX << " Y=" << g_state.mouse.deltaY << "\n";
    std::cout << "  Distance: " << g_state.mouse.distance << "\n";
    
    std::cout << "\nTriggers:\n";
    std::cout << "  L=" << (int)g_state.triggerL << " R=" << (int)g_state.triggerR << "\n";
    
    std::cout << "\nBattery:\n";
    std::cout << "  Voltage: " << g_state.battery.voltage << "V\n";
    std::cout << "  Current: " << g_state.battery.current << "mA\n";
    std::cout << "  Temp: " << g_state.battery.temperature << "°C\n";
    
    std::cout << "===================================\n\n";
}

static uint8_t makeHIDDpad(bool up, bool down, bool left, bool right) {
    if (up && right) return 1;
    if (up && left) return 7;
    if (down && right) return 3;
    if (down && left) return 5;
    if (up) return 0;
    if (down) return 4;
    if (left) return 6;
    if (right) return 2;
    return 8;
}

static void printJSONState(const std::vector<uint8_t>& buffer, JoyConSide side, uint32_t sideButtons) {
    if (!g_emitJSON) {
        return;
    }

    NSDate *lastJSONTime = side == JoyConSide::Right ? g_lastJSONRightTime : g_lastJSONLeftTime;
    NSDate *now = [NSDate date];
    if (lastJSONTime && [now timeIntervalSinceDate:lastJSONTime] < kJSONStateIntervalSeconds) {
        return;
    }
    if (side == JoyConSide::Right) {
        g_lastJSONRightTime = now;
    } else {
        g_lastJSONLeftTime = now;
    }

    const char *sideName = side == JoyConSide::Right ? "right" : "left";
    StickData sideStick = side == JoyConSide::Right ? g_state.rightStick : g_state.leftStick;
    // Match the per-side MotionData slot so a state line for the Left Joy-Con
    // only reports the Left IMU (and vice versa). Without this, the UI saw
    // the same gyro/accel trio for both controllers, which is the "wonky 3D
    // cube that doesn't match the physical Joy-Con" symptom.
    const MotionData &sideMotion = side == JoyConSide::Right ? g_state.motionRight : g_state.motionLeft;
    const MouseData &sideMouse = side == JoyConSide::Right ? g_state.mouseRight : g_state.mouseLeft;
    int mouseMode = g_mouseEmitter ? (int)g_mouseEmitter.currentMode : 0;
    int mouseSource = g_mouseEmitter ? (int)g_mouseEmitter.source : 0;
    const char *mouseActive = g_mouseEmitter && g_mouseEmitter.lastActiveSide == JoyConSide::Left ? "left" : "right";

    std::ostringstream out;
    out << "{"
        << "\"event\":\"state\","
        << "\"side\":\"" << sideName << "\","
        << "\"packetCount\":" << g_state.packetCount << ","
        << "\"packetSize\":" << buffer.size() << ","
        << "\"buttons\":" << sideButtons << ","
        << "\"leftButtons\":" << g_state.leftButtons << ","
        << "\"rightButtons\":" << g_state.rightButtons << ","
        << "\"stickX\":" << sideStick.x << ","
        << "\"stickY\":" << sideStick.y << ","
        << "\"leftStickX\":" << g_state.leftStick.x << ","
        << "\"leftStickY\":" << g_state.leftStick.y << ","
        << "\"rightStickX\":" << g_state.rightStick.x << ","
        << "\"rightStickY\":" << g_state.rightStick.y << ","
        << "\"gyroX\":" << sideMotion.gyroX << ","
        << "\"gyroY\":" << sideMotion.gyroY << ","
        << "\"gyroZ\":" << sideMotion.gyroZ << ","
        << "\"accelX\":" << sideMotion.accelX << ","
        << "\"accelY\":" << sideMotion.accelY << ","
        << "\"accelZ\":" << sideMotion.accelZ << ","
        << "\"mouseX\":" << sideMouse.deltaX << ","
        << "\"mouseY\":" << sideMouse.deltaY << ","
        << "\"mouseDistance\":" << sideMouse.distance << ","
        << "\"batteryVoltage\":" << g_state.battery.voltage << ","
        << "\"batteryCurrent\":" << g_state.battery.current << ","
        << "\"batteryTemperature\":" << g_state.battery.temperature << ","
        << "\"batteryPercentage\":" << g_state.battery.percentage << ","
        << "\"triggerL\":" << (int)g_state.triggerL << ","
        << "\"triggerR\":" << (int)g_state.triggerR << ","
        << "\"mouseMode\":" << mouseMode << ","
        << "\"mouseSource\":" << mouseSource << ","
        << "\"mouseActiveSide\":\"" << mouseActive << "\""
        << "}";
    emitJSONLine(out.str());
}

void onJoyConData(const std::vector<uint8_t>& buffer, JoyConSide side) {
    g_state.packetCount++;
    g_state.lastSide = side;
    g_state.isLeftJoyCon = (side == JoyConSide::Left);
    
    uint32_t sideButtons = ExtractButtonState(buffer, side);
    if (side == JoyConSide::Left) {
        g_state.leftButtons = sideButtons;
        g_state.leftStick = DecodeJoystick(buffer, JoyConSide::Left, JoyConOrientation::Upright);

        // [BLE->DEC L] Fires only when dpad or left-stick bucket actually
        // changes. dpad bucket = the 4 dpad bits isolated from the rest of
        // the button word; without this key the log would still fire on
        // every face-button press and drown out the signal we want.
        if (g_debugInput) {
            static uint32_t lastDpadBits = ~0u;
            static int lastLX = INT32_MAX, lastLY = INT32_MAX;
            uint32_t dpadBits = sideButtons & 0x00000F; // bits 0..3 = D/U/R/L
            if (dpadBits != lastDpadBits || g_state.leftStick.x != lastLX || g_state.leftStick.y != lastLY) {
                bool u = dpadBits & 0x2, d = dpadBits & 0x1, l = dpadBits & 0x8, r = dpadBits & 0x4;
                debugInputLog(
                        "[BLE->DEC L] btn=0x%06x dpad=%c%c%c%c  LS=(%6d,%6d)\n",
                        sideButtons,
                        u ? 'U' : '.', d ? 'D' : '.', l ? 'L' : '.', r ? 'R' : '.',
                        g_state.leftStick.x, g_state.leftStick.y);
                lastDpadBits = dpadBits;
                lastLX = g_state.leftStick.x;
                lastLY = g_state.leftStick.y;
            }
        }
    } else {
        g_state.rightButtons = sideButtons;
        // Switch 2 per-side BLE packet: right Joy-Con stick lives at
        // [13..15] with the X/Y nibble layout swapped vs the left side.
        // See the extended comment in DecodeJoystick for the nibble map.
        g_state.rightStick = DecodeJoystick(buffer, JoyConSide::Right, JoyConOrientation::Upright);

        // Right-stick-only trace: raw packet bytes, unpacked 12-bit values,
        // final decoded stick, and per-line decoded deltas. This is cleaner
        // than the broad [HID-TX] line when isolating physical right-stick
        // movement from buttons, left stick, and trigger noise.
        traceRightStickDecode(buffer, g_state.packetCount, g_state.rightStick);
    }

    g_state.buttons = sideButtons;
    // Write motion into the per-side slot. The JSON emitter below picks the
    // matching slot so gyroX/gyroY/gyroZ for the left packet never bleed
    // into the right controller's telemetry row and vice versa.
    if (side == JoyConSide::Left) {
        g_state.motionLeft = DecodeMotion(buffer, side);
        updateFindShakeStop(side, g_state.motionLeft);
        g_state.mouseLeft  = DecodeMouse(buffer);
        g_state.mouse      = g_state.mouseLeft;
    } else {
        g_state.motionRight = DecodeMotion(buffer, side);
        updateFindShakeStop(side, g_state.motionRight);
        g_state.mouseRight  = DecodeMouse(buffer);
        g_state.mouse       = g_state.mouseRight;
    }
    g_state.battery = DecodeBattery(buffer);
    auto triggers = DecodeAnalogTriggers(buffer);
    // Only update the trigger for the side that sent this packet.
    // Otherwise a left packet (with 0 at offset 0x3D) would zero out
    // triggerR on every left-side frame, causing rapid flicker when R
    // is held on the right Joy-Con.
    if (side == JoyConSide::Left) {
        g_state.triggerL = triggers.first;
    } else {
        g_state.triggerR = triggers.second;
    }
    
    // joycon2cpp: only the Right Joy-Con / Joy-Con 2 has a Chat (C) button,
    // and that button is the *only* trigger for mouse mode. On the left
    // Joy-Con we do nothing here — Capture remains a normal gamepad button.
    if (side == JoyConSide::Right) {
        static bool wasChatPressed = false;
        bool chatPressed = (sideButtons & 0x000040) != 0;
        if (chatPressed && !wasChatPressed) {
            toggleMouseMode();
        }
        wasChatPressed = chatPressed;
    }

    // Mouse mode: feed the raw packet to the emitter so it can decide
    // (based on its `source` setting + per-side distance) whether to
    // consume this packet as a mouse event.
    //
    // IMPORTANT: the emitter mutates `workingBuffer` to suppress the
    // HID bits it consumed. We want those suppressions to land on the
    // gamepad report ONLY — the UI JSON must still report the real
    // button state so the on-screen gamepad visualisation works. So we
    // build two derived button/stick values:
    //
    //   sideButtonsForGamepad / sideStickForGamepad → fed to DS4/HID
    //   g_state.rightButtons / g_state.rightStick   → untouched, UI sees them
    std::vector<uint8_t> workingBuffer = buffer;
    uint32_t sideButtonsForGamepad = sideButtons;
    StickData sideStickForGamepad  = (side == JoyConSide::Right)
                                        ? g_state.rightStick
                                        : g_state.leftStick;

    // Always feed the emitter — even when mouse mode is Off — so it can
    // keep its per-side surface tracking up to date and drive the "Active"
    // badge in the GUI. The emitter short-circuits internally if the mode
    // is Off (returns NO, buffer untouched) so the gamepad path is unaffected.
    if (g_mouseEmitter) {
        StickData sideStick = sideStickForGamepad;
        uint16_t sideDistance = (side == JoyConSide::Right)
                                  ? g_state.mouseRight.distance
                                  : g_state.mouseLeft.distance;
        BOOL consumed = [g_mouseEmitter processBuffer:workingBuffer
                                                 side:side
                                          buttonState:sideButtons
                                         stickReading:sideStick
                                        mouseDistance:sideDistance];
        if (consumed) {
            // Only the gamepad-path values get the stripped data.
            sideButtonsForGamepad = ExtractButtonState(workingBuffer, side);
            sideStickForGamepad   = DecodeJoystick(workingBuffer, side, JoyConOrientation::Upright);
        }
    }

    if (g_enableGamepad && g_driverClient) {
        // Build the DS4/HID report using the STRIPPED side buttons/stick
        // so the virtual gamepad doesn't also see the mouse clicks and
        // cursor-drive stick tilts. The UI/telemetry path below still
        // uses g_state.{left,right}Buttons which are the real values.
        uint32_t leftButtonsForReport  = g_state.leftButtons;
        uint32_t rightButtonsForReport = g_state.rightButtons;
        StickData leftStickForReport   = g_state.leftStick;
        StickData rightStickForReport  = g_state.rightStick;
        uint8_t triggerLForReport = g_state.triggerL;
        uint8_t triggerRForReport = g_state.triggerR;
        if (side == JoyConSide::Left) {
            leftButtonsForReport = sideButtonsForGamepad;
            leftStickForReport   = sideStickForGamepad;
        } else {
            rightButtonsForReport = sideButtonsForGamepad;
            rightStickForReport   = sideStickForGamepad;
        }

        // When mouse mode owns a Joy-Con on a surface, remove that half from
        // the virtual controller entirely. Lifting it rejoins the pair because
        // isSideMouseOwned flips false as soon as distance becomes non-zero.
        if (g_mouseEmitter && [g_mouseEmitter isSideMouseOwned:JoyConSide::Left]) {
            leftButtonsForReport = 0;
            leftStickForReport = { 0, 0, 0, 0 };
            triggerLForReport = 0;
        }
        if (g_mouseEmitter && [g_mouseEmitter isSideMouseOwned:JoyConSide::Right]) {
            rightButtonsForReport = 0;
            rightStickForReport = { 0, 0, 0, 0 };
            triggerRForReport = 0;
        }

        applyRailBindingsToReport(leftButtonsForReport, rightButtonsForReport);

        bool up    = leftButtonsForReport & 0x0002;
        bool down  = leftButtonsForReport & 0x0001;
        bool left  = leftButtonsForReport & 0x0008;
        bool right = leftButtonsForReport & 0x0004;

        struct JoyConReportData report;
        report.buttons = [DriverKitClient convertButtonsToHID:leftButtonsForReport
                                                 rightButtons:rightButtonsForReport
                                                       dpadUp:up
                                                     dpadDown:down
                                                     dpadLeft:left
                                                    dpadRight:right];
        report.dpad = makeHIDDpad(up, down, left, right);
        report.stickLX = leftStickForReport.x;
        report.stickLY = leftStickForReport.y;
        report.stickRX = rightStickForReport.x;
        report.stickRY = rightStickForReport.y;
        report.triggerL = triggerLForReport;
        report.triggerR = triggerRForReport;
        g_lastGamepadReport = report;
        g_haveLastGamepadReport = true;

        // Only send a new HID report when something actually changed.
        // Without this gate we fire ~132 reports/sec (66 Hz per side),
        // and some games interpret each report-with-button-set as a new
        // press event rather than a held state — causing R1/ZR/face
        // buttons to appear to fire repeatedly while held.
        static JoyConReportData lastSentReport = {};
        static bool firstReport = true;
        bool reportChanged = firstReport
            || report.buttons  != lastSentReport.buttons
            || report.dpad     != lastSentReport.dpad
            || report.stickLX  != lastSentReport.stickLX
            || report.stickLY  != lastSentReport.stickLY
            || report.stickRX  != lastSentReport.stickRX
            || report.stickRY  != lastSentReport.stickRY
            || report.triggerL != lastSentReport.triggerL
            || report.triggerR != lastSentReport.triggerR;

        if (reportChanged) {
            lastSentReport = report;
            firstReport = false;
            [g_driverClient postGamepadReport:report];
        }

        if (reportChanged) {
            traceRightStickTransmit(g_state.packetCount, side, report);
        }

        // [HID-TX] Fires only when we actually sent a new report (same
        // gate as the dedup check above). Shows the full button word,
        // hat, sticks, and triggers so you can verify the whole pipeline.
        // For right-stick work, grep RS-DEC/RS-TX instead; those lines are
        // dedicated to the physical right stick and its outgoing report.
        if (g_debugInput && reportChanged) {
            bool bU = report.buttons & (1u << 12);
            bool bD = report.buttons & (1u << 13);
            bool bL = report.buttons & (1u << 14);
            bool bR = report.buttons & (1u << 15);
            debugInputLog(
                    "[HID-TX] btn=0x%05x dpadBits=%c%c%c%c hat=%u "
                    "LS=(%6d,%6d) RS=(%6d,%6d) T=(%3u,%3u)\n",
                    report.buttons,
                    bU ? 'U' : '.', bD ? 'D' : '.', bL ? 'L' : '.', bR ? 'R' : '.',
                    (unsigned)report.dpad,
                    report.stickLX, report.stickLY,
                    report.stickRX, report.stickRY,
                    (unsigned)report.triggerL, (unsigned)report.triggerR);
        }
    }
    
    printJSONState(buffer, side, sideButtons);

    if (g_showDetailedOutput && g_state.packetCount % 60 == 0) {
        printDetailedState();
    } else {
        printControllerState();
    }
}

void printUsage() {
    std::cout << "\n╔════════════════════════════════════════════════════════╗\n";
    std::cout << "║         JoyCon2Mac Daemon - Composite DriverKit       ║\n";
    std::cout << "╚════════════════════════════════════════════════════════╝\n\n";
}

static void installShutdownHandler(int signalNumber) {
    signal(signalNumber, SIG_IGN);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signalNumber, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        std::cout << "\n[Daemon] Shutdown requested. Disconnecting Joy-Cons...\n";
        emitDaemonEvent("shutdownRequested", "signal received");
        if (g_rumblePollTimer) {
            dispatch_source_cancel(g_rumblePollTimer);
            g_rumblePollTimer = nullptr;
        }
        if (g_bleManager) {
            [g_bleManager setRumbleLowFrequency:0 highFrequency:0];
            [g_bleManager disconnect];
        }
        if (g_driverClient) {
            [g_driverClient stop];
        }
        CFRunLoopStop(CFRunLoopGetMain());
    });
    dispatch_resume(source);

    static NSMutableArray *sources = nil;
    if (!sources) {
        sources = [NSMutableArray array];
    }
    [sources addObject:source];
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            std::string arg = argv[i];
            if (arg == "-v" || arg == "--verbose") g_showDetailedOutput = true;
            else if (arg == "--json") g_emitJSON = true;
            else if (arg == "--json-file" && i + 1 < argc) {
                g_emitJSON = true;
                const char *jsonPath = argv[++i];
                g_jsonFile = fopen(jsonPath, "a");
                if (g_jsonFile) {
                    setvbuf(g_jsonFile, nullptr, _IOLBF, 0);
                }
                // Mirror the debug-input trace next to daemon.jsonl so you
                // can `tail -f ~/Library/Application Support/JoyCon2Mac/input-trace.log`
                // without digging through the unified system log.
                NSString *jsonNSPath = [NSString stringWithUTF8String:jsonPath];
                NSString *traceNSPath = [[jsonNSPath stringByDeletingLastPathComponent]
                                          stringByAppendingPathComponent:@"input-trace.log"];
                g_debugInputFile = fopen(traceNSPath.UTF8String, "a");
                if (g_debugInputFile) {
                    setvbuf(g_debugInputFile, nullptr, _IOLBF, 0);
                }
            }
            else if (arg == "--control-file" && i + 1 < argc) {
                // Path must come from the GUI, which creates the file inside
                // Application Support/JoyCon2Mac and passes the same path we
                // pass to --json-file. Store for post-init wiring.
                g_controlFilePath = [NSString stringWithUTF8String:argv[++i]];
            }
            else if (arg == "-h" || arg == "--help") { printUsage(); return 0; }
            else if (arg == "--no-gamepad") g_enableGamepad = false;
            else if (arg == "--no-debug-input") g_debugInput = false;
            else if (arg == "--sdl-only") g_sdlOnlyMode = true;
        }
        
        printUsage();
        emitDaemonEvent("started", "joycon2mac daemon main entered");
        if (g_debugInput) {
            if (g_debugInputFile) {
                fprintf(stderr, "[debug-input] tracing on; tail -f "
                                "~/Library/Application\\ Support/JoyCon2Mac/input-trace.log\n");
            } else {
                fprintf(stderr, "[debug-input] tracing on (stderr only; --json-file not set)\n");
            }
        }
        
        PairingManager *pairingManager = [PairingManager sharedManager];
        NSString *localMAC = [pairingManager getLocalBluetoothAddress];
        if (localMAC) std::cout << "Local Bluetooth MAC: " << [localMAC UTF8String] << "\n";
        
        // Initialize DriverKit client
        g_driverClient = [[DriverKitClient alloc] init];
        if ([g_driverClient startWithSDLOnlyMode:g_sdlOnlyMode ? YES : NO]) {
            std::cout << "✓ Connected to DriverKit Extension\n";
            emitDaemonEvent("driverReady", "Connected to VirtualJoyConDriver");
            applySDLOnlyMode(g_sdlOnlyMode);
        } else {
            std::cout << "✗ Failed to connect to DriverKit Extension\n";
            emitDaemonEvent("driverMissing", "VirtualJoyConDriver not loaded; HID mouse output unavailable");
        }
        g_mouseEmitter = [[MouseEmitter alloc] initWithDriverClient:g_driverClient];

        // Now that g_mouseEmitter + g_bleManager exist, hook up the GUI
        // control channel if a path was passed. Polls at 10 Hz on the main
        // queue, so mouse-mode changes show up within ~100ms.
        if (g_controlFilePath) {
            startControlFilePolling(g_controlFilePath);
        }
        
        std::cout << "Starting BLE manager...\n\n";
        
        BLEManager *bleManager = [[BLEManager alloc] init];
        g_bleManager = bleManager;
        [bleManager setDataCallback:onJoyConData];
        [bleManager setStatusCallback:onJoyConStatus];
        [bleManager setTelemetryCallback:onJoyConTelemetry];
        [bleManager setNFCCallback:onJoyConNFCTag];
        startRumblePolling();
        installShutdownHandler(SIGTERM);
        installShutdownHandler(SIGINT);
        
        std::cout << "Waiting for Bluetooth to power on...\n";
        [[NSRunLoop currentRunLoop] run];
        
        if (g_rumblePollTimer) {
            dispatch_source_cancel(g_rumblePollTimer);
            g_rumblePollTimer = nullptr;
        }
        if (g_driverClient) {
            [g_driverClient stop];
        }
        emitDaemonEvent("exiting", "run loop stopped");
        if (g_jsonFile) {
            fclose(g_jsonFile);
            g_jsonFile = nullptr;
        }
        if (g_debugInputFile) {
            fclose(g_debugInputFile);
            g_debugInputFile = nullptr;
        }
    }
    return 0;
}
