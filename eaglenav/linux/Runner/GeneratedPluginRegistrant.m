//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

#if __has_include(<flutter_tts/FlutterTtsPlugin.h>)
#import <flutter_tts/FlutterTtsPlugin.h>
#else
@import flutter_tts;
#endif

#if __has_include(<ultralytics_yolo/YOLOPlugin.h>)
#import <ultralytics_yolo/YOLOPlugin.h>
#else
@import ultralytics_yolo;
#endif

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
  [FlutterTtsPlugin registerWithRegistrar:[registry registrarForPlugin:@"FlutterTtsPlugin"]];
  [YOLOPlugin registerWithRegistrar:[registry registrarForPlugin:@"YOLOPlugin"]];
}

@end
