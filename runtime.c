#include <stdint.h>

// Not declared in trimmed SDK headers; exported by libSystem
extern uint32_t dyld_get_program_sdk_version(void);

// clang emits calls to __isPlatformVersionAtLeast for @available checks.
// Normally provided by compiler-rt (libclang_rt.ios), which Linux toolchains don't ship.
// Semantics: compare the SDK version the host app was linked against (same as Apple's impl).
int32_t __isPlatformVersionAtLeast(uint32_t Platform, uint32_t Major, uint32_t Minor, uint32_t Subminor) {
    uint32_t sdk = dyld_get_program_sdk_version();
    uint32_t sdkMajor = sdk >> 16;
    uint32_t sdkMinor = (sdk >> 8) & 0xFF;
    uint32_t sdkPatch = sdk & 0xFF;
    if (sdkMajor != Major) return sdkMajor > Major;
    if (sdkMinor != Minor) return sdkMinor > Minor;
    return sdkPatch >= Subminor;
}
