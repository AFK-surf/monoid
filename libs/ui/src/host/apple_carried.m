// What scripts/mbc carry took out of the program: an app's Bytes literal in a file of its own in the bundle's carried/,
// mapped as it is first read and kept (its pages are the file's, which the system drops and reads again).
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <moonbit.h>
#include <moonbit_runtime.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// The object the literal was: its header (a count that says it is never freed, its length), its bytes, a 0.
typedef struct {
  int32_t rc;
  uint32_t meta;
  uint8_t data[];
} Carried;

moonbit_bytes_t mbui_carried(char const *name, int32_t len) {
  static NSMutableDictionary<NSString *, NSValue *> *held;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ held = [NSMutableDictionary new]; });
  @autoreleasepool {
    @synchronized(held) {
      NSString *key = @(name);
      NSValue *was = held[key];
      if (was) return (moonbit_bytes_t)((Carried *)was.pointerValue)->data;
      NSString *path = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"carried"] stringByAppendingPathComponent:key];
      size_t size = sizeof(Carried) + (size_t)len + 1;
      int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
      struct stat st;
      void *p = MAP_FAILED;
      if (fd >= 0 && fstat(fd, &st) == 0 && (size_t)st.st_size == size) p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
      if (fd >= 0) close(fd);
      // (the bundle is signed whole: a file of it missing is no app)
      if (p == MAP_FAILED) {
        NSLog(@"mbui: %@ is not in the app as it was built", path);
        abort();
      }
      Carried *c = p;
      c->rc = Moonbit_make_static_rc(moonbit_BLOCK_KIND_VAL_ARRAY);
      c->meta = (uint32_t)len;
      held[key] = [NSValue valueWithPointer:p];
      return (moonbit_bytes_t)c->data;
    }
  }
}
