// This machine's station on macOS: the app's own native call (`local_station`, `local_station_act`: app_calls.h),
// the station being still.fail's and nothing of mbui's. Included by src/stillfail/core_engine.m on macOS.
#import <Cocoa/Cocoa.h>
#include <pwd.h>
#include <signal.h>
#include <libproc.h>
#include <sys/socket.h>
#include <sys/un.h>
#import "apple.h"
// (mbui's, beside its host: moon compiles this app's stub with no include path of mbui's)
#include "../../../../libs/ui/src/host/post_api.h"
#include "../../../../libs/ui/src/host/mini_json.h"
#include "station_install.h"  // what the installer is handed

// What it says changed (a step of the installer, an act done): a message posted on the app's channel for it, which
// builds the next frame whole (@ui.on_message's), as a frame asked for did when this was the host's.
static void station_changed(void) { mb_post("local_station", "{}", 2, NULL, 0); }

// This machine's station (the app's own call `local_station`, src/host/app_calls.h; apps/desktop/src/main.ts
// localStation): its data
// (~/.stillfail), whether it runs (run/station.json's pid alive) and by what (a launchd service the installer made, or a
// process started by hand), its release, whether the installer put one there, the workspace its data is in; what is
// being done to it and what went wrong last. "" where there is neither data nor a service. Its acts (`local_station_act`) run off the main thread:
// start, stop, restart (the service's launchctl, a hand-started one only stopped), the log or the folder opened.
static NSString *local_doing = nil;
static NSString *local_failed = nil;
static int local_percent = -1;   // how far the installer's download is (local_heard, below), -1 not said
static NSString *local_said = nil; // the last step the installer said
// (another product's app, its station's own: MBUI_STATION_ID's directory, MBUI_STATION_LABEL's service; cloud/src/
// install.ts names them so, monoid's ~/.monoid and build.monoid.station beside still.fail's)
static NSString *local_env(const char *name, NSString *otherwise) {
  const char *v = getenv(name);
  return v && *v ? @(v) : otherwise;
}
static NSString *local_data(void) {
  return [NSHomeDirectory() stringByAppendingPathComponent:[@"." stringByAppendingString:local_env("MBUI_STATION_ID", @"stillfail")]];
}
static NSString *local_service(void) {
  NSString *own = local_env("MBUI_STATION_LABEL", @"fail.still.station");
  NSArray *labels = [own isEqualToString:@"fail.still.station"] ? @[ own, @"org.3720.ember.station" ] : @[ own ];
  for (NSString *label in labels) {
    NSString *plist = [NSString stringWithFormat:@"%@/Library/LaunchAgents/%@.plist", NSHomeDirectory(), label];
    if ([NSFileManager.defaultManager fileExistsAtPath:plist]) return label;
  }
  return nil;
}
static NSDictionary *local_json(NSString *path) {
  NSData *d = [NSData dataWithContentsOfFile:path];
  if (!d) return nil;
  id v = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  return [v isKindOfClass:NSDictionary.class] ? v : nil;
}
static pid_t local_pid(NSString *data, NSString **version) {
  NSDictionary *s = local_json([data stringByAppendingPathComponent:@"run/station.json"]);
  id pid = s[@"pid"];
  if (![pid isKindOfClass:NSNumber.class] || [pid intValue] <= 0) return 0;
  if (kill([pid intValue], 0) != 0 && errno != EPERM) return 0;
  if ([s[@"version"] isKindOfClass:NSString.class]) *version = s[@"version"];
  return [pid intValue];
}
// Where its data is when it was moved (bin/stillfail's move: ~/.stillfail a link to it), nil where it is not a link.
static NSString *local_moved_to(NSString *data) {
  return [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:data error:nil];
}
// Whether its release's command moves its data (bin/stillfail's `move`, a release from before has none).
static BOOL local_moves(NSString *data) {
  NSString *command = [NSString stringWithContentsOfFile:[data stringByAppendingPathComponent:@"app/bin/stillfail"] encoding:NSUTF8StringEncoding error:nil];
  return [command containsString:@"stillfail move <folder>"];
}
static moonbit_string_t sf_station_said(void) {
  // An isolated end-to-end run must not inspect the person's installed station.
  if (getenv("MBUI_ISOLATED_STATION")) return mb_string_from_ns(@"");
  NSString *data = local_data();
  NSString *service = local_service();
  NSString *moved = local_moved_to(data);
  // (moved to a disk not connected: its link is there, what it names not)
  BOOL there = [NSFileManager.defaultManager fileExistsAtPath:data] || moved != nil;
  // none here, and nothing being done or gone wrong about it: ""; one being installed is said before it is there
  if (!there && !service && !local_doing && !local_failed) return mb_string_from_ns(@"");
  NSString *version = nil;
  pid_t pid = local_pid(data, &version);
  NSMutableDictionary *o = [NSMutableDictionary dictionary];
  if (there || service) o[@"data"] = [data stringByAbbreviatingWithTildeInPath];
  if (moved) {
    o[@"at"] = [moved stringByAbbreviatingWithTildeInPath];
    if (![NSFileManager.defaultManager fileExistsAtPath:data]) o[@"away"] = @YES;
  }
  if (local_moves(data)) o[@"moves"] = @YES;
  o[@"runner"] = pid == 0 ? @"none" : service ? @"service" : @"other";
  if (!version && service) {
    NSString *build = [NSString stringWithContentsOfFile:[data stringByAppendingPathComponent:@"app/BUILD"] encoding:NSUTF8StringEncoding error:nil];
    build = [build stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (build.length) version = [@"0.1." stringByAppendingString:build];
  }
  if (version) o[@"version"] = version;
  // a release of its own (<data>/app: the installer's); a station still.fail's desktop app ran from its bundle has none
  if ([NSFileManager.defaultManager fileExistsAtPath:[data stringByAppendingPathComponent:@"app"]]) o[@"installed"] = @YES;
  if (service) o[@"service"] = @{ @"kind" : @"launchd", @"name" : service };
  // taken away here (stillfail uninstall, or 卸载本机 Station), its data kept: never brought back unasked
  if ([NSFileManager.defaultManager fileExistsAtPath:[data stringByAppendingPathComponent:@"uninstalled"]]) o[@"uninstalled"] = @YES;
  NSDictionary *c = local_json([data stringByAppendingPathComponent:@"mesh/cloud.json"]);
  if ([c[@"workspace"] isKindOfClass:NSString.class] && [c[@"workspace"] length]) {
    NSMutableDictionary *w = [NSMutableDictionary dictionaryWithObject:c[@"workspace"] forKey:@"id"];
    for (NSString *k in @[ @"workspace_name", @"station", @"name" ]) {
      if ([c[k] isKindOfClass:NSString.class] && [c[k] length]) w[[k isEqualToString:@"workspace_name"] ? @"name" : [k isEqualToString:@"name"] ? @"stationName" : k] = c[k];
    }
    w[@"removed"] = @(c[@"removed_at"] != nil && c[@"removed_at"] != NSNull.null);
    // a machine that only runs tasks (enroll --rig): in that one workspace, never enrolled as a station beside it
    if ([c[@"rig"] isKindOfClass:NSDictionary.class]) w[@"rig"] = @YES;
    o[@"workspace"] = w;
  }
  if (local_doing) {
    o[@"doing"] = local_doing;
    if (local_percent >= 0) o[@"percent"] = @(local_percent);
    if (local_said) o[@"said"] = local_said;
  }
  if (local_failed) o[@"failed"] = local_failed;
  NSData *json = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
  return mb_string_from_ns(json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"");
}
// launchctl with these arguments: nil when it did, else what it said last.
static NSString *local_launchctl(NSArray<NSString *> *args) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
  t.arguments = args;
  NSPipe *out = [NSPipe pipe];
  t.standardOutput = out;
  t.standardError = out;
  NSError *e = nil;
  if (![t launchAndReturnError:&e]) return e.localizedDescription ?: @"launchctl";
  NSData *said = [out.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  if (t.terminationStatus == 0) return nil;
  NSString *s = [[NSString alloc] initWithData:said encoding:NSUTF8StringEncoding] ?: @"";
  s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return s.length ? s : [NSString stringWithFormat:@"launchctl %d", t.terminationStatus];
}
// The person's login shell's PATH and proxy variables, read once (as still.fail's desktop app reads them: station.ts
// ofShell): an app opened from the Finder or the Dock has neither, and the station the installer sets up runs with the
// PATH it is installed from (where the agents are found: nvm's Node, Homebrew's). A shell that does not answer in 5 s
// gives nothing.
static NSDictionary<NSString *, NSString *> *login_env(void) {
  static NSDictionary *env;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *shell = NSProcessInfo.processInfo.environment[@"SHELL"];
    if (!shell.length) {
      struct passwd *pw = getpwuid(getuid());
      shell = pw && pw->pw_shell ? @(pw->pw_shell) : @"/bin/zsh";
    }
    NSString *mark = @"__stillfail_env__";
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:shell];
    t.arguments = @[ @"-ilc", [NSString stringWithFormat:@"printf '%@'; env; printf '%@'", mark, mark] ];
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    NSMutableDictionary *got = [NSMutableDictionary dictionary];
    if ([t launchAndReturnError:nil]) {
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      __block NSData *said = nil;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        said = [out.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_signal(done);
      });
      if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        [t terminate];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
      }
      NSString *s = [[NSString alloc] initWithData:said ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
      NSArray<NSString *> *parts = [s componentsSeparatedByString:mark];
      if (parts.count >= 3) {
        for (NSString *line in [parts[1] componentsSeparatedByString:@"\n"]) {
          NSRange eq = [line rangeOfString:@"="];
          if (eq.location == NSNotFound) continue;
          NSString *k = [line substringToIndex:eq.location];
          if ([k isEqualToString:@"PATH"] || [k.lowercaseString hasSuffix:@"_proxy"])
            got[k] = [line substringFromIndex:eq.location + 1];
        }
      }
    }
    env = got;
  });
  return env;
}

// The station's installer (still.fail cloud's /install.sh, as 添加 station hands it out and still.fail's desktop app
// runs it: cloud/src/install.ts), run here as the person would in a terminal (their shell's PATH and proxies): with a
// token (`install`: one-time, for a workspace: the core's workspace.enroll) it downloads the release, puts it in
// ~/.stillfail/app, joins the workspace and runs the station as a launchd service; without one (`update`) it brings the
// station here up to the latest release and runs it as a service (a station's data with none, as the desktop app ran
// it, becomes one). `ask`: {"origin", "token"?, "lock"? (a safe-mode workspace's lock's hash, which the station pins
// rather than take the cloud's word: workspace.enroll's `lock`), "channel": stable | beta}. nil when it did, else the
// last it said.
// How far it is, as it goes (local_station's `percent` and `said`): the percent its downloads' curl shows
// (--progress-bar: "#### 45.2%", each redrawn after a \r), and the last other line it said (its step: downloading,
// installing, starting): local_percent, local_said (above).

static void local_heard(NSData *piece) {
  NSString *s = [[NSString alloc] initWithData:piece encoding:NSUTF8StringEncoding];
  s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!s.length) return;
  static NSRegularExpression *bar;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ bar = [NSRegularExpression regularExpressionWithPattern:@"^#*\\s*([0-9]+(\\.[0-9]+)?)%$" options:0 error:nil]; });
  NSTextCheckingResult *m = [bar firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
  int percent = m ? [[s substringWithRange:[m rangeAtIndex:1]] intValue] : -1;
  if (!m && [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"#"] invertedSet]].location == NSNotFound) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (m) {
      local_percent = percent;
    } else {
      local_said = s;
      local_percent = -1;
    }
    station_changed();
  });
}

static NSString *local_install(NSString *json) {
  // (what it is handed: station_install.h, held by its test)
  station_ask ask;
  if (!station_ask_read(json.UTF8String, &ask)) return @"origin";
  const char *argv[8];
  int argc = station_mac_args(&ask, argv);
  NSMutableArray *args = [NSMutableArray array];
  for (int i = 0; i < argc; i++) [args addObject:@(argv[i])];
  NSString *token = @(ask.token);
  BOOL beta = ask.beta;
  station_ask_free(&ask);
  NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
  [env addEntriesFromDictionary:login_env()];
  if (beta) env[@"STILLFAIL_CHANNEL"] = @"beta";
  // (this app's own station, never one a STILLFAIL_DATA the app was started with names)
  env[@"STILLFAIL_DATA"] = local_data();
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
  t.arguments = args;
  t.environment = env;
  t.standardInput = [NSFileHandle fileHandleWithNullDevice];
  NSPipe *out = [NSPipe pipe];
  t.standardOutput = out;
  t.standardError = out;
  NSError *e = nil;
  if (![t launchAndReturnError:&e]) return e.localizedDescription ?: @"sh";
  // what it says as it says it: each piece ended by a \r (curl's bar redrawn) or a \n heard (local_heard)
  NSMutableData *said = [NSMutableData data];
  NSUInteger from = 0;
  for (;;) {
    NSData *d = [out.fileHandleForReading availableData];
    if (d.length == 0) break;
    [said appendData:d];
    const uint8_t *b = (const uint8_t *)said.bytes;
    for (NSUInteger i = from; i < said.length; i++) {
      if (b[i] != '\r' && b[i] != '\n') continue;
      local_heard([said subdataWithRange:NSMakeRange(from, i - from)]);
      from = i + 1;
    }
  }
  [t waitUntilExit];
  NSString *s = [[NSString alloc] initWithData:said encoding:NSUTF8StringEncoding] ?: @"";
  fprintf(stdout, "mac: the station's installer (%s) exited %d\n%s\n", token.length ? "install" : "update",
          t.terminationStatus, s.UTF8String);
  fflush(stdout);
  if (t.terminationStatus == 0) return nil;
  NSString *last = @"";
  for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
    NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (l.length) last = l;
  }
  return last.length ? last : [NSString stringWithFormat:@"install.sh %d", t.terminationStatus];
}

// 更改存储位置: its data moved into `folder` by its release's own command (bin/stillfail's `move`), as the person would
// run it (their shell's PATH; its data named, this app's own: never another's STILLFAIL_DATA), what it says of the copy
// shown as it goes (its "NN%" lines: local_percent). nil when it did, else "move.<its exit>" (2 to 8: bin/stillfail says
// each), or "move:" and the last it said.
static NSString *local_move(NSString *data, NSString *folder) {
  NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
  [env addEntriesFromDictionary:login_env()];
  env[@"STILLFAIL_DATA"] = data;
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
  t.arguments = @[ [data stringByAppendingPathComponent:@"app/bin/stillfail"], @"move", folder ];
  t.environment = env;
  t.standardInput = [NSFileHandle fileHandleWithNullDevice];
  NSPipe *out = [NSPipe pipe];
  t.standardOutput = out;
  t.standardError = out;
  NSError *e = nil;
  if (![t launchAndReturnError:&e]) return [@"move:" stringByAppendingString:e.localizedDescription ?: @"sh"];
  NSMutableData *said = [NSMutableData data];
  NSUInteger from = 0;
  for (;;) {
    NSData *d = [out.fileHandleForReading availableData];
    if (d.length == 0) break;
    [said appendData:d];
    const uint8_t *b = (const uint8_t *)said.bytes;
    for (NSUInteger i = from; i < said.length; i++) {
      if (b[i] != '\n') continue;
      NSString *line = [[NSString alloc] initWithData:[said subdataWithRange:NSMakeRange(from, i - from)] encoding:NSUTF8StringEncoding];
      from = i + 1;
      if ([line hasSuffix:@"%"] && line.intValue >= 0 && line.length <= 4) {
        int percent = line.intValue;
        dispatch_async(dispatch_get_main_queue(), ^{
          local_percent = percent;
          station_changed();
        });
      }
    }
  }
  [t waitUntilExit];
  NSString *s = [[NSString alloc] initWithData:said encoding:NSUTF8StringEncoding] ?: @"";
  fprintf(stdout, "mac: the station's move exited %d\n%s\n", t.terminationStatus, s.UTF8String);
  fflush(stdout);
  int code = t.terminationStatus;
  if (code == 0) return nil;
  if (code >= 2 && code <= 8) return [NSString stringWithFormat:@"move.%d", code];
  NSString *last = @"";
  for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
    NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (l.length) last = l;
  }
  return [@"move:" stringByAppendingString:last.length ? last : [NSString stringWithFormat:@"%d", code]];
}

// still.fail Helper (station/native/helper: the macOS app the station starts) told to quit, on its socket with its token
// (main.swift's `quit`): what answers in 3 s, or nothing.
static void local_helper_quit(NSString *data) {
  NSString *helper = [data stringByAppendingPathComponent:@"helper"];
  NSString *token = [NSString stringWithContentsOfFile:[helper stringByAppendingPathComponent:@"token"] encoding:NSUTF8StringEncoding error:nil];
  token = [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  const char *path = [helper stringByAppendingPathComponent:@"helper.sock"].fileSystemRepresentation;
  struct sockaddr_un at = {.sun_family = AF_UNIX};
  if (!token.length || strlen(path) >= sizeof at.sun_path) return;
  strlcpy(at.sun_path, path, sizeof at.sun_path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return;
  struct timeval most = {3, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &most, sizeof most);
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &most, sizeof most);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  if (connect(fd, (struct sockaddr *)&at, sizeof at) == 0) {
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:@{@"token" : token, @"op" : @"quit"} options:0 error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    if (write(fd, line.bytes, line.length) == (ssize_t)line.length) {
      char answer[256];
      (void)read(fd, answer, sizeof answer);
    }
  }
  close(fd);
}

// 卸载本机 Station (bin/stillfail's uninstall, the same here): its launchd service gone (booted out, its disabling
// cleared, its plist removed), what still runs of it stopped, its Helper quit, ~/.local/bin's link to its release and
// the release removed, its data kept and said taken away (`uninstalled`). Done with no release there too (a service
// left of one removed by hand). nil when it did, else why not.
static NSString *local_uninstall(NSString *data) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *domain = [NSString stringWithFormat:@"gui/%d", getuid()];
  NSString *own = local_env("MBUI_STATION_LABEL", @"fail.still.station");
  NSArray *labels = [own isEqualToString:@"fail.still.station"] ? @[ own, @"org.3720.ember.station" ] : @[ own ];
  for (NSString *label in labels) {
    NSString *plist = [NSString stringWithFormat:@"%@/Library/LaunchAgents/%@.plist", NSHomeDirectory(), label];
    if (![fm fileExistsAtPath:plist]) continue;
    NSString *target = [NSString stringWithFormat:@"%@/%@", domain, label];
    local_launchctl(@[ @"bootout", target ]);
    // (bootout returns before the service is gone)
    for (int i = 0; i < 5 && !local_launchctl(@[ @"print", target ]); i++) sleep(1);
    local_launchctl(@[ @"enable", target ]);
    NSError *e = nil;
    if (![fm removeItemAtPath:plist error:&e]) return e.localizedDescription ?: @"plist";
  }
  NSString *version = nil;
  pid_t pid = local_pid(data, &version);
  // (by its pid as it said it, while that is still a station's launcher: a pid is reused once its process is gone)
  char name[64] = "";
  if (pid > 0) proc_name(pid, name, sizeof name);
  if (pid > 0 && !strncmp(name, "stillfail", 9) && kill(pid, SIGTERM) == 0) {
    for (int i = 0; i < 50 && kill(pid, 0) == 0; i++) usleep(100000);
  }
  local_helper_quit(data);
  NSString *link = [NSHomeDirectory() stringByAppendingPathComponent:[@".local/bin" stringByAppendingPathComponent:local_env("MBUI_STATION_ID", @"stillfail")]];
  NSString *to = [fm destinationOfSymbolicLinkAtPath:link error:nil];
  // (the release's own path and a slash: stringByAppendingPathComponent takes a trailing one off, and app.old/… is not it)
  if ([to hasPrefix:[[data stringByAppendingPathComponent:@"app"] stringByAppendingString:@"/"]]) [fm removeItemAtPath:link error:nil];
  for (NSString *part in @[ @"app", @"app.old", @"app.failed", @"app.before-replace", @"node", @"helper", @"run", @"stillfail.pid" ]) {
    NSString *path = [data stringByAppendingPathComponent:part];
    NSError *e = nil;
    if ([fm fileExistsAtPath:path] && ![fm removeItemAtPath:path error:&e]) return e.localizedDescription ?: part;
  }
  if ([fm fileExistsAtPath:data]) [fm createFileAtPath:[data stringByAppendingPathComponent:@"uninstalled"] contents:[NSData data] attributes:nil];
  return nil;
}

static void sf_station_act(moonbit_string_t action) {
  if (getenv("MBUI_ISOLATED_STATION")) return;
  NSString *a = mb_ns_from_string(action);
  NSString *data = local_data();
  // `install {…}`, `update {…}`: the installer (local_install), off the main thread, as the others
  NSRange space = [a rangeOfString:@" "];
  if (space.location != NSNotFound && ([a hasPrefix:@"install "] || [a hasPrefix:@"update "])) {
    NSString *verb = [a substringToIndex:space.location];
    NSString *ask = [a substringFromIndex:space.location + 1];
    if (local_doing) {
      local_failed = @"busy";
      station_changed();
      return;
    }
    local_doing = verb;
    local_failed = nil;
    local_percent = -1;
    local_said = nil;
    station_changed();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSString *failed = local_install(ask);
      dispatch_async(dispatch_get_main_queue(), ^{
        local_doing = nil;
        local_failed = failed;
        station_changed();
      });
    });
    return;
  }
  if ([a isEqualToString:@"log"]) {
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[data stringByAppendingPathComponent:@"stillfail.log"]]];
    return;
  }
  if ([a isEqualToString:@"folder"]) {
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:data]];
    return;
  }
  // 更改存储位置 (asked first on its page): a folder chosen (the system's panel, not over the window: the app goes on
  // drawing), then its data moved there off the main thread (local_move)
  if ([a isEqualToString:@"move"]) {
    if (local_doing) {
      local_failed = @"busy";
      station_changed();
      return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    [panel beginWithCompletionHandler:^(NSModalResponse r) {
      NSURL *picked = panel.URLs.firstObject;
      if (r != NSModalResponseOK || !picked || local_doing) return;
      local_doing = @"move";
      local_failed = nil;
      local_percent = -1;
      local_said = nil;
      station_changed();
      NSString *folder = picked.path;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failed = local_move(data, folder);
        dispatch_async(dispatch_get_main_queue(), ^{
          local_doing = nil;
          local_failed = failed;
          station_changed();
        });
      });
    }];
    return;
  }
  if (![@[ @"start", @"stop", @"restart", @"uninstall" ] containsObject:a]) return;
  if (local_doing) {
    local_failed = @"busy";
    station_changed();
    return;
  }
  local_doing = a;
  local_failed = nil;
  station_changed();
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *failed = nil;
    NSString *service = local_service();
    NSString *version = nil;
    pid_t pid = local_pid(data, &version);
    if ([a isEqualToString:@"uninstall"]) {
      failed = local_uninstall(data);
    } else if (service) {
      NSString *domain = [NSString stringWithFormat:@"gui/%d", getuid()];
      NSString *target = [NSString stringWithFormat:@"%@/%@", domain, service];
      if ([a isEqualToString:@"stop"]) {
        // for good: disabled, launchd starts it at no next login (RunAtLoad) until it is started from here again
        local_launchctl(@[ @"disable", target ]);
        failed = local_launchctl(@[ @"bootout", target ]);
        // (not loaded, nothing running: stopped already)
        if (failed && pid == 0) failed = nil;
      } else {
        // started again: no longer taken away, and enabled (stopped here, it was disabled)
        [NSFileManager.defaultManager removeItemAtPath:[data stringByAppendingPathComponent:@"uninstalled"] error:nil];
        local_launchctl(@[ @"enable", target ]);
        if (local_launchctl([a isEqualToString:@"restart"] ? @[ @"kickstart", @"-k", target ] : @[ @"kickstart", target ])) {
          // not loaded (stopped here, or never since login): loaded, which starts it (RunAtLoad)
          NSString *plist = [NSString stringWithFormat:@"%@/Library/LaunchAgents/%@.plist", NSHomeDirectory(), service];
          failed = local_launchctl(@[ @"bootstrap", domain, plist ]);
        }
      }
    } else if (pid != 0) {
      // started by hand (`stillfail start`): only stopped from here, it has nothing to start it again
      if ([a isEqualToString:@"stop"]) {
        if (kill(pid, SIGTERM) != 0) failed = [NSString stringWithUTF8String:strerror(errno)];
      } else {
        failed = @"byHand";
      }
    } else {
      failed = @"noService";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      local_doing = nil;
      local_failed = failed;
      station_changed();
    });
  });
}
