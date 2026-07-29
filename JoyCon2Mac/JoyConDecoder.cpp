#include "JoyConDecoder.h"
#include <cmath>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <climits>
#include <cstdlib>

// Helper function to convert two bytes to signed 16-bit integer
static int16_t to_signed_16(uint8_t lsb, uint8_t msb) {
    return static_cast<int16_t>((msb << 8) | lsb);
}

struct StickCalibration {
    int centerX = 2048;
    int centerY = 2048;
    int lastRawX = INT_MIN;
    int lastRawY = INT_MIN;
    int stableSamples = 0;
    long long stableSumX = 0;
    long long stableSumY = 0;
    bool calibrated = false;
};

static bool rawLooksLikeNeutral(int raw) {
    return raw >= 1500 && raw <= 2300;
}

static bool updateStickCalibration(StickCalibration& calibration, int rawX, int rawY) {
    bool plausibleNeutral = rawLooksLikeNeutral(rawX) && rawLooksLikeNeutral(rawY);
    bool stable = plausibleNeutral &&
        (calibration.lastRawX == INT_MIN ||
         (std::abs(rawX - calibration.lastRawX) <= 4 &&
          std::abs(rawY - calibration.lastRawY) <= 4));

    calibration.lastRawX = rawX;
    calibration.lastRawY = rawY;

    if (!stable) {
        calibration.stableSamples = 0;
        calibration.stableSumX = 0;
        calibration.stableSumY = 0;
        return calibration.calibrated;
    }

    calibration.stableSamples++;
    calibration.stableSumX += rawX;
    calibration.stableSumY += rawY;

    static const int CAL_SAMPLES = 30;
    if (calibration.stableSamples >= CAL_SAMPLES) {
        calibration.centerX = static_cast<int>(calibration.stableSumX / calibration.stableSamples);
        calibration.centerY = static_cast<int>(calibration.stableSumY / calibration.stableSamples);
        calibration.calibrated = true;
        calibration.stableSamples = 0;
        calibration.stableSumX = 0;
        calibration.stableSumY = 0;
    }

    return calibration.calibrated;
}

uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer) {
    // joycon2cpp ExtractButtonState (single form): 24-bit state built from
    // bytes [3..5] of the input report. Same function body as
    // joycon2cpp/testapp/src/JoyConDecoder.cpp.
    if (buffer.size() < 6) return 0;
    return (buffer[3] << 16) | (buffer[4] << 8) | buffer[5];
}

uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer, JoyConSide side) {
    // Side-aware variant: joycon2cpp's GenerateDS4Report uses
    //   btnOffset = isLeft ? 4 : 3
    //   state = (buffer[btnOffset] << 16) | (buffer[btnOffset+1] << 8)
    //         | buffer[btnOffset+2]
    // so left Joy-Con state starts one byte later than right. That's how
    // joycon2cpp lines up the BUTTON_*_MASK_LEFT / _RIGHT bit numbers with
    // the actual packet, so we mirror it exactly.
    int btnOffset = (side == JoyConSide::Left) ? 4 : 3;
    if (buffer.size() < static_cast<size_t>(btnOffset + 3)) return 0;
    return (uint32_t(buffer[btnOffset]) << 16)
         | (uint32_t(buffer[btnOffset + 1]) << 8)
         |  uint32_t(buffer[btnOffset + 2]);
}

StickData DecodeJoystick(const std::vector<uint8_t>& buffer, JoyConSide side, JoyConOrientation orientation) {
    if (buffer.size() < 16) {
        return { 0, 0, 0, 0 };
    }

    bool isLeft = (side == JoyConSide::Left);
    bool upright = (orientation == JoyConOrientation::Upright);

    const uint8_t* data = isLeft ? &buffer[10] : &buffer[13];

    int x_raw = ((data[1] & 0x0F) << 8) | data[0];
    int y_raw = (data[2] << 4) | ((data[1] & 0xF0) >> 4);

    // Per-controller auto-calibration: only accept a center after the raw
    // stick stays still inside the normal neutral band. The old "first 30
    // packets always win" path could poison the cached center if the daemon
    // restarted while a stick was held, which showed up as permanent drift.
    static StickCalibration leftCalibration;
    static StickCalibration rightCalibration;
    StickCalibration& calibration = isLeft ? leftCalibration : rightCalibration;

    if (!updateStickCalibration(calibration, x_raw, y_raw)) {
        return { 0, 0, 0, 0 };
    }

    float x = (x_raw - calibration.centerX) / 2048.0f;
    float y = (y_raw - calibration.centerY) / 2048.0f;

    if (!upright) {
        float tx = x, ty = y;
        x = isLeft ? -ty : ty;
        y = isLeft ? tx : -tx;
    }

    const float deadzone = 0.08f;
    if (std::abs(x) < deadzone && std::abs(y) < deadzone) {
        return { 0, 0, 0, 0 };
    }

    x = std::clamp(x * 1.7f, -1.0f, 1.0f);
    y = std::clamp(y * 1.7f, -1.0f, 1.0f);

    int16_t outX = static_cast<int16_t>(x * 32767);
    int16_t outY = static_cast<int16_t>(-y * 32767);

    return { outX, outY, 0, 0 };
}

MotionData DecodeMotion(const std::vector<uint8_t>& buffer, JoyConSide side) {
    // IMU layout and scaling from joycon2cpp README and testapp:
    //   Accel X/Y/Z at 0x30/0x32/0x34, scale 4096 raw = 1 G
    //   Gyro  X/Y/Z at 0x36/0x38/0x3A, scale 48000 raw = 360°/s
    // joycon2cpp ships raw int16 into DS4 reports; for our UI we surface
    // engineering units.
    if (buffer.size() < 0x3C) {
        return { 0, 0, 0, 0, 0, 0 };
    }

    (void)side;

    int16_t raw_accel_x = to_signed_16(buffer[0x30], buffer[0x31]);
    int16_t raw_accel_y = to_signed_16(buffer[0x32], buffer[0x33]);
    int16_t raw_accel_z = to_signed_16(buffer[0x34], buffer[0x35]);

    int16_t raw_gyro_x = to_signed_16(buffer[0x36], buffer[0x37]);
    int16_t raw_gyro_y = to_signed_16(buffer[0x38], buffer[0x39]);
    int16_t raw_gyro_z = to_signed_16(buffer[0x3A], buffer[0x3B]);

    const float accel_factor = 1.0f / 4096.0f;
    const float gyro_factor  = 360.0f / 48000.0f;

    MotionData motion;
    motion.accelX = raw_accel_x * accel_factor;
    motion.accelY = raw_accel_y * accel_factor;
    motion.accelZ = raw_accel_z * accel_factor;

    motion.gyroX = raw_gyro_x * gyro_factor;
    motion.gyroY = raw_gyro_y * gyro_factor;
    motion.gyroZ = raw_gyro_z * gyro_factor;

    return motion;
}

MouseData DecodeMouse(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x18) {
        return { 0, 0, 0 };
    }

    // Mouse raw X/Y at 0x10 and 0x12 (Joy2Win datas[16:20], joycon2cpp GetRawOpticalMouse)
    int16_t deltaX = to_signed_16(buffer[0x10], buffer[0x11]);
    int16_t deltaY = to_signed_16(buffer[0x12], buffer[0x13]);
    
    // IR distance / surface state at mouseDatas[7] == packet offset 0x17
    uint16_t distance = buffer[0x17];

    return { deltaX, deltaY, distance };
}

std::pair<int16_t, int16_t> GetRawOpticalMouse(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x18) return { 0, 0 };
    int16_t raw_x = to_signed_16(buffer[0x10], buffer[0x11]);
    int16_t raw_y = to_signed_16(buffer[0x12], buffer[0x13]);
    return { raw_x, raw_y };
}

BatteryData DecodeBattery(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x30) {
        return {};
    }

    // Switch 2 common input report:
    //   0x1F..0x20: battery voltage, little-endian millivolts
    //   0x21:       raw charge status
    //   0x22..0x23: battery current, little-endian 1/100 mA
    //   0x2E..0x2F: signed controller temperature sample
    //
    // Bytes 0x1F..0x20 are a voltage, not a 12-bit state-of-charge value.
    // Joy-Con 2's BEE-004 pack is rated at 3.89 V. The firmware does not
    // expose a percentage, so estimate one around that nominal midpoint.
    // This remains an approximation until a full discharge curve is captured.
    constexpr float kEmptyVoltage = 3.0f;
    constexpr float kNominalVoltage = 3.89f;
    constexpr float kFullVoltage = 4.45f;
    const uint16_t voltageRaw =
        static_cast<uint16_t>(buffer[0x1F]) |
        static_cast<uint16_t>(static_cast<uint16_t>(buffer[0x20]) << 8);
    const uint16_t currentRaw =
        static_cast<uint16_t>(buffer[0x22]) |
        static_cast<uint16_t>(static_cast<uint16_t>(buffer[0x23]) << 8);
    const int16_t temperatureRaw = to_signed_16(buffer[0x2E], buffer[0x2F]);

    BatteryData battery;
    battery.voltage = static_cast<float>(voltageRaw) / 1000.0f;
    battery.current = static_cast<float>(currentRaw) / 100.0f;
    battery.temperature = 25.0f + static_cast<float>(temperatureRaw) / 127.0f;
    if (voltageRaw != 0) {
        if (battery.voltage <= kNominalVoltage) {
            battery.percentage =
                std::clamp((battery.voltage - kEmptyVoltage) /
                               (kNominalVoltage - kEmptyVoltage) * 50.0f,
                           0.0f, 50.0f);
        } else {
            battery.percentage =
                std::clamp(50.0f +
                               (battery.voltage - kNominalVoltage) /
                                   (kFullVoltage - kNominalVoltage) * 50.0f,
                           50.0f, 100.0f);
        }
    }
    battery.chargeStatus = buffer[0x21];
    battery.voltageValid = voltageRaw != 0;
    battery.currentValid = currentRaw != 0;
    battery.temperatureValid = true;
    return battery;
}

std::pair<uint8_t, uint8_t> DecodeAnalogTriggers(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x3E) {
        return { 0, 0 };
    }

    // Analog triggers at 0x3C and 0x3D (Joy-Con 2 specific)
    uint8_t triggerL = buffer[0x3C];
    uint8_t triggerR = buffer[0x3D];

    return { triggerL, triggerR };
}
