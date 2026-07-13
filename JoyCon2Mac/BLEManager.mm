#import "BLEManager.h"
#import "PairingManager.h"
#include <iostream>
#include <cmath>
#include <algorithm>
#include <cstring>

static const uint16_t NINTENDO_MANUFACTURER_ID = 0x0553;
static NSString *const UUID_INPUT = @"ab7de9be-89fe-49ad-828f-118f09df7fd2";
static NSString *const UUID_COMMAND = @"649d4ac9-8eb7-4e6c-af44-1ea54fe5f005";
static NSString *const UUID_RESPONSE = @"c765a961-d9d8-4d36-a20a-5315b111836a";

typedef NS_ENUM(NSInteger, JoyConNFCPhase) {
    JoyConNFCPhaseIdle = 0,
    JoyConNFCPhaseEnteringScan,
    JoyConNFCPhaseWaitingForTag,
    JoyConNFCPhaseStartingRead,
    JoyConNFCPhaseWaitingForReadReady,
    JoyConNFCPhaseReadingBuffer,
    JoyConNFCPhaseWaitingForRemoval,
    JoyConNFCPhaseError,
};

static const NSUInteger kJoyConNFCReadPayloadLength = 622;
static const NSUInteger kJoyConNFCReadMetadataLength = 63;
static const NSUInteger kJoyConNFCRawTagLength = 540;

@interface JoyConPeripheralContext : NSObject
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, strong) CBCharacteristic *inputCharacteristic;
@property (nonatomic, strong) CBCharacteristic *commandCharacteristic;
@property (nonatomic, strong) CBCharacteristic *responseCharacteristic;
@property (nonatomic, strong) CBCharacteristic *vibrationCharacteristic;
@property (nonatomic, strong) NSTimer *responseTimer;
@property (nonatomic, strong) NSMutableArray<NSData *> *commandQueue;
@property (nonatomic, strong) NSMutableArray<NSString *> *commandLabels;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *commandWaitsForProtocolResponse;
@property (nonatomic, assign) JoyConSide side;
@property (nonatomic, assign) BOOL initStarted;
@property (nonatomic, assign) BOOL isInitialized;
@property (nonatomic, assign) BOOL waitingForResponse;
@property (nonatomic, assign) BOOL commandInFlight;
@property (nonatomic, assign) BOOL currentCommandWaitsForProtocolResponse;
@property (nonatomic, assign) BOOL sideWasInferred;
@property (nonatomic, assign) BOOL characteristicsReady;
@property (nonatomic, assign) BOOL pairingPersistenceStarted;
@property (nonatomic, assign) BOOL startupLifecycleDone;
@property (nonatomic, assign) int initStep;
@property (nonatomic, assign) uint8_t ledMask;
@property (nonatomic, assign) NSUInteger inputPacketCount;
@property (nonatomic, assign) uint8_t currentCommandID;
@property (nonatomic, assign) BOOL imuAllZeroLastSeen;
@property (nonatomic, assign) uint8_t vibrationCounter;
@property (nonatomic, assign) uint8_t lastRumbleAmplitude;
@property (nonatomic, assign) BOOL hasLastRumbleAmplitude;
@property (nonatomic, assign) BOOL nfcScanning;
@property (nonatomic, strong) NSTimer *nfcPollTimer;
@property (nonatomic, assign) uint8_t nfcOutputCounter;
@property (nonatomic, assign) NSUInteger nfcFrameCount;
@property (nonatomic, copy) NSString *lastNFCUID;
@property (nonatomic, assign) JoyConNFCPhase nfcPhase;
@property (nonatomic, strong) NSMutableData *nfcReadBuffer;
@property (nonatomic, strong) NSData *nfcTagID;
@property (nonatomic, assign) uint8_t nfcTagType;
@property (nonatomic, assign) NSUInteger nfcRequestedOffset;
@property (nonatomic, assign) NSUInteger nfcStatusPollCount;
@property (nonatomic, assign) BOOL nfcRequireRemoval;
@end

@implementation JoyConPeripheralContext
- (instancetype)init {
    self = [super init];
    if (self) {
        _commandQueue = [NSMutableArray array];
        _commandLabels = [NSMutableArray array];
        _commandWaitsForProtocolResponse = [NSMutableArray array];
        _imuAllZeroLastSeen = YES;
        _nfcPhase = JoyConNFCPhaseIdle;
        _nfcReadBuffer = [NSMutableData data];
    }
    return self;
}
@end

@interface BLEManager ()
- (void)schedulePairingPersistenceForContext:(JoyConPeripheralContext *)context delay:(NSTimeInterval)delay;
- (void)sendPairingPersistenceCommandsToContext:(JoyConPeripheralContext *)context;
@end

static uint16_t JoyConRumbleAmplitude10Bit(uint8_t amplitude) {
    if (amplitude == 0) {
        return 0;
    }
    return static_cast<uint16_t>(64 + ((static_cast<uint32_t>(amplitude) * 704 + 127) / 255));
}

static void FillJoyConVibrationMotorBlock(uint8_t *block, uint8_t counter, uint16_t amplitude) {
    if (!block || amplitude == 0) {
        return;
    }

    const uint16_t frequency0 = 512;
    const uint16_t frequency1 = 512;
    uint64_t packed = ((static_cast<uint64_t>(amplitude) & 0x3FF) << 30) |
                      ((static_cast<uint64_t>(frequency1) & 0x3FF) << 20) |
                      ((static_cast<uint64_t>(amplitude) & 0x3FF) << 10) |
                      (static_cast<uint64_t>(frequency0) & 0x3FF);

    block[0] = static_cast<uint8_t>((0x05 << 4) | (counter & 0x0F));
    for (size_t i = 0; i < 5; i++) {
        block[i + 1] = static_cast<uint8_t>((packed >> (8 * i)) & 0xFF);
    }
}

static uint8_t JoyConMcuCRC8(const uint8_t *bytes, size_t length) {
    uint8_t crc = 0;
    for (size_t i = 0; i < length; i++) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

@implementation BLEManager {
    JoyConDataCallback _dataCallback;
    JoyConStatusCallback _statusCallback;
    JoyConTelemetryCallback _telemetryCallback;
    JoyConNFCCallback _nfcCallback;
    NSMutableDictionary<NSString *, JoyConPeripheralContext *> *_contextsByPeripheralID;
    NSMutableDictionary<NSString *, NSNumber *> *_sideByPeripheralID;
    NSMutableDictionary<NSString *, NSNumber *> *_reconnectAttemptsByPeripheralID;
    NSMutableDictionary<NSString *, NSDate *> *_lastConnectionAttemptByPeripheralID;
    NSMutableDictionary<NSString *, CBPeripheral *> *_pendingPeripheralsByID;
    NSMutableDictionary<NSString *, NSString *> *_pendingNamesByID;
    NSMutableDictionary<NSString *, NSNumber *> *_pendingRSSIByID;
    NSMutableDictionary<NSString *, NSNumber *> *_pendingSideWasInferredByID;
    NSMutableSet<NSString *> *_connectingPeripheralIDs;
    NSMutableArray<NSString *> *_pendingInitializationPeripheralIDs;
    NSString *_startupOwnerPeripheralID;
    NSTimer *_findTimer;
    BOOL _findLeftActive;
    BOOL _findRightActive;
    NSUInteger _findPhase;
    BOOL _isShuttingDown;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.discoveredPeripherals = [NSMutableArray array];
        _contextsByPeripheralID = [NSMutableDictionary dictionary];
        _sideByPeripheralID = [NSMutableDictionary dictionary];
        _reconnectAttemptsByPeripheralID = [NSMutableDictionary dictionary];
        _lastConnectionAttemptByPeripheralID = [NSMutableDictionary dictionary];
        _pendingPeripheralsByID = [NSMutableDictionary dictionary];
        _pendingNamesByID = [NSMutableDictionary dictionary];
        _pendingRSSIByID = [NSMutableDictionary dictionary];
        _pendingSideWasInferredByID = [NSMutableDictionary dictionary];
        _connectingPeripheralIDs = [NSMutableSet set];
        _pendingInitializationPeripheralIDs = [NSMutableArray array];
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
    return self;
}

- (void)setDataCallback:(JoyConDataCallback)callback {
    _dataCallback = callback;
}

- (void)setStatusCallback:(JoyConStatusCallback)callback {
    _statusCallback = callback;
}

- (void)setTelemetryCallback:(JoyConTelemetryCallback)callback {
    _telemetryCallback = callback;
}

- (void)setNFCCallback:(JoyConNFCCallback)callback {
    _nfcCallback = callback;
}

- (void)emitStatus:(const char *)status message:(const char *)message forContext:(JoyConPeripheralContext *)context {
    if (_statusCallback && context) {
        const char *name = context.peripheral.name ? [context.peripheral.name UTF8String] : "";
        _statusCallback(context.side, status, message ?: "", name);
    }
}

- (void)emitStatus:(const char *)status message:(const char *)message side:(JoyConSide)side name:(NSString *)name {
    if (_statusCallback) {
        _statusCallback(side, status, message ?: "", name ? [name UTF8String] : "");
    }
}

- (NSString *)hexStringForData:(NSData *)data maxBytes:(NSUInteger)maxBytes {
    if (!data) {
        return @"";
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = MIN(data.length, maxBytes);
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 3];
    for (NSUInteger i = 0; i < length; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
        if (i + 1 < length) {
            [hex appendString:@" "];
        }
    }
    if (data.length > maxBytes) {
        [hex appendFormat:@" ... (%lu bytes)", (unsigned long)data.length];
    }
    return hex;
}

- (NSString *)propertiesStringForCharacteristic:(CBCharacteristic *)characteristic {
    if (!characteristic) {
        return @"";
    }

    NSMutableArray<NSString *> *properties = [NSMutableArray array];
    CBCharacteristicProperties flags = characteristic.properties;
    if (flags & CBCharacteristicPropertyBroadcast) [properties addObject:@"broadcast"];
    if (flags & CBCharacteristicPropertyRead) [properties addObject:@"read"];
    if (flags & CBCharacteristicPropertyWriteWithoutResponse) [properties addObject:@"writeWithoutResponse"];
    if (flags & CBCharacteristicPropertyWrite) [properties addObject:@"write"];
    if (flags & CBCharacteristicPropertyNotify) [properties addObject:@"notify"];
    if (flags & CBCharacteristicPropertyIndicate) [properties addObject:@"indicate"];
    if (flags & CBCharacteristicPropertyAuthenticatedSignedWrites) [properties addObject:@"authenticatedSignedWrites"];
    if (flags & CBCharacteristicPropertyExtendedProperties) [properties addObject:@"extended"];
    if (flags & CBCharacteristicPropertyNotifyEncryptionRequired) [properties addObject:@"notifyEncryptionRequired"];
    if (flags & CBCharacteristicPropertyIndicateEncryptionRequired) [properties addObject:@"indicateEncryptionRequired"];
    return [properties componentsJoinedByString:@"|"];
}

- (void)emitTelemetry:(const char *)phase detail:(NSString *)detail forContext:(JoyConPeripheralContext *)context {
    if (_telemetryCallback && context) {
        const char *name = context.peripheral.name ? [context.peripheral.name UTF8String] : "";
        _telemetryCallback(context.side, phase, detail ? [detail UTF8String] : "", name);
    }
}

- (void)emitTelemetry:(const char *)phase detail:(NSString *)detail side:(JoyConSide)side name:(NSString *)name {
    if (_telemetryCallback) {
        _telemetryCallback(side, phase, detail ? [detail UTF8String] : "", name ? [name UTF8String] : "");
    }
}

- (void)startScanning {
    _isShuttingDown = NO;

    if (self.centralManager.state != CBManagerStatePoweredOn) {
        std::cout << "[BLE] Bluetooth not ready. Current state: " << (int)self.centralManager.state << std::endl;
        [self emitTelemetry:"scan.deferred"
                     detail:[NSString stringWithFormat:@"centralState=%ld", (long)self.centralManager.state]
                       side:JoyConSide::Left
                       name:nil];
        return;
    }

    std::cout << "[BLE] Scanning for left and right Joy-Con 2 controllers..." << std::endl;
    [self emitTelemetry:"scan.start" detail:@"allowDuplicates=true services=nil" side:JoyConSide::Left name:nil];
    [self emitStatus:"scanning" message:"Scanning for Joy-Con 2 controllers" side:JoyConSide::Left name:nil];
    [self emitStatus:"scanning" message:"Scanning for Joy-Con 2 controllers" side:JoyConSide::Right name:nil];
    [self.centralManager scanForPeripheralsWithServices:nil options:@{
        CBCentralManagerScanOptionAllowDuplicatesKey: @YES
    }];
}

- (void)stopScanning {
    [self.centralManager stopScan];
    std::cout << "[BLE] Stopped scanning." << std::endl;
    [self emitTelemetry:"scan.stop" detail:@"central scan stopped" side:JoyConSide::Left name:nil];
}

- (void)disconnect {
    _isShuttingDown = YES;
    [self emitTelemetry:"daemon.disconnect" detail:@"disconnect requested" side:JoyConSide::Left name:nil];
    [self setFindModeLeft:NO right:NO];
    [self stopScanning];
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [context.responseTimer invalidate];
        context.responseTimer = nil;
        if (context.peripheral.state != CBPeripheralStateDisconnected) {
            [self.centralManager cancelPeripheralConnection:context.peripheral];
        }
    }
    [_connectingPeripheralIDs removeAllObjects];
    [_pendingPeripheralsByID removeAllObjects];
    [_pendingNamesByID removeAllObjects];
    [_pendingRSSIByID removeAllObjects];
    [_pendingSideWasInferredByID removeAllObjects];
    [_pendingInitializationPeripheralIDs removeAllObjects];
    _startupOwnerPeripheralID = nil;
}

- (NSString *)keyForPeripheral:(CBPeripheral *)peripheral {
    return peripheral.identifier.UUIDString;
}

- (NSString *)labelForSide:(JoyConSide)side {
    return side == JoyConSide::Right ? @"Right" : @"Left";
}

- (BOOL)isNintendoAdvertisement:(NSDictionary<NSString *,id> *)advertisementData
                      peripheral:(CBPeripheral *)peripheral {
    NSString *deviceName = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"";
    NSString *lowerName = [deviceName lowercaseString];
    if ([lowerName containsString:@"nintendo"] ||
        [lowerName containsString:@"joy-con"] ||
        [lowerName containsString:@"joy con"] ||
        [lowerName containsString:@"joycon"] ||
        [lowerName containsString:@"switch"] ||
        [lowerName containsString:@"pro controller"]) {
        return YES;
    }

    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if (!manufacturerData || manufacturerData.length < 2) {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)manufacturerData.bytes;
    uint16_t companyID = bytes[0] | (bytes[1] << 8);
    if (companyID == NINTENDO_MANUFACTURER_ID) {
        return YES;
    }

    // Switch2-Controllers matches the Switch 2 controller payload marker
    // 03 7E inside the manufacturer payload, independent of the BLE company key.
    if (manufacturerData.length >= 4 && bytes[2] == 0x03 && bytes[3] == 0x7E) {
        return YES;
    }
    if (manufacturerData.length >= 6 && bytes[4] == 0x03 && bytes[5] == 0x7E) {
        return YES;
    }

    return NO;
}

- (JoyConSide)sideForPeripheralName:(NSString *)name {
    NSString *lowerName = [[name ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([lowerName containsString:@"right"] ||
        [lowerName containsString:@"joy-con (r"] ||
        [lowerName containsString:@"joy-con 2 (r"] ||
        [lowerName containsString:@"(r)"] ||
        [lowerName hasSuffix:@" r"] ||
        [lowerName hasSuffix:@"-r"]) {
        return JoyConSide::Right;
    }
    return JoyConSide::Left;
}

- (NSNumber *)explicitSideForPeripheralName:(NSString *)name {
    NSString *lowerName = [[name ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([lowerName containsString:@"right"] ||
        [lowerName containsString:@"joy-con (r"] ||
        [lowerName containsString:@"joy-con 2 (r"] ||
        [lowerName containsString:@"(r)"] ||
        [lowerName hasSuffix:@" r"] ||
        [lowerName hasSuffix:@"-r"]) {
        return @((NSInteger)JoyConSide::Right);
    }
    if ([lowerName containsString:@"left"] ||
        [lowerName containsString:@"joy-con (l"] ||
        [lowerName containsString:@"joy-con 2 (l"] ||
        [lowerName containsString:@"(l)"] ||
        [lowerName hasSuffix:@" l"] ||
        [lowerName hasSuffix:@"-l"]) {
        return @((NSInteger)JoyConSide::Left);
    }
    return nil;
}

- (JoyConSide)missingOrDefaultSide {
    if (![self hasContextForSide:JoyConSide::Left] && ![self hasPendingConnectionForSide:JoyConSide::Left]) {
        return JoyConSide::Left;
    }
    return JoyConSide::Right;
}

- (BOOL)hasContextForSide:(JoyConSide)side {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if (context.side == side &&
            context.peripheral.state != CBPeripheralStateDisconnected) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasPendingConnectionForSide:(JoyConSide)side {
    for (NSString *peripheralID in _connectingPeripheralIDs) {
        NSNumber *sideValue = _sideByPeripheralID[peripheralID];
        if (sideValue && (JoyConSide)sideValue.integerValue == side) {
            return YES;
        }
    }
    for (NSString *peripheralID in _pendingPeripheralsByID.allKeys) {
        NSNumber *sideValue = _sideByPeripheralID[peripheralID];
        if (sideValue && (JoyConSide)sideValue.integerValue == side) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasBothSides {
    return [self hasContextForSide:JoyConSide::Left] && [self hasContextForSide:JoyConSide::Right];
}

- (NSUInteger)activeOrPendingConnectionCount {
    NSUInteger count = _connectingPeripheralIDs.count;
    count += _pendingPeripheralsByID.count;
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if (context.peripheral.state != CBPeripheralStateDisconnected) {
            count++;
        }
    }
    return count;
}

- (void)beginConnectionToPeripheral:(CBPeripheral *)peripheral
                               side:(JoyConSide)side
                               name:(NSString *)deviceName
                               RSSI:(NSNumber *)RSSI
                    sideWasInferred:(BOOL)sideWasInferred {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    NSNumber *attemptValue = _reconnectAttemptsByPeripheralID[peripheralID] ?: @0;

    _sideByPeripheralID[peripheralID] = @((NSInteger)side);
    _lastConnectionAttemptByPeripheralID[peripheralID] = [NSDate date];
    _reconnectAttemptsByPeripheralID[peripheralID] = @(attemptValue.integerValue + 1);
    [_connectingPeripheralIDs addObject:peripheralID];

    std::cout << "[BLE] Connecting to " << [[self labelForSide:side] UTF8String]
              << " Joy-Con: " << [deviceName UTF8String]
              << (sideWasInferred ? " (side inferred)" : "")
              << " [RSSI: " << [RSSI intValue] << " dBm]" << std::endl;
    [self emitTelemetry:"connect.begin"
                 detail:[NSString stringWithFormat:@"name=%@ rssi=%@ sideInferred=%@ attempt=%ld",
                         deviceName, RSSI, sideWasInferred ? @"true" : @"false", (long)attemptValue.integerValue + 1]
                   side:side
                   name:deviceName];
    [self emitStatus:"connecting" message:"BLE peripheral found" side:side name:deviceName];
    [self.centralManager connectPeripheral:peripheral options:nil];
}

- (void)connectNextPendingPeripheralIfPossible {
    NSUInteger activeCount = 0;
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if (context.peripheral.state != CBPeripheralStateDisconnected) {
            activeCount++;
        }
    }
    if (_connectingPeripheralIDs.count > 0 || activeCount >= 2) {
        return;
    }

    for (NSString *peripheralID in _pendingPeripheralsByID.allKeys) {
        CBPeripheral *peripheral = _pendingPeripheralsByID[peripheralID];
        NSNumber *sideValue = _sideByPeripheralID[peripheralID];
        if (!peripheral || !sideValue) {
            [_pendingPeripheralsByID removeObjectForKey:peripheralID];
            [_pendingNamesByID removeObjectForKey:peripheralID];
            [_pendingRSSIByID removeObjectForKey:peripheralID];
            [_pendingSideWasInferredByID removeObjectForKey:peripheralID];
            continue;
        }

        JoyConSide side = (JoyConSide)sideValue.integerValue;
        if ([self hasContextForSide:side]) {
            [_pendingPeripheralsByID removeObjectForKey:peripheralID];
            [_pendingNamesByID removeObjectForKey:peripheralID];
            [_pendingRSSIByID removeObjectForKey:peripheralID];
            [_pendingSideWasInferredByID removeObjectForKey:peripheralID];
            continue;
        }

        NSString *deviceName = _pendingNamesByID[peripheralID] ?: peripheral.name ?: @"Unknown";
        NSNumber *RSSI = _pendingRSSIByID[peripheralID] ?: @0;
        BOOL sideWasInferred = _pendingSideWasInferredByID[peripheralID].boolValue;

        [_pendingPeripheralsByID removeObjectForKey:peripheralID];
        [_pendingNamesByID removeObjectForKey:peripheralID];
        [_pendingRSSIByID removeObjectForKey:peripheralID];
        [_pendingSideWasInferredByID removeObjectForKey:peripheralID];

        [self beginConnectionToPeripheral:peripheral
                                     side:side
                                     name:deviceName
                                     RSSI:RSSI
                          sideWasInferred:sideWasInferred];
        return;
    }
}

- (JoyConPeripheralContext *)contextForPeripheral:(CBPeripheral *)peripheral {
    return _contextsByPeripheralID[[self keyForPeripheral:peripheral]];
}

- (NSString *)keyForContext:(JoyConPeripheralContext *)context {
    if (!context || !context.peripheral) {
        return nil;
    }
    return [self keyForPeripheral:context.peripheral];
}

- (JoyConPeripheralContext *)contextForSide:(JoyConSide)side {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if (context.side == side &&
            context.peripheral.state == CBPeripheralStateConnected &&
            context.commandCharacteristic) {
            return context;
        }
    }
    return nil;
}

- (NSString *)compactHexForBytes:(const uint8_t *)bytes length:(NSUInteger)length {
    if (!bytes || length == 0) {
        return @"";
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (NSUInteger i = 0; i < length; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
    }
    return hex;
}

- (NSString *)compactHexForVector:(const std::vector<uint8_t>&)bytes {
    return [self compactHexForBytes:bytes.data() length:bytes.size()];
}

- (void)queueInitializationForContext:(JoyConPeripheralContext *)context reason:(NSString *)reason {
    NSString *peripheralID = [self keyForContext:context];
    if (!peripheralID) {
        return;
    }
    if (![_pendingInitializationPeripheralIDs containsObject:peripheralID]) {
        [_pendingInitializationPeripheralIDs addObject:peripheralID];
    }
    [self emitTelemetry:"init.queued"
                 detail:reason ?: @"another startup sequence is active"
             forContext:context];
    [self emitStatus:"queued" message:"Waiting for other Joy-Con startup commands" forContext:context];
}

- (void)startNextQueuedInitializationIfPossible {
    if (_startupOwnerPeripheralID != nil) {
        return;
    }

    while (_pendingInitializationPeripheralIDs.count > 0) {
        NSString *peripheralID = _pendingInitializationPeripheralIDs.firstObject;
        [_pendingInitializationPeripheralIDs removeObjectAtIndex:0];

        JoyConPeripheralContext *context = _contextsByPeripheralID[peripheralID];
        if (!context ||
            context.peripheral.state != CBPeripheralStateConnected ||
            !context.characteristicsReady ||
            context.initStarted ||
            context.isInitialized) {
            continue;
        }

        [self initializeIMUForContext:context];
        return;
    }
}

- (void)releaseStartupSlotForContext:(JoyConPeripheralContext *)context {
    NSString *peripheralID = [self keyForContext:context];
    if (!peripheralID || ![_startupOwnerPeripheralID isEqualToString:peripheralID]) {
        return;
    }

    _startupOwnerPeripheralID = nil;
    [self emitTelemetry:"init.slotReleased"
                 detail:@"startup command slot released"
             forContext:context];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self connectNextPendingPeripheralIfPossible];
        [self startNextQueuedInitializationIfPossible];
    });
}

- (void)schedulePairingPersistenceForContext:(JoyConPeripheralContext *)context delay:(NSTimeInterval)delay {
    NSString *peripheralID = [[self keyForContext:context] copy];
    if (!peripheralID || context.pairingPersistenceStarted) {
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JoyConPeripheralContext *liveContext = self->_contextsByPeripheralID[peripheralID];
        if (!liveContext ||
            liveContext.pairingPersistenceStarted ||
            !liveContext.isInitialized ||
            liveContext.peripheral.state != CBPeripheralStateConnected) {
            return;
        }

        if (self->_startupOwnerPeripheralID != nil ||
            liveContext.commandInFlight ||
            liveContext.commandQueue.count > 0) {
            [self emitTelemetry:"pairing.defer"
                         detail:@"waiting for startup/command queue to go idle"
                     forContext:liveContext];
            [self schedulePairingPersistenceForContext:liveContext delay:1.0];
            return;
        }

        [self sendPairingPersistenceCommandsToContext:liveContext];
    });
}

- (JoyConPeripheralContext *)contextForCharacteristic:(CBCharacteristic *)characteristic peripheral:(CBPeripheral *)peripheral {
    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    if (!context) {
        return nil;
    }
    if ([characteristic isEqual:context.inputCharacteristic] ||
        [characteristic isEqual:context.responseCharacteristic] ||
        [characteristic isEqual:context.commandCharacteristic] ||
        [characteristic isEqual:context.vibrationCharacteristic]) {
        return context;
    }
    return nil;
}

#pragma mark - Command Sending

- (void)sendCommand:(NSData *)commandData {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self enqueueCommand:commandData label:@"manual command" toContext:context];
    }
}

- (void)sendCommand:(NSData *)commandData toContext:(JoyConPeripheralContext *)context {
    [self enqueueCommand:commandData label:@"manual command" toContext:context];
}

- (void)enqueueCommand:(NSData *)commandData label:(NSString *)label toContext:(JoyConPeripheralContext *)context {
    [self enqueueCommand:commandData label:label waitsForProtocolResponse:YES toContext:context];
}

- (void)enqueueCommand:(NSData *)commandData
                 label:(NSString *)label
waitsForProtocolResponse:(BOOL)waitsForProtocolResponse
             toContext:(JoyConPeripheralContext *)context {
    if (!commandData || !context) {
        return;
    }
    [context.commandQueue addObject:commandData];
    [context.commandLabels addObject:label ?: @"command"];
    [context.commandWaitsForProtocolResponse addObject:@(waitsForProtocolResponse)];
    [self emitTelemetry:"command.enqueue"
                 detail:[NSString stringWithFormat:@"label=%@ waitsForProtocolResponse=%@ queueDepth=%lu bytes=%@",
                         label ?: @"command",
                         waitsForProtocolResponse ? @"true" : @"false",
                         (unsigned long)context.commandQueue.count,
                         [self hexStringForData:commandData maxBytes:24]]
             forContext:context];
    [self sendNextQueuedCommandForContext:context];
}

- (void)sendNextQueuedCommandForContext:(JoyConPeripheralContext *)context {
    if (context.commandInFlight || context.commandQueue.count == 0) {
        if (!context.commandInFlight && context.initStarted && !context.isInitialized && context.commandQueue.count == 0) {
            context.isInitialized = YES;
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
                      << " startup command sequence complete" << std::endl;
            [self emitTelemetry:"init.ready" detail:@"startup command queue drained" forContext:context];
            context.startupLifecycleDone = YES;
            [self emitTelemetry:"init.lifecycleReady"
                         detail:@"startup complete; pairing persistence deferred"
                     forContext:context];
            [self emitStatus:"ready" message:"Device ready" forContext:context];
            [self releaseStartupSlotForContext:context];
            [self schedulePairingPersistenceForContext:context delay:1.25];
        }
        return;
    }

    NSData *commandData = context.commandQueue.firstObject;
    NSString *label = context.commandLabels.firstObject;
    BOOL waitsForProtocolResponse = context.commandWaitsForProtocolResponse.firstObject.boolValue;
    [context.commandQueue removeObjectAtIndex:0];
    [context.commandLabels removeObjectAtIndex:0];
    [context.commandWaitsForProtocolResponse removeObjectAtIndex:0];

    if (!context.commandCharacteristic || !context.peripheral) {
        std::cout << "[BLE] Error: Command characteristic not available" << std::endl;
        context.commandInFlight = NO;
        [self sendNextQueuedCommandForContext:context];
        return;
    }

    const uint8_t *bytes = (const uint8_t *)commandData.bytes;
    context.commandInFlight = YES;
    context.waitingForResponse = waitsForProtocolResponse;
    context.currentCommandWaitsForProtocolResponse = waitsForProtocolResponse;
    context.currentCommandID = commandData.length > 0 ? bytes[0] : 0;

    std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
              << " " << [label UTF8String] << ": ";
    for (NSUInteger i = 0; i < commandData.length; i++) {
        printf("%02X ", bytes[i]);
    }
    std::cout << std::endl;
    [self emitTelemetry:"command.write"
                 detail:[NSString stringWithFormat:@"label=%@ waitsForProtocolResponse=%@ remainingQueue=%lu bytes=%@",
                         label ?: @"command",
                         waitsForProtocolResponse ? @"true" : @"false",
                         (unsigned long)context.commandQueue.count,
                         [self hexStringForData:commandData maxBytes:24]]
             forContext:context];

    CBCharacteristicWriteType writeType = CBCharacteristicWriteWithResponse;
    if (!(context.commandCharacteristic.properties & CBCharacteristicPropertyWrite) &&
        (context.commandCharacteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)) {
        writeType = CBCharacteristicWriteWithoutResponse;
    }

    [self emitTelemetry:"command.writeMode"
                 detail:[NSString stringWithFormat:@"label=%@ mode=%@ properties=%@",
                         label ?: @"command",
                         writeType == CBCharacteristicWriteWithResponse ? @"withResponse" : @"withoutResponse",
                         [self propertiesStringForCharacteristic:context.commandCharacteristic]]
             forContext:context];

    [context.peripheral writeValue:commandData
                  forCharacteristic:context.commandCharacteristic
                               type:writeType];
    if (writeType == CBCharacteristicWriteWithoutResponse && !waitsForProtocolResponse) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeQueuedCommandForContext:context];
        });
        return;
    }
    if (waitsForProtocolResponse) {
        [self scheduleCommandTimeoutForContext:context label:label];
    }
}

- (void)scheduleCommandTimeoutForContext:(JoyConPeripheralContext *)context label:(NSString *)label {
    [context.responseTimer invalidate];
    context.responseTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                            repeats:NO
                                                              block:^(NSTimer * _Nonnull timer) {
        if (!context.waitingForResponse) {
            return;
        }
        std::cout << "[BLE] Warning: No response for "
                  << [[self labelForSide:context.side] UTF8String]
                  << " " << [label UTF8String] << ", continuing" << std::endl;
        [self emitTelemetry:"command.timeout"
                     detail:[NSString stringWithFormat:@"label=%@", label ?: @"command"]
                 forContext:context];
        [self emitStatus:"commandTimeout" message:[label UTF8String] forContext:context];
        context.waitingForResponse = NO;
        context.commandInFlight = NO;
        context.currentCommandID = 0;
        [self sendNextQueuedCommandForContext:context];
    }];
}

- (void)completeQueuedCommandForContext:(JoyConPeripheralContext *)context {
    context.waitingForResponse = NO;
    context.commandInFlight = NO;
    context.currentCommandID = 0;
    [context.responseTimer invalidate];
    context.responseTimer = nil;
    [self emitTelemetry:"command.complete" detail:@"command completed" forContext:context];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self sendNextQueuedCommandForContext:context];
    });
}

- (void)initializeIMU {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self initializeIMUForContext:context];
    }
}

- (void)initializeIMUForContext:(JoyConPeripheralContext *)context {
    if (context.initStarted || context.isInitialized) {
        return;
    }

    NSString *peripheralID = [self keyForContext:context];
    if (_startupOwnerPeripheralID != nil && ![_startupOwnerPeripheralID isEqualToString:peripheralID]) {
        [self queueInitializationForContext:context reason:@"another Joy-Con is still running startup commands"];
        return;
    }
    _startupOwnerPeripheralID = peripheralID;

    context.initStarted = YES;
    std::cout << "[BLE] Starting startup command sequence for "
              << [[self labelForSide:context.side] UTF8String]
              << " Joy-Con..." << std::endl;
    [self emitTelemetry:"init.start" detail:@"IMU enable -> 500ms -> IMU enable2 -> 200ms -> LED -> sound" forContext:context];
    [self emitStatus:"initializing" message:"Sending startup commands" forContext:context];

    // Send ONLY the first IMU-enable up front. We then schedule the second
    // IMU-enable 500 ms later (joycon2cpp's SendCustomCommands waits that
    // long between the two), followed by the LED + vibration 200 ms after
    // that (joycon2cpp's post-custom-command delay). Packing everything
    // into the queue with no spacing caused the IMU block in the input
    // packets to stay all-zero — the controller accepts the first write
    // but then discards the rest if they arrive too close together.
    [self enqueueCommand:[self dataFromHexString:@"0C91010200040000FF000000"]
                   label:@"imu enable step1 (0x02)"
waitsForProtocolResponse:NO
               toContext:context];

    __weak typeof(self) weakSelf = self;
    __weak JoyConPeripheralContext *weakContext = context;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        JoyConPeripheralContext *strongContext = weakContext;
        if (!strongSelf || !strongContext ||
            strongContext.peripheral.state != CBPeripheralStateConnected) {
            return;
        }
        [strongSelf enqueueCommand:[strongSelf dataFromHexString:@"0C91010400040000FF000000"]
                             label:@"imu enable step2 (0x04)"
          waitsForProtocolResponse:NO
                         toContext:strongContext];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            JoyConPeripheralContext *c = weakContext;
            if (!s || !c || c.peripheral.state != CBPeripheralStateConnected) {
                return;
            }
            [s configureVibrationForContext:c];
            [s setPlayerLED:c.ledMask forContext:c];
            [s sendPairingVibrationToContext:c];
        });
    });
}

- (void)scheduleResponseTimeoutForContext:(JoyConPeripheralContext *)context step:(int)step {
    [context.responseTimer invalidate];
    context.responseTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                            repeats:NO
                                                              block:^(NSTimer * _Nonnull timer) {
        if (!context.waitingForResponse) {
            return;
        }
        std::cout << "[BLE] Warning: No response for "
                  << [[self labelForSide:context.side] UTF8String]
                  << " IMU step " << step << ", continuing" << std::endl;
        context.waitingForResponse = NO;
        context.commandInFlight = NO;
        [self sendNextQueuedCommandForContext:context];
    }];
}

- (void)setPlayerLED:(uint8_t)ledMask {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self setPlayerLED:ledMask forContext:context];
    }
}

- (void)setPlayerLED:(uint8_t)ledMask forContext:(JoyConPeripheralContext *)context {
    [self setPlayerLED:ledMask forContext:context label:@"set player LED"];
}

- (void)setPlayerLED:(uint8_t)ledMask forContext:(JoyConPeripheralContext *)context label:(NSString *)label {
    uint8_t cmdBytes[] = {0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00,
                          ledMask, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    NSData *commandData = [NSData dataWithBytes:cmdBytes length:sizeof(cmdBytes)];
    [self enqueueCommand:commandData
                   label:label ?: @"set player LED"
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)setPlayerLEDFallback:(uint8_t)ledMask forContext:(JoyConPeripheralContext *)context {
    uint8_t cmdBytes[] = {0x30, 0x01, 0x00, 0x30, 0x00, 0x08, 0x00, 0x00,
                          ledMask, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    NSData *commandData = [NSData dataWithBytes:cmdBytes length:sizeof(cmdBytes)];
    [self enqueueCommand:commandData
                   label:@"set player LED fallback"
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)configureVibrationForContext:(JoyConPeripheralContext *)context {
    uint8_t cmdBytes[] = {
        0x0A, 0x91, 0x01, 0x08, 0x00, 0x14, 0x00, 0x00,
        0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0x35, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00
    };
    NSData *commandData = [NSData dataWithBytes:cmdBytes length:sizeof(cmdBytes)];
    [self enqueueCommand:commandData
                   label:@"configure vibration"
 waitsForProtocolResponse:NO
               toContext:context];
}

- (void)sendPairingVibration {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self sendPairingVibrationToContext:context];
    }
}

- (void)sendPairingVibrationToContext:(JoyConPeripheralContext *)context {
    [self sendPairingVibrationToContext:context label:@"connected vibration"];
}

- (void)sendPairingVibrationToContext:(JoyConPeripheralContext *)context label:(NSString *)label {
    [self enqueueCommand:[self dataFromHexString:@"0A9101020004000003000000"]
                   label:label ?: @"connected vibration"
waitsForProtocolResponse:NO
               toContext:context];
}

- (NSData *)vibrationPacketForAmplitude:(uint8_t)amplitude counter:(uint8_t)counter {
    uint8_t packet[42] = {};
    uint16_t amplitude10Bit = JoyConRumbleAmplitude10Bit(amplitude);
    if (amplitude10Bit != 0) {
        FillJoyConVibrationMotorBlock(&packet[1], counter, amplitude10Bit);
        FillJoyConVibrationMotorBlock(&packet[17], counter, amplitude10Bit);
    }
    return [NSData dataWithBytes:packet length:sizeof(packet)];
}

- (void)sendRumbleAmplitude:(uint8_t)amplitude toContext:(JoyConPeripheralContext *)context {
    if (!context || !context.characteristicsReady || context.peripheral.state != CBPeripheralStateConnected) {
        return;
    }
    if (context.hasLastRumbleAmplitude && context.lastRumbleAmplitude == amplitude) {
        return;
    }

    context.hasLastRumbleAmplitude = YES;
    context.lastRumbleAmplitude = amplitude;

    if (!context.vibrationCharacteristic) {
        if (amplitude != 0) {
            [self sendPairingVibrationToContext:context label:@"rumble fallback sample"];
        }
        return;
    }

    NSData *packet = [self vibrationPacketForAmplitude:amplitude counter:context.vibrationCounter];
    context.vibrationCounter = (context.vibrationCounter + 1) & 0x0F;

    CBCharacteristicWriteType writeType = CBCharacteristicWriteWithoutResponse;
    if (!(context.vibrationCharacteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) &&
        (context.vibrationCharacteristic.properties & CBCharacteristicPropertyWrite)) {
        writeType = CBCharacteristicWriteWithResponse;
    }

    [self emitTelemetry:"rumble.write"
                 detail:[NSString stringWithFormat:@"amplitude=%u counter=%u mode=%@ bytes=%@",
                         (unsigned)amplitude,
                         (unsigned)((context.vibrationCounter + 15) & 0x0F),
                         writeType == CBCharacteristicWriteWithResponse ? @"withResponse" : @"withoutResponse",
                         [self hexStringForData:packet maxBytes:24]]
             forContext:context];

    [context.peripheral writeValue:packet
                 forCharacteristic:context.vibrationCharacteristic
                              type:writeType];
}

- (BOOL)findModeActiveForContext:(JoyConPeripheralContext *)context {
    if (!context) {
        return NO;
    }
    return context.side == JoyConSide::Right ? _findRightActive : _findLeftActive;
}

- (void)sendFindPulse {
    static const uint8_t pattern[] = {
        255, 0, 220, 0,
        255, 0, 0,   0,
        170, 0, 255, 0,
        0,   0, 0,   0
    };
    const size_t patternCount = sizeof(pattern) / sizeof(pattern[0]);
    uint8_t amplitude = pattern[_findPhase % patternCount];
    _findPhase++;

    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if ([self findModeActiveForContext:context]) {
            [self sendRumbleAmplitude:amplitude toContext:context];
        }
    }
}

- (void)startFindTimerIfNeeded {
    if (_findTimer) {
        return;
    }
    _findPhase = 0;
    _findTimer = [NSTimer timerWithTimeInterval:0.10
                                         target:self
                                       selector:@selector(handleFindTimer:)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_findTimer forMode:NSRunLoopCommonModes];
    [self sendFindPulse];
}

- (void)stopFindTimerIfIdle {
    if (_findLeftActive || _findRightActive) {
        return;
    }
    [_findTimer invalidate];
    _findTimer = nil;
    _findPhase = 0;
}

- (void)handleFindTimer:(NSTimer *)timer {
    (void)timer;
    if (!_findLeftActive && !_findRightActive) {
        [self stopFindTimerIfIdle];
        return;
    }
    [self sendFindPulse];
}

- (void)setFindModeLeft:(BOOL)leftActive right:(BOOL)rightActive {
    BOOL leftChanged = _findLeftActive != leftActive;
    BOOL rightChanged = _findRightActive != rightActive;
    _findLeftActive = leftActive;
    _findRightActive = rightActive;

    if (_findLeftActive || _findRightActive) {
        [self startFindTimerIfNeeded];
    } else {
        [self stopFindTimerIfIdle];
    }

    if (leftChanged && !leftActive) {
        for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
            if (context.side == JoyConSide::Left) {
                [self sendRumbleAmplitude:0 toContext:context];
            }
        }
    }
    if (rightChanged && !rightActive) {
        for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
            if (context.side == JoyConSide::Right) {
                [self sendRumbleAmplitude:0 toContext:context];
            }
        }
    }
}

- (void)setRumbleLowFrequency:(uint8_t)lowFrequency highFrequency:(uint8_t)highFrequency {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if ([self findModeActiveForContext:context]) {
            continue;
        }
        uint8_t amplitude = context.side == JoyConSide::Right ? highFrequency : lowFrequency;
        [self sendRumbleAmplitude:amplitude toContext:context];
    }
}

- (void)sendPairingPersistenceCommands {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self schedulePairingPersistenceForContext:context delay:0.0];
    }
}

- (void)sendPairingPersistenceCommandsToContext:(JoyConPeripheralContext *)context {
    if (!context ||
        context.pairingPersistenceStarted ||
        !context.isInitialized ||
        context.peripheral.state != CBPeripheralStateConnected) {
        return;
    }

    PairingManager *pairingManager = [PairingManager sharedManager];
    NSString *localMAC = [pairingManager getLocalBluetoothAddress];
    if (!localMAC) {
        std::cout << "[BLE] Skipping MAC persistence: local Bluetooth MAC unavailable" << std::endl;
        [self emitTelemetry:"pairing.skip" detail:@"local Bluetooth MAC unavailable" forContext:context];
        context.pairingPersistenceStarted = YES;
        return;
    }

    context.pairingPersistenceStarted = YES;
    [self emitTelemetry:"pairing.start"
                 detail:[NSString stringWithFormat:@"localMAC=%@", localMAC]
             forContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep1:localMAC mac2:nil] label:@"save MAC step 1" toContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep2] label:@"save MAC step 2" toContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep3] label:@"save MAC step 3" toContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep4] label:@"save MAC step 4" toContext:context];
}

- (NSData *)dataFromHexString:(NSString *)hexString {
    NSMutableData *data = [NSMutableData data];
    unsigned char byte;
    for (NSUInteger i = 0; i < hexString.length; i += 2) {
        NSString *byteString = [hexString substringWithRange:NSMakeRange(i, 2)];
        byte = (unsigned char)strtol([byteString UTF8String], NULL, 16);
        [data appendBytes:&byte length:1];
    }
    return data;
}

- (NSData *)legacySubcommandReport:(uint8_t)subcommand
                            payload:(const uint8_t *)payload
                             length:(NSUInteger)payloadLength
                          forContext:(JoyConPeripheralContext *)context {
    uint8_t report[49] = {};
    report[0] = 0x01;
    report[1] = context.nfcOutputCounter & 0x0F;
    context.nfcOutputCounter = (context.nfcOutputCounter + 1) & 0x0F;
    report[10] = subcommand;

    NSUInteger copyLength = std::min<NSUInteger>(payloadLength, 37);
    if (payload && copyLength > 0) {
        memcpy(&report[11], payload, copyLength);
    }

    if (subcommand == 0x21) {
        report[48] = JoyConMcuCRC8(&report[12], 36);
    }
    return [NSData dataWithBytes:report length:sizeof(report)];
}

- (NSData *)legacyMcuReportWithFrame:(const uint8_t *)frame
                               length:(NSUInteger)frameLength
                            forContext:(JoyConPeripheralContext *)context {
    uint8_t report[49] = {};
    report[0] = 0x11;
    report[1] = context.nfcOutputCounter & 0x0F;
    context.nfcOutputCounter = (context.nfcOutputCounter + 1) & 0x0F;

    NSUInteger copyLength = std::min<NSUInteger>(frameLength, 37);
    if (frame && copyLength > 0) {
        memcpy(&report[10], frame, copyLength);
    }
    report[47] = JoyConMcuCRC8(&report[11], 36);
    report[48] = 0xFF;
    return [NSData dataWithBytes:report length:sizeof(report)];
}

- (NSData *)switch2Command:(uint8_t)command
                    marker:(uint8_t)marker
                subcommand:(uint8_t)subcommand
                   payload:(const uint8_t *)payload
                    length:(NSUInteger)payloadLength {
    uint8_t header[8] = {
        command,
        0x91,
        marker,
        subcommand,
        0x00,
        (uint8_t)(payloadLength & 0xFF),
        (uint8_t)((payloadLength >> 8) & 0xFF),
        0x00
    };
    NSMutableData *data = [NSMutableData dataWithBytes:header length:sizeof(header)];
    if (payload && payloadLength > 0) {
        [data appendBytes:payload length:payloadLength];
    }
    return data;
}

- (NSData *)switch2Command:(uint8_t)command
                subcommand:(uint8_t)subcommand
                   payload:(const uint8_t *)payload
                    length:(NSUInteger)payloadLength {
    return [self switch2Command:command
                         marker:0x00
                     subcommand:subcommand
                        payload:payload
                         length:payloadLength];
}

- (void)enqueueSwitch2NFCSubcommand:(uint8_t)subcommand
                             payload:(const uint8_t *)payload
                              length:(NSUInteger)payloadLength
                               label:(NSString *)label
                           forContext:(JoyConPeripheralContext *)context {
    NSData *command = [self switch2Command:0x01
                                subcommand:subcommand
                                   payload:payload
                                    length:payloadLength];
    [self enqueueCommand:command
                   label:label
 waitsForProtocolResponse:YES
               toContext:context];
}

- (void)enqueueSwitch2NFCSubcommand:(uint8_t)subcommand
                              marker:(uint8_t)marker
                             payload:(const uint8_t *)payload
                              length:(NSUInteger)payloadLength
                               label:(NSString *)label
                           forContext:(JoyConPeripheralContext *)context {
    NSData *command = [self switch2Command:0x01
                                    marker:marker
                                subcommand:subcommand
                                   payload:payload
                                    length:payloadLength];
    [self enqueueCommand:command
                   label:label
 waitsForProtocolResponse:YES
               toContext:context];
}

- (void)enqueueLegacySubcommand:(uint8_t)subcommand
                        payload:(const uint8_t *)payload
                         length:(NSUInteger)payloadLength
                          label:(NSString *)label
                      forContext:(JoyConPeripheralContext *)context {
    NSData *report = [self legacySubcommandReport:subcommand
                                          payload:payload
                                           length:payloadLength
                                       forContext:context];
    [self enqueueCommand:report
                   label:label
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)enqueueLegacyMcuFrame:(const uint8_t *)frame
                       length:(NSUInteger)frameLength
                        label:(NSString *)label
                    forContext:(JoyConPeripheralContext *)context {
    NSData *report = [self legacyMcuReportWithFrame:frame
                                             length:frameLength
                                         forContext:context];
    [self enqueueCommand:report
                   label:label
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)resetNFCReadStateForContext:(JoyConPeripheralContext *)context {
    context.nfcRequestedOffset = 0;
    context.nfcStatusPollCount = 0;
    [context.nfcReadBuffer setLength:0];
    context.nfcTagID = nil;
    context.nfcTagType = 0;
}

- (void)enqueueNFCEnterScanForContext:(JoyConPeripheralContext *)context {
    if (!context.nfcScanning) {
        return;
    }
    static const uint8_t setupPayload[] = {0x00, 0xe8, 0x03, 0x2c, 0x01};
    context.nfcPhase = JoyConNFCPhaseEnteringScan;
    [self enqueueSwitch2NFCSubcommand:0x03
                                marker:0x00
                               payload:setupPayload
                                length:sizeof(setupPayload)
                                 label:@"nfc enter scan"
                             forContext:context];
}

- (void)enqueueNFCStatusForContext:(JoyConPeripheralContext *)context {
    if (!context.nfcScanning || context.commandInFlight) {
        return;
    }
    context.nfcStatusPollCount += 1;
    [self enqueueSwitch2NFCSubcommand:0x05
                                marker:0x00
                               payload:nil
                                length:0
                                 label:@"nfc get status"
                             forContext:context];
}

- (void)scheduleNFCStatusForContext:(JoyConPeripheralContext *)context delay:(NSTimeInterval)delay {
    [context.nfcPollTimer invalidate];
    if (!context.nfcScanning) {
        context.nfcPollTimer = nil;
        return;
    }
    __weak typeof(self) weakSelf = self;
    __weak JoyConPeripheralContext *weakContext = context;
    context.nfcPollTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                           repeats:NO
                                                             block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        typeof(self) strongSelf = weakSelf;
        JoyConPeripheralContext *strongContext = weakContext;
        if (!strongSelf || !strongContext || !strongContext.nfcScanning) {
            return;
        }
        strongContext.nfcPollTimer = nil;
        [strongSelf enqueueNFCStatusForContext:strongContext];
    }];
}

- (void)enqueueNFCReadOperationForContext:(JoyConPeripheralContext *)context {
    static const uint8_t readDescriptor[] = {
        0xd0, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x03, 0x00, 0x3b, 0x3c, 0x77, 0x78,
        0x86, 0x00, 0x00
    };
    context.nfcPhase = JoyConNFCPhaseStartingRead;
    [context.nfcReadBuffer setLength:0];
    context.nfcRequestedOffset = 0;
    [self enqueueSwitch2NFCSubcommand:0x06
                                marker:0x00
                               payload:readDescriptor
                                length:sizeof(readDescriptor)
                                 label:@"nfc begin Amiibo read"
                             forContext:context];
}

- (void)enqueueNFCReadBufferForContext:(JoyConPeripheralContext *)context {
    if (!context.nfcScanning || context.nfcReadBuffer.length >= kJoyConNFCReadPayloadLength) {
        return;
    }
    uint16_t offset = (uint16_t)context.nfcReadBuffer.length;
    uint8_t payload[] = {
        (uint8_t)(offset & 0xff),
        (uint8_t)((offset >> 8) & 0xff)
    };
    context.nfcRequestedOffset = offset;
    context.nfcPhase = JoyConNFCPhaseReadingBuffer;
    [self enqueueSwitch2NFCSubcommand:0x15
                                marker:0x01
                               payload:payload
                                length:sizeof(payload)
                                 label:[NSString stringWithFormat:@"nfc read buffer offset=%u", (unsigned)offset]
                             forContext:context];
}

- (void)leaveNFCTransactionForContext:(JoyConPeripheralContext *)context requireRemoval:(BOOL)requireRemoval {
    if (!context.nfcScanning) {
        return;
    }
    context.nfcRequireRemoval = requireRemoval;
    context.nfcPhase = JoyConNFCPhaseWaitingForRemoval;
    [self enqueueSwitch2NFCSubcommand:0x04
                                marker:0x00
                               payload:nil
                                length:0
                                 label:@"nfc leave scan"
                             forContext:context];
}

- (void)emitNFCTagStatus:(uint8_t)status
                  detail:(uint8_t)detail
              forContext:(JoyConPeripheralContext *)context {
    if (!_nfcCallback || !context.nfcTagID) {
        return;
    }
    const uint8_t *uidBytes = (const uint8_t *)context.nfcTagID.bytes;
    std::vector<uint8_t> tagId(uidBytes, uidBytes + context.nfcTagID.length);
    std::vector<uint8_t> payload = {status, detail};
    _nfcCallback(2, context.nfcTagType, tagId, payload);
}

- (BOOL)validateAndPublishNFCReadForContext:(JoyConPeripheralContext *)context {
    if (context.nfcReadBuffer.length != kJoyConNFCReadPayloadLength || !context.nfcTagID) {
        return NO;
    }

    const uint8_t *payload = (const uint8_t *)context.nfcReadBuffer.bytes;
    BOOL validEnvelope = payload[0] == 0x01 && payload[1] == 0x58 && payload[2] == 0x02;
    const uint8_t *raw = payload + kJoyConNFCReadMetadataLength;
    uint8_t bcc0 = (uint8_t)(0x88 ^ raw[0] ^ raw[1] ^ raw[2]);
    uint8_t bcc1 = (uint8_t)(raw[4] ^ raw[5] ^ raw[6] ^ raw[7]);
    BOOL validTag = raw[3] == bcc0 && raw[8] == bcc1 &&
                    raw[12] == 0xe1 && raw[14] == 0x3e;

    uint8_t rawUID[] = {raw[0], raw[1], raw[2], raw[4], raw[5], raw[6], raw[7]};
    BOOL uidMatches = context.nfcTagID.length == sizeof(rawUID) &&
                      memcmp(context.nfcTagID.bytes, rawUID, sizeof(rawUID)) == 0;
    if (!validEnvelope || !validTag || !uidMatches) {
        [self emitTelemetry:"nfc.readInvalid"
                     detail:[NSString stringWithFormat:@"envelope=%d tag=%d uid=%d bytes=%lu",
                             validEnvelope, validTag, uidMatches,
                             (unsigned long)context.nfcReadBuffer.length]
                 forContext:context];
        [self emitNFCTagStatus:0x07 detail:0x48 forContext:context];
        return NO;
    }

    std::vector<uint8_t> tagId(rawUID, rawUID + sizeof(rawUID));
    std::vector<uint8_t> rawTag(raw, raw + kJoyConNFCRawTagLength);
    [self emitTelemetry:"nfc.readComplete"
                 detail:[NSString stringWithFormat:@"uid=%@ rawBytes=%lu transferBytes=%lu",
                         context.lastNFCUID ?: @"",
                         (unsigned long)rawTag.size(),
                         (unsigned long)context.nfcReadBuffer.length]
             forContext:context];
    if (_nfcCallback) {
        _nfcCallback(1, context.nfcTagType, tagId, rawTag);
    }
    return YES;
}

- (BOOL)startNFCScanning {
    JoyConPeripheralContext *context = [self contextForSide:JoyConSide::Right];
    if (!context) {
        [self emitTelemetry:"nfc.unavailable"
                     detail:@"right Joy-Con command characteristic is not connected"
                       side:JoyConSide::Right
                       name:nil];
        return NO;
    }

    if (context.nfcScanning) {
        [self emitTelemetry:"nfc.alreadyScanning" detail:@"scan request ignored" forContext:context];
        return YES;
    }

    context.nfcScanning = YES;
    context.nfcOutputCounter = 0;
    context.nfcFrameCount = 0;
    context.lastNFCUID = nil;
    context.nfcRequireRemoval = NO;
    [context.nfcPollTimer invalidate];
    context.nfcPollTimer = nil;
    [self resetNFCReadStateForContext:context];

    [self emitTelemetry:"nfc.start"
                 detail:@"right stick NFC touchpoint; using Switch 2 sidechannel NFC commands"
             forContext:context];
    [self emitStatus:"nfcScanning" message:"NFC scanning active" forContext:context];

    [self enqueueNFCEnterScanForContext:context];
    return YES;
}

- (BOOL)runNFCProtocolProbe {
    JoyConPeripheralContext *context = [self contextForSide:JoyConSide::Right];
    if (context) {
        [self emitTelemetry:"nfc.probe"
                     detail:@"using the marker-correct state machine; unsafe marker permutations removed"
                 forContext:context];
    }
    return [self startNFCScanning];
}

- (void)stopNFCScanning {
    JoyConPeripheralContext *context = [self contextForSide:JoyConSide::Right];
    if (!context) {
        return;
    }
    BOOL wasScanning = context.nfcScanning;
    context.nfcScanning = NO;
    context.nfcPhase = JoyConNFCPhaseIdle;
    context.nfcRequireRemoval = NO;
    context.lastNFCUID = nil;
    [context.nfcPollTimer invalidate];
    context.nfcPollTimer = nil;
    [self resetNFCReadStateForContext:context];

    if (!wasScanning) {
        return;
    }

    [self emitTelemetry:"nfc.stop" detail:@"stopping Switch 2 NFC transaction state machine" forContext:context];
    [self enqueueSwitch2NFCSubcommand:0x04
                                marker:0x00
                               payload:nil
                                length:0
                                 label:@"nfc deactivate reader"
                             forContext:context];
    [self emitStatus:"ready" message:"NFC scanning stopped" forContext:context];
}

- (BOOL)parseNFCRegion:(const uint8_t *)bytes
                length:(NSUInteger)length
               context:(JoyConPeripheralContext *)context {
    if (!bytes || length < 10 || !context.nfcScanning) {
        return NO;
    }

    context.nfcFrameCount += 1;
    if (context.nfcFrameCount <= 10 || context.nfcFrameCount % 40 == 0) {
        NSData *sample = [NSData dataWithBytes:bytes length:std::min<NSUInteger>(length, 96)];
        [self emitTelemetry:"nfc.frame"
                     detail:[NSString stringWithFormat:@"count=%lu length=%lu bytes=%@",
                             (unsigned long)context.nfcFrameCount,
                             (unsigned long)length,
                             [self hexStringForData:sample maxBytes:96]]
                 forContext:context];
    }

    for (NSUInteger i = 0; i + 5 < length; i++) {
        uint8_t uidLength = bytes[i + 4];
        BOOL plausibleHeader = bytes[i] == 0x01 &&
                               bytes[i + 1] == 0x01 &&
                               bytes[i + 3] == 0x00 &&
                               (uidLength == 4 || uidLength == 7 || uidLength == 10);
        if (!plausibleHeader || i + 5 + uidLength > length) {
            continue;
        }

        const uint8_t *uidBytes = bytes + i + 5;
        BOOL uidNonZero = NO;
        for (uint8_t j = 0; j < uidLength; j++) {
            if (uidBytes[j] != 0) {
                uidNonZero = YES;
                break;
            }
        }
        if (!uidNonZero) {
            continue;
        }

        std::vector<uint8_t> tagId(uidBytes, uidBytes + uidLength);
        NSString *uid = [self compactHexForVector:tagId];
        if ([uid isEqualToString:context.lastNFCUID]) {
            return YES;
        }

        NSUInteger payloadLength = std::min<NSUInteger>(length, 192);
        std::vector<uint8_t> payload(bytes, bytes + payloadLength);
        uint8_t tagType = bytes[i + 2];
        context.lastNFCUID = uid;

        [self emitTelemetry:"nfc.tag"
                     detail:[NSString stringWithFormat:@"uid=%@ type=0x%02X payloadLength=%lu",
                             uid,
                             tagType,
                             (unsigned long)payload.size()]
                 forContext:context];
        if (_nfcCallback) {
            _nfcCallback(1, tagType, tagId, payload);
        }
        return YES;
    }

    for (NSUInteger i = 0; i + 4 < length; i++) {
        uint8_t uidLength = bytes[i + 3];
        BOOL plausibleHeader = bytes[i] == 0x01 &&
                               bytes[i + 1] == 0x02 &&
                               bytes[i + 2] == 0x00 &&
                               (uidLength == 4 || uidLength == 7 || uidLength == 10);
        if (!plausibleHeader || i + 4 + uidLength > length) {
            continue;
        }

        const uint8_t *uidBytes = bytes + i + 4;
        BOOL uidNonZero = NO;
        for (uint8_t j = 0; j < uidLength; j++) {
            if (uidBytes[j] != 0) {
                uidNonZero = YES;
                break;
            }
        }
        if (!uidNonZero) {
            continue;
        }

        std::vector<uint8_t> tagId(uidBytes, uidBytes + uidLength);
        NSString *uid = [self compactHexForVector:tagId];
        if ([uid isEqualToString:context.lastNFCUID]) {
            return YES;
        }

        NSUInteger payloadLength = std::min<NSUInteger>(length, 192);
        std::vector<uint8_t> payload(bytes, bytes + payloadLength);
        uint8_t tagType = bytes[i + 1];
        context.lastNFCUID = uid;

        [self emitTelemetry:"nfc.tag"
                     detail:[NSString stringWithFormat:@"uid=%@ type=0x%02X payloadLength=%lu",
                             uid,
                             tagType,
                             (unsigned long)payload.size()]
                 forContext:context];
        if (_nfcCallback) {
            _nfcCallback(1, tagType, tagId, payload);
        }
        return YES;
    }
    return NO;
}

- (BOOL)handleNFCInputData:(NSData *)data forContext:(JoyConPeripheralContext *)context {
    if (!data || !context.nfcScanning || context.side != JoyConSide::Right) {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    BOOL looksLikeLargeMCUReport = length > 80 || (length > 0 && bytes[0] == 0x31);
    if (!looksLikeLargeMCUReport) {
        return NO;
    }

    BOOL found = NO;
    if (length > 49 && bytes[0] == 0x31) {
        found = [self parseNFCRegion:bytes + 49 length:length - 49 context:context];
    }
    if (!found) {
        found = [self parseNFCRegion:bytes length:length context:context];
    }
    return looksLikeLargeMCUReport || found;
}

- (BOOL)handleNFCResponseData:(NSData *)data forContext:(JoyConPeripheralContext *)context {
    if (!data || !context.nfcScanning || context.side != JoyConSide::Right) {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    if (length < 8 || bytes[0] != 0x01) {
        return NO;
    }

    uint8_t subcommand = bytes[3];
    BOOL isNFCSetupResponse = subcommand == 0x03 ||
                              subcommand == 0x04;
    BOOL isNFCResponse = subcommand == 0x05 ||
                         subcommand == 0x06 ||
                         subcommand == 0x0C ||
                         subcommand == 0x14 ||
                         subcommand == 0x15;
    if (!isNFCResponse && !isNFCSetupResponse) {
        return NO;
    }

    NSData *sample = [NSData dataWithBytes:bytes length:std::min<NSUInteger>(length, 192)];
    [self emitTelemetry:"nfc.response"
                 detail:[NSString stringWithFormat:@"subcommand=0x%02X length=%lu bytes=%@",
                         subcommand,
                         (unsigned long)length,
                         [self hexStringForData:sample maxBytes:192]]
             forContext:context];

    BOOL commandAccepted = bytes[1] == 0x01;
    if (!commandAccepted) {
        [self emitTelemetry:"nfc.commandRejected"
                     detail:[NSString stringWithFormat:@"subcommand=0x%02X direction=0x%02X expected=0x01",
                             subcommand, bytes[1]]
                 forContext:context];
        if (subcommand == 0x15) {
            [self emitNFCTagStatus:0x07 detail:0x4a forContext:context];
            [self leaveNFCTransactionForContext:context requireRemoval:YES];
        } else {
            [self scheduleNFCStatusForContext:context delay:0.20];
        }
        return YES;
    }

    if (subcommand == 0x03) {
        context.nfcPhase = context.nfcRequireRemoval
            ? JoyConNFCPhaseWaitingForRemoval
            : JoyConNFCPhaseWaitingForTag;
        [self scheduleNFCStatusForContext:context delay:0.04];
        return YES;
    }

    if (subcommand == 0x04) {
        if (context.nfcScanning) {
            __weak typeof(self) weakSelf = self;
            __weak JoyConPeripheralContext *weakContext = context;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                JoyConPeripheralContext *strongContext = weakContext;
                if (strongSelf && strongContext && strongContext.nfcScanning) {
                    [strongSelf enqueueNFCEnterScanForContext:strongContext];
                }
            });
        }
        return YES;
    }

    if (subcommand == 0x06) {
        context.nfcPhase = JoyConNFCPhaseWaitingForReadReady;
        [self scheduleNFCStatusForContext:context delay:0.04];
        return YES;
    }

    if (subcommand == 0x05) {
        if (length < 10) {
            [self scheduleNFCStatusForContext:context delay:0.20];
            return YES;
        }

        uint8_t nfcState = bytes[8];
        uint8_t nfcDetail = bytes[9];
        [self emitTelemetry:"nfc.state"
                     detail:[NSString stringWithFormat:@"state=0x%02X detail=0x%02X phase=%ld poll=%lu",
                             nfcState, nfcDetail, (long)context.nfcPhase,
                             (unsigned long)context.nfcStatusPollCount]
                 forContext:context];

        if (nfcState == 0x09) {
            if (length < 17) {
                [self scheduleNFCStatusForContext:context delay:0.20];
                return YES;
            }
            uint8_t uidLength = bytes[16];
            if ((uidLength != 4 && uidLength != 7 && uidLength != 10) || 17 + uidLength > length) {
                [self emitTelemetry:"nfc.invalidIdentity"
                             detail:[NSString stringWithFormat:@"uidLength=%u responseLength=%lu",
                                     uidLength, (unsigned long)length]
                         forContext:context];
                [self scheduleNFCStatusForContext:context delay:0.20];
                return YES;
            }

            NSData *tagID = [NSData dataWithBytes:bytes + 17 length:uidLength];
            const uint8_t *tagIDBytes = (const uint8_t *)tagID.bytes;
            std::vector<uint8_t> tagIDVector(tagIDBytes, tagIDBytes + tagID.length);
            NSString *uid = [self compactHexForVector:tagIDVector];
            if (context.nfcRequireRemoval && [uid isEqualToString:context.lastNFCUID]) {
                [self scheduleNFCStatusForContext:context delay:0.15];
                return YES;
            }

            context.nfcTagID = tagID;
            context.nfcTagType = bytes[14];
            context.lastNFCUID = uid;
            context.nfcRequireRemoval = NO;
            context.nfcStatusPollCount = 0;
            [context.nfcReadBuffer setLength:0];
            [self emitTelemetry:"nfc.tagDetected"
                         detail:[NSString stringWithFormat:@"uid=%@ type=0x%02X",
                                 uid, context.nfcTagType]
                     forContext:context];
            if (_nfcCallback) {
                std::vector<uint8_t> emptyPayload;
                _nfcCallback(0, context.nfcTagType, tagIDVector, emptyPayload);
            }
            [self enqueueNFCReadOperationForContext:context];
            return YES;
        }

        if (nfcState == 0x04) {
            if (context.nfcTagID) {
                [self enqueueNFCReadBufferForContext:context];
            } else {
                [self leaveNFCTransactionForContext:context requireRemoval:NO];
            }
            return YES;
        }

        if (nfcState == 0x07) {
            if (nfcDetail == 0x41) {
                if (context.nfcRequireRemoval) {
                    context.nfcRequireRemoval = NO;
                    context.lastNFCUID = nil;
                    [self resetNFCReadStateForContext:context];
                }
                context.nfcPhase = JoyConNFCPhaseWaitingForTag;
                [self scheduleNFCStatusForContext:context delay:0.25];
            } else {
                context.nfcPhase = JoyConNFCPhaseError;
                [self emitNFCTagStatus:nfcState detail:nfcDetail forContext:context];
                [self emitStatus:"nfcTagRejected"
                          message:nfcDetail == 0x48
                              ? "Tag detected, but it is not in the Amiibo format"
                              : "NFC tag read failed"
                       forContext:context];
                [self leaveNFCTransactionForContext:context requireRemoval:YES];
            }
            return YES;
        }

        [self scheduleNFCStatusForContext:context delay:0.10];
        return YES;
    }

    if (subcommand == 0x15) {
        if (length < 12 || bytes[8] != 0x00) {
            [self emitNFCTagStatus:0x07 detail:0x3e forContext:context];
            [self leaveNFCTransactionForContext:context requireRemoval:YES];
            return YES;
        }

        uint16_t responseOffset = (uint16_t)(bytes[9] | ((uint16_t)bytes[10] << 8));
        if (responseOffset != context.nfcRequestedOffset || responseOffset != context.nfcReadBuffer.length) {
            [self emitTelemetry:"nfc.offsetMismatch"
                         detail:[NSString stringWithFormat:@"requested=%lu response=%u assembled=%lu",
                                 (unsigned long)context.nfcRequestedOffset,
                                 (unsigned)responseOffset,
                                 (unsigned long)context.nfcReadBuffer.length]
                     forContext:context];
            [self emitNFCTagStatus:0x07 detail:0x4a forContext:context];
            [self leaveNFCTransactionForContext:context requireRemoval:YES];
            return YES;
        }

        NSUInteger available = length - 11;
        NSUInteger remaining = kJoyConNFCReadPayloadLength - context.nfcReadBuffer.length;
        NSUInteger appendLength = MIN(available, remaining);
        [context.nfcReadBuffer appendBytes:bytes + 11 length:appendLength];
        [self emitTelemetry:"nfc.buffer"
                     detail:[NSString stringWithFormat:@"offset=%u chunk=%lu assembled=%lu/%lu",
                             (unsigned)responseOffset,
                             (unsigned long)appendLength,
                             (unsigned long)context.nfcReadBuffer.length,
                             (unsigned long)kJoyConNFCReadPayloadLength]
                 forContext:context];

        if (context.nfcReadBuffer.length < kJoyConNFCReadPayloadLength) {
            [self enqueueNFCReadBufferForContext:context];
        } else {
            [self validateAndPublishNFCReadForContext:context];
            [self leaveNFCTransactionForContext:context requireRemoval:YES];
        }
        return YES;
    }

    return isNFCResponse || isNFCSetupResponse;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            std::cout << "[BLE] Bluetooth powered on" << std::endl;
            [self emitTelemetry:"central.poweredOn" detail:@"CoreBluetooth ready" side:JoyConSide::Left name:nil];
            [self startScanning];
            break;
        case CBManagerStatePoweredOff:
            std::cout << "[BLE] Bluetooth powered off" << std::endl;
            [self emitTelemetry:"central.poweredOff" detail:@"Bluetooth is off" side:JoyConSide::Left name:nil];
            break;
        case CBManagerStateUnsupported:
            std::cout << "[BLE] Bluetooth not supported" << std::endl;
            [self emitTelemetry:"central.unsupported" detail:@"Bluetooth unsupported" side:JoyConSide::Left name:nil];
            break;
        case CBManagerStateUnauthorized:
            std::cout << "[BLE] Bluetooth unauthorized" << std::endl;
            [self emitTelemetry:"central.unauthorized" detail:@"Bluetooth permission denied" side:JoyConSide::Left name:nil];
            break;
        default:
            std::cout << "[BLE] Bluetooth state: " << (int)central.state << std::endl;
            [self emitTelemetry:"central.state"
                         detail:[NSString stringWithFormat:@"state=%ld", (long)central.state]
                           side:JoyConSide::Left
                           name:nil];
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (![self isNintendoAdvertisement:advertisementData peripheral:peripheral]) {
        return;
    }

    NSString *peripheralID = [self keyForPeripheral:peripheral];
    if (_contextsByPeripheralID[peripheralID] ||
        [_connectingPeripheralIDs containsObject:peripheralID] ||
        _pendingPeripheralsByID[peripheralID]) {
        return;
    }

    if ([self activeOrPendingConnectionCount] >= 2) {
        return;
    }

    NSString *deviceName = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"Unknown";
    NSNumber *explicitSide = [self explicitSideForPeripheralName:deviceName];
    BOOL sideWasInferred = (explicitSide == nil);
    JoyConSide side = explicitSide ? (JoyConSide)explicitSide.integerValue : [self missingOrDefaultSide];
    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    NSString *manufacturerHex = [self hexStringForData:manufacturerData maxBytes:32];

    [self emitTelemetry:"scan.candidate"
                 detail:[NSString stringWithFormat:@"name=%@ rssi=%@ manufacturer=%@ side=%@ inferred=%@",
                         deviceName,
                         RSSI,
                         manufacturerHex,
                         [self labelForSide:side],
                         sideWasInferred ? @"true" : @"false"]
                   side:side
                   name:deviceName];

    if (explicitSide && ([self hasContextForSide:side] || [self hasPendingConnectionForSide:side])) {
        std::cout << "[BLE] Ignoring additional " << [[self labelForSide:side] UTF8String]
                  << " Joy-Con candidate: " << [deviceName UTF8String] << std::endl;
        [self emitTelemetry:"scan.ignored"
                     detail:@"same side already active or pending"
                       side:side
                       name:deviceName];
        return;
    }

    NSDate *lastAttempt = _lastConnectionAttemptByPeripheralID[peripheralID];
    NSNumber *attemptValue = _reconnectAttemptsByPeripheralID[peripheralID] ?: @0;
    if (lastAttempt && attemptValue.integerValue > 0) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:lastAttempt];
        if (elapsed < 180.0) {
            std::cout << "[BLE] Cooldown active for " << [deviceName UTF8String]
                      << ". Waiting " << (int)(180.0 - elapsed) << " more seconds" << std::endl;
            [self emitTelemetry:"scan.cooldown"
                         detail:[NSString stringWithFormat:@"remainingSeconds=%.0f", 180.0 - elapsed]
                           side:side
                           name:deviceName];
            return;
        }
    }

    if (![self.discoveredPeripherals containsObject:peripheral]) {
        [self.discoveredPeripherals addObject:peripheral];
    }

    if (_connectingPeripheralIDs.count > 0) {
        _sideByPeripheralID[peripheralID] = @((NSInteger)side);
        _pendingPeripheralsByID[peripheralID] = peripheral;
        _pendingNamesByID[peripheralID] = deviceName;
        _pendingRSSIByID[peripheralID] = RSSI;
        _pendingSideWasInferredByID[peripheralID] = @(sideWasInferred);
        std::cout << "[BLE] Queued " << [[self labelForSide:side] UTF8String]
                  << " Joy-Con: " << [deviceName UTF8String] << std::endl;
        [self emitTelemetry:"connect.queued"
                     detail:@"another BLE connection is in progress"
                       side:side
                       name:deviceName];
        [self emitStatus:"queued" message:"Waiting for current BLE connection" side:side name:deviceName];
        return;
    }

    [self beginConnectionToPeripheral:peripheral
                                 side:side
                                 name:deviceName
                                 RSSI:RSSI
                      sideWasInferred:sideWasInferred];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    JoyConSide side = (JoyConSide)(_sideByPeripheralID[peripheralID] ?: @((NSInteger)JoyConSide::Left)).integerValue;

    JoyConPeripheralContext *context = [[JoyConPeripheralContext alloc] init];
    context.peripheral = peripheral;
    context.side = side;
    context.sideWasInferred = ([self explicitSideForPeripheralName:peripheral.name] == nil);
    context.ledMask = side == JoyConSide::Left ? 0x01 : 0x02;
    _contextsByPeripheralID[peripheralID] = context;
    [_connectingPeripheralIDs removeObject:peripheralID];
    _reconnectAttemptsByPeripheralID[peripheralID] = @0;

    std::cout << "[BLE] Connected " << [[self labelForSide:side] UTF8String] << " Joy-Con. Discovering services..." << std::endl;
    [self emitTelemetry:"connect.connected" detail:@"CoreBluetooth didConnectPeripheral" forContext:context];
    [self emitStatus:"bleConnected" message:"Discovering services" forContext:context];
    peripheral.delegate = self;
    [peripheral discoverServices:nil];

    if ([self hasBothSides]) {
        [self stopScanning];
    } else {
        [self connectNextPendingPeripheralIfPossible];
    }
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    [_connectingPeripheralIDs removeObject:peripheralID];
    std::cout << "[BLE] Failed to connect: " << [[error localizedDescription] UTF8String] << std::endl;
    NSNumber *sideValue = _sideByPeripheralID[peripheralID];
    JoyConSide side = sideValue ? (JoyConSide)sideValue.integerValue : JoyConSide::Left;
    [self emitTelemetry:"connect.failed"
                 detail:error.localizedDescription ?: @"Connection failed"
                   side:side
                   name:peripheral.name];
    [self emitStatus:"connectFailed"
             message:error.localizedDescription ? [error.localizedDescription UTF8String] : "Connection failed"
                side:side
                name:peripheral.name];

    NSNumber *attemptValue = _reconnectAttemptsByPeripheralID[peripheralID] ?: @1;
    NSTimeInterval backoff = pow(2, MIN((int)attemptValue.integerValue, 5)) * 30.0;
    std::cout << "[BLE] Will retry scan in " << (int)backoff << " seconds" << std::endl;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self connectNextPendingPeripheralIfPossible];
        [self startScanning];
    });
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    JoyConPeripheralContext *context = _contextsByPeripheralID[peripheralID];
    if (context) {
        std::cout << "[BLE] Disconnected " << [[self labelForSide:context.side] UTF8String] << " Joy-Con" << std::endl;
        [self emitTelemetry:"connect.disconnected"
                     detail:error.localizedDescription ?: @"Disconnected"
                 forContext:context];
        [self emitStatus:"disconnected"
                 message:error.localizedDescription ? [error.localizedDescription UTF8String] : "Disconnected"
              forContext:context];
        [context.responseTimer invalidate];
    } else {
        std::cout << "[BLE] Disconnected Joy-Con" << std::endl;
    }

    [_contextsByPeripheralID removeObjectForKey:peripheralID];
    [_connectingPeripheralIDs removeObject:peripheralID];
    [_pendingInitializationPeripheralIDs removeObject:peripheralID];
    if ([_startupOwnerPeripheralID isEqualToString:peripheralID]) {
        _startupOwnerPeripheralID = nil;
        [self startNextQueuedInitializationIfPossible];
    }

    if (!_isShuttingDown) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [self connectNextPendingPeripheralIfPossible];
            [self startScanning];
        });
    }
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        std::cout << "[BLE] Error discovering services: " << [[error localizedDescription] UTF8String] << std::endl;
        JoyConPeripheralContext *failedContext = [self contextForPeripheral:peripheral];
        if (failedContext) {
            [self emitTelemetry:"services.failed" detail:error.localizedDescription ?: @"service discovery failed" forContext:failedContext];
        }
        return;
    }

    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    if (!context) {
        return;
    }
    std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
              << " discovered " << peripheral.services.count << " services" << std::endl;
    NSMutableArray<NSString *> *serviceUUIDs = [NSMutableArray array];
    for (CBService *service in peripheral.services) {
        [serviceUUIDs addObject:service.UUID.UUIDString];
        [peripheral discoverCharacteristics:nil forService:service];
    }
    [self emitTelemetry:"services.discovered"
                 detail:[NSString stringWithFormat:@"count=%lu uuids=%@",
                         (unsigned long)peripheral.services.count,
                         [serviceUUIDs componentsJoinedByString:@","]]
             forContext:context];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    if (error) {
        return;
    }

    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    if (!context) {
        return;
    }

    CBUUID *inputUUID = [CBUUID UUIDWithString:UUID_INPUT];
    CBUUID *commandUUID = [CBUUID UUIDWithString:UUID_COMMAND];
    CBUUID *responseUUID = [CBUUID UUIDWithString:UUID_RESPONSE];

    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:inputUUID]) {
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String] << " input characteristic" << std::endl;
            context.inputCharacteristic = characteristic;
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
            [self emitTelemetry:"characteristic.input"
                         detail:[NSString stringWithFormat:@"uuid=%@ properties=%@ notify=true",
                                 characteristic.UUID.UUIDString,
                                 [self propertiesStringForCharacteristic:characteristic]]
                     forContext:context];
        } else if ([characteristic.UUID isEqual:commandUUID]) {
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String] << " command characteristic" << std::endl;
            context.commandCharacteristic = characteristic;
            [self emitTelemetry:"characteristic.command"
                         detail:[NSString stringWithFormat:@"uuid=%@ properties=%@",
                                 characteristic.UUID.UUIDString,
                                 [self propertiesStringForCharacteristic:characteristic]]
                     forContext:context];
        } else if ([characteristic.UUID isEqual:responseUUID]) {
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String] << " response characteristic" << std::endl;
            context.responseCharacteristic = characteristic;
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
            [self emitTelemetry:"characteristic.response"
                         detail:[NSString stringWithFormat:@"uuid=%@ properties=%@ notify=true",
                                 characteristic.UUID.UUIDString,
                                 [self propertiesStringForCharacteristic:characteristic]]
                     forContext:context];
        }
    }

    if (!context.vibrationCharacteristic && context.commandCharacteristic) {
        NSUInteger commandIndex = [service.characteristics indexOfObject:context.commandCharacteristic];
        if (commandIndex != NSNotFound && commandIndex > 0) {
            for (NSInteger i = (NSInteger)commandIndex - 1; i >= 0; i--) {
                CBCharacteristic *candidate = service.characteristics[(NSUInteger)i];
                if ([candidate isEqual:context.inputCharacteristic] ||
                    [candidate isEqual:context.responseCharacteristic] ||
                    [candidate isEqual:context.commandCharacteristic]) {
                    continue;
                }
                if (candidate.properties & (CBCharacteristicPropertyWriteWithoutResponse | CBCharacteristicPropertyWrite)) {
                    context.vibrationCharacteristic = candidate;
                    std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
                              << " vibration characteristic" << std::endl;
                    [self emitTelemetry:"characteristic.vibration"
                                 detail:[NSString stringWithFormat:@"uuid=%@ properties=%@",
                                         candidate.UUID.UUIDString,
                                         [self propertiesStringForCharacteristic:candidate]]
                             forContext:context];
                    break;
                }
            }
        }
    }

    if (context.inputCharacteristic &&
        context.commandCharacteristic &&
        context.responseCharacteristic &&
        !context.characteristicsReady) {
        context.characteristicsReady = YES;
        [self emitTelemetry:"services.ready"
                     detail:@"input, command, and response characteristics discovered"
                 forContext:context];
        [self emitStatus:"servicesReady" message:"Nintendo characteristics discovered" forContext:context];
        NSString *peripheralID = [[self keyForPeripheral:peripheral] copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            JoyConPeripheralContext *readyContext = self->_contextsByPeripheralID[peripheralID];
            if (!readyContext || readyContext.peripheral.state != CBPeripheralStateConnected) {
                return;
            }
            [self initializeIMUForContext:readyContext];
        });
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        return;
    }

    JoyConPeripheralContext *context = [self contextForCharacteristic:characteristic peripheral:peripheral];
    if (!context) {
        return;
    }

    NSData *data = characteristic.value;
    if ([characteristic isEqual:context.responseCharacteristic]) {
        std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
                  << " command response (" << data.length << " bytes)" << std::endl;
        BOOL nfcResponse = [self handleNFCResponseData:data forContext:context];
        [self emitTelemetry:"command.response"
                     detail:[NSString stringWithFormat:@"length=%lu bytes=%@",
                             (unsigned long)data.length,
                             [self hexStringForData:data maxBytes:nfcResponse ? 192 : 24]]
                 forContext:context];
        if (context.waitingForResponse) {
            const uint8_t *responseBytes = (const uint8_t *)data.bytes;
            if (data.length > 0 && responseBytes[0] != context.currentCommandID) {
                [self emitTelemetry:"command.responseIgnored"
                             detail:[NSString stringWithFormat:@"expectedCommand=%02X got=%02X",
                                     context.currentCommandID,
                                     responseBytes[0]]
                         forContext:context];
                return;
            }
            [self completeQueuedCommandForContext:context];
        }
        return;
    }

    if ([characteristic isEqual:context.inputCharacteristic]) {
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        if ([self handleNFCInputData:data forContext:context]) {
            return;
        }
        std::vector<uint8_t> buffer(bytes, bytes + data.length);
        if (_dataCallback) {
            _dataCallback(buffer, context.side);
        }
        context.inputPacketCount += 1;

        // Gyro diagnostics path. We want to be able to tell, at a glance,
        // whether:
        //   1. The Joy-Con is actually sending >= 0x3C-byte packets
        //      (header + buttons + sticks + mouse + battery + IMU).
        //   2. The IMU slice (0x30..0x3B) is literally all zeros — i.e. the
        //      IMU-enable command never took effect.
        //   3. The IMU slice has raw values but our decoder is eating them.
        //
        // To stay cheap, we only emit once for each distinct "state" of the
        // IMU slice: first packet, first non-zero IMU, every 600th packet.
        if (context.inputPacketCount <= 5 || context.inputPacketCount % 600 == 0) {
            NSString *hex = [self hexStringForData:data maxBytes:64];
            [self emitTelemetry:"input.packet"
                         detail:[NSString stringWithFormat:@"count=%lu length=%lu bytes=%@",
                                 (unsigned long)context.inputPacketCount,
                                 (unsigned long)data.length,
                                 hex]
                     forContext:context];
        }

        if (data.length >= 0x3C) {
            const uint8_t *b = bytes;
            int16_t rawAccelX = (int16_t)(b[0x30] | (b[0x31] << 8));
            int16_t rawAccelY = (int16_t)(b[0x32] | (b[0x33] << 8));
            int16_t rawAccelZ = (int16_t)(b[0x34] | (b[0x35] << 8));
            int16_t rawGyroX  = (int16_t)(b[0x36] | (b[0x37] << 8));
            int16_t rawGyroY  = (int16_t)(b[0x38] | (b[0x39] << 8));
            int16_t rawGyroZ  = (int16_t)(b[0x3A] | (b[0x3B] << 8));
            bool imuAllZero = (rawAccelX | rawAccelY | rawAccelZ |
                               rawGyroX | rawGyroY | rawGyroZ) == 0;
            if (imuAllZero != context.imuAllZeroLastSeen ||
                context.inputPacketCount == 1 ||
                context.inputPacketCount == 60 ||
                context.inputPacketCount % 600 == 0) {
                context.imuAllZeroLastSeen = imuAllZero;
                [self emitTelemetry:"imu.sample"
                             detail:[NSString stringWithFormat:@"count=%lu allZero=%@ accel=%d,%d,%d gyro=%d,%d,%d",
                                     (unsigned long)context.inputPacketCount,
                                     imuAllZero ? @"true" : @"false",
                                     rawAccelX, rawAccelY, rawAccelZ,
                                     rawGyroX, rawGyroY, rawGyroZ]
                         forContext:context];
            }
        } else if (context.inputPacketCount <= 5) {
            [self emitTelemetry:"imu.shortPacket"
                         detail:[NSString stringWithFormat:@"length=%lu (<0x3C so no IMU slice)",
                                 (unsigned long)data.length]
                     forContext:context];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    BOOL isCommandWrite = context && [characteristic isEqual:context.commandCharacteristic];
    if (error) {
        NSString *sideLabel = context ? [self labelForSide:context.side] : @"Unknown";
        std::cout << "[BLE] Error writing " << [sideLabel UTF8String]
                  << " characteristic: " << [[error localizedDescription] UTF8String] << std::endl;
        if (context && isCommandWrite) {
            [self emitTelemetry:"command.writeFailed"
                         detail:error.localizedDescription ?: @"GATT write failed"
                     forContext:context];
            [self emitStatus:"writeFailed"
                     message:error.localizedDescription ? [error.localizedDescription UTF8String] : "GATT write failed"
                  forContext:context];
            context.waitingForResponse = NO;
            context.commandInFlight = NO;
            context.currentCommandID = 0;
            [context.responseTimer invalidate];
            context.responseTimer = nil;
            [self sendNextQueuedCommandForContext:context];
        }
        return;
    }

    if (isCommandWrite && context.commandInFlight && !context.currentCommandWaitsForProtocolResponse) {
        [self emitTelemetry:"command.writeAck" detail:@"CoreBluetooth write-with-response completed" forContext:context];
        [self completeQueuedCommandForContext:context];
    }
}

@end
