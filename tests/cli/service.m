#import "../../cmd/main/platform.h"
#include <fcntl.h>
#include <unistd.h>

static pid_t writerPID(void) {
  NSString *path = [as_data_directory()
      stringByAppendingPathComponent:@"records.sqlite3.lock"];
  int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0)
    return 0;
  struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
  if (fcntl(fd, F_GETLK, &lock) != 0)
    abort();
  close(fd);
  return lock.l_type != F_UNLCK ? lock.l_pid : 0;
}

id as_service_request(NSDictionary *input, NSError **error) {
  NSString *op = input[@"op"];
  NSString *directory = as_data_directory();
  NSString *statePath =
      [directory stringByAppendingPathComponent:@"service-state"];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *state =
      [fm fileExistsAtPath:statePath]
          ? [NSString stringWithContentsOfFile:statePath
                                      encoding:NSUTF8StringEncoding
                                         error:error]
          : @"not_registered";
  if (*error)
    return nil;
  if ([op isEqual:@"service_probe"]) {
    pid_t writer = writerPID();
    NSString *db =
        [directory stringByAppendingPathComponent:@"records.sqlite3"];
    return @{
      @"registration" : state,
      @"writer_active" : writer ? @YES : @NO,
      @"writer_pid" : writer ? @(writer) : NSNull.null,
      @"database" : db,
      @"database_exists" : @([fm fileExistsAtPath:db]),
      @"config_exists" :
          @([fm fileExistsAtPath:[directory stringByAppendingPathComponent:
                                                @"devices.json"]]),
      @"log" : [directory stringByAppendingPathComponent:@"collector.log"],
      @"bundle" : @"test-only"
    };
  }
  if ([op isEqual:@"service_register"] || [op isEqual:@"service_unregister"]) {
    NSString *next =
        [op isEqual:@"service_register"] ? @"enabled" : @"not_registered";
    [next writeToFile:statePath
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:error];
    return NSNull.null;
  }
  if ([op isEqual:@"service_signal"])
    return @NO;
  if ([op isEqual:@"service_wait"]) {
    usleep(100000);
    return NSNull.null;
  }
  if ([op isEqual:@"service_kickstart"] || [op isEqual:@"service_log"])
    return NSNull.null;
  *error = as_failure(
      [@"unexpected service operation: " stringByAppendingString:op]);
  return nil;
}
