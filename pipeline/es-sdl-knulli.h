/* Joystick functions that Knulli's SDL2 adds (board/patches/sdl2/sdl2_input_p003_extra_functions.patch
 * in knulli-linux) and Knulli's ES package patches call. The builds compile against Debian's SDL2
 * headers, which lack them; the firmware build links the firmware's libSDL2, which exports them.
 * Prototypes as in that patch's include/SDL_joystick.h. Forced in with -include by build_es.sh.
 * ES_SDL_KNULLI_STUBS (test_es_functional.sh only): Debian's libSDL2 has no such functions, so the
 * headless build gets stand-ins (no device path, no event codes). */
#ifndef ES_SDL_KNULLI_H
#define ES_SDL_KNULLI_H
#ifdef __cplusplus
extern "C" {
#endif
#ifdef ES_SDL_KNULLI_STUBS
static inline const char *SDL_JoystickDevicePathById(int device_instance_id) { (void)device_instance_id; return ""; }
static inline int SDL_JoystickButtonEventCodeById(int device_instance_id, int button) { (void)device_instance_id; (void)button; return -1; }
static inline int SDL_JoystickAxisEventCodeById(int device_instance_id, int axis) { (void)device_instance_id; (void)axis; return -1; }
static inline int SDL_JoystickHatEventCodeById(int device_instance_id, int hat) { (void)device_instance_id; (void)hat; return -1; }
#else
extern const char *SDL_JoystickDevicePathById(int device_instance_id);
extern int SDL_JoystickButtonEventCodeById(int device_instance_id, int button);
extern int SDL_JoystickAxisEventCodeById(int device_instance_id, int axis);
extern int SDL_JoystickHatEventCodeById(int device_instance_id, int hat);
#endif
#ifdef __cplusplus
}
#endif
#endif
