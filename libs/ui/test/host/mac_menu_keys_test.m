// The app's menu is asked before the system's close item, with the canvas or a native page focused.
#import <Cocoa/Cocoa.h>
#include <stdio.h>

static int32_t (*window_key)(int32_t, int32_t);

@interface TestWindow : NSObject
@property(nonatomic) BOOL keyWindow;
@property(nonatomic, strong) id firstResponder;
@end
@implementation TestWindow
- (BOOL)isKeyWindow { return self.keyWindow; }
@end

@interface TestView : NSObject
@property(nonatomic, strong) TestWindow *window;
@end
@implementation TestView
@end
static TestView *the_view;

#include "mac_menu_keys.h"

@interface CloseSpy : NSObject
@property(nonatomic) int closed;
- (void)close:(id)sender;
@end
@implementation CloseSpy
- (void)close:(id)sender { (void)sender; self.closed++; }
@end

static int calls, accepted;
static int32_t take_key(int32_t code, int32_t mods) {
  calls++;
  return code == 1000 + 'w' && mods == 8 && accepted;
}

static int failed;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); failed = 1; } } while (0)

static NSEvent *key(NSString *characters, NSEventModifierFlags mods) {
  return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:0 windowNumber:0
                          context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:13];
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    TestWindow *window = [TestWindow new];
    window.keyWindow = YES;
    the_view = [TestView new];
    the_view.window = window;
    window_key = take_key;

    NSMenu *bar = [[NSMenu alloc] initWithTitle:@"bar"];
    MBShownKeysMenu *actions = [[MBShownKeysMenu alloc] initWithTitle:@"File"];
    NSMenuItem *file = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    file.submenu = actions;
    [bar addItem:file];
    NSMenu *windows = [[NSMenu alloc] initWithTitle:@"Window"];
    windows.autoenablesItems = NO;
    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    windowItem.submenu = windows;
    [bar addItem:windowItem];
    CloseSpy *spy = [CloseSpy new];
    NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(close:) keyEquivalent:@"w"];
    close.target = spy;
    close.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [windows addItem:close];
    NSEvent *cmdW = key(@"w", NSEventModifierFlagCommand);

    for (id focus in @[the_view, [NSObject new]]) {
      window.firstResponder = focus;
      accepted = 1;
      calls = 0;
      CHECK([bar performKeyEquivalent:cmdW]);
      CHECK(calls == 1 && spy.closed == 0);
      accepted = 0;
      calls = 0;
      CHECK([bar performKeyEquivalent:cmdW]);
      CHECK(calls == 1 && spy.closed == 1);
      spy.closed = 0;
    }
    window.firstResponder = the_view;
    calls = 0;
    CHECK(![actions performKeyEquivalent:key(@"w", NSEventModifierFlagCommand | NSEventModifierFlagShift)]);
    CHECK(calls == 0);
    window.keyWindow = NO;
    CHECK(![actions performKeyEquivalent:cmdW]);
    CHECK(calls == 0);
  }
  if (!failed) puts("mac menu keys: panel first, then the system close item");
  return failed;
}
