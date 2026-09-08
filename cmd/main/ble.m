#include "platform.h"
#import <CoreBluetooth/CoreBluetooth.h>

// CoreBluetooth objects stay on worker. Event dictionaries own copies of all
// payloads; MoonBit allocation and decoding happen only on the calling thread.
@interface ASBluetooth
    : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property dispatch_queue_t worker;
@property dispatch_semaphore_t ready;
@property NSLock *eventLock;
@property NSMutableArray<NSDictionary *> *events;
@property NSMutableDictionary<NSString *, CBPeripheral *> *devices;
@property NSMutableDictionary<NSString *, CBCharacteristic *> *characteristics;
@property NSMutableArray<NSDictionary *> *writes;
@property CBCentralManager *central;
@property CBPeripheral *peripheral;
@property NSString *target;
@property NSInteger attempt;
@property NSInteger sequence;
@property NSUInteger pendingServices;
@property NSUInteger dropped;
@property BOOL closed;
- (void)emit:(NSDictionary *)event;
- (NSArray *)drain;
- (void)flushWrites;
@end

@implementation ASBluetooth
- (instancetype)init {
  if ((self = [super init])) {
    _worker = dispatch_queue_create("com.ph0ryn.AnkerScale.bluetooth",
                                    DISPATCH_QUEUE_SERIAL);
    _ready = dispatch_semaphore_create(0);
    _eventLock = [NSLock new];
    _events = [NSMutableArray array];
    _devices = [NSMutableDictionary dictionary];
    _characteristics = [NSMutableDictionary dictionary];
    _writes = [NSMutableArray array];
  }
  return self;
}

- (void)emit:(NSDictionary *)event {
  if (self.closed)
    return;
  NSMutableDictionary *record = [event mutableCopy];
  record[@"utc"] = as_utc_now();
  record[@"mono_ms"] = @((int64_t)as_monotonic_ms());
  record[@"seq"] = @(++self.sequence);
  if (!record[@"attempt"])
    record[@"attempt"] = @(self.attempt);
  [self.eventLock lock];
  if (self.events.count >= 1024 || self.dropped) {
    self.dropped++;
    [self.eventLock unlock];
    [self.central stopScan];
    if (self.peripheral)
      [self.central cancelPeripheralConnection:self.peripheral];
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
  [self emit:@{
    @"event" : @"power",
    @"state" : @(central.state),
    @"attempt" : @0
  }];
  if (central.state != CBManagerStatePoweredOn) {
    self.peripheral.delegate = nil;
    self.peripheral = nil;
    [self.characteristics removeAllObjects];
    [self.writes removeAllObjects];
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI {
  (void)central;
  NSString *identifier = peripheral.identifier.UUIDString;
  if (self.target.length && ![self.target isEqual:identifier])
    return;
  if (!self.devices[identifier] && self.devices.count >= 512) {
    [self emit:@{
      @"event" : @"fatal",
      @"message" : @"device discovery capacity exceeded"
    }];
    [self.central stopScan];
    return;
  }
  self.devices[identifier] = peripheral;
  NSMutableArray *services = [NSMutableArray array];
  for (CBUUID *uuid in advertisementData[CBAdvertisementDataServiceUUIDsKey])
    [services addObject:uuid.UUIDString];
  NSMutableDictionary *event = [@{ @"event": @"device", @"device": identifier,
      @"name": advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name ?: @"",
      @"services": services, @"rssi": RSSI, @"attempt": @0 } mutableCopy];
  NSData *manufacturer =
      advertisementData[CBAdvertisementDataManufacturerDataKey];
  if (manufacturer)
    event[@"manufacturer_hex"] = [self hex:manufacturer];
  NSDictionary<CBUUID *, NSData *> *serviceData =
      advertisementData[CBAdvertisementDataServiceDataKey];
  if (serviceData) {
    NSMutableDictionary *payloads = [NSMutableDictionary dictionary];
    for (CBUUID *uuid in serviceData)
      payloads[uuid.UUIDString] = [self hex:serviceData[uuid]];
    event[@"service_data_hex"] = payloads;
  }
  if (advertisementData[CBAdvertisementDataIsConnectable])
    event[@"connectable"] = advertisementData[CBAdvertisementDataIsConnectable];
  if (advertisementData[CBAdvertisementDataTxPowerLevelKey])
    event[@"tx_power"] = advertisementData[CBAdvertisementDataTxPowerLevelKey];
  [self emit:event];
}

- (void)centralManager:(CBCentralManager *)central
    didConnectPeripheral:(CBPeripheral *)peripheral {
  (void)central;
  if (peripheral != self.peripheral)
    return;
  [self emit:@{
    @"event" : @"connected",
    @"device" : peripheral.identifier.UUIDString
  }];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error {
  (void)central;
  if (peripheral != self.peripheral)
    return;
  // didFailToConnect also completes cancellation of a pending connection.
  [self emit:@{
    @"event" : @"disconnected",
    @"stage" : @"connect",
    @"message" : error.localizedDescription ?: @"connection failed"
  }];
  self.peripheral.delegate = nil;
  self.peripheral = nil;
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
  (void)central;
  if (peripheral != self.peripheral)
    return;
  [self emit:@{
    @"event" : @"disconnected",
    @"message" : error.localizedDescription ?: @"disconnected"
  }];
  self.peripheral.delegate = nil;
  self.peripheral = nil;
  [self.characteristics removeAllObjects];
  [self.writes removeAllObjects];
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
    @"device" : self.peripheral.identifier.UUIDString,
    @"name" : self.peripheral.name ?: @"",
    @"services" : services
  }];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverServices:(NSError *)error {
  if (peripheral != self.peripheral)
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
  if (peripheral != self.peripheral)
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
  if (peripheral != self.peripheral)
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

- (NSString *)hex:(NSData *)data {
  const uint8_t *bytes = data.bytes;
  NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
  for (NSUInteger i = 0; i < data.length; i++)
    [hex appendFormat:@"%02x", bytes[i]];
  return hex;
}

- (void)packet:(NSData *)data
    characteristic:(CBCharacteristic *)characteristic
         direction:(NSString *)direction {
  [self emit:@{
    @"event" : @"packet",
    @"device" : self.peripheral.identifier.UUIDString,
    @"name" : self.peripheral.name ?: @"",
    @"service" : characteristic.service.UUID.UUIDString,
    @"characteristic" : characteristic.UUID.UUIDString,
    @"direction" : direction,
    @"hex" : [self hex:data],
    @"session" : [NSString stringWithFormat:@"%ld", (long)self.attempt]
  }];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
                              error:(NSError *)error {
  if (peripheral != self.peripheral)
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
  if (peripheral == self.peripheral)
    [self emit:@{
      @"event" : @"failed",
      @"message" : @"GATT services changed; reconnect required"
    }];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
  if (peripheral == self.peripheral)
    [self flushWrites];
}

- (void)flushWrites {
  while (self.writes.count && self.peripheral.canSendWriteWithoutResponse) {
    NSDictionary *write = self.writes[0];
    [self.writes removeObjectAtIndex:0];
    CBCharacteristic *characteristic = write[@"characteristic"];
    NSData *data = write[@"data"];
    [self.peripheral writeValue:data
              forCharacteristic:characteristic
                           type:CBCharacteristicWriteWithoutResponse];
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
    bluetooth.target = input[@"device"] ?: @"";
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
      [b.central stopScan];
      if (b.peripheral && b.central.state == CBManagerStatePoweredOn)
        [b.central cancelPeripheralConnection:b.peripheral];
      b.peripheral.delegate = nil;
      b.central.delegate = nil;
      b.peripheral = nil;
      b.central = nil;
      [b.devices removeAllObjects];
      [b.characteristics removeAllObjects];
      [b.writes removeAllObjects];
      b.closed = YES;
    });
    NSArray *remaining = [b drain];
    bluetooth = nil;
    return remaining;
  }
  __block NSError *commandError = nil;
  dispatch_sync(b.worker, ^{
    if ([op isEqual:@"ble_scan"]) {
      if (b.central.state != CBManagerStatePoweredOn) {
        commandError = as_failure(@"Bluetooth is not powered on");
        return;
      }
      [b.devices removeAllObjects];
      [b.central
          scanForPeripheralsWithServices:nil
                                 options:@{
                                   CBCentralManagerScanOptionAllowDuplicatesKey :
                                       @NO
                                 }];
    } else if ([op isEqual:@"ble_stop_scan"]) {
      [b.central stopScan];
    } else if ([op isEqual:@"ble_connect"]) {
      CBPeripheral *p = b.devices[input[@"device"]];
      if (!p || b.peripheral) {
        commandError =
            as_failure(@"device disappeared or connection already exists");
        return;
      }
      b.attempt = [input[@"attempt"] integerValue];
      b.peripheral = p;
      p.delegate = b;
      [b.central connectPeripheral:p options:nil];
    } else if ([op isEqual:@"ble_disconnect"]) {
      [b.writes removeAllObjects];
      if (b.peripheral && b.peripheral.state != CBPeripheralStateDisconnected)
        [b.central cancelPeripheralConnection:b.peripheral];
      else
        [b emit:@{
          @"event" : @"disconnected",
          @"message" : @"already disconnected"
        }];
    } else if ([op isEqual:@"ble_discover"]) {
      [b.peripheral discoverServices:nil];
    } else if ([op isEqual:@"ble_subscribe"] || [op isEqual:@"ble_write"]) {
      NSString *key = [NSString stringWithFormat:@"%@/%@", input[@"service"],
                                                 input[@"characteristic"]];
      CBCharacteristic *c = b.characteristics[key];
      if (!c || b.peripheral.state != CBPeripheralStateConnected) {
        commandError = as_failure(@"characteristic is unavailable");
        return;
      }
      if ([op isEqual:@"ble_subscribe"]) {
        [b.peripheral setNotifyValue:YES forCharacteristic:c];
      } else {
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
        if (!(c.properties & CBCharacteristicPropertyWriteWithoutResponse) ||
            data.length >
                [b.peripheral maximumWriteValueLengthForType:
                                  CBCharacteristicWriteWithoutResponse] ||
            b.writes.count >= 16) {
          commandError = as_failure(
              @"write is unsupported, too large, or transport queue is full");
          return;
        }
        [b.writes addObject:@{@"data" : data, @"characteristic" : c}];
        [b flushWrites];
      }
    } else {
      commandError = as_failure(@"unknown Bluetooth command");
    }
  });
  *error = commandError;
  return NSNull.null;
}
