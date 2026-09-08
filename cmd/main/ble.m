#include "platform.h"
#import <CoreBluetooth/CoreBluetooth.h>

@class ASBluetooth;

// Each connection owns its delegate and generation. Buffered callbacks retain
// their original device/attempt instead of borrowing a global current target.
@interface ASConnection : NSObject <CBPeripheralDelegate>
@property(weak) ASBluetooth *owner;
@property CBPeripheral *peripheral;
@property NSInteger attempt;
@property NSMutableDictionary<NSString *, CBCharacteristic *> *characteristics;
@property NSMutableArray<NSDictionary *> *writes;
@property BOOL writingWithResponse;
@property NSUInteger pendingServices;
@property BOOL disconnecting;
- (BOOL)current;
- (void)emit:(NSDictionary *)event;
- (void)flushWrites;
@end

// CoreBluetooth objects stay on worker. Event dictionaries own copies of all
// payloads; MoonBit allocation and decoding happen only on the calling thread.
@interface ASBluetooth : NSObject <CBCentralManagerDelegate>
@property dispatch_queue_t worker;
@property dispatch_semaphore_t ready;
@property NSLock *eventLock;
@property NSMutableArray<NSDictionary *> *events;
@property NSMutableDictionary<NSString *, CBPeripheral *> *devices;
@property NSMutableDictionary<NSString *, ASConnection *> *connections;
@property NSSet<NSString *> *targets;
@property CBCentralManager *central;
@property NSInteger sequence;
@property NSUInteger dropped;
@property BOOL closed;
- (void)emit:(NSDictionary *)event;
- (NSArray *)drain;
- (void)cancelConnections;
@end

static NSString *hexString(NSData *data) {
  const uint8_t *bytes = data.bytes;
  NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
  for (NSUInteger i = 0; i < data.length; i++)
    [hex appendFormat:@"%02x", bytes[i]];
  return hex;
}

static CBCharacteristicWriteType writeType(CBCharacteristic *characteristic) {
  return characteristic.properties &
                 CBCharacteristicPropertyWriteWithoutResponse
             ? CBCharacteristicWriteWithoutResponse
             : CBCharacteristicWriteWithResponse;
}

@implementation ASBluetooth
- (instancetype)init {
  if ((self = [super init])) {
    _worker = dispatch_queue_create("com.ph0ryn.AnkerScale.bluetooth",
                                    DISPATCH_QUEUE_SERIAL);
    _ready = dispatch_semaphore_create(0);
    _eventLock = [NSLock new];
    _events = [NSMutableArray array];
    _devices = [NSMutableDictionary dictionary];
    _connections = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)cancelConnections {
  [self.central stopScan];
  for (ASConnection *connection in self.connections.allValues) {
    [connection.writes removeAllObjects];
    if (!connection.disconnecting &&
        self.central.state == CBManagerStatePoweredOn) {
      connection.disconnecting = YES;
      [self.central cancelPeripheralConnection:connection.peripheral];
    }
  }
}

- (void)emit:(NSDictionary *)event {
  if (self.closed)
    return;
  NSMutableDictionary *record = [event mutableCopy];
  record[@"utc"] = as_utc_now();
  record[@"mono_ms"] = @((int64_t)as_monotonic_ms());
  record[@"seq"] = @(++self.sequence);
  if (!record[@"attempt"])
    record[@"attempt"] = @0;
  [self.eventLock lock];
  if (self.events.count >= 1024 || self.dropped) {
    BOOL first = self.dropped == 0;
    self.dropped++;
    [self.eventLock unlock];
    if (first)
      [self cancelConnections];
    return;
  }
  BOOL wake = self.events.count == 0;
  [self.events addObject:record];
  [self.eventLock unlock];
  if (wake)
    dispatch_semaphore_signal(self.ready);
}

- (NSArray *)drain {
  [self.eventLock lock];
  NSMutableArray *result = [self.events mutableCopy];
  [self.events removeAllObjects];
  if (self.dropped) {
    [result addObject:@{
      @"event" : @"fatal",
      @"message" :
          [NSString stringWithFormat:@"Bluetooth event queue overflow; %lu "
                                     @"events could not be retained",
                                     (unsigned long)self.dropped],
      @"utc" : as_utc_now(),
      @"mono_ms" : @((int64_t)as_monotonic_ms()),
      @"attempt" : @0
    }];
  }
  [self.eventLock unlock];
  return result;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  [self emit:@{@"event" : @"power", @"state" : @(central.state)}];
  if (central.state != CBManagerStatePoweredOn) {
    for (ASConnection *connection in self.connections.allValues) {
      connection.peripheral.delegate = nil;
      [connection.writes removeAllObjects];
    }
    [self.connections removeAllObjects];
    [self.devices removeAllObjects];
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI {
  (void)central;
  NSString *identifier = peripheral.identifier.UUIDString;
  if (self.targets && ![self.targets containsObject:identifier])
    return;
  if (!self.devices[identifier] && self.devices.count >= 512) {
    [self emit:@{
      @"event" : @"fatal",
      @"message" : @"device discovery capacity exceeded"
    }];
    [self cancelConnections];
    return;
  }
  self.devices[identifier] = peripheral;
  NSMutableArray *services = [NSMutableArray array];
  for (CBUUID *uuid in advertisementData[CBAdvertisementDataServiceUUIDsKey])
    [services addObject:uuid.UUIDString];
  NSMutableDictionary *event = [@{
    @"event" : @"device", @"device" : identifier,
    @"name" : advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name ?: @"",
    @"services" : services, @"rssi" : RSSI
  } mutableCopy];
  NSData *manufacturer =
      advertisementData[CBAdvertisementDataManufacturerDataKey];
  if (manufacturer)
    event[@"manufacturer_hex"] = hexString(manufacturer);
  NSDictionary<CBUUID *, NSData *> *serviceData =
      advertisementData[CBAdvertisementDataServiceDataKey];
  if (serviceData) {
    NSMutableDictionary *payloads = [NSMutableDictionary dictionary];
    for (CBUUID *uuid in serviceData)
      payloads[uuid.UUIDString] = hexString(serviceData[uuid]);
    event[@"service_data_hex"] = payloads;
  }
  if (advertisementData[CBAdvertisementDataIsConnectable])
    event[@"connectable"] = advertisementData[CBAdvertisementDataIsConnectable];
  if (advertisementData[CBAdvertisementDataTxPowerLevelKey])
    event[@"tx_power"] = advertisementData[CBAdvertisementDataTxPowerLevelKey];
  [self emit:event];
}

- (ASConnection *)connectionFor:(CBPeripheral *)peripheral {
  ASConnection *connection = self.connections[peripheral.identifier.UUIDString];
  return connection.peripheral == peripheral ? connection : nil;
}

- (void)centralManager:(CBCentralManager *)central
    didConnectPeripheral:(CBPeripheral *)peripheral {
  (void)central;
  ASConnection *connection = [self connectionFor:peripheral];
  if (connection && !connection.disconnecting)
    [connection emit:@{@"event" : @"connected"}];
}

- (void)finishConnection:(CBPeripheral *)peripheral
                 message:(NSString *)message
                  failed:(BOOL)failed {
  ASConnection *connection = [self connectionFor:peripheral];
  if (!connection)
    return;
  [connection emit:@{
    @"event" : @"disconnected",
    @"message" : message,
    @"failed" : @(failed)
  }];
  peripheral.delegate = nil;
  [connection.writes removeAllObjects];
  [self.connections removeObjectForKey:peripheral.identifier.UUIDString];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error {
  (void)central;
  ASConnection *connection = [self connectionFor:peripheral];
  [self finishConnection:peripheral
                 message:error.localizedDescription ?: @"connection failed"
                  failed:!connection.disconnecting];
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
  (void)central;
  [self finishConnection:peripheral
                 message:error.localizedDescription ?: @"disconnected"
                  failed:error != nil];
}
@end

@implementation ASConnection
- (instancetype)init {
  if ((self = [super init])) {
    _characteristics = [NSMutableDictionary dictionary];
    _writes = [NSMutableArray array];
  }
  return self;
}

- (BOOL)current {
  return self.owner && !self.owner.closed &&
         self.owner.connections[self.peripheral.identifier.UUIDString] == self;
}

- (void)emit:(NSDictionary *)event {
  if (![self current])
    return;
  NSMutableDictionary *record = [event mutableCopy];
  record[@"device"] = self.peripheral.identifier.UUIDString;
  record[@"attempt"] = @(self.attempt);
  [self.owner emit:record];
}

- (void)profile {
  NSMutableArray *services = [NSMutableArray array];
  for (CBService *service in self.peripheral.services) {
    NSMutableArray *characteristics = [NSMutableArray array];
    for (CBCharacteristic *c in service.characteristics) {
      [characteristics addObject:@{
        @"uuid" : c.UUID.UUIDString,
        @"properties" : @(c.properties)
      }];
      self.characteristics[[NSString stringWithFormat:@"%@/%@",
                                                      service.UUID.UUIDString,
                                                      c.UUID.UUIDString]] = c;
    }
    [services addObject:@{
      @"uuid" : service.UUID.UUIDString,
      @"characteristics" : characteristics
    }];
  }
  [self emit:@{
    @"event" : @"profile",
    @"name" : self.peripheral.name ?: @"",
    @"services" : services
  }];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverServices:(NSError *)error {
  if (![self current] || peripheral != self.peripheral || self.disconnecting)
    return;
  if (error) {
    [self
        emit:@{@"event" : @"failed", @"message" : error.localizedDescription}];
    return;
  }
  self.pendingServices = peripheral.services.count;
  if (!self.pendingServices)
    [self profile];
  for (CBService *service in peripheral.services)
    [peripheral discoverCharacteristics:nil forService:service];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service
                                   error:(NSError *)error {
  (void)service;
  if (![self current] || peripheral != self.peripheral || self.disconnecting)
    return;
  if (error) {
    [self
        emit:@{@"event" : @"failed", @"message" : error.localizedDescription}];
    return;
  }
  if (self.pendingServices > 0 && --self.pendingServices == 0)
    [self profile];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateNotificationStateForCharacteristic:
        (CBCharacteristic *)characteristic
                                          error:(NSError *)error {
  if (![self current] || peripheral != self.peripheral || self.disconnecting)
    return;
  if (error || !characteristic.isNotifying) {
    [self emit:@{
      @"event" : @"failed",
      @"message" : error.localizedDescription
          ?: @"notification subscription ended"
    }];
    return;
  }
  [self emit:@{
    @"event" : @"subscribed",
    @"service" : characteristic.service.UUID.UUIDString,
    @"characteristic" : characteristic.UUID.UUIDString
  }];
}

- (void)packet:(NSData *)data
    characteristic:(CBCharacteristic *)characteristic
         direction:(NSString *)direction {
  [self emit:@{
    @"event" : @"packet",
    @"name" : self.peripheral.name ?: @"",
    @"service" : characteristic.service.UUID.UUIDString,
    @"characteristic" : characteristic.UUID.UUIDString,
    @"direction" : direction,
    @"hex" : hexString(data),
    @"session" : [NSString stringWithFormat:@"%ld", (long)self.attempt]
  }];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
                              error:(NSError *)error {
  // Keep already-received notifications during cancellation until disconnect
  // completes. They still belong to this connection's immutable generation.
  if (![self current] || peripheral != self.peripheral)
    return;
  if (error) {
    [self
        emit:@{@"event" : @"failed", @"message" : error.localizedDescription}];
    return;
  }
  [self packet:characteristic.value ?: NSData.data
      characteristic:characteristic
           direction:@"rx"];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didModifyServices:(NSArray<CBService *> *)invalidatedServices {
  (void)invalidatedServices;
  if ([self current] && peripheral == self.peripheral && !self.disconnecting)
    [self emit:@{
      @"event" : @"failed",
      @"message" : @"GATT services changed; reconnect required"
    }];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
  if (peripheral == self.peripheral)
    [self flushWrites];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
                             error:(NSError *)error {
  (void)characteristic;
  if (![self current] || peripheral != self.peripheral || self.disconnecting ||
      !self.writingWithResponse)
    return;
  self.writingWithResponse = NO;
  [self.writes removeObjectAtIndex:0];
  if (error) {
    [self.writes removeAllObjects];
    [self
        emit:@{@"event" : @"failed", @"message" : error.localizedDescription}];
    if (!self.disconnecting) {
      self.disconnecting = YES;
      [self.owner.central cancelPeripheralConnection:peripheral];
    }
    return;
  }
  [self flushWrites];
}

- (void)flushWrites {
  while ([self current] && !self.disconnecting && self.writes.count &&
         !self.writingWithResponse) {
    NSDictionary *write = self.writes[0];
    CBCharacteristic *characteristic = write[@"characteristic"];
    NSData *data = write[@"data"];
    CBCharacteristicWriteType type = writeType(characteristic);
    if (type == CBCharacteristicWriteWithoutResponse) {
      if (!self.peripheral.canSendWriteWithoutResponse)
        return;
      [self.writes removeObjectAtIndex:0];
    } else {
      // Keep the in-flight write at the head until its completion callback.
      self.writingWithResponse = YES;
    }
    [self.peripheral writeValue:data
              forCharacteristic:characteristic
                           type:type];
    [self packet:data characteristic:characteristic direction:@"tx"];
  }
}
@end

static ASBluetooth *bluetooth;

id as_ble_request(NSDictionary *input, NSError **error) {
  NSString *op = input[@"op"];
  if ([op isEqual:@"ble_start"]) {
    if (bluetooth) {
      *error = as_failure(@"Bluetooth is already open");
      return nil;
    }
    if (![NSBundle.mainBundle
            objectForInfoDictionaryKey:@"NSBluetoothAlwaysUsageDescription"]) {
      *error = as_failure(@"Bluetooth requires the AnkerScale.app bundle; run "
                          @"nix build and use result/bin/ankerscale");
      return nil;
    }
    bluetooth = [ASBluetooth new];
    if (input[@"devices"])
      bluetooth.targets = [NSSet setWithArray:input[@"devices"]];
    dispatch_sync(bluetooth.worker, ^{
      bluetooth.central = [[CBCentralManager alloc]
          initWithDelegate:bluetooth
                     queue:bluetooth.worker
                   options:@{
                     CBCentralManagerOptionShowPowerAlertKey : @NO
                   }];
    });
    return NSNull.null;
  }
  ASBluetooth *b = bluetooth;
  if (!b) {
    *error = as_failure(@"Bluetooth is not open");
    return nil;
  }
  if ([op isEqual:@"ble_poll"]) {
    int64_t timeout = MIN(1000, MAX(0, [input[@"timeout_ms"] longLongValue]));
    dispatch_semaphore_wait(
        b.ready, dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_MSEC));
    return [b drain];
  }
  if ([op isEqual:@"ble_close"]) {
    dispatch_sync(b.worker, ^{
      [b cancelConnections];
      for (ASConnection *connection in b.connections.allValues)
        connection.peripheral.delegate = nil;
      b.central.delegate = nil;
      b.central = nil;
      [b.connections removeAllObjects];
      [b.devices removeAllObjects];
      b.closed = YES;
    });
    NSArray *remaining = [b drain];
    bluetooth = nil;
    return remaining;
  }
  __block NSError *commandError = nil;
  dispatch_sync(b.worker, ^{
    if ([op isEqual:@"ble_targets"]) {
      b.targets = [NSSet setWithArray:input[@"devices"]];
      for (NSString *identifier in b.devices.allKeys)
        if (![b.targets containsObject:identifier])
          [b.devices removeObjectForKey:identifier];
    } else if ([op isEqual:@"ble_scan"]) {
      if (b.central.state != CBManagerStatePoweredOn) {
        commandError = as_failure(@"Bluetooth is not powered on");
        return;
      }
      // Restart only when the collector requests discovery (including retries
      // and added registrations), so duplicate suppression cannot starve them.
      [b.central stopScan];
      [b.central
          scanForPeripheralsWithServices:nil
                                 options:@{
                                   CBCentralManagerScanOptionAllowDuplicatesKey :
                                       @NO
                                 }];
    } else if ([op isEqual:@"ble_stop_scan"]) {
      [b.central stopScan];
    } else if ([op isEqual:@"ble_connect"]) {
      NSString *identifier = input[@"device"];
      CBPeripheral *peripheral = b.devices[identifier];
      if (!peripheral || b.connections[identifier] ||
          (b.targets && ![b.targets containsObject:identifier])) {
        commandError = as_failure(@"device disappeared, is no longer "
                                  @"registered, or already has a connection");
        return;
      }
      ASConnection *connection = [ASConnection new];
      connection.owner = b;
      connection.peripheral = peripheral;
      connection.attempt = [input[@"attempt"] integerValue];
      b.connections[identifier] = connection;
      peripheral.delegate = connection;
      [b.central connectPeripheral:peripheral options:nil];
    } else {
      NSString *identifier = input[@"device"];
      ASConnection *connection = b.connections[identifier];
      NSInteger attempt = [input[@"attempt"] integerValue];
      if ([op isEqual:@"ble_disconnect"] && !connection) {
        [b emit:@{
          @"event" : @"disconnected",
          @"device" : identifier,
          @"attempt" : @(attempt),
          @"message" : @"already disconnected",
          @"failed" : @NO
        }];
        return;
      }
      if (!connection || connection.attempt != attempt) {
        commandError = as_failure(@"stale or unavailable Bluetooth connection");
        return;
      }
      if ([op isEqual:@"ble_disconnect"]) {
        [connection.writes removeAllObjects];
        if (!connection.disconnecting) {
          connection.disconnecting = YES;
          [b.central cancelPeripheralConnection:connection.peripheral];
        }
        return;
      }
      if (connection.disconnecting ||
          connection.peripheral.state != CBPeripheralStateConnected) {
        commandError = as_failure(@"Bluetooth connection is not ready");
        return;
      }
      if ([op isEqual:@"ble_discover"]) {
        [connection.peripheral discoverServices:nil];
        return;
      }
      if (![op isEqual:@"ble_subscribe"] && ![op isEqual:@"ble_write"]) {
        commandError = as_failure(@"unknown Bluetooth command");
        return;
      }
      NSString *key = [NSString stringWithFormat:@"%@/%@", input[@"service"],
                                                 input[@"characteristic"]];
      CBCharacteristic *characteristic = connection.characteristics[key];
      if (!characteristic) {
        commandError = as_failure(@"characteristic is unavailable");
        return;
      }
      if ([op isEqual:@"ble_subscribe"]) {
        [connection.peripheral setNotifyValue:YES
                            forCharacteristic:characteristic];
        return;
      }
      NSString *hex = input[@"hex"];
      NSMutableData *data = [NSMutableData data];
      if (hex.length % 2) {
        commandError = as_failure(@"invalid write hex");
        return;
      }
      for (NSUInteger i = 0; i < hex.length; i += 2) {
        unsigned value = 0;
        NSScanner *scanner = [NSScanner
            scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        if (![scanner scanHexInt:&value] || !scanner.isAtEnd) {
          commandError = as_failure(@"invalid write hex");
          return;
        }
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
      }
      if (!(characteristic.properties &
            (CBCharacteristicPropertyWriteWithoutResponse |
             CBCharacteristicPropertyWrite)) ||
          data.length >
              [connection.peripheral
                  maximumWriteValueLengthForType:writeType(characteristic)] ||
          connection.writes.count >= 16) {
        commandError = as_failure(
            @"write is unsupported, too large, or transport queue is full");
        return;
      }
      [connection.writes
          addObject:@{@"data" : data, @"characteristic" : characteristic}];
      [connection flushWrites];
    }
  });
  *error = commandError;
  return NSNull.null;
}
