#pragma once
#include <vector>
#include <utility>
#include <cstdint>

enum class JoyConSide { Left, Right };
enum class JoyConOrientation { Upright, Sideways };
enum class GyroSource { Both, Left, Right };

// Button masks — copied from joycon2cpp/testapp/src/JoyConDecoder.cpp.
// ExtractButtonState returns a 24-bit state packed from 3 bytes of the BLE
// input report (byte offset depends on side; see the .cpp implementation).
// These masks are meant to be applied against the value returned by
// ExtractButtonState(buffer, side).

// Left Joy-Con
constexpr uint32_t BTN_LEFT_DOWN    = 0x000001;
constexpr uint32_t BTN_LEFT_UP      = 0x000002;
constexpr uint32_t BTN_LEFT_RIGHT   = 0x000004;
constexpr uint32_t BTN_LEFT_LEFT    = 0x000008;
constexpr uint32_t BTN_LEFT_SRL     = 0x000010;
constexpr uint32_t BTN_LEFT_SLL     = 0x000020;
constexpr uint32_t BTN_LEFT_L       = 0x000040;
constexpr uint32_t BTN_LEFT_ZL      = 0x000080;
constexpr uint32_t BTN_LEFT_MINUS   = 0x000100;
constexpr uint32_t BTN_LEFT_L3      = 0x000800;
constexpr uint32_t BTN_LEFT_CAPTURE = 0x002000;

// Right Joy-Con
constexpr uint32_t BTN_RIGHT_Y      = 0x000100;
constexpr uint32_t BTN_RIGHT_X      = 0x000400;
constexpr uint32_t BTN_RIGHT_B      = 0x000200;
constexpr uint32_t BTN_RIGHT_A      = 0x000800;
constexpr uint32_t BTN_RIGHT_SRR    = 0x001000;
constexpr uint32_t BTN_RIGHT_SLR    = 0x002000;
constexpr uint32_t BTN_RIGHT_R      = 0x004000;
constexpr uint32_t BTN_RIGHT_ZR     = 0x008000;
constexpr uint32_t BTN_RIGHT_PLUS   = 0x000002;
constexpr uint32_t BTN_RIGHT_R3     = 0x000004;
constexpr uint32_t BTN_RIGHT_HOME   = 0x000010;
// Chat / "C" button introduced on Switch 2 Right Joy-Con.
// joycon2cpp uses this bit to toggle optical-mouse mode.
constexpr uint32_t BTN_RIGHT_CHAT   = 0x000040;

struct StickData {
    int16_t x;
    int16_t y;
    uint8_t rx;
    uint8_t ry;
};

struct MotionData {
    float gyroX, gyroY, gyroZ;      // degrees/second
    float accelX, accelY, accelZ;   // G-force
};

struct MouseData {
    int16_t deltaX;
    int16_t deltaY;
    uint16_t distance;  // IR distance to surface
};

struct BatteryData {
    float voltage = 0.0f;      // volts
    float current = 0.0f;      // milliamps
    float temperature = 0.0f;  // controller sensor, celsius
    float percentage = -1.0f;  // estimated from voltage; negative if unavailable
    uint8_t chargeStatus = 0;   // raw protocol value; semantics are not yet known
    bool voltageValid = false;
    bool currentValid = false;
    bool temperatureValid = false;
};

// Button extraction
uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer);
uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer, JoyConSide side);

// Joystick decoding
StickData DecodeJoystick(const std::vector<uint8_t>& buffer, JoyConSide side, JoyConOrientation orientation);

// Motion decoding (IMU)
MotionData DecodeMotion(const std::vector<uint8_t>& buffer, JoyConSide side);

// Optical mouse sensor
MouseData DecodeMouse(const std::vector<uint8_t>& buffer);
std::pair<int16_t, int16_t> GetRawOpticalMouse(const std::vector<uint8_t>& buffer);

// Battery and temperature
BatteryData DecodeBattery(const std::vector<uint8_t>& buffer);

// Analog triggers (Joy-Con 2 specific)
std::pair<uint8_t, uint8_t> DecodeAnalogTriggers(const std::vector<uint8_t>& buffer);
