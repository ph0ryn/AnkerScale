#import "../../cmd/main/platform.h"
#include <unistd.h>

static NSDictionary *scenario;
static NSMutableArray *pending;
static NSMutableDictionary *attempts;
static NSArray *targets;
static NSInteger sequence;

static void emit(NSDictionary *event) {
  NSMutableDictionary *value = [event mutableCopy];
  value[@"utc"] = as_utc_now();
  value[@"mono_ms"] = @((int64_t)as_monotonic_ms());
  value[@"seq"] = @(++sequence);
  if (!value[@"attempt"])
    value[@"attempt"] =
        value[@"device"] ? attempts[value[@"device"]] ?: @0 : @0;
  [pending addObject:value];
}

static NSDictionary *device(NSString *identifier) {
  for (NSDictionary *value in scenario[@"devices"])
    if ([value[@"device"] isEqual:identifier])
      return value;
  return nil;
}

static void trace(NSDictionary *input) {
  NSString *path = [as_data_directory()
      stringByAppendingPathComponent:@"ble-commands.jsonl"];
  NSData *data = [NSJSONSerialization dataWithJSONObject:input
                                                 options:0
                                                   error:NULL];
  FILE *file = fopen(path.fileSystemRepresentation, "a");
  if (!file)
    abort();
  fwrite(data.bytes, 1, data.length, file);
  fputc('\n', file);
  fclose(file);
}

id as_ble_request(NSDictionary *input, NSError **error) {
  NSString *op = input[@"op"];
  if ([op isEqual:@"ble_start"]) {
    NSString *path =
        NSProcessInfo.processInfo.environment[@"ANKERSCALE_TEST_SCENARIO"];
    if (!path) {
      *error = as_failure(@"unexpected Bluetooth operation: ble_start");
      return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data)
      return nil;
    scenario = [NSJSONSerialization JSONObjectWithData:data
                                               options:0
                                                 error:error];
    if (!scenario)
      return nil;
    pending = [NSMutableArray array];
    attempts = [NSMutableDictionary dictionary];
    targets = input[@"devices"];
    emit(@{@"event" : @"power", @"state" : scenario[@"power"] ?: @5});
  } else if ([op isEqual:@"ble_poll"]) {
    if (!pending.count)
      usleep((useconds_t)MIN(10, [input[@"timeout_ms"] integerValue]) * 1000);
    NSArray *events = [pending copy];
    [pending removeAllObjects];
    return events;
  } else if ([op isEqual:@"ble_scan"]) {
    for (NSDictionary *value in scenario[@"devices"]) {
      if (targets && ![targets containsObject:value[@"device"]])
        continue;
      emit(@{
        @"event" : @"device",
        @"device" : value[@"device"],
        @"name" : value[@"name"],
        @"services" : value[@"services"],
        @"rssi" : value[@"rssi"] ?: @(-50),
        @"attempt" : @0
      });
    }
  } else if ([op isEqual:@"ble_targets"]) {
    targets = input[@"devices"];
  } else if ([op isEqual:@"ble_connect"]) {
    NSString *identifier = input[@"device"];
    attempts[identifier] = input[@"attempt"];
    NSDictionary *value = device(identifier);
    if (![value[@"failure"] isEqual:@"connect_timeout"])
      emit(@{
        @"event" : [value[@"failure"] isEqual:@"connect"] ? @"disconnected"
                                                          : @"connected",
        @"device" : identifier
      });
  } else if ([op isEqual:@"ble_discover"]) {
    NSDictionary *value = device(input[@"device"]);
    NSArray *services = [value[@"failure"] isEqual:@"profile"] ? @[] : @[ @{
      @"uuid" : @"FFF0",
      @"characteristics" : @[
        @{@"uuid" : @"FFF4",
          @"properties" : @16},
        @{@"uuid" : @"FFF1",
          @"properties" : @4}
      ]
    } ];
    emit(@{
      @"event" : @"profile",
      @"device" : input[@"device"],
      @"name" : value[@"profile_name"] ?: value[@"name"],
      @"services" : services
    });
    if ([value[@"failure"] isEqual:@"fatal_after_profile"])
      emit(@{
        @"event" : @"fatal",
        @"message" : @"test shared transport failure"
      });
  } else if ([op isEqual:@"ble_disconnect"]) {
    if ([device(input[@"device"])[@"packet_on_disconnect"] boolValue])
      emit(@{
        @"event" : @"packet",
        @"device" : input[@"device"],
        @"name" : @"eufy T9120",
        @"service" : @"FFF0",
        @"characteristic" : @"FFF4",
        @"direction" : @"rx",
        @"hex" : @"cfe812b414b3b69f00000f",
        @"session" : [attempts[input[@"device"]] stringValue]
      });
    if (![device(input[@"device"])[@"failure"] isEqual:@"disconnect_timeout"])
      emit(@{@"event" : @"disconnected", @"device" : input[@"device"]});
    if ([device(input[@"device"])[@"failure"]
            isEqual:@"fatal_after_disconnect"])
      emit(@{
        @"event" : @"fatal",
        @"message" : @"test shared transport failure"
      });
  } else if ([op isEqual:@"ble_subscribe"]) {
    emit(@{@"event" : @"subscribed", @"device" : input[@"device"]});
  } else if ([op isEqual:@"ble_write"]) {
    NSString *identifier = input[@"device"];
    emit(@{
      @"event" : @"packet",
      @"device" : identifier,
      @"name" : @"eufy T9120",
      @"service" : @"FFF0",
      @"characteristic" : @"FFF1",
      @"direction" : @"tx",
      @"hex" : input[@"hex"],
      @"session" : [attempts[identifier] stringValue]
    });
    if ([input[@"hex"] isEqual:@"f200"])
      emit(@{
        @"event" : @"packet",
        @"device" : identifier,
        @"name" : @"eufy T9120",
        @"service" : @"FFF0",
        @"characteristic" : @"FFF4",
        @"direction" : @"rx",
        @"hex" : @"cfe812b414b3b69f00000f",
        @"session" : [attempts[identifier] stringValue]
      });
  } else if ([op isEqual:@"ble_close"]) {
    trace(input);
    NSArray *events = [pending copy];
    [pending removeAllObjects];
    return events;
  } else if (![op isEqual:@"ble_stop_scan"] && ![op isEqual:@"ble_write"]) {
    *error = as_failure(
        [@"unknown test Bluetooth operation: " stringByAppendingString:op]);
    return nil;
  }
  trace(input);
  return NSNull.null;
}
