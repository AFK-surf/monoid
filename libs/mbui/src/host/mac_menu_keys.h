// The canvas takes its own keys first. Offer ⌘W to the app before the system's close item; a native page with focus
// also offers window-wide keys to the app before the page. Included after the_view and window_key are declared.
@interface MBShownKeysMenu : NSMenu
@end
@implementation MBShownKeysMenu
- (BOOL)performKeyEquivalent:(NSEvent *)e {
  if (!window_key || e.type != NSEventTypeKeyDown || !the_view.window.isKeyWindow)
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
  if (the_view.window.firstResponder == the_view && !(code == 1000 + 'w' && mods == 8)) return NO;
  return code && window_key(code, mods);
}
@end
