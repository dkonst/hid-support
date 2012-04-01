/**
 * Click injection
 *
 * swiped from and update of Lance Fetter's MouseSupport and Jay Freeman's Veency
 *
 * next steps:
 *   handle device rotation
 *   show mouse cursor - decide on keep-alive
 */
  
#include <objc/runtime.h>
#include <mach/mach_port.h>
#include <mach/mach_init.h>
#include <dlfcn.h>

// kenytm
#import <GraphicsServices/GSEvent.h>

#include "../hid-support-internal.h"

// MSHookSymbol is not available in the autogenerated substrate.h
template <typename Type_>
static inline void MyMSHookSymbol(Type_ *&value, const char *name, void *handle = RTLD_DEFAULT) {
    value = reinterpret_cast<Type_ *>(dlsym(handle, name));
}


extern "C" uint64_t GSCurrentEventTimestamp(void);
extern "C" GSEventRef _GSCreateSyntheticKeyEvent(UniChar key, BOOL up, BOOL repeating);

// used interface from CAWindowServer & CAWindowServerDisplay
@interface CAWindowServer : NSObject
+ (id)serverIfRunning;
- (id)displays;
@end
@interface CAWindowServerDisplay : NSObject
- (unsigned int)clientPortAtPosition:(struct CGPoint)fp8;
@end

#if !defined(__IPHONE_3_2) || __IPHONE_3_2 > __IPHONE_OS_VERSION_MAX_ALLOWED
typedef enum {
    UIUserInterfaceIdiomPhone,           // iPhone and iPod touch style UI
    UIUserInterfaceIdiomPad,             // iPad style UI
} UIUserInterfaceIdiom;
@interface UIDevice (privateAPI)
- (BOOL) userInterfaceIdiom;
@end
#endif

@interface UIScreen (fourZeroAndLater)
@property(nonatomic,readonly) CGFloat scale;
@end

// types for touches
typedef enum __GSHandInfoType2 {
        kGSHandInfoType2TouchDown    = 1,    // first down
        kGSHandInfoType2TouchDragged = 2,    // drag
        kGSHandInfoType2TouchChange  = 5,    // nr touches change
        kGSHandInfoType2TouchFinal   = 6,    // final up
} GSHandInfoType2;

static CFDataRef myCallBack(CFMessagePortRef local, SInt32 msgid, CFDataRef cfData, void *info);

// globals

// GS functions
GSEventRef (*$GSEventCreateKeyEvent)(int, CGPoint, CFStringRef, CFStringRef, uint32_t, UniChar, short, short);
GSEventRef (*$GSCreateSyntheticKeyEvent)(UniChar, BOOL, BOOL);
void       (*$GSEventSetKeyCode)(GSEventRef event, uint16_t keyCode);


// GSEvent being sent
static uint8_t  touchEvent[sizeof(GSEventRecord) + sizeof(GSHandInfo) + sizeof(GSPathInfo)];

// Screen dimension
static float screen_width = 0;
static float screen_height = 0;
static float retina_factor = 1.0f;

// Mouse area (might be rotated)
static float mouse_max_x = 0;
static float mouse_max_y = 0;

// Mouse position
static float mouse_x = 0;
static float mouse_y = 0;

// access to system event server
static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static bool PurpleAllocated;
static int Level_;  // < 3.0, 3.0-3.1.x, 3.2+

// iPad support
static int is_iPad = 0;


template <typename Type_>
static void dlset(Type_ &function, const char *name) {
    function = reinterpret_cast<Type_>(dlsym(RTLD_DEFAULT, name));
}

// project GSEventRecord for OS < 3 if needed
void detectOSLevel(){
    if (dlsym(RTLD_DEFAULT, "GSLibraryCopyGenerationInfoValueForKey")){
        Level_ = 3;
        return;
    }
    if (dlsym(RTLD_DEFAULT, "GSKeyboardCreate")) {
        Level_ = 2;
        return;
    }
    if (dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId")) {
        Level_ = 1;
        return;
    }
    Level_ = 0;
}

void FixRecord(GSEventRecord *record) {
    if (Level_ < 1) {
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->infoSize);
    }
}

static float box(float min, float value, float max){
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

static void sendGSEvent(GSEventRecord *eventRecord, CGPoint point){

    mach_port_t port(0);
    mach_port_t purple(0);
    
    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0){
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0]) { 
               CGPoint point2;
               if (is_iPad) {
                    point2.x = screen_height - 1 - point.y;
                    point2.y = point.x;
                } else {
                    point2.x = point.x;
                    point2.y = point.y;
                }
                point2.x *= retina_factor;
                point2.y *= retina_factor;
                port = [display clientPortAtPosition:point2];
                // NSLog(@"display port : %x", (int) port_);
            }
        }
    }
    
    if (!port) {
        if (!purple) {
            purple = (*GSTakePurpleSystemEventPort)();
        }
        port = purple;
    }
    
    if (port) {
        // FixRecord(eventRecord);
        GSSendEvent(eventRecord, port);
    }
    
    if (purple && PurpleAllocated){
        mach_port_deallocate(mach_task_self(), purple);
    }
}

// decide on GSHandInfoType
static GSHandInfoType getHandInfoType(int touch_before, int touch_now){
    if (!touch_before) {
        return (GSHandInfoType) kGSHandInfoType2TouchDown;
    }
    if (touch_now) {
        return (GSHandInfoType) kGSHandInfoType2TouchChange;
    }
    return (GSHandInfoType) kGSHandInfoType2TouchFinal;
}

static void postMouseEvent(float x, float y, int click){

    static int prev_click = 0;

    if (!click && !prev_click) return;

    CGPoint location = CGPointMake(x, y);

    // structure of touch GSEvent
    struct GSTouchEvent {
        GSEventRecord record;
        GSHandInfo    handInfo;
    } * event = (struct GSTouchEvent*) &touchEvent;
    bzero(touchEvent, sizeof(touchEvent));
    
    // set up GSEvent
    event->record.type = kGSEventHand;
    event->record.windowLocation = location;
    event->record.timestamp = GSCurrentEventTimestamp();
    event->record.infoSize = sizeof(GSHandInfo) + sizeof(GSPathInfo);
    event->handInfo.type = getHandInfoType(prev_click, click);
    if (Level_ >= 3){
        event->handInfo.x52 = 1;
    } else {
    	event->handInfo.pathInfosCount = 1;
    }
    bzero(&event->handInfo.pathInfos[0], sizeof(GSPathInfo));
    event->handInfo.pathInfos[0].pathIndex     = 1;
    event->handInfo.pathInfos[0].pathIdentity  = 2;
    event->handInfo.pathInfos[0].pathProximity = click ? 0x03 : 0x00;;
    event->handInfo.pathInfos[0].pathLocation  = location;

    // send GSEvent
    sendGSEvent( (GSEventRecord*) event, location);  
    
    prev_click = click;  
}

// handle special function keys (>= 0f700)
typedef struct mapping {
    int specialFunction;
    int keyCode;
    int charCode;
    int modifier;
} mapping;

static mapping specialMapping[] = {
    { NSUpArrowFunctionKey,    0x52, 0x1e, 0x00 },
    { NSDownArrowFunctionKey,  0x51, 0x1f, 0x00 },
    { NSLeftArrowFunctionKey,  0x50, 0x1c, 0x00 },
    { NSRightArrowFunctionKey, 0x4f, 0x1d, 0x00 },
};

static int specialMapppingCount = sizeof(specialMapping) / sizeof(mapping);

static void postKeyEvent(int down, uint16_t modifier, unichar unicode){
    CGPoint location = CGPointMake(100, 100);
    CFStringRef string = NULL;
    GSEventRef  event  = NULL;
    GSEventType type = down ? kGSEventKeyDown : kGSEventKeyUp;
    uint32_t flags = (GSEventFlags) 0;
    if (modifier == CMD){
        flags |= 1 << 16;
    }
    if ($GSEventCreateKeyEvent) {           // >= 3.2

        // handle special function keys
        int keycode = 0;
        if (unicode >= 0xf700){
            for (int i = 0; i < specialMapppingCount ; i ++){
                if (specialMapping[i].specialFunction == unicode){
                    unicode = specialMapping[i].charCode;
                    keycode = specialMapping[i].keyCode;
                    break;
                }
            }
        }

        // NSLog(@"GSEventCreateKeyEvent type %u for %@ with flags %08x", type, modifier, string, flags); 
        
        string = CFStringCreateWithCharacters(kCFAllocatorDefault, &unicode, 1);
        event = (*$GSEventCreateKeyEvent)(type, location, string, string, (GSEventFlags) flags, 0, 0, 1);
        (*GSEventSetKeyCode)(event, keycode);
        
    } else if ($GSCreateSyntheticKeyEvent && down) { // < 3.2 - no up events
        // NSLog(@"GSCreateSyntheticKeyEvent down %u for %C", down, unicode);
        event = (*$GSCreateSyntheticKeyEvent)(unicode, down, YES);
        GSEventRecord *record((GSEventRecord*) _GSEventGetGSEventRecord(event));
        record->type = kGSEventSimulatorKeyDown;
        record->flags = (GSEventFlags) flags;
    } else return;

    // send GSEvent
    sendGSEvent((GSEventRecord*) _GSEventGetGSEventRecord(event), location);
    
    if (string){
        CFRelease(string);
    }
    CFRelease(event);
}

static void handleMouseEvent(const mouse_event_t *mouse_event){
    int new_mouse_x, new_mouse_y;
    switch (mouse_event->type) {
        case REL_MOVE:
            new_mouse_x = mouse_x + mouse_event->x;
            new_mouse_y = mouse_y + mouse_event->y;
            break;
        case ABS_MOVE:
            new_mouse_x = mouse_event->x;
            new_mouse_y = mouse_event->y;
            break;
        default:
            return;
    }
    mouse_x = box(0, new_mouse_x, mouse_max_x);
    mouse_y = box(0, new_mouse_y, mouse_max_y);

    int buttons = mouse_event->buttons ? 1 : 0;
    // NSLog(@"MOUSE type %u, button %u, dx %f, dy %f", mouse_event->type, mouse_event->buttons, mouse_event->x, mouse_event->y);
    postMouseEvent(mouse_x, mouse_y, buttons);
}

static void handleButtonEvent(const button_event_t *button_event){
    struct GSEventRecord record;
    memset(&record, 0, sizeof(record));
    record.timestamp = GSCurrentEventTimestamp();
    
    switch (button_event->action){
        case HWButtonHome:
            // Simulate Home button press
            record.type = (button_event->down) != 0 ? kGSEventMenuButtonDown : kGSEventMenuButtonUp;
            GSSendSystemEvent(&record);
            break;
        default:
            break;
    }
}

static CFDataRef myCallBack(CFMessagePortRef local, SInt32 msgid, CFDataRef cfData, void *info) {

    //NSLog(@"hidsupport callback, msg %u", msgid);
    const char *data = (const char *) CFDataGetBytePtr(cfData);
    uint16_t dataLen = CFDataGetLength(cfData);
    char *buffer;
    NSString * text;
    unsigned int i;
    // have pointers ready
    key_event_t     * key_event;
    // remote_action_t * remote_action;
    // unichar           theChar;
    // touch_event_t   * touch_event;
    // accelerometer_t * acceleometer;
    dimension_t dimension_result;
    CFDataRef returnData = NULL;
    
    switch ( (hid_event_type_t) msgid){
        case TEXT:
            // regular text
            if (dataLen == 0 || !data) break;
            // append \0 byte for NSString conversion
            buffer = (char*) malloc(dataLen + 1);
            if (!buffer) {
                break;
            }
            memcpy(buffer, data, dataLen);
            buffer[dataLen] = 0;
            text = [NSString stringWithUTF8String:buffer];
            for (i=0; i< [text length]; i++){
                // NSLog(@"TEXT: sending %C", [text characterAtIndex:i]);
                postKeyEvent(1, 0, [text characterAtIndex:i]);
                postKeyEvent(0, 0, [text characterAtIndex:i]);
            }
            free(buffer);
            break;
            
        case KEY:
            // individual key events
            key_event = (key_event_t*) data;
            key_event->down = key_event->down ? 1 : 0;
            postKeyEvent(key_event->down, key_event->modifier, key_event->unicode);
            break;
            
        case MOUSE:
            if (dataLen != sizeof(mouse_event_t) || !data) break;
            handleMouseEvent((const mouse_event_t *) data);
            break;
            
        case BUTTON:
            if (dataLen != sizeof(button_event_t) || !data) break;
              handleButtonEvent((const button_event_t *) data);
              break;
                    
        case GET_SCREEN_DIMENSION:
            dimension_result.width  = screen_width;
            dimension_result.height = screen_height;
            returnData = CFDataCreate(kCFAllocatorDefault, (const uint8_t*) &dimension_result, sizeof(dimension_t));
            break;
        
        default:
            NSLog(@"HID_SUPPORT_PORT_NAME server, msgid %u not supported", msgid);
            break;
    }
    return returnData;  // as stated in header, both data and returnData will be released for us after callback returns
}

%hook SpringBoard
-(void)applicationDidFinishLaunching:(id)fp8 {

    %orig;

    // GraphicsServices used
    MyMSHookSymbol(GSTakePurpleSystemEventPort, "GSGetPurpleSystemEventPort");
    if (GSTakePurpleSystemEventPort == NULL) {
        MyMSHookSymbol(GSTakePurpleSystemEventPort, "GSCopyPurpleSystemEventPort");
        PurpleAllocated = true;
    }
	dlset($GSEventCreateKeyEvent, "GSEventCreateKeyEvent");
    dlset($GSCreateSyntheticKeyEvent, "_GSCreateSyntheticKeyEvent");
    dlset($GSEventSetKeyCode, "_GSEventSetKeyCode");
    detectOSLevel();

    // Setup a mach port for receiving mouse events from outside of SpringBoard
    // NOTE (by ashikase): Using kCFRunLoopDefaultMode causes issues when dragging SpringBoard's
    //       scrollview; why kCFRunLoopCommonModes fixes the issue, I do not know.
    CFMessagePortRef local = CFMessagePortCreateLocal(NULL, CFSTR(HID_SUPPORT_PORT_NAME), myCallBack, NULL, false);
    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, local, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);

    // Get initial screen size
    // FIXME: Consider adding support for TVOut* users
    CGRect rect = [[UIScreen mainScreen] bounds];
    screen_width = rect.size.width;
    screen_height = rect.size.height;
    mouse_max_x = screen_width - 1;
    mouse_max_y = screen_height - 1;
    
    // iPad has rotated framebuffer
    if ([[UIDevice currentDevice] respondsToSelector:@selector(userInterfaceIdiom)]){
        is_iPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    }

    // handle retina devices (checks for iOS4.x)
    if ([[UIScreen mainScreen] respondsToSelector:@selector(displayLinkWithTarget:selector:)]){
        retina_factor = [UIScreen mainScreen].scale;
        NSLog(@"retina factor %f", retina_factor);
    }
}
%end

// Main init
// __attribute__((constructor)) static void init(){
// }

