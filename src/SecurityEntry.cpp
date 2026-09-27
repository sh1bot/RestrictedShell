#define WIN32_LEAN_AND_MEAN
#include <windows.h>

extern "C" void __cdecl __security_init_cookie(void);
extern "C" void WINAPI entry(void);

// This tiny entry point is compiled with /GS- so the security cookie can be
// initialized before control reaches any /GS-protected RestrictedShell code.
extern "C" void WINAPI secure_entry(void)
{
    __security_init_cookie();
    entry();
}
