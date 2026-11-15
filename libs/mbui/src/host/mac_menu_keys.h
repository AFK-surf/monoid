// The canvas takes its own keys first. Offer ⌘W to the app before the system's close item; a native page with focus
// also offers window-wide keys to the app before the page. Included after the_view, window_key and the windows of the run (win_slots) are declared.
#ifndef MB_KEY_VIEW
#define MB_KEY_VIEW() the_view
#define MB_IN_KEY_WINDOW(call) call
#endif
@interface MBShownKeysMenu : NSMenu
@end
@implementation MBShownKeysMenu
- (BOOL)performKeyEquivalent:(NSEvent *)e {
  // (the key window's view, whichever window of the run it is, put in place for the app's asking: the includer's
  // MB_KEY_VIEW and MB_IN_KEY_WINDOW, mac_app.m's win_use; else the one view)
  __typeof__(the_view) kv = MB_KEY_VIEW();
  if (!window_key || e.type != NSEventTypeKeyDown || !kv.window.isKeyWindow)
    return NO;
  NSEventModifierFlags m = e.modifierFlags;
  int mods = ((m & NSEventModifierFlagShift) ? 1 : 0) | ((m & NSEventModifierFlagControl) ? 2 : 0) |
             ((m & NSEventModifierFlagOption) ? 4 : 0) | ((m & NSEventModifierFlagCommand) ? 8 : 0);
  int code = e.keyCode == 123 ? 3 : e.keyCode == 124 ? 4 : e.keyCode == 126 ? 5 : e.keyCode == 125 ? 6 :
             e.keyCode == 36 || e.keyCode == 76 ? 7 : e.keyCode == 53 ? 17 : 0;
  if (!code) {
    NSString *key = e.charactersIgnoringModifiers.lowercaseString;
    if (key.length == 1) code = 1000 + [key characterAtIndex:0];
  }
  if (kv.window.firstResponder == kv && !(code == 1000 + 'w' && mods == 8)) return NO;
  if (!code) return NO;
  __block BOOL taken = NO;
  MB_IN_KEY_WINDOW(taken = window_key(code, mods) != 0);
  return taken;
}
@end
