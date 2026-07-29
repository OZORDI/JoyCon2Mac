#ifndef DRIVER_KIT_CLIENT_H
#define DRIVER_KIT_CLIENT_H

#import <Foundation/Foundation.h>

// Structs mapping to the DriverKit .iig structs
struct JoyConReportData {
    uint32_t buttons;
    uint8_t dpad;
    int16_t stickLX;
    int16_t stickLY;
    int16_t stickRX;
    int16_t stickRY;
    uint8_t triggerL;
    uint8_t triggerR;
};

struct JoyConMouseReportData {
    uint8_t buttons; // Left=1, Right=2, Middle=4, Back=8, Forward=16
    int16_t deltaX;
    int16_t deltaY;
    int8_t scroll;
};

struct JoyConKeyboardReportData {
    uint8_t modifiers;
    uint8_t reserved;
    uint8_t keys[6];
};

struct JoyConNFCReportData {
    uint8_t status;
    uint8_t tagId[7];
    uint8_t payload[32];
};

struct JoyConRumbleReportData {
    uint8_t lowFrequency;
    uint8_t highFrequency;
    uint8_t active;
    uint8_t reserved;
    uint32_t sequence;
};

struct JoyConHIDModeData {
    uint8_t sdlOnly;
    uint8_t reserved[3];
};

@interface DriverKitClient : NSObject

@property (nonatomic, assign, readonly) BOOL isRunning;

- (BOOL)start;
- (BOOL)startWithSDLOnlyMode:(BOOL)enabled;
- (void)stop;

- (void)postGamepadReport:(struct JoyConReportData)report;
- (void)postMouseReport:(struct JoyConMouseReportData)report;
- (void)postKeyboardReport:(struct JoyConKeyboardReportData)report;
- (void)postNFCReport:(struct JoyConNFCReportData)report;
- (BOOL)copyLatestRumbleReport:(struct JoyConRumbleReportData *)report;
- (BOOL)setSDLOnlyMode:(BOOL)enabled;

// Helper: Convert button state to HID format
+ (uint32_t)convertButtonsToHID:(uint32_t)leftButtons rightButtons:(uint32_t)rightButtons dpadUp:(BOOL)up dpadDown:(BOOL)down dpadLeft:(BOOL)left dpadRight:(BOOL)right;

@end

#endif // DRIVER_KIT_CLIENT_H
