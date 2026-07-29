#import "DriverKitClient.h"
#import <IOKit/IOKitLib.h>

static BOOL servicePropertyEquals(io_service_t service, CFStringRef key, CFStringRef expected) {
    if (service == IO_OBJECT_NULL) return NO;

    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return NO;

    BOOL equals = CFGetTypeID(value) == CFStringGetTypeID() && CFEqual(value, expected);
    CFRelease(value);
    return equals;
}

static BOOL isVirtualJoyConService(io_service_t service) {
    return servicePropertyEquals(service, CFSTR("IOUserClass"), CFSTR("VirtualJoyConDriver")) &&
           servicePropertyEquals(service, CFSTR("CFBundleIdentifier"), CFSTR("local.joycon2mac.driver")) &&
           servicePropertyEquals(service, CFSTR("IOUserServerName"), CFSTR("local.joycon2mac.driver"));
}

static io_service_t copyVirtualJoyConServiceFromIterator(io_iterator_t iterator) {
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (isVirtualJoyConService(service)) {
            return service;
        }
        IOObjectRelease(service);
    }
    return IO_OBJECT_NULL;
}

static io_service_t copyVirtualJoyConService(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                       IOServiceNameMatching("VirtualJoyConDriver"));
    if (service != IO_OBJECT_NULL) {
        if (isVirtualJoyConService(service)) {
            return service;
        }
        IOObjectRelease(service);
    }

    service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                          IOServiceMatching("VirtualJoyConDriver"));
    if (service != IO_OBJECT_NULL) {
        if (isVirtualJoyConService(service)) {
            return service;
        }
        IOObjectRelease(service);
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                    IOServiceMatching("IOUserService"),
                                                    &iterator);
    if (kr != KERN_SUCCESS || iterator == IO_OBJECT_NULL) {
        return IO_OBJECT_NULL;
    }

    service = copyVirtualJoyConServiceFromIterator(iterator);
    IOObjectRelease(iterator);
    return service;
}

@interface DriverKitClient ()
@property (nonatomic, assign) io_service_t service;
@property (nonatomic, assign) io_connect_t connection;
@property (nonatomic, assign) BOOL isRunning;
@end

@implementation DriverKitClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _service = IO_OBJECT_NULL;
        _connection = IO_OBJECT_NULL;
        _isRunning = NO;
    }
    return self;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)dealloc {
    [self stop];
}
#pragma clang diagnostic pop

- (BOOL)start {
    return [self startWithSDLOnlyMode:NO];
}

- (BOOL)startWithSDLOnlyMode:(BOOL)enabled {
    if (_isRunning) return YES;

    _service = copyVirtualJoyConService();
    if (_service == IO_OBJECT_NULL) {
        NSLog(@"[DriverKitClient] ✗ VirtualJoyConDriver not found. Is the extension loaded?");
        return NO;
    }

    uint32_t type = enabled ? 1 : 0;
    kern_return_t ret = IOServiceOpen(_service, mach_task_self(), type, &_connection);
    if (ret != KERN_SUCCESS) {
        NSLog(@"[DriverKitClient] ✗ Failed to open connection: 0x%x", ret);
        IOObjectRelease(_service);
        _service = IO_OBJECT_NULL;
        return NO;
    }

    _isRunning = YES;
    NSLog(@"[DriverKitClient] ✓ Connected to VirtualJoyConDriver (SDL-only=%d)", enabled);
    return YES;
}

- (void)stop {
    if (_connection != IO_OBJECT_NULL) {
        IOServiceClose(_connection);
        _connection = IO_OBJECT_NULL;
    }
    if (_service != IO_OBJECT_NULL) {
        IOObjectRelease(_service);
        _service = IO_OBJECT_NULL;
    }
    _isRunning = NO;
}

- (void)postGamepadReport:(struct JoyConReportData)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return;
    
    size_t outputSize = 0;
    // Method selector 0 for postGamepadReport
    kern_return_t ret = IOConnectCallStructMethod(_connection, 0, &report, sizeof(report), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) NSLog(@"[DriverKitClient] Failed to post gamepad report: 0x%x", ret);
    }
}

- (void)postMouseReport:(struct JoyConMouseReportData)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return;
    
    size_t outputSize = 0;
    // Method selector 1 for postMouseReport
    kern_return_t ret = IOConnectCallStructMethod(_connection, 1, &report, sizeof(report), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) NSLog(@"[DriverKitClient] Failed to post mouse report: 0x%x", ret);
    }
}

- (void)postKeyboardReport:(struct JoyConKeyboardReportData)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return;

    size_t outputSize = 0;
    kern_return_t ret = IOConnectCallStructMethod(_connection, 5, &report, sizeof(report), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) NSLog(@"[DriverKitClient] Failed to post keyboard report: 0x%x", ret);
    }
}

- (void)postNFCReport:(struct JoyConNFCReportData)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return;
    
    size_t outputSize = 0;
    // Method selector 2 for postNFCReport
    kern_return_t ret = IOConnectCallStructMethod(_connection, 2, &report, sizeof(report), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) NSLog(@"[DriverKitClient] Failed to post NFC report: 0x%x", ret);
    }
}

- (BOOL)copyLatestRumbleReport:(struct JoyConRumbleReportData *)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL || !report) return NO;

    size_t outputSize = sizeof(*report);
    kern_return_t ret = IOConnectCallStructMethod(_connection, 3, NULL, 0, report, &outputSize);
    if (ret != KERN_SUCCESS || outputSize != sizeof(*report)) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) {
            NSLog(@"[DriverKitClient] Failed to copy rumble report: 0x%x size=%zu", ret, outputSize);
        }
        return NO;
    }
    return YES;
}

- (BOOL)setSDLOnlyMode:(BOOL)enabled {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return NO;

    struct JoyConHIDModeData mode = {};
    mode.sdlOnly = enabled ? 1 : 0;
    size_t outputSize = 0;
    kern_return_t ret = IOConnectCallStructMethod(_connection, 4, &mode, sizeof(mode), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        NSLog(@"[DriverKitClient] Failed to set SDL-only mode=%d: 0x%x", enabled, ret);
        return NO;
    }
    return YES;
}

+ (uint32_t)convertButtonsToHID:(uint32_t)leftButtons rightButtons:(uint32_t)rightButtons dpadUp:(BOOL)up dpadDown:(BOOL)down dpadLeft:(BOOL)left dpadRight:(BOOL)right {
    // Button layout follows the W3C Standard Gamepad indices so browsers
    // (Chrome gamepad API), Game Pass, SDL's generic gamepad heuristic, and
    // most engines that hit unknown HID gamepads map them correctly:
    //   [0]=A [1]=B [2]=X [3]=Y
    //   [4]=L1 [5]=R1 [6]=L2 [7]=R2
    //   [8]=Select [9]=Start
    //   [10]=L3 [11]=R3
    //   [12]=Dpad↑ [13]=Dpad↓ [14]=Dpad← [15]=Dpad→
    //   [16]=Home [17]=Capture
    //
    // Face, shoulder, stick-click bits are unchanged from the previous
    // mapping — user confirmed in-game that A/B/X/Y, L/R, ZL/ZR, L3, R3,
    // Minus, Plus all work. Only the D-pad (was hat-only and therefore
    // invisible to standard-mapping consumers) moved to [12..15], and
    // Home/Capture slid over so nothing else lost its slot. Side rails
    // (SL/SR) were dropped — only 18 button bits fit in the descriptor
    // and they weren't reported as missing.
    //
    // Masks come from joycon2cpp/testapp/src/JoyConDecoder.cpp
    // BUTTON_*_MASK_LEFT / _MASK_RIGHT. ExtractButtonState(side) already
    // produces the 24-bit state these masks are designed against.
    (void)up;
    (void)down;
    (void)left;
    (void)right;
    uint32_t hidButtons = 0;

    // Face buttons (Right Joy-Con). Bottom/top pair is manually swapped
    // relative to pure positional mapping so B (bottom) -> Triangle and
    // X (top) -> Cross, matching games that hard-code PS layout.
    if (rightButtons & 0x000400) hidButtons |= (1u << 0);     // X (top)    -> Cross / A
    if (rightButtons & 0x000800) hidButtons |= (1u << 1);     // A (right)  -> Circle / B
    if (rightButtons & 0x000100) hidButtons |= (1u << 2);     // Y (left)   -> Square / X
    if (rightButtons & 0x000200) hidButtons |= (1u << 3);     // B (bottom) -> Triangle / Y

    // Shoulders / triggers.
    if (leftButtons  & 0x000040) hidButtons |= (1u << 4);     // L   -> L1
    if (rightButtons & 0x004000) hidButtons |= (1u << 5);     // R   -> R1
    if (leftButtons  & 0x000080) hidButtons |= (1u << 6);     // ZL  -> L2 (digital)
    if (rightButtons & 0x008000) hidButtons |= (1u << 7);     // ZR  -> R2 (digital)

    // System buttons.
    if (leftButtons  & 0x000100) hidButtons |= (1u << 8);     // Minus -> Select
    if (rightButtons & 0x000002) hidButtons |= (1u << 9);     // Plus  -> Start

    // Stick clicks.
    if (leftButtons  & 0x000800) hidButtons |= (1u << 10);    // L3
    if (rightButtons & 0x000004) hidButtons |= (1u << 11);    // R3

    // D-pad as dedicated buttons so standard-mapping consumers see it.
    // Bits are taken directly from the left Joy-Con state (same values
    // the hat switch already uses), so both the hat field in the HID
    // report and these individual button bits stay consistent.
    if (up)    hidButtons |= (1u << 12);                      // Dpad Up
    if (down)  hidButtons |= (1u << 13);                      // Dpad Down
    if (left)  hidButtons |= (1u << 14);                      // Dpad Left
    if (right) hidButtons |= (1u << 15);                      // Dpad Right

    // Meta.
    if (rightButtons & 0x000010) hidButtons |= (1u << 16);    // Home
    if (leftButtons  & 0x002000) hidButtons |= (1u << 17);    // Capture

    return hidButtons;
}

@end
