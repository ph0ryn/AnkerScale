#include "platform.h"
#include <errno.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static int registryLock = -1;

static id readRegistryFile(NSString *path, BOOL *exists, NSError **error) {
  NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
  if (!data) {
    if ([(*error).domain isEqual:NSCocoaErrorDomain] &&
        ((*error).code == NSFileReadNoSuchFileError ||
         (*error).code == NSFileNoSuchFileError)) {
      *error = nil;
      *exists = NO;
    }
    return nil;
  }
  *exists = YES;
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
}

id as_registry_request(NSDictionary *input, NSError **error) {
  NSString *op = input[@"op"];
  NSString *directory = as_data_directory();
  NSString *path = [directory stringByAppendingPathComponent:@"devices.json"];
  if ([op isEqual:@"registry_read"]) {
    BOOL exists = NO;
    id value = readRegistryFile(path, &exists, error);
    if (*error)
      return nil;
    if (exists)
      return @{@"source" : @"current", @"value" : value};
    if ([input[@"allow_legacy"] boolValue]) {
      value = readRegistryFile(
          [directory stringByAppendingPathComponent:@"service.json"], &exists,
          error);
      if (*error)
        return nil;
      if (exists)
        return @{@"source" : @"legacy", @"value" : value};
    }
    return @{@"source" : @"missing"};
  }
  if ([op isEqual:@"registry_lock"]) {
    if (registryLock >= 0) {
      *error = as_failure(@"device registration is already locked");
      return nil;
    }
    umask(0077);
    if (![NSFileManager.defaultManager
                  createDirectoryAtPath:directory
            withIntermediateDirectories:YES
                             attributes:@{
                               NSFilePosixPermissions : @0700
                             }
                                  error:error])
      return nil;
    NSString *lockPath =
        [directory stringByAppendingPathComponent:@"devices.lock"];
    int fd = open(lockPath.fileSystemRepresentation,
                  O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
      *error = as_failure(
          [NSString stringWithFormat:@"cannot open registration lock: %s",
                                     strerror(errno)]);
      return nil;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
      int reason = errno;
      close(fd);
      *error = as_failure([NSString
          stringWithFormat:@"cannot acquire registration lock; another "
                           @"registration operation may be running: %s",
                           strerror(reason)]);
      return nil;
    }
    registryLock = fd;
    return NSNull.null;
  }
  if ([op isEqual:@"registry_unlock"]) {
    if (registryLock >= 0)
      close(registryLock);
    registryLock = -1;
    return NSNull.null;
  }
  if ([op isEqual:@"registry_write"]) {
    if (registryLock < 0) {
      *error = as_failure(@"device registration must be locked before writing");
      return nil;
    }
    NSData *data = [NSJSONSerialization
        dataWithJSONObject:input[@"value"]
                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                     error:error];
    if (!data || ![data writeToFile:path
                            options:NSDataWritingAtomic
                              error:error])
      return nil;
    return NSNull.null;
  }
  *error = as_failure(@"unknown registry operation");
  return nil;
}
