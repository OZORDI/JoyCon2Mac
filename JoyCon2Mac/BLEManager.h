#pragma once

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <functional>
#include <vector>
#include "JoyConDecoder.h"

// Forward declare the C++ callback type
using JoyConDataCallback = std::function<void(const std::vector<uint8_t>&, JoyConSide)>;
using JoyConStatusCallback = std::function<void(JoyConSide, const char *, const char *, const char *)>;
using JoyConTelemetryCallback = std::function<void(JoyConSide, const char *, const char *, const char *)>;
using JoyConNFCCallback = std::function<void(uint8_t, uint8_t, const std::vector<uint8_t>&, const std::vector<uint8_t>&)>;

@interface BLEManager : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>

@property (nonatomic, strong) CBCentralManager *centralManager;
@property (nonatomic, strong) NSMutableArray<CBPeripheral *> *discoveredPeripherals;

// C++ callback for data
- (void)setDataCallback:(JoyConDataCallback)callback;
- (void)setStatusCallback:(JoyConStatusCallback)callback;
- (void)setTelemetryCallback:(JoyConTelemetryCallback)callback;
- (void)setNFCCallback:(JoyConNFCCallback)callback;

// Control methods
- (void)startScanning;
- (void)stopScanning;
- (void)disconnect;

// Command sending
- (void)sendCommand:(NSData *)commandData;
- (void)initializeIMU;
- (void)setPlayerLED:(uint8_t)ledMask;
- (void)sendPairingVibration;
- (void)setRumbleLowFrequency:(uint8_t)lowFrequency highFrequency:(uint8_t)highFrequency;
- (void)setFindModeLeft:(BOOL)leftActive right:(BOOL)rightActive;
- (void)sendPairingPersistenceCommands;
- (BOOL)startNFCScanning;
- (BOOL)runNFCProtocolProbe;
- (void)stopNFCScanning;

@end
