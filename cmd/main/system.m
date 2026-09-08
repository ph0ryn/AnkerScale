#include "moonbit.h"
#include "platform.h"
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <sqlite3.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *dbError;
static volatile sig_atomic_t stopping;
static int writerLock = -1;

static NSString *text(moonbit_bytes_t bytes) {
  return [[NSString alloc] initWithBytes:bytes
                                  length:Moonbit_array_length(bytes)
                                encoding:NSUTF8StringEncoding];
}

static moonbit_bytes_t bytes(NSData *data) {
  moonbit_bytes_t result = moonbit_make_bytes_raw((int32_t)data.length);
  memcpy(result, data.bytes, data.length);
  return result;
}

static moonbit_bytes_t reply(id value, NSError *error) {
  NSDictionary *envelope = error ? @{@"error" : error.localizedDescription}
                                 : @{@"ok" : value ?: NSNull.null};
  return bytes([NSJSONSerialization dataWithJSONObject:envelope
                                               options:0
                                                 error:NULL]);
}

NSError *as_failure(NSString *message) {
  return [NSError errorWithDomain:@"AnkerScale"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

static NSDictionary *request(moonbit_bytes_t raw, NSError **error) {
  id value = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithBytes:raw
                                        length:Moonbit_array_length(raw)]
                 options:0
                   error:error];
  if (value && ![value isKindOfClass:NSDictionary.class]) {
    *error = as_failure(@"request must be an object");
    return nil;
  }
  return value;
}

void *as_db_open(moonbit_bytes_t raw, int writable) {
  @autoreleasepool {
    sqlite3 *db = NULL;
    NSString *path = text(raw);
    int flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
                         : SQLITE_OPEN_READONLY;
    int code = sqlite3_open_v2(path.fileSystemRepresentation, &db, flags, NULL);
    if (code != SQLITE_OK) {
      dbError = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
      sqlite3_close(db);
      return NULL;
    }
    sqlite3_busy_timeout(db, 3000);
    sqlite3_extended_result_codes(db, 1);
    return db;
  }
}

int as_db_valid(void *db) { return db != NULL; }
moonbit_bytes_t as_db_error(void) {
  @autoreleasepool {
    return bytes([dbError dataUsingEncoding:NSUTF8StringEncoding]);
  }
}
void as_db_close(void *db) { sqlite3_close(db); }

moonbit_bytes_t as_db_query(void *handle, moonbit_bytes_t raw) {
  @autoreleasepool {
    NSError *error = nil;
    NSDictionary *input = request(raw, &error);
    if (!input)
      return reply(nil, error);
    sqlite3 *db = handle;
    sqlite3_stmt *statement = NULL;
    const char *tail = NULL;
    int code = sqlite3_prepare_v2(db, [input[@"sql"] UTF8String], -1,
                                  &statement, &tail);
    if (code == SQLITE_OK && (!statement || (tail && *tail))) {
      sqlite3_finalize(statement);
      return reply(nil, as_failure(@"exactly one SQL statement is required"));
    }
    NSArray *args = input[@"args"];
    if (code == SQLITE_OK &&
        (int)args.count != sqlite3_bind_parameter_count(statement)) {
      sqlite3_finalize(statement);
      return reply(nil, as_failure(@"SQL parameter count mismatch"));
    }
    for (NSUInteger i = 0; code == SQLITE_OK && i < args.count; i++) {
      id arg = args[i];
      if (arg == NSNull.null)
        code = sqlite3_bind_null(statement, (int)i + 1);
      else if ([arg isKindOfClass:NSString.class])
        code = sqlite3_bind_text(
            statement, (int)i + 1, [arg UTF8String],
            (int)[arg lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
            SQLITE_TRANSIENT);
      else if ([arg isKindOfClass:NSNumber.class])
        code = sqlite3_bind_int64(statement, (int)i + 1, [arg longLongValue]);
      else {
        sqlite3_finalize(statement);
        return reply(nil, as_failure(@"unsupported SQL parameter"));
      }
    }
    NSMutableArray *rows = [NSMutableArray array];
    if (code == SQLITE_OK) {
      while ((code = sqlite3_step(statement)) == SQLITE_ROW) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (int i = 0; i < sqlite3_column_count(statement); i++) {
          NSString *key =
              [NSString stringWithUTF8String:sqlite3_column_name(statement, i)];
          switch (sqlite3_column_type(statement, i)) {
          case SQLITE_NULL:
            row[key] = NSNull.null;
            break;
          case SQLITE_INTEGER:
            row[key] = @(sqlite3_column_int64(statement, i));
            break;
          case SQLITE_FLOAT:
            row[key] = @(sqlite3_column_double(statement, i));
            break;
          case SQLITE_TEXT:
            row[key] = [[NSString alloc]
                initWithBytes:sqlite3_column_text(statement, i)
                       length:sqlite3_column_bytes(statement, i)
                     encoding:NSUTF8StringEncoding];
            break;
          default:
            sqlite3_finalize(statement);
            return reply(nil, as_failure(@"unexpected SQLite blob column"));
          }
        }
        [rows addObject:row];
      }
    }
    if (code != SQLITE_DONE)
      error = as_failure([NSString stringWithUTF8String:sqlite3_errmsg(db)]);
    int finalCode = sqlite3_finalize(statement);
    if (!error && finalCode != SQLITE_OK)
      error = as_failure([NSString stringWithUTF8String:sqlite3_errmsg(db)]);
    return reply(rows, error);
  }
}

static void signalStop(int sig) {
  (void)sig;
  stopping = 1;
}

double as_monotonic_ms(void) {
  mach_timebase_info_data_t info;
  mach_timebase_info(&info);
  return (double)mach_continuous_time() * info.numer / info.denom / 1000000.0;
}

NSString *as_utc_now(void) {
  NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  return [formatter stringFromDate:NSDate.date];
}

NSString *as_data_directory(void) {
  return [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/AnkerScale"];
}

moonbit_bytes_t as_system_call(moonbit_bytes_t raw) {
  @autoreleasepool {
    NSError *error = nil;
    NSDictionary *input = request(raw, &error);
    if (!input)
      return reply(nil, error);
    NSString *op = input[@"op"];
    if ([op hasPrefix:@"ble_"]) {
      id value = as_ble_request(input, &error);
      return reply(value, error);
    }
    if ([op hasPrefix:@"service_"]) {
      id value = as_service_request(input, &error);
      return reply(value, error);
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([op isEqual:@"paths"])
      return reply(@{
        @"data" : as_data_directory(),
        @"db" : [as_data_directory()
            stringByAppendingPathComponent:@"records.sqlite3"]
      },
                   nil);
    if ([op isEqual:@"uuid"])
      return reply(NSUUID.UUID.UUIDString, nil);
    if ([op isEqual:@"validate_device"]) {
      NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:input[@"device"]];
      return uuid ? reply(uuid.UUIDString, nil)
                  : reply(nil, as_failure(@"device must be a CoreBluetooth "
                                          @"UUID from devices"));
    }
    if ([op isEqual:@"now"]) {
      NSCalendar *calendar = [[NSCalendar alloc]
          initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
      calendar.timeZone = NSTimeZone.localTimeZone;
      NSDateComponents *c =
          [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth |
                               NSCalendarUnitDay | NSCalendarUnitHour |
                               NSCalendarUnitMinute | NSCalendarUnitSecond
                      fromDate:NSDate.date];
      return reply(
          @{
            @"utc" : as_utc_now(),
            @"mono_ms" : @((int64_t)as_monotonic_ms()),
            @"local" : @[
              @(c.year), @(c.month), @(c.day), @(c.hour), @(c.minute),
              @(c.second)
            ]
          },
          nil);
    }
    if ([op isEqual:@"date"]) {
      NSString *value = input[@"value"];
      NSDateFormatter *f = [NSDateFormatter new];
      f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
      f.calendar = [[NSCalendar alloc]
          initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
      f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
      f.lenient = NO;
      f.dateFormat =
          value.length == 10
              ? @"yyyy-MM-dd"
              : (value.length == 20 ? @"yyyy-MM-dd'T'HH:mm:ss'Z'"
                                    : @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");
      NSDate *date = [f dateFromString:value];
      if (!date || ![[f stringFromDate:date] isEqual:value])
        return reply(
            nil,
            as_failure(
                @"date must be YYYY-MM-DD or UTC YYYY-MM-DDTHH:mm:ss[.SSS]Z"));
      f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
      return reply([f stringFromDate:date], nil);
    }
    if ([op isEqual:@"prepare_directory"]) {
      NSString *directory = [input[@"path"] stringByDeletingLastPathComponent];
      if (!directory.length)
        directory = @".";
      [fm createDirectoryAtPath:directory
          withIntermediateDirectories:YES
                           attributes:@{
                             NSFilePosixPermissions : @0700
                           }
                                error:&error];
      return reply(nil, error);
    }
    if ([op isEqual:@"read"]) {
      NSString *value = [NSString stringWithContentsOfFile:input[@"path"]
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
      return reply(value, error);
    }
    if ([op isEqual:@"lock"]) {
      umask(0077);
      writerLock = open([input[@"path"] fileSystemRepresentation],
                        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
      struct flock lock = {
          .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0};
      if (writerLock < 0 || fcntl(writerLock, F_SETLK, &lock) != 0) {
        if (writerLock >= 0)
          close(writerLock);
        writerLock = -1;
        return reply(nil, as_failure(@"cannot acquire writer lock; another "
                                     @"collector may be running"));
      }
      signal(SIGINT, signalStop);
      signal(SIGTERM, signalStop);
      return reply(nil, nil);
    }
    if ([op isEqual:@"unlock"]) {
      if (writerLock >= 0)
        close(writerLock);
      writerLock = -1;
      return reply(nil, nil);
    }
    if ([op isEqual:@"stopping"])
      return reply(@(stopping != 0), nil);
    return reply(nil, as_failure([@"unknown OS operation: "
                          stringByAppendingString:op]));
  }
}

void as_stderr(moonbit_bytes_t raw) {
  fwrite(raw, 1, Moonbit_array_length(raw), stderr);
  fflush(stderr);
}
