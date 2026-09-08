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

static pid_t writerPID(NSError *_Nullable *_Nonnull error) {
  NSString *path = [as_data_directory()
      stringByAppendingPathComponent:@"records.sqlite3.lock"];
  int fd =
      open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    if (errno != ENOENT)
      *error = as_failure([NSString
          stringWithFormat:@"cannot read writer lock: %s", strerror(errno)]);
    return 0;
  }
  // Query without briefly taking the lock and racing a new collector.
  struct flock lock = {
      .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0};
  if (fcntl(fd, F_GETLK, &lock) != 0)
    *error = as_failure([NSString
        stringWithFormat:@"cannot inspect writer lock: %s", strerror(errno)]);
  close(fd);
  return lock.l_type != F_UNLCK ? lock.l_pid : 0;
}

static int launchctl(NSArray<NSString *> *arguments,
                     NSString *_Nullable *_Nullable outputText,
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
  NSString *description =
      [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
  if (outputText)
    *outputText = description;
  if (task.terminationStatus != 0 && task.terminationStatus != ESRCH) {
    *error = as_failure(description.length ? description : @"launchctl failed");
  }
  return task.terminationStatus;
}

id as_service_request(NSDictionary *input, NSError **error) {
  NSString *op = input[@"op"];
  NSString *directory = as_data_directory();
  NSString *config = [directory stringByAppendingPathComponent:@"devices.json"];
  NSFileManager *fm = NSFileManager.defaultManager;
  if ([op isEqual:@"service_log"]) {
    umask(0077);
    if (![fm createDirectoryAtPath:directory
            withIntermediateDirectories:YES
                             attributes:@{
                               NSFilePosixPermissions : @0700
                             }
                                  error:error])
      return nil;
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
    pid_t writer = writerPID(error);
    if (*error)
      return nil;
    return @{
      @"registration" : states[status],
      @"writer_active" : writer ? @YES : @NO,
      @"writer_pid" : writer ? @(writer) : NSNull.null,
      @"database" :
          [directory stringByAppendingPathComponent:@"records.sqlite3"],
      @"database_exists" :
          @([fm fileExistsAtPath:[directory stringByAppendingPathComponent:
                                                @"records.sqlite3"]]),
      @"config_exists" :
              ([fm fileExistsAtPath:config] ||
               [fm fileExistsAtPath:[directory stringByAppendingPathComponent:
                                                   @"service.json"]])
          ? @YES
          : @NO,
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
    int code = launchctl(@[ @"kill", @"SIGTERM", target ], NULL, error);
    return code == 0 ? @YES : @NO;
  }
  if ([op isEqual:@"service_kickstart"]) {
    NSString *output = nil;
    int code = launchctl(@[ @"kickstart", @"-p", target ], &output, error);
    if (code != 0) {
      if (!*error)
        *error = as_failure(@"registered launch agent was not found");
      return nil;
    }
    NSScanner *scanner = [NSScanner scannerWithString:output ?: @""];
    int pid = 0;
    if (![scanner scanInt:&pid] || !scanner.isAtEnd || pid <= 0) {
      *error = as_failure(@"launchctl did not return a valid service PID");
      return nil;
    }
    return @(pid);
  }
  *error = as_failure(@"unknown service operation");
  return nil;
}
