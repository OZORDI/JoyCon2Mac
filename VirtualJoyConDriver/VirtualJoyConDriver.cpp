#include "VirtualJoyConDriver.h"
#include <os/log.h>
#include <string.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/IOUserClient.h>
#include <HIDDriverKit/IOHIDDeviceKeys.h>
#include <HIDDriverKit/IOHIDDeviceTypes.h>
#include <HIDDriverKit/IOHIDUsageTables.h>

// ---------------------------------------------------------------------------
// Packed wire formats for the HID report types.
//
// reportId = 1 : generic gamepad (buttons + padding + sticks + triggers)
// reportId = 1 : DualSense-compatible input packet on the Sony-shaped device
// reportId = 2 : mouse (buttons, dx, dy, wheel)
// reportId = 3 : vendor-defined NFC blob
// Byte layouts MUST match the descriptor byte-for-byte or macOS rejects the
// reports silently. The report IDs remain stable even though gamepad and mouse
// are now published as separate HID devices.
// ---------------------------------------------------------------------------
struct JoyConHIDGamepadReport {
    uint8_t  reportId;
    uint32_t buttons;
    uint8_t  padding;   // reserved; D-pad is exposed as buttons only
    int16_t  x;         // left stick X
    int16_t  y;         // left stick Y
    int16_t  z;         // right stick X (HID Z, Chrome axis 2)
    int16_t  rx;        // right stick Y (HID Rx, Chrome axis 3)
    uint8_t  ry;        // left analog trigger
    uint8_t  rz;        // right analog trigger
} __attribute__((packed));

struct JoyConHIDMouseReport {
    uint8_t reportId;   // 2
    uint8_t buttons;    // bits 0..4 = left/right/middle/back/forward
    int16_t x;
    int16_t y;
    int8_t  wheel;
} __attribute__((packed));

struct JoyConHIDNFCReport {
    uint8_t reportId;   // 3
    uint8_t status;
    uint8_t tagId[7];
    uint8_t payload[32];
} __attribute__((packed));

struct DualSenseUSBInputReport {
    uint8_t  reportId;          // 1
    uint8_t  leftX;
    uint8_t  leftY;
    uint8_t  rightX;
    uint8_t  rightY;
    uint8_t  leftTrigger;
    uint8_t  rightTrigger;
    uint8_t  counter;
    uint8_t  buttonsHat0;       // low nibble = hat, high nibble = face buttons
    uint8_t  buttons1;
    uint8_t  buttons2;
    uint8_t  buttons3;
    uint8_t  packetSequence[4];
    int16_t  gyroX;
    int16_t  gyroY;
    int16_t  gyroZ;
    int16_t  accelX;
    int16_t  accelY;
    int16_t  accelZ;
    uint32_t sensorTimestamp;
    uint8_t  reserved[32];
} __attribute__((packed));

static_assert(sizeof(DualSenseUSBInputReport) == 64,
              "DualSense USB input report must remain 64 bytes");

enum : uint32_t {
    kVirtualJoyConUserClientStandard = 0,
    kVirtualJoyConUserClientSDLOnly  = 1
};

enum : uint64_t {
    kVirtualJoyConSelectorGamepad = 0,
    kVirtualJoyConSelectorMouse   = 1,
    kVirtualJoyConSelectorNFC     = 2,
    kVirtualJoyConSelectorRumble  = 3,
    kVirtualJoyConSelectorHIDMode = 4,
    kVirtualJoyConSelectorCount   = 5
};

enum : uint8_t {
    kDualSenseInputReportId           = 0x01,
    kDualSenseOutputReportId          = 0x02,
    kDualSenseSerialFeatureReportId   = 0x09,
    kDualSenseFirmwareFeatureReportId = 0x20,
    kDualSenseNeutralHat              = 0x08
};

enum : uint32_t {
    kVirtualLocationGamepad   = 0x4A433201,
    kVirtualLocationDualSense = 0x4A433202,
    kVirtualLocationMouse     = 0x4A433203
};

static JoyConRumbleReportData g_latestRumbleReport = {};

static void PublishRumbleReport(uint8_t lowFrequency, uint8_t highFrequency, bool force) {
    if (!force &&
        g_latestRumbleReport.lowFrequency == lowFrequency &&
        g_latestRumbleReport.highFrequency == highFrequency) {
        return;
    }

    g_latestRumbleReport.lowFrequency = lowFrequency;
    g_latestRumbleReport.highFrequency = highFrequency;
    g_latestRumbleReport.active = (lowFrequency || highFrequency) ? 1 : 0;
    g_latestRumbleReport.reserved = 0;
    g_latestRumbleReport.sequence += 1;
}

enum : uint32_t {
    kJoyConButtonSouth     = 0x000001,
    kJoyConButtonEast      = 0x000002,
    kJoyConButtonWest      = 0x000004,
    kJoyConButtonNorth     = 0x000008,
    kJoyConButtonL1        = 0x000010,
    kJoyConButtonR1        = 0x000020,
    kJoyConButtonL2Digital = 0x000040,
    kJoyConButtonR2Digital = 0x000080,
    kJoyConButtonBack      = 0x000100,
    kJoyConButtonStart     = 0x000200,
    kJoyConButtonL3        = 0x000400,
    kJoyConButtonR3        = 0x000800,
    kJoyConButtonDpadUp    = 0x001000,
    kJoyConButtonDpadDown  = 0x002000,
    kJoyConButtonDpadLeft  = 0x004000,
    kJoyConButtonDpadRight = 0x008000,
    kJoyConButtonGuide     = 0x010000,
    kJoyConButtonCapture   = 0x020000
};

// ---------------------------------------------------------------------------
// Gamepad HID descriptor: gamepad (ID 1) + NFC vendor (ID 3)
// ---------------------------------------------------------------------------
const uint8_t VirtualGamepadDescriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop Ctrls)
    0x09, 0x05,        // Usage (Game Pad)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x01,        //   Report ID (1)

    // Buttons (18 bits)
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (0x01)
    0x29, 0x12,        //   Usage Maximum (0x12)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x95, 0x12,        //   Report Count (18)
    0x75, 0x01,        //   Report Size (1)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Padding (14 bits) -> Aligns to uint32_t buttons
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x0E,        //   Report Size (14)
    0x81, 0x03,        //   Input (Const,Var,Abs)

    // Padding (1 byte). D-pad is already exposed as buttons 12..15, so do
    // not also publish a Hat Switch axis. Chrome normalized our neutral hat
    // value (8) against logical max 7 as axis9 = 1.28571.
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x03,        //   Input (Const,Var,Abs)

    // Left & Right Sticks (4 axes: X, Y, Z, Rx) - 16 bit, signed.
    //
    // Chrome's generic macOS HID path indexes Generic Desktop usages directly:
    // X/Y -> axes 0/1 and Z/Rx -> axes 2/3. That is the shape shown by the
    // current working Gamepad Tester captures for the physical right stick.
    0x05, 0x01,        //   Usage Page (Generic Desktop Ctrls)
    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x09, 0x32,        //   Usage (Z)
    0x09, 0x33,        //   Usage (Rx)
    0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
    0x36, 0x00, 0x80,  //   Physical Minimum (-32768)
    0x46, 0xFF, 0x7F,  //   Physical Maximum (32767)
    0x95, 0x04,        //   Report Count (4)
    0x75, 0x10,        //   Report Size (16)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Analog Triggers (Ry, Rz -> L2/R2) - 8 bit.
    0x09, 0x34,        //   Usage (Ry)
    0x09, 0x35,        //   Usage (Rz)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x35, 0x00,        //   Physical Minimum (0)
    0x46, 0xFF, 0x00,  //   Physical Maximum (255)
    0x95, 0x02,        //   Report Count (2)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    0xC0,              // End Collection

    // --- NFC (Vendor Defined - Report ID 3) ---
    0x06, 0x00, 0xFF,  // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01,        // Usage (0x01)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x03,        //   Report ID (3)

    // Status (1 byte)
    0x09, 0x02,        //   Usage (0x02)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Tag ID (7 bytes)
    0x09, 0x03,        //   Usage (0x03)
    0x95, 0x07,        //   Report Count (7)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Payload (32 bytes)
    0x09, 0x04,        //   Usage (0x04)
    0x95, 0x20,        //   Report Count (32)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    0xC0               // End Collection
};

// ---------------------------------------------------------------------------
// DualSense-compatible HID descriptor: Sony-shaped gamepad (ID 1)
// ---------------------------------------------------------------------------
const uint8_t VirtualDualSenseDescriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop Ctrls)
    0x09, 0x05,        // Usage (Game Pad)
    0xA1, 0x01,        // Collection (Application)

    // Input report 1: 64-byte USB-style DualSense state packet.
    0x85, 0x01,        //   Report ID (1)

    // SDL's PS5 HIDAPI parser consumes these bytes as LX, LY, RX, RY, L2,
    // R2. Chrome's macOS DualSense mapper, however, keys off HID usages and
    // expects raw axes[2]=RX, axes[3]=L2, axes[4]=R2, axes[5]=RY. The usage
    // order below satisfies Chrome without changing the SDL-compatible byte
    // order.
    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x09, 0x32,        //   Usage (Z)
    0x09, 0x35,        //   Usage (Rz)
    0x09, 0x33,        //   Usage (Rx)
    0x09, 0x34,        //   Usage (Ry)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x06,        //   Report Count (6)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Packet counter (1 byte)
    0x06, 0x00, 0xFF,  //   Usage Page (Vendor Defined 0xFF00)
    0x09, 0x20,        //   Usage (0x20)
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // D-pad hat in the low nibble of byte 8. Null state allows centered=8.
    0x05, 0x01,        //   Usage Page (Generic Desktop Ctrls)
    0x09, 0x39,        //   Usage (Hat switch)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x07,        //   Logical Maximum (7)
    0x35, 0x00,        //   Physical Minimum (0)
    0x46, 0x3B, 0x01,  //   Physical Maximum (315)
    0x65, 0x14,        //   Unit (English Rotation, Degrees)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x42,        //   Input (Data,Var,Abs,Null)
    0x65, 0x00,        //   Unit (None)

    // Face buttons in the high nibble of byte 8.
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (1)
    0x29, 0x04,        //   Usage Maximum (4)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x04,        //   Report Count (4)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Shoulder/menu/stick/PS/touchpad bits in bytes 9 and 10.
    0x19, 0x05,        //   Usage Minimum (5)
    0x29, 0x14,        //   Usage Maximum (20)
    0x95, 0x10,        //   Report Count (16)
    0x75, 0x01,        //   Report Size (1)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Remaining bytes: buttons3, packet sequence, inert sensors, timestamp.
    0x06, 0x00, 0xFF,  //   Usage Page (Vendor Defined 0xFF00)
    0x09, 0x21,        //   Usage (0x21)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x95, 0x35,        //   Report Count (53)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Output report 2: SDL/Apple effects. We parse rumble bytes and ignore LED.
    0x85, 0x02,        //   Report ID (2)
    0x09, 0x22,        //   Usage (0x22)
    0x95, 0x2F,        //   Report Count (47)
    0x75, 0x08,        //   Report Size (8)
    0x91, 0x02,        //   Output (Data,Var,Abs)

    // Feature reports used by common DualSense probing paths.
    0x85, 0x09,        //   Report ID (9)
    0x09, 0x23,        //   Usage (0x23)
    0x95, 0x3F,        //   Report Count (63)
    0x75, 0x08,        //   Report Size (8)
    0xB1, 0x02,        //   Feature (Data,Var,Abs)

    0x85, 0x20,        //   Report ID (32)
    0x09, 0x24,        //   Usage (0x24)
    0x95, 0x3F,        //   Report Count (63)
    0x75, 0x08,        //   Report Size (8)
    0xB1, 0x02,        //   Feature (Data,Var,Abs)

    0xC0               // End Collection
};

// ---------------------------------------------------------------------------
// Mouse HID descriptor: mouse (ID 2)
// ---------------------------------------------------------------------------
const uint8_t VirtualMouseDescriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x02,        //   Report ID (2)
    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)

    // Mouse Buttons (5)
    0x05, 0x09,        //     Usage Page (Button)
    0x19, 0x01,        //     Usage Minimum (1)
    0x29, 0x05,        //     Usage Maximum (5)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x95, 0x05,        //     Report Count (5)
    0x75, 0x01,        //     Report Size (1)
    0x81, 0x02,        //     Input (Data,Var,Abs)

    // Padding (3 bits)
    0x95, 0x01,        //     Report Count (1)
    0x75, 0x03,        //     Report Size (3)
    0x81, 0x03,        //     Input (Const,Var,Abs)

    // Mouse X/Y (16-bit relative)
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x09, 0x31,        //     Usage (Y)
    0x16, 0x00, 0x80,  //     Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
    0x95, 0x02,        //     Report Count (2)
    0x75, 0x10,        //     Report Size (16)
    0x81, 0x06,        //     Input (Data,Var,Rel)

    // Mouse Wheel
    0x09, 0x38,        //     Usage (Wheel)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x95, 0x01,        //     Report Count (1)
    0x75, 0x08,        //     Report Size (8)
    0x81, 0x06,        //     Input (Data,Var,Rel)

    0xC0,              //   End Collection
    0xC0               // End Collection
};

static bool HasButton(uint32_t buttons, uint32_t mask) {
    return (buttons & mask) != 0;
}

static uint8_t DualSenseAxisByte(int16_t value) {
    int32_t scaled = static_cast<int32_t>(value) + 32768;
    if (scaled < 0) {
        scaled = 0;
    } else if (scaled > 65535) {
        scaled = 65535;
    }
    return static_cast<uint8_t>(scaled >> 8);
}

static uint8_t DualSenseHat(uint32_t buttons) {
    const bool up    = HasButton(buttons, kJoyConButtonDpadUp);
    const bool down  = HasButton(buttons, kJoyConButtonDpadDown);
    const bool left  = HasButton(buttons, kJoyConButtonDpadLeft);
    const bool right = HasButton(buttons, kJoyConButtonDpadRight);

    if ((up && down) || (left && right)) {
        return kDualSenseNeutralHat;
    }
    if (up && right) {
        return 1;
    }
    if (right && down) {
        return 3;
    }
    if (down && left) {
        return 5;
    }
    if (left && up) {
        return 7;
    }
    if (up) {
        return 0;
    }
    if (right) {
        return 2;
    }
    if (down) {
        return 4;
    }
    if (left) {
        return 6;
    }
    return kDualSenseNeutralHat;
}

static kern_return_t CopyBytesToDescriptor(IOMemoryDescriptor * report,
                                           const void * bytes,
                                           size_t byteCount) {
    if (!report || !bytes) {
        return kIOReturnBadArgument;
    }

    uint64_t descriptorLength = 0;
    kern_return_t ret = report->GetLength(&descriptorLength);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    if (descriptorLength == 0) {
        return kIOReturnNoMemory;
    }

    uint64_t copyLength = byteCount;
    if (copyLength > descriptorLength) {
        copyLength = descriptorLength;
    }

    IOMemoryMap * map = nullptr;
    ret = report->CreateMapping(kIOMemoryMapCacheModeDefault, 0, 0, copyLength, 0, &map);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    if (!map || map->GetAddress() == 0 || map->GetLength() < copyLength) {
        if (map) {
            map->release();
        }
        return kIOReturnNoMemory;
    }

    memcpy((void *)map->GetAddress(), bytes, copyLength);
    map->release();
    return kIOReturnSuccess;
}

static kern_return_t CopyBytesFromDescriptor(IOMemoryDescriptor * report,
                                             void * bytes,
                                             size_t byteCapacity,
                                             size_t * copiedCount) {
    if (!report || !bytes || !copiedCount) {
        return kIOReturnBadArgument;
    }

    *copiedCount = 0;

    uint64_t descriptorLength = 0;
    kern_return_t ret = report->GetLength(&descriptorLength);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    if (descriptorLength == 0) {
        return kIOReturnBadArgument;
    }

    uint64_t copyLength = byteCapacity;
    if (copyLength > descriptorLength) {
        copyLength = descriptorLength;
    }

    IOMemoryMap * map = nullptr;
    ret = report->CreateMapping(kIOMemoryMapCacheModeDefault, 0, 0, copyLength, 0, &map);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    if (!map || map->GetAddress() == 0 || map->GetLength() < copyLength) {
        if (map) {
            map->release();
        }
        return kIOReturnNoMemory;
    }

    memcpy(bytes, (const void *)map->GetAddress(), copyLength);
    *copiedCount = static_cast<size_t>(copyLength);
    map->release();
    return kIOReturnSuccess;
}

// ===========================================================================
// VirtualJoyConDriver — root service matching on IOUserResources
// ===========================================================================

bool VirtualJoyConDriver::init() {
    return super::init();
}

void VirtualJoyConDriver::free() {
    super::free();
}

kern_return_t VirtualJoyConDriver::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Start enter");

    // SUPERDISPATCH bypasses the IIG RPC table so the call resolves to the
    // actual base-class Start instead of looping back through our own
    // override. Without it we got EXC_BAD_ACCESS / SIGBUS from stack
    // overflow — the dext crashed before RegisterService ran. Karabiner's
    // IMPL(...) macro expands to the same SUPERDISPATCH pattern.
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::super::Start failed 0x%x", ret);
        return ret;
    }

    ret = RegisterService();
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::RegisterService returned 0x%x", ret);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Start success, waiting for UserClient");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConDriver::Stop_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Stop");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t VirtualJoyConDriver::NewUserClient_Impl(uint32_t type, IOUserClient ** userClient) {
    if (!userClient) {
        return kIOReturnBadArgument;
    }

    // The Info.plist defines a UserClientProperties child personality with
    // IOUserClass=VirtualJoyConUserClient; Create() looks that up and
    // instantiates the right class on our behalf.
    IOService * service = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &service);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Create UserClient failed 0x%x", ret);
        return ret;
    }

    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, service);
    if (!client) {
        if (service) {
            service->release();
        }
        return kIOReturnUnsupported;
    }

    client->setInitialSDLOnlyMode(type == kVirtualJoyConUserClientSDLOnly);
    *userClient = client;
    return kIOReturnSuccess;
}

// ===========================================================================
// VirtualJoyConGamepadDevice — the gamepad HID device published to the system
// ===========================================================================

bool VirtualJoyConGamepadDevice::init() {
    return super::init();
}

void VirtualJoyConGamepadDevice::free() {
    super::free();
}

kern_return_t VirtualJoyConGamepadDevice::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConGamepadDevice::Start");

    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConGamepadDevice::super::Start failed 0x%x", ret);
        return ret;
    }

    // Publish as an HID device. AppleUserHIDDevice (the kernel half) calls
    // into our newDeviceDescription() / newReportDescriptor() from here, so
    // by the time RegisterService returns we have a live /dev/input entry.
    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConGamepadDevice::RegisterService failed 0x%x", ret);
        return ret;
    }

    os_log(OS_LOG_DEFAULT, "VirtualJoyConGamepadDevice ready");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConGamepadDevice::Stop_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConGamepadDevice::Stop");
    return Stop(provider, SUPERDISPATCH);
}

OSData * VirtualJoyConGamepadDevice::newReportDescriptor() {
    return OSData::withBytes(VirtualGamepadDescriptor, sizeof(VirtualGamepadDescriptor));
}

OSDictionary * VirtualJoyConGamepadDevice::newDeviceDescription() {
    OSDictionary * description = OSDictionary::withCapacity(10);
    if (!description) {
        return nullptr;
    }

    OSNumber * vendor       = OSNumber::withNumber(static_cast<uint32_t>(0x057E), 32); // Nintendo
    OSNumber * product      = OSNumber::withNumber(static_cast<uint32_t>(0x2066), 32); // Joy-Con 2 pair (custom)
    OSNumber * version      = OSNumber::withNumber(static_cast<uint32_t>(1), 32);
    OSNumber * location     = OSNumber::withNumber(kVirtualLocationGamepad, 32);
    OSString * transport    = OSString::withCString("Virtual");
    OSString * manufacturer = OSString::withCString("JoyCon2Mac");
    OSString * productName  = OSString::withCString("Joy-Con 2 Gamepad (Virtual)");
    OSString * serial       = OSString::withCString("JoyCon2Mac-Gamepad-01");

    if (vendor)       { description->setObject(kIOHIDVendorIDKey,       vendor);       vendor->release(); }
    if (product)      { description->setObject(kIOHIDProductIDKey,      product);      product->release(); }
    if (version)      { description->setObject(kIOHIDVersionNumberKey,  version);      version->release(); }
    if (location)     { description->setObject(kIOHIDLocationIDKey,     location);     location->release(); }
    if (transport)    { description->setObject(kIOHIDTransportKey,      transport);    transport->release(); }
    if (manufacturer) { description->setObject(kIOHIDManufacturerKey,   manufacturer); manufacturer->release(); }
    if (productName)  { description->setObject(kIOHIDProductKey,        productName);  productName->release(); }
    if (serial)       { description->setObject(kIOHIDSerialNumberKey,   serial);       serial->release(); }

    return description;
}

kern_return_t VirtualJoyConGamepadDevice::setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

kern_return_t VirtualJoyConGamepadDevice::getReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

kern_return_t VirtualJoyConGamepadDevice::dispatchGamepadReport(JoyConReportData reportData) {
    JoyConHIDGamepadReport report = {};
    report.reportId = 1;
    report.buttons  = reportData.buttons & 0x3FFFF; // 18 bits max
    report.padding  = 0;
    report.x        = reportData.stickLX;
    report.y        = reportData.stickLY;
    report.z        = reportData.stickRX;
    report.rx       = reportData.stickRY;
    report.ry       = reportData.triggerL;
    report.rz       = reportData.triggerR;

    IOBufferMemoryDescriptor * md = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(report), 0, &md);
    if (ret == kIOReturnSuccess && md != nullptr) {
        IOAddressSegment range = {};
        if (md->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 && range.length >= sizeof(report)) {
            memcpy((void *)range.address, &report, sizeof(report));
            md->SetLength(sizeof(report));
            ret = handleReport(0, md, sizeof(report), kIOHIDReportTypeInput, 0);
        }
        md->release();
    }
    return ret;
}

kern_return_t VirtualJoyConGamepadDevice::dispatchNFCReport(JoyConNFCReportData reportData) {
    JoyConHIDNFCReport report = {};
    report.reportId = 3;
    report.status   = reportData.status;
    memcpy(report.tagId,   reportData.tagId,   7);
    memcpy(report.payload, reportData.payload, 32);

    IOBufferMemoryDescriptor * md = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(report), 0, &md);
    if (ret == kIOReturnSuccess && md != nullptr) {
        IOAddressSegment range = {};
        if (md->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 && range.length >= sizeof(report)) {
            memcpy((void *)range.address, &report, sizeof(report));
            md->SetLength(sizeof(report));
            ret = handleReport(0, md, sizeof(report), kIOHIDReportTypeInput, 0);
        }
        md->release();
    }
    return ret;
}

// ===========================================================================
// VirtualJoyConDualSenseDevice — Sony-shaped gamepad for SDL/GameController
// ===========================================================================

bool VirtualJoyConDualSenseDevice::init() {
    return super::init();
}

void VirtualJoyConDualSenseDevice::free() {
    super::free();
}

kern_return_t VirtualJoyConDualSenseDevice::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDualSenseDevice::Start");

    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDualSenseDevice::super::Start failed 0x%x", ret);
        return ret;
    }

    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDualSenseDevice::RegisterService failed 0x%x", ret);
        return ret;
    }

    os_log(OS_LOG_DEFAULT, "VirtualJoyConDualSenseDevice ready");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConDualSenseDevice::Stop_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDualSenseDevice::Stop");
    return Stop(provider, SUPERDISPATCH);
}

OSData * VirtualJoyConDualSenseDevice::newReportDescriptor() {
    return OSData::withBytes(VirtualDualSenseDescriptor, sizeof(VirtualDualSenseDescriptor));
}

OSDictionary * VirtualJoyConDualSenseDevice::newDeviceDescription() {
    OSDictionary * description = OSDictionary::withCapacity(10);
    if (!description) {
        return nullptr;
    }

    OSNumber * vendor       = OSNumber::withNumber(static_cast<uint32_t>(0x054C), 32); // Sony
    OSNumber * product      = OSNumber::withNumber(static_cast<uint32_t>(0x0CE6), 32); // DualSense
    OSNumber * version      = OSNumber::withNumber(static_cast<uint32_t>(0x0100), 32);
    OSNumber * location     = OSNumber::withNumber(kVirtualLocationDualSense, 32);
    OSString * transport    = OSString::withCString("USB");
    OSString * manufacturer = OSString::withCString("Sony Interactive Entertainment");
    OSString * productName  = OSString::withCString("DualSense Wireless Controller");
    OSString * serial       = OSString::withCString("66:55:44:33:22:11");

    if (vendor)       { description->setObject(kIOHIDVendorIDKey,       vendor);       vendor->release(); }
    if (product)      { description->setObject(kIOHIDProductIDKey,      product);      product->release(); }
    if (version)      { description->setObject(kIOHIDVersionNumberKey,  version);      version->release(); }
    if (location)     { description->setObject(kIOHIDLocationIDKey,     location);     location->release(); }
    if (transport)    { description->setObject(kIOHIDTransportKey,      transport);    transport->release(); }
    if (manufacturer) { description->setObject(kIOHIDManufacturerKey,   manufacturer); manufacturer->release(); }
    if (productName)  { description->setObject(kIOHIDProductKey,        productName);  productName->release(); }
    if (serial)       { description->setObject(kIOHIDSerialNumberKey,   serial);       serial->release(); }

    return description;
}

kern_return_t VirtualJoyConDualSenseDevice::setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    (void)completionTimeout;
    (void)action;

    if (reportType != kIOHIDReportTypeOutput) {
        return kIOReturnUnsupported;
    }

    uint8_t data[64] = {};
    size_t dataLength = 0;
    kern_return_t ret = CopyBytesFromDescriptor(report, data, sizeof(data), &dataLength);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    size_t effectsOffset = 0;
    uint8_t reportId = static_cast<uint8_t>(options & 0xFF);
    if (dataLength > 0 && data[0] == kDualSenseOutputReportId) {
        reportId = data[0];
        effectsOffset = 1;
    } else if (reportId == 0) {
        reportId = kDualSenseOutputReportId;
    }

    if (reportId != kDualSenseOutputReportId) {
        return kIOReturnSuccess;
    }

    if (dataLength < effectsOffset + 4) {
        return kIOReturnBadArgument;
    }

    const uint8_t highFrequency = data[effectsOffset + 2];
    const uint8_t lowFrequency  = data[effectsOffset + 3];
    PublishRumbleReport(lowFrequency, highFrequency, false);
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConDualSenseDevice::getReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    (void)completionTimeout;
    (void)action;

    if (reportType != kIOHIDReportTypeFeature) {
        return kIOReturnUnsupported;
    }

    uint8_t feature[64] = {};
    uint8_t reportId = static_cast<uint8_t>(options & 0xFF);
    if (reportId == 0) {
        reportId = kDualSenseSerialFeatureReportId;
    }

    feature[0] = reportId;
    if (reportId == kDualSenseSerialFeatureReportId) {
        feature[1] = 0x11;
        feature[2] = 0x22;
        feature[3] = 0x33;
        feature[4] = 0x44;
        feature[5] = 0x55;
        feature[6] = 0x66;
    } else if (reportId == kDualSenseFirmwareFeatureReportId) {
        feature[44] = 0x24;
        feature[45] = 0x02;
    }

    return CopyBytesToDescriptor(report, feature, sizeof(feature));
}

kern_return_t VirtualJoyConDualSenseDevice::dispatchDualSenseReport(JoyConReportData reportData) {
    static uint8_t reportCounter = 0;
    static uint32_t packetSequence = 0;

    const uint32_t buttons = reportData.buttons;

    DualSenseUSBInputReport report = {};
    report.reportId      = kDualSenseInputReportId;
    report.leftX         = DualSenseAxisByte(reportData.stickLX);
    report.leftY         = DualSenseAxisByte(reportData.stickLY);
    report.rightX        = DualSenseAxisByte(reportData.stickRX);
    report.rightY        = DualSenseAxisByte(reportData.stickRY);
    report.leftTrigger   = HasButton(buttons, kJoyConButtonL2Digital) ? 0xFF : 0x00;
    report.rightTrigger  = HasButton(buttons, kJoyConButtonR2Digital) ? 0xFF : 0x00;
    report.counter       = reportCounter++;
    report.buttonsHat0   = DualSenseHat(buttons);

    if (HasButton(buttons, kJoyConButtonWest)) {
        report.buttonsHat0 |= 0x10; // Square
    }
    if (HasButton(buttons, kJoyConButtonSouth)) {
        report.buttonsHat0 |= 0x20; // Cross
    }
    if (HasButton(buttons, kJoyConButtonEast)) {
        report.buttonsHat0 |= 0x40; // Circle
    }
    if (HasButton(buttons, kJoyConButtonNorth)) {
        report.buttonsHat0 |= 0x80; // Triangle
    }

    if (HasButton(buttons, kJoyConButtonL1)) {
        report.buttons1 |= 0x01;
    }
    if (HasButton(buttons, kJoyConButtonR1)) {
        report.buttons1 |= 0x02;
    }
    if (HasButton(buttons, kJoyConButtonL2Digital)) {
        report.buttons1 |= 0x04;
    }
    if (HasButton(buttons, kJoyConButtonR2Digital)) {
        report.buttons1 |= 0x08;
    }
    if (HasButton(buttons, kJoyConButtonBack)) {
        report.buttons1 |= 0x10;
    }
    if (HasButton(buttons, kJoyConButtonStart)) {
        report.buttons1 |= 0x20;
    }
    if (HasButton(buttons, kJoyConButtonL3)) {
        report.buttons1 |= 0x40;
    }
    if (HasButton(buttons, kJoyConButtonR3)) {
        report.buttons1 |= 0x80;
    }

    if (HasButton(buttons, kJoyConButtonGuide)) {
        report.buttons2 |= 0x01;
    }
    if (HasButton(buttons, kJoyConButtonCapture)) {
        report.buttons2 |= 0x02;
    }

    memcpy(report.packetSequence, &packetSequence, sizeof(report.packetSequence));
    packetSequence++;

    IOBufferMemoryDescriptor * md = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(report), 0, &md);
    if (ret == kIOReturnSuccess && md != nullptr) {
        IOAddressSegment range = {};
        if (md->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 && range.length >= sizeof(report)) {
            memcpy((void *)range.address, &report, sizeof(report));
            md->SetLength(sizeof(report));
            ret = handleReport(0, md, sizeof(report), kIOHIDReportTypeInput, 0);
        }
        md->release();
    }
    return ret;
}

// ===========================================================================
// VirtualJoyConMouseDevice — the mouse HID device published to the system
// ===========================================================================

bool VirtualJoyConMouseDevice::init() {
    return super::init();
}

void VirtualJoyConMouseDevice::free() {
    super::free();
}

kern_return_t VirtualJoyConMouseDevice::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConMouseDevice::Start");

    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConMouseDevice::super::Start failed 0x%x", ret);
        return ret;
    }

    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConMouseDevice::RegisterService failed 0x%x", ret);
        return ret;
    }

    os_log(OS_LOG_DEFAULT, "VirtualJoyConMouseDevice ready");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConMouseDevice::Stop_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConMouseDevice::Stop");
    return Stop(provider, SUPERDISPATCH);
}

OSData * VirtualJoyConMouseDevice::newReportDescriptor() {
    return OSData::withBytes(VirtualMouseDescriptor, sizeof(VirtualMouseDescriptor));
}

OSDictionary * VirtualJoyConMouseDevice::newDeviceDescription() {
    OSDictionary * description = OSDictionary::withCapacity(10);
    if (!description) {
        return nullptr;
    }

    OSNumber * vendor       = OSNumber::withNumber(static_cast<uint32_t>(0x057E), 32);
    OSNumber * product      = OSNumber::withNumber(static_cast<uint32_t>(0x2067), 32);
    OSNumber * version      = OSNumber::withNumber(static_cast<uint32_t>(1), 32);
    OSNumber * location     = OSNumber::withNumber(kVirtualLocationMouse, 32);
    OSString * transport    = OSString::withCString("Bluetooth");
    OSString * manufacturer = OSString::withCString("JoyCon2Mac");
    OSString * productName  = OSString::withCString("JoyCon2Mac Bluetooth Mouse");
    OSString * serial       = OSString::withCString("JoyCon2Mac-Mouse-01");

    if (vendor)       { description->setObject(kIOHIDVendorIDKey,       vendor);       vendor->release(); }
    if (product)      { description->setObject(kIOHIDProductIDKey,      product);      product->release(); }
    if (version)      { description->setObject(kIOHIDVersionNumberKey,  version);      version->release(); }
    if (location)     { description->setObject(kIOHIDLocationIDKey,     location);     location->release(); }
    if (transport)    { description->setObject(kIOHIDTransportKey,      transport);    transport->release(); }
    if (manufacturer) { description->setObject(kIOHIDManufacturerKey,   manufacturer); manufacturer->release(); }
    if (productName)  { description->setObject(kIOHIDProductKey,        productName);  productName->release(); }
    if (serial)       { description->setObject(kIOHIDSerialNumberKey,   serial);       serial->release(); }

    return description;
}

kern_return_t VirtualJoyConMouseDevice::setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

kern_return_t VirtualJoyConMouseDevice::getReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

kern_return_t VirtualJoyConMouseDevice::dispatchMouseReport(JoyConMouseReportData reportData) {
    JoyConHIDMouseReport report = {};
    report.reportId = 2;
    report.buttons  = reportData.buttons;
    report.x        = reportData.deltaX;
    report.y        = reportData.deltaY;
    report.wheel    = reportData.scroll;

    IOBufferMemoryDescriptor * md = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(report), 0, &md);
    if (ret == kIOReturnSuccess && md != nullptr) {
        IOAddressSegment range = {};
        if (md->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 && range.length >= sizeof(report)) {
            memcpy((void *)range.address, &report, sizeof(report));
            md->SetLength(sizeof(report));
            ret = handleReport(0, md, sizeof(report), kIOHIDReportTypeInput, 0);
        }
        md->release();
    }
    return ret;
}

// ===========================================================================
// VirtualJoyConUserClient — bridges the daemon to the HID device
// ===========================================================================
//
// Owns the generic gamepad, DualSense, and mouse HID children while the daemon
// is connected. Keep this close to Karabiner's lifecycle: Create(), retain via
// ivars, release on user-client teardown. The split devices are important
// because Apple's GameController stack classified the old composite device as
// GCMouse only.

struct VirtualJoyConUserClient_IVars {
    VirtualJoyConGamepadDevice * gamepadDevice;
    VirtualJoyConDualSenseDevice * dualSenseDevice;
    VirtualJoyConMouseDevice * mouseDevice;
    bool sdlOnlyMode;
};

static kern_return_t ensureGamepadDevice(VirtualJoyConUserClient * self);
static kern_return_t ensureDualSenseDevice(VirtualJoyConUserClient * self);
static kern_return_t ensureMouseDevice(VirtualJoyConUserClient * self);
static kern_return_t ensureAllHIDDevices(VirtualJoyConUserClient * self);

template <typename Device>
static void terminateAndReleaseDevice(Device *& device) {
    if (!device) {
        return;
    }

    device->Terminate(0);
    device->release();
    device = nullptr;
}

static void releaseGamepadDevice(VirtualJoyConUserClient * self) {
    if (self && self->ivars && self->ivars->gamepadDevice) {
        terminateAndReleaseDevice(self->ivars->gamepadDevice);
    }
}

static void releaseDualSenseDevice(VirtualJoyConUserClient * self) {
    if (self && self->ivars && self->ivars->dualSenseDevice) {
        terminateAndReleaseDevice(self->ivars->dualSenseDevice);
    }
}

static void releaseMouseDevice(VirtualJoyConUserClient * self) {
    if (self && self->ivars && self->ivars->mouseDevice) {
        terminateAndReleaseDevice(self->ivars->mouseDevice);
    }
}

static void releaseHIDDevices(VirtualJoyConUserClient * self) {
    if (!self || !self->ivars) {
        return;
    }
    releaseGamepadDevice(self);
    releaseDualSenseDevice(self);
    releaseMouseDevice(self);
}

bool VirtualJoyConUserClient::init() {
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(VirtualJoyConUserClient_IVars, 1);
    return ivars != nullptr;
}

void VirtualJoyConUserClient::setInitialSDLOnlyMode(bool enabled) {
    if (ivars) {
        ivars->sdlOnlyMode = enabled;
    }
}

void VirtualJoyConUserClient::free() {
    releaseHIDDevices(this);
    IOSafeDeleteNULL(ivars, VirtualJoyConUserClient_IVars, 1);
    super::free();
}

kern_return_t VirtualJoyConUserClient::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConUserClient::Start");
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConUserClient::super::Start failed 0x%x", ret);
        return ret;
    }

    ret = ensureAllHIDDevices(this);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConUserClient::ensureAllHIDDevices failed 0x%x", ret);
        releaseHIDDevices(this);
        Stop(provider, SUPERDISPATCH);
        return ret;
    }
    PublishRumbleReport(0, 0, true);
    os_log(OS_LOG_DEFAULT, "VirtualJoyConUserClient::Start ready");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConUserClient::Stop_Impl(IOService * provider) {
    PublishRumbleReport(0, 0, true);
    releaseHIDDevices(this);
    return Stop(provider, SUPERDISPATCH);
}

static kern_return_t ensureGamepadDevice(VirtualJoyConUserClient * self) {
    if (!self || !self->ivars) {
        return kIOReturnBadArgument;
    }
    if (self->ivars->gamepadDevice != nullptr) {
        return kIOReturnSuccess;
    }

    IOService * created = nullptr;
    kern_return_t kr = self->Create(self, "GamepadDeviceProperties", &created);
    if (kr != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: Create(GamepadDeviceProperties) failed 0x%x", kr);
        return kr;
    }
    VirtualJoyConGamepadDevice * dev = OSDynamicCast(VirtualJoyConGamepadDevice, created);
    if (!dev) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: gamepad device class mismatch after Create");
        if (created) created->release();
        return kIOReturnUnsupported;
    }

    self->ivars->gamepadDevice = dev;
    return kIOReturnSuccess;
}

static kern_return_t ensureDualSenseDevice(VirtualJoyConUserClient * self) {
    if (!self || !self->ivars) {
        return kIOReturnBadArgument;
    }
    if (self->ivars->dualSenseDevice != nullptr) {
        return kIOReturnSuccess;
    }

    IOService * created = nullptr;
    kern_return_t kr = self->Create(self, "DualSenseDeviceProperties", &created);
    if (kr != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: Create(DualSenseDeviceProperties) failed 0x%x", kr);
        return kr;
    }
    VirtualJoyConDualSenseDevice * dev = OSDynamicCast(VirtualJoyConDualSenseDevice, created);
    if (!dev) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: DualSense device class mismatch after Create");
        if (created) created->release();
        return kIOReturnUnsupported;
    }

    self->ivars->dualSenseDevice = dev;
    return kIOReturnSuccess;
}

static kern_return_t ensureMouseDevice(VirtualJoyConUserClient * self) {
    if (!self || !self->ivars) {
        return kIOReturnBadArgument;
    }
    if (self->ivars->mouseDevice != nullptr) {
        return kIOReturnSuccess;
    }

    IOService * created = nullptr;
    kern_return_t kr = self->Create(self, "MouseDeviceProperties", &created);
    if (kr != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: Create(MouseDeviceProperties) failed 0x%x", kr);
        return kr;
    }
    VirtualJoyConMouseDevice * dev = OSDynamicCast(VirtualJoyConMouseDevice, created);
    if (!dev) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: mouse device class mismatch after Create");
        if (created) created->release();
        return kIOReturnUnsupported;
    }

    self->ivars->mouseDevice = dev;
    return kIOReturnSuccess;
}

static kern_return_t ensureAllHIDDevices(VirtualJoyConUserClient * self) {
    if (!self || !self->ivars) {
        return kIOReturnBadArgument;
    }
    if (self->ivars->sdlOnlyMode) {
        kern_return_t kr = ensureDualSenseDevice(self);
        if (kr != kIOReturnSuccess) {
            return kr;
        }
        return ensureMouseDevice(self);
    }

    kern_return_t kr = ensureGamepadDevice(self);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    kr = ensureDualSenseDevice(self);
    if (kr != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: DualSense device unavailable 0x%x", kr);
    }
    return ensureMouseDevice(self);
}

static kern_return_t PostGamepadReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }
    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }
    JoyConReportData report = {};
    memcpy(&report, bytes, sizeof(report));

    if (client->ivars && client->ivars->sdlOnlyMode) {
        kern_return_t dsCreate = ensureDualSenseDevice(client);
        if (dsCreate != kIOReturnSuccess || !client->ivars->dualSenseDevice) {
            return dsCreate == kIOReturnSuccess ? kIOReturnNotAttached : dsCreate;
        }
        return client->ivars->dualSenseDevice->dispatchDualSenseReport(report);
    }

    kern_return_t kr = ensureGamepadDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    VirtualJoyConGamepadDevice * device = client->ivars ? client->ivars->gamepadDevice : nullptr;
    if (!device) {
        return kIOReturnNotAttached;
    }

    kern_return_t primary = device->dispatchGamepadReport(report);

    kern_return_t dsCreate = ensureDualSenseDevice(client);
    if (dsCreate == kIOReturnSuccess && client->ivars && client->ivars->dualSenseDevice) {
        kern_return_t dsReport = client->ivars->dualSenseDevice->dispatchDualSenseReport(report);
        if (dsReport != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT,
                   "VirtualJoyConUserClient: DualSense report failed 0x%x", dsReport);
        }
    } else if (dsCreate != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: DualSense device missing during report 0x%x", dsCreate);
    }

    return primary;
}

static kern_return_t PostMouseReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }
    kern_return_t kr = ensureMouseDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    VirtualJoyConMouseDevice * device = client->ivars ? client->ivars->mouseDevice : nullptr;
    if (!device) {
        return kIOReturnNotAttached;
    }
    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConMouseReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }
    JoyConMouseReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return device->dispatchMouseReport(report);
}

static kern_return_t PostNFCReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }
    if (client->ivars && client->ivars->sdlOnlyMode) {
        return kIOReturnSuccess;
    }
    kern_return_t kr = ensureGamepadDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    VirtualJoyConGamepadDevice * device = client->ivars ? client->ivars->gamepadDevice : nullptr;
    if (!device) {
        return kIOReturnNotAttached;
    }
    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConNFCReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }
    JoyConNFCReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return device->dispatchNFCReport(report);
}

static kern_return_t CopyRumbleReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    (void)target;
    (void)reference;

    if (!arguments) {
        return kIOReturnBadArgument;
    }

    if (arguments->structureOutputDescriptor) {
        return CopyBytesToDescriptor(arguments->structureOutputDescriptor,
                                     &g_latestRumbleReport,
                                     sizeof(g_latestRumbleReport));
    }

    arguments->structureOutput = OSData::withBytes(&g_latestRumbleReport,
                                                   sizeof(g_latestRumbleReport));
    if (!arguments->structureOutput) {
        return kIOReturnNoMemory;
    }
    return kIOReturnSuccess;
}

static kern_return_t SetHIDMode(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    (void)reference;

    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !client->ivars || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }

    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConHIDModeData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }

    JoyConHIDModeData mode = {};
    memcpy(&mode, bytes, sizeof(mode));
    const bool sdlOnly = mode.sdlOnly != 0;
    client->ivars->sdlOnlyMode = sdlOnly;

    kern_return_t kr = ensureDualSenseDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }

    if (sdlOnly) {
        releaseGamepadDevice(client);
        kr = ensureMouseDevice(client);
        if (kr != kIOReturnSuccess) {
            return kr;
        }
        os_log(OS_LOG_DEFAULT, "VirtualJoyConUserClient: HID mode set to SDL-only");
        return kIOReturnSuccess;
    }

    kr = ensureGamepadDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    kr = ensureMouseDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    os_log(OS_LOG_DEFAULT, "VirtualJoyConUserClient: HID mode set to standard");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConUserClient::ExternalMethod(
    uint64_t selector,
    IOUserClientMethodArguments * arguments,
    const IOUserClientMethodDispatch * dispatch,
    OSObject * target,
    void * reference) {
    static const IOUserClientMethodDispatch dispatchTable[kVirtualJoyConSelectorCount] = {
        { PostGamepadReport, 0, 0, sizeof(JoyConReportData),      0, 0 },
        { PostMouseReport,   0, 0, sizeof(JoyConMouseReportData), 0, 0 },
        { PostNFCReport,     0, 0, sizeof(JoyConNFCReportData),   0, 0 },
        { CopyRumbleReport,  0, 0, 0,                             0, sizeof(JoyConRumbleReportData) },
        { SetHIDMode,        0, 0, sizeof(JoyConHIDModeData),      0, 0 },
    };

    if (selector >= kVirtualJoyConSelectorCount) {
        return kIOReturnUnsupported;
    }
    return super::ExternalMethod(selector, arguments, &dispatchTable[selector], this, nullptr);
}
