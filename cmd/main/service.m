#include "platform.h"
#import <ServiceManagement/ServiceManagement.h>
#include <errno.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const label = @"com.ph0ryn.AnkerScale.collector";
static NSString *const plist = @"com.ph0ryn.AnkerScale.collector.plist";

static BOOL bundled(NSError *_Nullable *_Nonnull error) {
  NSString *path = [NSBundle.mainBundle.bundlePath
      stringByAppendingPathComponent:[@"Contents/Library/LaunchAgents"
                                         stringByAppendingPathComponent:plist]];
  if (![NSBundle.mainBundle.bundleIdentifier
          isEqual:@"com.ph0ryn.AnkerScale"] ||
      ![NSFileManager.defaultManager fileExistsAtPath:path]) {
    *error = as_failure(@"service management requires the signed "
                        @"AnkerScale.app bundle; use result/bin/ankerscale");
    return NO;
  }
  return YES;
}

static BOOL writerActive(NSError *_Nullable *_Nonnull error) {
  NSString *path = [as_data_directory()
      stringByAppendingPathComponent:@"records.sqlite3.lock"];
  int fd =
      open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    if (errno != ENOENT)
      *error = as_failure([NSString
          stringWithFormat:@"cannot read writer lock: %s", strerror(errno)]);
    return NO;
  }
  // Query without briefly taking the lock and racing a new collector.
  struct flock lock = {
      .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0};
  if (fcntl(fd, F_GETLK, &lock) != 0)
    *error = as_failure([NSString
        stringWithFormat:@"cannot inspect writer lock: %s", strerror(errno)]);
  close(fd);
  return lock.l_type != F_UNLCK;
}

static int launchctl(NSArray<NSString *> *arguments,
                     NSError *_Nullable *_Nonnull error) {
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
  task.arguments = arguments;
  NSPipe *output = NSPipe.pipe;
  task.standardError = output;
  task.standardOutput = output;
  if (![task launchAndReturnError:error])
    return -1;
  NSData *message = [output.fileHandleForReading readDataToEndOfFile];
  [task waitUntilExit];
  if (task.terminationStatus != 0 && task.terminationStatus != ESRCH) {
    NSString *description =
        [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
    *error = as_failure(description.length ? description : @"launchctl failed");
  }
  return task.terminationStatus;
}

id as_service_request(NSDictionary *input, NSError **error) {
  NSString *op = input[@"op"];
  NSString *directory = as_data_directory();
  NSString *config = [directory stringByAppendingPathComponent:@"service.json"];
  NSFileManager *fm = NSFileManager.defaultManager;
  if ([op isEqual:@"service_config_read"]) {
    NSData *data = [NSData dataWithContentsOfFile:config options:0 error:error];
    if (!data)
      return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  }
  if ([op isEqual:@"service_config_write"] || [op isEqual:@"service_log"]) {
    umask(0077);
    if (![fm createDirectoryAtPath:directory
            withIntermediateDirectories:YES
                             attributes:@{
                               NSFilePosixPermissions : @0700
                             }
                                  error:error])
      return nil;
    if ([op isEqual:@"service_config_write"]) {
      NSData *data = [NSJSONSerialization
          dataWithJSONObject:@{@"device" : input[@"device"]}
                     options:NSJSONWritingPrettyPrinted
                       error:error];
      if (!data || ![data writeToFile:config
                              options:NSDataWritingAtomic
                                error:error])
        return nil;
      return NSNull.null;
    }
    NSString *path =
        [directory stringByAppendingPathComponent:@"collector.log"];
    int fd = open(path.fileSystemRepresentation,
                  O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
      *error = as_failure([NSString
          stringWithFormat:@"cannot open collector log: %s", strerror(errno)]);
      return nil;
    }
    if (dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0) {
      *error = as_failure(@"cannot redirect collector output");
      close(fd);
      return nil;
    }
    close(fd);
    setvbuf(stdout, NULL, _IOLBF, 0);
    fprintf(stderr, "%s collector starting (pid %d)\n", as_utc_now().UTF8String,
            getpid());
    return NSNull.null;
  }
  if ([op isEqual:@"service_wait"]) {
    usleep(100000);
    return NSNull.null;
  }
  if (!bundled(error))
    return nil;
  SMAppService *service = [SMAppService agentServiceWithPlistName:plist];
  if ([op isEqual:@"service_probe"]) {
    NSArray *states =
        @[ @"not_registered", @"enabled", @"requires_approval", @"not_found" ];
    SMAppServiceStatus status = service.status;
    BOOL active = writerActive(error);
    if (*error)
      return nil;
    return @{
      @"registration" : states[status],
      @"writer_active" : @(active),
      @"database" :
          [directory stringByAppendingPathComponent:@"records.sqlite3"],
      @"database_exists" :
          @([fm fileExistsAtPath:[directory stringByAppendingPathComponent:
                                                @"records.sqlite3"]]),
      @"config_exists" : @([fm fileExistsAtPath:config]),
      @"log" : [directory stringByAppendingPathComponent:@"collector.log"],
      @"bundle" : NSBundle.mainBundle.bundlePath
    };
  }
  if ([op isEqual:@"service_register"]) {
    [service registerAndReturnError:error];
    return NSNull.null;
  }
  if ([op isEqual:@"service_unregister"]) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *unregisterError = nil;
    [service unregisterWithCompletionHandler:^(NSError *result) {
      unregisterError = result;
      dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
      *error = as_failure(@"service unregistration timed out; inspect service "
                          @"status before retrying");
    } else {
      *error = unregisterError;
    }
    return NSNull.null;
  }
  NSString *target = [NSString stringWithFormat:@"gui/%u/%@", getuid(), label];
  if ([op isEqual:@"service_signal"]) {
    int code = launchctl(@[ @"kill", @"SIGTERM", target ], error);
    return @(code == 0);
  }
  if ([op isEqual:@"service_kickstart"]) {
    int code = launchctl(@[ @"kickstart", target ], error);
    if (code != 0 && !*error)
      *error = as_failure(@"registered launch agent was not found");
    return NSNull.null;
  }
  *error = as_failure(@"unknown service operation");
  return nil;
}
