#include "JoyConDecoder.h"

#include <cmath>
#include <iostream>
#include <string>
#include <vector>

namespace {

int failures = 0;

void Expect(bool condition, const std::string &message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void ExpectNear(float actual, float expected, float tolerance, const std::string &message) {
    Expect(std::fabs(actual - expected) <= tolerance, message);
}

void TestCommonReportBatteryLayout() {
    std::vector<uint8_t> report(0x3F, 0);

    // Poison the obsolete offsets so this test fails if the old layout returns.
    report[0x1C] = 0xAA;
    report[0x1D] = 0xBB;
    report[0x1E] = 0xCC;

    report[0x1F] = 0xD0;
    report[0x20] = 0x0D;
    report[0x21] = 0x07;
    report[0x22] = 0x39;
    report[0x23] = 0x30;
    report[0x2E] = 0x81;
    report[0x2F] = 0xFF;

    const BatteryData battery = DecodeBattery(report);
    ExpectNear(battery.voltage, 3.536f, 0.0001f, "voltage uses bytes 0x1F..0x20");
    ExpectNear(battery.current, 123.45f, 0.001f, "current uses bytes 0x22..0x23");
    ExpectNear(battery.temperature, 24.0f, 0.001f, "temperature is signed");
    ExpectNear(battery.percentage, 30.11236f, 0.001f, "percentage is estimated from voltage");
    Expect(battery.chargeStatus == 0x07, "charge status uses byte 0x21");
    Expect(battery.voltageValid, "nonzero voltage is valid");
    Expect(battery.currentValid, "nonzero current is valid");
    Expect(battery.temperatureValid, "full report contains temperature");
}

void TestUnavailableCurrentAndPositiveTemperature() {
    std::vector<uint8_t> report(0x30, 0);
    report[0x1F] = 0xD0;
    report[0x20] = 0x0D;
    report[0x2E] = 0xFE;

    const BatteryData battery = DecodeBattery(report);
    Expect(!battery.currentValid, "zero current is reported as unavailable");
    ExpectNear(battery.temperature, 27.0f, 0.001f, "positive temperature sample decodes");
}

void TestBatteryPercentageAnchors() {
    std::vector<uint8_t> report(0x30, 0);

    report[0x1F] = 0xB8;
    report[0x20] = 0x0B;
    ExpectNear(DecodeBattery(report).percentage, 0.0f, 0.001f, "empty voltage maps to zero");

    report[0x1F] = 0x32;
    report[0x20] = 0x0F;
    ExpectNear(DecodeBattery(report).percentage, 50.0f, 0.001f, "rated voltage is midpoint");

    report[0x1F] = 0x62;
    report[0x20] = 0x11;
    ExpectNear(DecodeBattery(report).percentage, 100.0f, 0.001f, "full voltage maps to 100");
}

void TestTruncatedReportIsInvalid() {
    const BatteryData battery = DecodeBattery(std::vector<uint8_t>(0x2F, 0xFF));
    Expect(!battery.voltageValid, "truncated report has no voltage");
    Expect(!battery.currentValid, "truncated report has no current");
    Expect(!battery.temperatureValid, "truncated report has no temperature");
    Expect(battery.percentage < 0.0f, "truncated report has no percentage");
}

} // namespace

int main() {
    TestCommonReportBatteryLayout();
    TestUnavailableCurrentAndPositiveTemperature();
    TestBatteryPercentageAnchors();
    TestTruncatedReportIsInvalid();

    if (failures != 0) {
        std::cerr << failures << " decoder test(s) failed\n";
        return 1;
    }

    std::cout << "All Joy-Con decoder tests passed\n";
    return 0;
}
