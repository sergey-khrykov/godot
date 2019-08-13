/*************************************************************************/
/*  app_delegate.mm                                                      */
/*************************************************************************/
/*                       This file is part of:                           */
/*                           GODOT ENGINE                                */
/*                      https://godotengine.org                          */
/*************************************************************************/
/* Copyright (c) 2007-2021 Juan Linietsky, Ariel Manzur.                 */
/* Copyright (c) 2014-2021 Godot Engine contributors (cf. AUTHORS.md).   */
/*                                                                       */
/* Permission is hereby granted, free of charge, to any person obtaining */
/* a copy of this software and associated documentation files (the       */
/* "Software"), to deal in the Software without restriction, including   */
/* without limitation the rights to use, copy, modify, merge, publish,   */
/* distribute, sublicense, and/or sell copies of the Software, and to    */
/* permit persons to whom the Software is furnished to do so, subject to */
/* the following conditions:                                             */
/*                                                                       */
/* The above copyright notice and this permission notice shall be        */
/* included in all copies or substantial portions of the Software.       */
/*                                                                       */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF    */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.*/
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY  */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,  */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE     */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                */
/*************************************************************************/

#import "app_delegate.h"

#include "core/project_settings.h"
#include "drivers/coreaudio/audio_driver_coreaudio.h"
#import "godot_view.h"
#include "main/main.h"
#include "os_iphone.h"
#import "view_controller.h"

#import <AudioToolbox/AudioServices.h>

#define kRenderingFrequency 60
#define kAccelerometerFrequency 100.0 // Hz

Error _shell_open(String);
void _set_keep_screen_on(bool p_enabled);
Variant nsobject_to_variant(NSObject *object);
NSObject *variant_to_nsobject(Variant v);

//convert from apple's abstract type to godot's abstract type....
Variant nsobject_to_variant(NSObject *object) {
	if ([object isKindOfClass:[NSString class]]) {
		const char *str = [(NSString *)object UTF8String];
		return String::utf8(str != NULL ? str : "");
	} else if ([object isKindOfClass:[NSData class]]) {
		PoolByteArray ret;
		NSData *data = (NSData *)object;
		if ([data length] > 0) {
			ret.resize([data length]);
			{
				PoolByteArray::Write w = ret.write();
				copymem(w.ptr(), [data bytes], [data length]);
			}
		}
		return ret;
	} else if ([object isKindOfClass:[NSArray class]]) {
		Array result;
		NSArray *array = (NSArray *)object;
		for (unsigned int i = 0; i < [array count]; ++i) {
			NSObject *value = [array objectAtIndex:i];
			result.push_back(nsobject_to_variant(value));
		}
		return result;
	} else if ([object isKindOfClass:[NSDictionary class]]) {
		Dictionary result;
		NSDictionary *dic = (NSDictionary *)object;

		NSArray *keys = [dic allKeys];
		int count = [keys count];
		for (int i = 0; i < count; ++i) {
			NSObject *k = [keys objectAtIndex:i];
			NSObject *v = [dic objectForKey:k];

			result[nsobject_to_variant(k)] = nsobject_to_variant(v);
		}
		return result;
	} else if ([object isKindOfClass:[NSNumber class]]) {
		//Every type except numbers can reliably identify its type.  The following is comparing to the *internal* representation, which isn't guaranteed to match the type that was used to create it, and is not advised, particularly when dealing with potential platform differences (ie, 32/64 bit)
		//To avoid errors, we'll cast as broadly as possible, and only return int or float.
		//bool, char, int, uint, longlong -> int
		//float, double -> float
		NSNumber *num = (NSNumber *)object;
		if (strcmp([num objCType], @encode(BOOL)) == 0) {
			return Variant((int)[num boolValue]);
		} else if (strcmp([num objCType], @encode(char)) == 0) {
			return Variant((int)[num charValue]);
		} else if (strcmp([num objCType], @encode(int)) == 0) {
			return Variant([num intValue]);
		} else if (strcmp([num objCType], @encode(unsigned int)) == 0) {
			return Variant((int)[num unsignedIntValue]);
		} else if (strcmp([num objCType], @encode(long long)) == 0) {
			return Variant((int)[num longValue]);
		} else if (strcmp([num objCType], @encode(float)) == 0) {
			return Variant([num floatValue]);
		} else if (strcmp([num objCType], @encode(double)) == 0) {
			return Variant((float)[num doubleValue]);
		} else {
			return Variant();
		}
	} else if ([object isKindOfClass:[NSDate class]]) {
		//this is a type that icloud supports...but how did you submit it in the first place?
		//I guess this is a type that *might* show up, if you were, say, trying to make your game
		//compatible with existing cloud data written by another engine's version of your game
		WARN_PRINT("NSDate unsupported, returning null Variant");
		return Variant();
	} else if ([object isKindOfClass:[NSNull class]] or object == nil) {
		return Variant();
	} else {
		WARN_PRINT("Trying to convert unknown NSObject type to Variant");
		return Variant();
	}
}

NSObject *variant_to_nsobject(Variant v) {
	if (v.get_type() == Variant::STRING) {
		return [[[NSString alloc] initWithUTF8String:((String)v).utf8().get_data()] autorelease];
	} else if (v.get_type() == Variant::REAL) {
		return [NSNumber numberWithDouble:(double)v];
	} else if (v.get_type() == Variant::INT) {
		return [NSNumber numberWithLongLong:(long)(int)v];
	} else if (v.get_type() == Variant::BOOL) {
		return [NSNumber numberWithBool:BOOL((bool)v)];
	} else if (v.get_type() == Variant::DICTIONARY) {
		NSMutableDictionary *result = [[[NSMutableDictionary alloc] init] autorelease];
		Dictionary dic = v;
		Array keys = dic.keys();
		for (unsigned int i = 0; i < keys.size(); ++i) {
			NSString *key = [[[NSString alloc] initWithUTF8String:((String)(keys[i])).utf8().get_data()] autorelease];
			NSObject *value = variant_to_nsobject(dic[keys[i]]);

			if (key == NULL || value == NULL) {
				return NULL;
			}

			[result setObject:value forKey:key];
		}
		return result;
	} else if (v.get_type() == Variant::ARRAY) {
		NSMutableArray *result = [[[NSMutableArray alloc] init] autorelease];
		Array arr = v;
		for (unsigned int i = 0; i < arr.size(); ++i) {
			NSObject *value = variant_to_nsobject(arr[i]);
			if (value == NULL) {
				//trying to add something unsupported to the array. cancel the whole array
				return NULL;
			}
			[result addObject:value];
		}
		return result;
	} else if (v.get_type() == Variant::POOL_BYTE_ARRAY) {
		PoolByteArray arr = v;
		PoolByteArray::Read r = arr.read();
		NSData *result = [NSData dataWithBytes:r.ptr() length:arr.size()];
		return result;
	}
	WARN_PRINT(String("Could not add unsupported type to iCloud: '" + Variant::get_type_name(v.get_type()) + "'").utf8().get_data());
	return NULL;
}

Error _shell_open(String p_uri) {
	NSString *url = [[NSString alloc] initWithUTF8String:p_uri.utf8().get_data()];

	if (![[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:url]]) {
		[url release];
		return ERR_CANT_OPEN;
	}

	printf("opening url %ls\n", p_uri.c_str());
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
	[url release];
	return OK;
};

void _set_keep_screen_on(bool p_enabled) {
	[[UIApplication sharedApplication] setIdleTimerDisabled:(BOOL)p_enabled];
};

void _vibrate() {
	AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
};

@implementation AppDelegate

@synthesize window;

extern int gargc;
extern char **gargv;

extern int iphone_main(int, char **, String);
extern void iphone_finish();

@implementation AppDelegate

static ViewController *mainViewController = nil;

+ (ViewController *)viewController {
	return mainViewController;
}

- (void)controllerWasConnected:(NSNotification *)notification {
	// create our dictionary if we don't have one yet
	if (ios_joysticks == nil) {
		ios_joysticks = [[NSMutableDictionary alloc] init];
	};

	// get our controller
	GCController *controller = (GCController *)notification.object;
	if (controller == nil) {
		printf("Couldn't retrieve new controller\n");
	} else if ([[ios_joysticks allKeysForObject:controller] count] != 0) {
		printf("Controller is already registered\n");
	} else if (frame_count > 1) {
		_ios_add_joystick(controller, self);
	} else {
		if (pending_ios_joysticks == nil)
			pending_ios_joysticks = [[NSMutableArray alloc] init];
		[pending_ios_joysticks addObject:controller];
	};
};

- (void)controllerWasDisconnected:(NSNotification *)notification {
	if (ios_joysticks != nil) {
		// find our joystick, there should be only one in our dictionary
		GCController *controller = (GCController *)notification.object;
		NSArray *keys = [ios_joysticks allKeysForObject:controller];
		for (NSNumber *key in keys) {
			// tell Godot this joystick is no longer there
			int joy_id = [key intValue];
			OSIPhone::get_singleton()->joy_connection_changed(joy_id, false, "");

			// and remove it from our dictionary
			[ios_joysticks removeObjectForKey:key];
		};
	};
};

- (int)getJoyIdForController:(GCController *)controller {
	if (ios_joysticks != nil) {
		// find our joystick, there should be only one in our dictionary
		NSArray *keys = [ios_joysticks allKeysForObject:controller];
		for (NSNumber *key in keys) {
			int joy_id = [key intValue];
			return joy_id;
		};
	};

	return -1;
};

- (void)setControllerInputHandler:(GCController *)controller {
	// Hook in the callback handler for the correct gamepad profile.
	// This is a bit of a weird design choice on Apples part.
	// You need to select the most capable gamepad profile for the
	// gamepad attached.
	if (controller.extendedGamepad != nil) {
		// The extended gamepad profile has all the input you could possibly find on
		// a gamepad but will only be active if your gamepad actually has all of
		// these...
		controller.extendedGamepad.valueChangedHandler = ^(
				GCExtendedGamepad *gamepad, GCControllerElement *element) {
			int joy_id = [self getJoyIdForController:controller];

			if (element == gamepad.buttonA) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_0,
						gamepad.buttonA.isPressed);
			} else if (element == gamepad.buttonB) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_1,
						gamepad.buttonB.isPressed);
			} else if (element == gamepad.buttonX) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_2,
						gamepad.buttonX.isPressed);
			} else if (element == gamepad.buttonY) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_3,
						gamepad.buttonY.isPressed);
			} else if (element == gamepad.leftShoulder) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_L,
						gamepad.leftShoulder.isPressed);
			} else if (element == gamepad.rightShoulder) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_R,
						gamepad.rightShoulder.isPressed);
			} else if (element == gamepad.leftTrigger) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_L2,
						gamepad.leftTrigger.isPressed);
			} else if (element == gamepad.rightTrigger) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_R2,
						gamepad.rightTrigger.isPressed);
			} else if (element == gamepad.dpad) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_UP,
						gamepad.dpad.up.isPressed);
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_DOWN,
						gamepad.dpad.down.isPressed);
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_LEFT,
						gamepad.dpad.left.isPressed);
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_RIGHT,
						gamepad.dpad.right.isPressed);
			};

			InputDefault::JoyAxis jx;
			jx.min = -1;
			if (element == gamepad.leftThumbstick) {
				jx.value = gamepad.leftThumbstick.xAxis.value;
				OSIPhone::get_singleton()->joy_axis(joy_id, JOY_ANALOG_LX, jx);
				jx.value = -gamepad.leftThumbstick.yAxis.value;
				OSIPhone::get_singleton()->joy_axis(joy_id, JOY_ANALOG_LY, jx);
			} else if (element == gamepad.rightThumbstick) {
				jx.value = gamepad.rightThumbstick.xAxis.value;
				OSIPhone::get_singleton()->joy_axis(joy_id, JOY_ANALOG_RX, jx);
				jx.value = -gamepad.rightThumbstick.yAxis.value;
				OSIPhone::get_singleton()->joy_axis(joy_id, JOY_ANALOG_RY, jx);
			} else if (element == gamepad.leftTrigger) {
				jx.value = gamepad.leftTrigger.value;
				OSIPhone::get_singleton()->joy_axis(joy_id, JOY_ANALOG_L2, jx);
			} else if (element == gamepad.rightTrigger) {
				jx.value = gamepad.rightTrigger.value;
				OSIPhone::get_singleton()->joy_axis(joy_id, JOY_ANALOG_R2, jx);
			};
		};
	} else if (controller.gamepad != nil) {
		// gamepad is the standard profile with 4 buttons, shoulder buttons and a
		// D-pad
		controller.gamepad.valueChangedHandler = ^(GCGamepad *gamepad,
				GCControllerElement *element) {
			int joy_id = [self getJoyIdForController:controller];

			if (element == gamepad.buttonA) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_0,
						gamepad.buttonA.isPressed);
			} else if (element == gamepad.buttonB) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_1,
						gamepad.buttonB.isPressed);
			} else if (element == gamepad.buttonX) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_2,
						gamepad.buttonX.isPressed);
			} else if (element == gamepad.buttonY) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_3,
						gamepad.buttonY.isPressed);
			} else if (element == gamepad.leftShoulder) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_L,
						gamepad.leftShoulder.isPressed);
			} else if (element == gamepad.rightShoulder) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_R,
						gamepad.rightShoulder.isPressed);
			} else if (element == gamepad.dpad) {
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_UP,
						gamepad.dpad.up.isPressed);
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_DOWN,
						gamepad.dpad.down.isPressed);
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_LEFT,
						gamepad.dpad.left.isPressed);
				OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_RIGHT,
						gamepad.dpad.right.isPressed);
			};
		};
#ifdef ADD_MICRO_GAMEPAD // disabling this for now, only available on iOS 9+,
		// while we are setting that as the minimum, seems our
		// build environment doesn't like it
	} else if (controller.microGamepad != nil) {
		// micro gamepads were added in OS 9 and feature just 2 buttons and a d-pad
		controller.microGamepad.valueChangedHandler =
				^(GCMicroGamepad *gamepad, GCControllerElement *element) {
					int joy_id = [self getJoyIdForController:controller];

					if (element == gamepad.buttonA) {
						OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_0,
								gamepad.buttonA.isPressed);
					} else if (element == gamepad.buttonX) {
						OSIPhone::get_singleton()->joy_button(joy_id, JOY_BUTTON_2,
								gamepad.buttonX.isPressed);
					} else if (element == gamepad.dpad) {
						OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_UP,
								gamepad.dpad.up.isPressed);
						OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_DOWN,
								gamepad.dpad.down.isPressed);
						OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_LEFT,
								gamepad.dpad.left.isPressed);
						OSIPhone::get_singleton()->joy_button(joy_id, JOY_DPAD_RIGHT,
								gamepad.dpad.right.isPressed);
					};
				};
#endif
	};

	///@TODO need to add support for controller.motion which gives us access to
	/// the orientation of the device (if supported)

	///@TODO need to add support for controllerPausedHandler which should be a
	/// toggle
};

- (void)initGameControllers {
	// get told when controllers connect, this will be called right away for
	// already connected controllers
	[[NSNotificationCenter defaultCenter]
			addObserver:self
			   selector:@selector(controllerWasConnected:)
				   name:GCControllerDidConnectNotification
				 object:nil];

	// get told when controllers disconnect
	[[NSNotificationCenter defaultCenter]
			addObserver:self
			   selector:@selector(controllerWasDisconnected:)
				   name:GCControllerDidDisconnectNotification
				 object:nil];
};

- (void)deinitGameControllers {
	[[NSNotificationCenter defaultCenter]
			removeObserver:self
					  name:GCControllerDidConnectNotification
					object:nil];
	[[NSNotificationCenter defaultCenter]
			removeObserver:self
					  name:GCControllerDidDisconnectNotification
					object:nil];

	if (ios_joysticks != nil) {
		[ios_joysticks dealloc];
		ios_joysticks = nil;
	};

	if (pending_ios_joysticks != nil) {
		[pending_ios_joysticks dealloc];
		pending_ios_joysticks = nil;
	};
};

OS::VideoMode _get_video_mode() {
	int backingWidth;
	int backingHeight;
	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES,
			GL_RENDERBUFFER_WIDTH_OES, &backingWidth);
	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES,
			GL_RENDERBUFFER_HEIGHT_OES, &backingHeight);

	OS::VideoMode vm;
	vm.fullscreen = true;
	vm.width = backingWidth;
	vm.height = backingHeight;
	vm.resizable = false;
	return vm;
};

static int frame_count = 0;
- (void)drawView:(GLView *)view;
{

	switch (frame_count) {
		case 0: {
			OS::get_singleton()->set_video_mode(_get_video_mode());

			if (!OS::get_singleton()) {
				exit(0);
			};
			++frame_count;

			//NSString *locale_code = [[NSLocale currentLocale] localeIdentifier];
			// https://stackoverflow.com/questions/3910244/getting-current-device-language-in-ios
			NSString *locale_code = [[NSLocale preferredLanguages] firstObject];
			OSIPhone::get_singleton()->set_locale(
					String::utf8([locale_code UTF8String]));

			NSString *uuid;
			if ([[UIDevice currentDevice]
						respondsToSelector:@selector(identifierForVendor)]) {
				uuid = [UIDevice currentDevice].identifierForVendor.UUIDString;
			} else {
				// before iOS 6, so just generate an identifier and store it
				uuid = [[NSUserDefaults standardUserDefaults]
						objectForKey:@"identiferForVendor"];
				if (!uuid) {
					CFUUIDRef cfuuid = CFUUIDCreate(NULL);
					uuid = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, cfuuid);
					CFRelease(cfuuid);
					[[NSUserDefaults standardUserDefaults]
							setObject:uuid
							   forKey:@"identifierForVendor"];
				}
			}

			OSIPhone::get_singleton()->set_unique_id(String::utf8([uuid UTF8String]));

		}; break;

		case 1: {

			Main::setup2();
			++frame_count;

			if (pending_ios_joysticks != nil) {
				for (GCController *controller in pending_ios_joysticks) {
					_ios_add_joystick(controller, self);
				}
				[pending_ios_joysticks dealloc];
				pending_ios_joysticks = nil;
			}

			// this might be necessary before here
			NSDictionary *dict = [[NSBundle mainBundle] infoDictionary];
			for (NSString *key in dict) {
				NSObject *value = [dict objectForKey:key];
				String ukey = String::utf8([key UTF8String]);

				// we need a NSObject to Variant conversor

				if ([value isKindOfClass:[NSString class]]) {
					NSString *str = (NSString *)value;
					String uval = String::utf8([str UTF8String]);

					ProjectSettings::get_singleton()->set("Info.plist/" + ukey, uval);

				} else if ([value isKindOfClass:[NSNumber class]]) {

					NSNumber *n = (NSNumber *)value;
					double dval = [n doubleValue];

					ProjectSettings::get_singleton()->set("Info.plist/" + ukey, dval);
				};
				// do stuff
			}

		}; break;

		case 2: {

			Main::start();
			++frame_count;

		}; break; // no fallthrough

		default: {
			if (OSIPhone::get_singleton()) {
				// OSIPhone::get_singleton()->update_accelerometer(accel[0], accel[1],
				// accel[2]);
				if (motionInitialised) {
					// Just using polling approach for now, we can set this up so it sends
					// data to us in intervals, might be better. See Apple reference pages
					// for more details:
					// https://developer.apple.com/reference/coremotion/cmmotionmanager?language=objc

					// Apple splits our accelerometer date into a gravity and user movement
					// component. We add them back together
					CMAcceleration gravity = motionManager.deviceMotion.gravity;
					CMAcceleration acceleration =
							motionManager.deviceMotion.userAcceleration;

					///@TODO We don't seem to be getting data here, is my device broken or
					/// is this code incorrect?
					CMMagneticField magnetic =
							motionManager.deviceMotion.magneticField.field;

					///@TODO we can access rotationRate as a CMRotationRate variable
					///(processed date) or CMGyroData (raw data), have to see what works
					/// best
					CMRotationRate rotation = motionManager.deviceMotion.rotationRate;

					// Adjust for screen orientation.
					// [[UIDevice currentDevice] orientation] changes even if we've fixed
					// our orientation which is not a good thing when you're trying to get
					// your user to move the screen in all directions and want consistent
					// output

					///@TODO Using [[UIApplication sharedApplication] statusBarOrientation]
					/// is a bit of a hack. Godot obviously knows the orientation so maybe
					/// we
					// can use that instead? (note that left and right seem swapped)

					switch ([[UIApplication sharedApplication] statusBarOrientation]) {
						case UIInterfaceOrientationLandscapeLeft: {
							OSIPhone::get_singleton()->update_gravity(-gravity.y, gravity.x,
									gravity.z);
							OSIPhone::get_singleton()->update_accelerometer(
									-(acceleration.y + gravity.y), (acceleration.x + gravity.x),
									acceleration.z + gravity.z);
							OSIPhone::get_singleton()->update_magnetometer(
									-magnetic.y, magnetic.x, magnetic.z);
							OSIPhone::get_singleton()->update_gyroscope(-rotation.y, rotation.x,
									rotation.z);
						}; break;
						case UIInterfaceOrientationLandscapeRight: {
							OSIPhone::get_singleton()->update_gravity(gravity.y, -gravity.x,
									gravity.z);
							OSIPhone::get_singleton()->update_accelerometer(
									(acceleration.y + gravity.y), -(acceleration.x + gravity.x),
									acceleration.z + gravity.z);
							OSIPhone::get_singleton()->update_magnetometer(
									magnetic.y, -magnetic.x, magnetic.z);
							OSIPhone::get_singleton()->update_gyroscope(rotation.y, -rotation.x,
									rotation.z);
						}; break;
						case UIInterfaceOrientationPortraitUpsideDown: {
							OSIPhone::get_singleton()->update_gravity(-gravity.x, gravity.y,
									gravity.z);
							OSIPhone::get_singleton()->update_accelerometer(
									-(acceleration.x + gravity.x), (acceleration.y + gravity.y),
									acceleration.z + gravity.z);
							OSIPhone::get_singleton()->update_magnetometer(
									-magnetic.x, magnetic.y, magnetic.z);
							OSIPhone::get_singleton()->update_gyroscope(-rotation.x, rotation.y,
									rotation.z);
						}; break;
						default: { // assume portrait
							OSIPhone::get_singleton()->update_gravity(gravity.x, gravity.y,
									gravity.z);
							OSIPhone::get_singleton()->update_accelerometer(
									acceleration.x + gravity.x, acceleration.y + gravity.y,
									acceleration.z + gravity.z);
							OSIPhone::get_singleton()->update_magnetometer(magnetic.x, magnetic.y,
									magnetic.z);
							OSIPhone::get_singleton()->update_gyroscope(rotation.x, rotation.y,
									rotation.z);
						}; break;
					};
				}

				OSIPhone::get_singleton()->iterate();
			};

		}; break;
	};
};

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
	if (OS::get_singleton()->get_main_loop()) {
		OS::get_singleton()->get_main_loop()->notification(
				MainLoop::NOTIFICATION_OS_MEMORY_WARNING);
	}
};

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	
	// Create a full-screen window
	CGRect windowBounds = [[UIScreen mainScreen] bounds];
	self.window = [[UIWindow alloc] initWithFrame:windowBounds];

	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
			NSUserDomainMask, YES);
	NSString *documentsDirectory = [paths objectAtIndex:0];

	int err = iphone_main(gargc, gargv, String::utf8([documentsDirectory UTF8String]));
	if (err != 0) {
		// bail, things did not go very well for us, should probably output a message on screen with our error code...
		exit(0);
		return FALSE;
	}

	// WARNING: We must *always* create the GodotView after we have constructed the
	// OS with iphone_main. This allows the GodotView to access project settings so
	// it can properly initialize the OpenGL context

	ViewController *viewController = [[ViewController alloc] init];
	viewController.godotView.useCADisplayLink = bool(GLOBAL_DEF("display.iOS/use_cadisplaylink", true)) ? YES : NO;
	viewController.godotView.renderingInterval = 1.0 / kRenderingFrequency;

	self.window.rootViewController = viewController;

	// Show the window
	[self.window makeKeyAndVisible];

	[[NSNotificationCenter defaultCenter]
			addObserver:self
			   selector:@selector(onAudioInterruption:)
				   name:AVAudioSessionInterruptionNotification
				 object:[AVAudioSession sharedInstance]];

	mainViewController = viewController;

	// prevent to stop music in another background app
	[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];

	bool keep_screen_on = bool(GLOBAL_DEF("display/window/energy_saving/keep_screen_on", true));
	OSIPhone::get_singleton()->set_keep_screen_on(keep_screen_on);

	[[NSNotificationCenter defaultCenter] postNotificationName: 
                       @"didFinishLaunchingWithOptions_finish" object:nil userInfo:launchOptions];
	return TRUE;
}


- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
	NSDictionary *data = @{ @"app" : app, @"url": url, @"options":options};
	[[NSNotificationCenter defaultCenter] postNotificationName: 
                       @"appOpenUrlWithOptions_finish" object:nil userInfo:data];
	return YES;
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray * _Nullable))restorationHandler {
	// handler for Universal Links
	[[NSNotificationCenter defaultCenter] postNotificationName: 
                       @"appContinueUserActivity_finish" object:nil userInfo: @{@"userActivity" :userActivity}];
	return YES;
}


- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
  // handler for Push Notifications
  NSLog(@"appDidReceiveRemoteNotification_finish");
  [[NSNotificationCenter defaultCenter] postNotificationName: 
                       @"appDidReceiveRemoteNotification_finish" object:nil userInfo: @{@"userInfo" :userInfo}];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
	NSLog(@"appDidReceiveRemoteNotification_finish with completion");
	[[NSNotificationCenter defaultCenter] postNotificationName: 
                       @"appDidReceiveRemoteNotification_finish" object:nil userInfo: @{@"userInfo" :userInfo}];



	completionHandler(UIBackgroundFetchResultNewData);
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken; {
  NSLog(@"didRegisterForRemoteNotificationsWithDeviceToken_finish");
  // handler for Push Notifications
  [[NSNotificationCenter defaultCenter] postNotificationName: 
                       @"didRegisterForRemoteNotificationsWithDeviceToken_finish" object:nil userInfo: @{@"deviceToken":deviceToken}];
}







- (void)onAudioInterruption:(NSNotification *)notification {
	if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
		if ([[notification.userInfo valueForKey:AVAudioSessionInterruptionTypeKey] isEqualToNumber:[NSNumber numberWithInt:AVAudioSessionInterruptionTypeBegan]]) {
			NSLog(@"Audio interruption began");
			OSIPhone::get_singleton()->on_focus_out();
		} else if ([[notification.userInfo valueForKey:AVAudioSessionInterruptionTypeKey] isEqualToNumber:[NSNumber numberWithInt:AVAudioSessionInterruptionTypeEnded]]) {
			NSLog(@"Audio interruption ended");
			OSIPhone::get_singleton()->on_focus_in();
		}
	}
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
	if (OS::get_singleton()->get_main_loop()) {
		OS::get_singleton()->get_main_loop()->notification(
				MainLoop::NOTIFICATION_OS_MEMORY_WARNING);
	}
}

- (void)applicationWillTerminate:(UIApplication *)application {
	iphone_finish();
}

// When application goes to background (e.g. user switches to another app or presses Home),
// then applicationWillResignActive -> applicationDidEnterBackground are called.
// When user opens the inactive app again,
// applicationWillEnterForeground -> applicationDidBecomeActive are called.

// There are cases when applicationWillResignActive -> applicationDidBecomeActive
// sequence is called without the app going to background. For example, that happens
// if you open the app list without switching to another app or open/close the
// notification panel by swiping from the upper part of the screen.

- (void)applicationWillResignActive:(UIApplication *)application {
	OSIPhone::get_singleton()->on_focus_out();
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	OSIPhone::get_singleton()->on_focus_in();
}

- (void)dealloc {
	self.window = nil;
}

@end
