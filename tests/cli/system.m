#import "../../cmd/main/platform.h"

static NSString *testHomeDirectory(void) {
  NSString *path =
      NSProcessInfo.processInfo.environment[@"ANKERSCALE_TEST_HOME"];
  if (!path.length)
    abort();
  return path;
}

// Only this test executable substitutes the home directory. Production has no
// test environment switches and the CLI still uses its real filesystem code.
#define NSHomeDirectory testHomeDirectory
#include "../../cmd/main/system.m"
