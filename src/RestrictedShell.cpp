#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>

#pragma comment(lib, "advapi32.lib")

#ifndef PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY
#define PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY ((DWORD_PTR)0x0002000E)
#endif

#ifndef PROCESS_CREATION_CHILD_PROCESS_RESTRICTED
#define PROCESS_CREATION_CHILD_PROCESS_RESTRICTED 0x01
#endif

constexpr int kCommandBufferChars = 32768;
constexpr int kOsdTextChars = 32;
constexpr UINT_PTR kProcessTimerId = 1;
constexpr UINT_PTR kOsdTimerId = 2;

#pragma optimize("", off)
extern "C" void* memset(void* dst, int value, size_t count) {
  unsigned char* output = static_cast<unsigned char*>(dst);
  while (count--) {
    *output++ = static_cast<unsigned char>(value);
  }
  return dst;
}
#pragma optimize("", on)

extern "C" int _fltused = 0;

static HHOOK keyboard_hook;
static HANDLE child_process;
static HWND message_window;
static HWND osd_window;
static UINT shell_hook_message;
static BOOL shell_hook_registered = FALSE;
static MINIMIZEDMETRICS original_minimized_metrics;
static BOOL minimized_metrics_changed = FALSE;
static IMMDeviceEnumerator* device_enumerator;
static WCHAR osd_title[kOsdTextChars];
static WCHAR osd_value[kOsdTextChars];

static WCHAR target_arguments[kCommandBufferChars];
static WCHAR pre_run_arguments[kCommandBufferChars];
static WCHAR pre_run_command[kCommandBufferChars];
static WCHAR command_line[kCommandBufferChars];
static BOOL logoff_on_exit = TRUE;
static BOOL block_shell_hotkeys = TRUE;
static BOOL prevent_child_processes = FALSE;
static BOOL standard_keyboard_volume_shortcuts = FALSE;
static WCHAR ini_path[MAX_PATH];
static WCHAR username[256];

static BOOL IsKeyDown(int virtual_key) {
  return (GetAsyncKeyState(virtual_key) & 0x8000) != 0;
}

static void CopyString(WCHAR* destination, const WCHAR* source, int capacity) {
  if (!capacity) {
    return;
  }

  while (--capacity && (*destination++ = *source++)) {
  }
  *destination = 0;
}

static BOOL AppendString(WCHAR* destination, int capacity,
                         const WCHAR* source) {
  int index = 0;
  while (index < capacity && destination[index]) {
    ++index;
  }

  if (index >= capacity) {
    return FALSE;
  }

  while (*source) {
    if (index + 1 >= capacity) {
      return FALSE;
    }
    destination[index++] = *source++;
  }

  destination[index] = 0;
  return TRUE;
}

static WCHAR ToLowerAscii(WCHAR value) {
  if (value >= L'A' && value <= L'Z') {
    return static_cast<WCHAR>(value + (L'a' - L'A'));
  }
  return value;
}

static BOOL EndsWithCaseInsensitive(const WCHAR* value, const WCHAR* suffix) {
  int value_length = 0;
  int suffix_length = 0;

  while (value[value_length]) {
    ++value_length;
  }
  while (suffix[suffix_length]) {
    ++suffix_length;
  }

  if (suffix_length > value_length) {
    return FALSE;
  }

  for (int i = 0; i < suffix_length; ++i) {
    if (ToLowerAscii(value[value_length - suffix_length + i]) !=
        ToLowerAscii(suffix[i])) {
      return FALSE;
    }
  }

  return TRUE;
}

static void GetWorkingDirectory(const WCHAR* executable, WCHAR* directory) {
  CopyString(directory, executable, MAX_PATH);

  WCHAR* last_separator = nullptr;
  for (WCHAR* cursor = directory; *cursor; ++cursor) {
    if (*cursor == L'\\' || *cursor == L'/') {
      last_separator = cursor;
    }
  }

  if (last_separator) {
    *last_separator = 0;
  } else {
    directory[0] = 0;
  }
}

static BOOL GetSystemExecutable(const WCHAR* relative_path, WCHAR* path) {
  DWORD length = GetWindowsDirectoryW(path, MAX_PATH);
  if (!length || length >= MAX_PATH) {
    return FALSE;
  }
  return AppendString(path, MAX_PATH, relative_path);
}

static BOOL BuildCommandLine(const WCHAR* executable, const WCHAR* arguments) {
  command_line[0] = 0;

  if (!AppendString(command_line, kCommandBufferChars, L"\"") ||
      !AppendString(command_line, kCommandBufferChars, executable) ||
      !AppendString(command_line, kCommandBufferChars, L"\"")) {
    return FALSE;
  }

  if (arguments && arguments[0]) {
    if (!AppendString(command_line, kCommandBufferChars, L" ") ||
        !AppendString(command_line, kCommandBufferChars, arguments)) {
      return FALSE;
    }
  }

  return TRUE;
}

static void ShowOsd(const WCHAR* title, const WCHAR* value) {
  CopyString(osd_title, title, kOsdTextChars);
  CopyString(osd_value, value, kOsdTextChars);

  RECT work_area;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  SetWindowPos(osd_window, HWND_TOPMOST,
               work_area.left + (work_area.right - work_area.left - 360) / 2,
               work_area.top + (work_area.bottom - work_area.top - 104) / 2,
               360, 104, SWP_NOACTIVATE | SWP_SHOWWINDOW);

  InvalidateRect(osd_window, nullptr, TRUE);
  UpdateWindow(osd_window);
  KillTimer(osd_window, kOsdTimerId);
  SetTimer(osd_window, kOsdTimerId, 1200, nullptr);
}

static void FormatPercent(int value, WCHAR* output) {
  WCHAR digits[8];
  WCHAR reversed[8];
  int reversed_length = 0;
  int output_length = 0;

  if (!value) {
    digits[output_length++] = L'0';
  } else {
    while (value) {
      reversed[reversed_length++] =
          static_cast<WCHAR>(L'0' + value % 10);
      value /= 10;
    }
    while (reversed_length) {
      digits[output_length++] = reversed[--reversed_length];
    }
  }

  digits[output_length++] = L'%';
  digits[output_length] = 0;
  CopyString(output, digits, kOsdTextChars);
}

static IAudioEndpointVolume* GetDefaultEndpointVolume(EDataFlow flow,
                                                       ERole role) {
  if (!device_enumerator) {
    return nullptr;
  }

  IMMDevice* device = nullptr;
  IAudioEndpointVolume* volume = nullptr;

  if (SUCCEEDED(
          device_enumerator->GetDefaultAudioEndpoint(flow, role, &device))) {
    device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_INPROC_SERVER,
                     nullptr, reinterpret_cast<void**>(&volume));
    device->Release();
  }

  return volume;
}

static void ShowOutputVolume(IAudioEndpointVolume* volume) {
  if (!volume) {
    ShowOsd(L"Volume", L"ERROR");
    return;
  }

  BOOL muted = FALSE;
  float level = 0;
  if (FAILED(volume->GetMute(&muted)) ||
      FAILED(volume->GetMasterVolumeLevelScalar(&level))) {
    ShowOsd(L"Volume", L"ERROR");
    return;
  }

  if (muted) {
    ShowOsd(L"Volume", L"MUTED");
    return;
  }

  WCHAR percent[kOsdTextChars];
  FormatPercent(static_cast<int>(level * 100.0f + 0.5f), percent);
  ShowOsd(L"Volume", percent);
}

static void AdjustOutputVolume(float delta) {
  IAudioEndpointVolume* volume =
      GetDefaultEndpointVolume(eRender, eMultimedia);

  if (volume) {
    float level;
    if (SUCCEEDED(volume->GetMasterVolumeLevelScalar(&level))) {
      level += delta;
      if (level < 0) {
        level = 0;
      }
      if (level > 1) {
        level = 1;
      }
      volume->SetMasterVolumeLevelScalar(level, nullptr);
    }
  }

  ShowOutputVolume(volume);
  if (volume) {
    volume->Release();
  }
}

static void ToggleOutputMute() {
  IAudioEndpointVolume* volume =
      GetDefaultEndpointVolume(eRender, eMultimedia);

  if (volume) {
    BOOL muted;
    if (SUCCEEDED(volume->GetMute(&muted))) {
      volume->SetMute(!muted, nullptr);
    }
  }

  ShowOutputVolume(volume);
  if (volume) {
    volume->Release();
  }
}

static void ToggleMicrophoneMute() {
  IAudioEndpointVolume* volume =
      GetDefaultEndpointVolume(eCapture, eCommunications);
  if (!volume) {
    ShowOsd(L"Microphone", L"ERROR");
    return;
  }

  BOOL muted = FALSE;
  if (FAILED(volume->GetMute(&muted)) ||
      FAILED(volume->SetMute(!muted, nullptr)) ||
      FAILED(volume->GetMute(&muted))) {
    ShowOsd(L"Microphone", L"ERROR");
  } else {
    ShowOsd(L"Microphone", muted ? L"MUTED" : L"ON");
  }

  volume->Release();
}

static void InitializeAudio() {
  CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                   CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&device_enumerator));
}

static LRESULT CALLBACK KeyboardHookProc(int code, WPARAM wparam,
                                         LPARAM lparam) {
  if (code < 0) {
    return CallNextHookEx(keyboard_hook, code, wparam, lparam);
  }

  auto* key = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
  BOOL key_down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
  BOOL key_up = wparam == WM_KEYUP || wparam == WM_SYSKEYUP;
  if (!key_down && !key_up) {
    return CallNextHookEx(keyboard_hook, code, wparam, lparam);
  }

  DWORD virtual_key = key->vkCode;
  BOOL windows_key = IsKeyDown(VK_LWIN) || IsKeyDown(VK_RWIN) ||
                     virtual_key == VK_LWIN || virtual_key == VK_RWIN;
  BOOL alt_key = IsKeyDown(VK_LMENU) || IsKeyDown(VK_RMENU);
  BOOL control_key = IsKeyDown(VK_LCONTROL) || IsKeyDown(VK_RCONTROL);
  BOOL shift_key = IsKeyDown(VK_LSHIFT) || IsKeyDown(VK_RSHIFT);

  if (key_down) {
    if (virtual_key == VK_VOLUME_UP) {
      AdjustOutputVolume(0.05f);
      return 1;
    }
    if (virtual_key == VK_VOLUME_DOWN) {
      AdjustOutputVolume(-0.05f);
      return 1;
    }
    if (virtual_key == VK_VOLUME_MUTE) {
      ToggleOutputMute();
      return 1;
    }

    if (standard_keyboard_volume_shortcuts && windows_key && alt_key) {
      if (virtual_key == VK_OEM_PLUS) {
        AdjustOutputVolume(0.05f);
        return 1;
      }
      if (virtual_key == VK_OEM_MINUS) {
        AdjustOutputVolume(-0.05f);
        return 1;
      }
      if (virtual_key == 'M') {
        ToggleOutputMute();
        return 1;
      }
    }

    if (windows_key && alt_key && virtual_key == 'K') {
      ToggleMicrophoneMute();
      return 1;
    }

    if (windows_key && virtual_key == 'L') {
      LockWorkStation();
      return 1;
    }

    if (block_shell_hotkeys) {
      if (alt_key && (virtual_key == VK_TAB || virtual_key == VK_ESCAPE)) {
        return 1;
      }
      if (control_key && shift_key && virtual_key == VK_ESCAPE) {
        return 1;
      }
      if (control_key && virtual_key == VK_ESCAPE) {
        return 1;
      }
    }
  }

  // Once the explicitly allowed Windows-key chords above have been handled,
  // consume every other Windows-key chord rather than maintaining a fragile
  // blacklist of shell shortcuts.
  if (block_shell_hotkeys && windows_key) {
    return 1;
  }

  return CallNextHookEx(keyboard_hook, code, wparam, lparam);
}

static void RestoreShellMetrics() {
  if (!minimized_metrics_changed) {
    return;
  }

  SystemParametersInfoW(SPI_SETMINIMIZEDMETRICS,
                        sizeof(original_minimized_metrics),
                        &original_minimized_metrics, 0);
  minimized_metrics_changed = FALSE;
}

static void EnableShellHook() {
  MINIMIZEDMETRICS metrics;
  memset(&metrics, 0, sizeof(metrics));
  metrics.cbSize = sizeof(metrics);

  memset(&original_minimized_metrics, 0, sizeof(original_minimized_metrics));
  original_minimized_metrics.cbSize = sizeof(original_minimized_metrics);

  if (SystemParametersInfoW(SPI_GETMINIMIZEDMETRICS, sizeof(metrics), &metrics,
                            0)) {
    original_minimized_metrics = metrics;
    metrics.iArrange |= ARW_HIDE;
    minimized_metrics_changed = SystemParametersInfoW(
        SPI_SETMINIMIZEDMETRICS, sizeof(metrics), &metrics, 0);
  }

  shell_hook_message = RegisterWindowMessageW(L"SHELLHOOK");
  shell_hook_registered = RegisterShellHookWindow(message_window);
}

static LRESULT CALLBACK OsdWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == WM_TIMER && wparam == kOsdTimerId) {
    KillTimer(hwnd, kOsdTimerId);
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }

  if (message == WM_ERASEBKGND) {
    RECT client_rect;
    GetClientRect(hwnd, &client_rect);

    HBRUSH brush = CreateSolidBrush(RGB(24, 24, 24));
    FillRect(reinterpret_cast<HDC>(wparam), &client_rect, brush);
    DeleteObject(brush);
    return 1;
  }

  if (message == WM_PAINT) {
    PAINTSTRUCT paint;
    HDC device_context = BeginPaint(hwnd, &paint);

    RECT client_rect;
    GetClientRect(hwnd, &client_rect);
    SetBkMode(device_context, TRANSPARENT);
    SetTextColor(device_context, RGB(255, 255, 255));

    HFONT title_font = CreateFontW(
        -21, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
        CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HFONT value_font = CreateFontW(
        -29, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
        CLEARTYPE_QUALITY, 0, L"Segoe UI");

    HGDIOBJ old_font = SelectObject(device_context, title_font);

    RECT text_rect = client_rect;
    text_rect.bottom = 44;
    DrawTextW(device_context, osd_title, -1, &text_rect,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    SelectObject(device_context, value_font);
    text_rect = client_rect;
    text_rect.top = 38;
    DrawTextW(device_context, osd_value, -1, &text_rect,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    SelectObject(device_context, old_font);
    DeleteObject(title_font);
    DeleteObject(value_font);
    EndPaint(hwnd, &paint);
    return 0;
  }

  return DefWindowProcW(hwnd, message, wparam, lparam);
}

static LRESULT CALLBACK MessageWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam) {
  if (shell_hook_message && message == shell_hook_message &&
      wparam == HSHELL_APPCOMMAND) {
    int command = GET_APPCOMMAND_LPARAM(lparam);
    if (command == APPCOMMAND_MICROPHONE_VOLUME_MUTE ||
        command == APPCOMMAND_MIC_ON_OFF_TOGGLE) {
      ToggleMicrophoneMute();
      return TRUE;
    }
  }

  if (message == WM_ENDSESSION && wparam) {
    RestoreShellMetrics();
    return 0;
  }

  if (message == WM_TIMER && wparam == kProcessTimerId && child_process &&
      WaitForSingleObject(child_process, 0) == WAIT_OBJECT_0) {
    KillTimer(hwnd, kProcessTimerId);
    CloseHandle(child_process);
    child_process = nullptr;

    if (logoff_on_exit) {
      if (!ExitWindowsEx(EWX_LOGOFF, 0)) {
        MessageBoxW(nullptr, L"Target exited, but logoff failed.",
                    L"Restricted Shell", MB_ICONERROR);
        PostQuitMessage(1);
      }
    } else {
      PostQuitMessage(0);
    }
    return 0;
  }

  return DefWindowProcW(hwnd, message, wparam, lparam);
}

static void PumpMessages() {
  MSG message;
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    if (message.message == WM_QUIT) {
      continue;
    }
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}

static BOOL WaitForProcessExit(HANDLE process, DWORD* exit_code) {
  for (;;) {
    DWORD result = MsgWaitForMultipleObjects(1, &process, FALSE, INFINITE,
                                             QS_ALLINPUT);
    if (result == WAIT_OBJECT_0) {
      break;
    }
    if (result == WAIT_OBJECT_0 + 1) {
      PumpMessages();
      continue;
    }
    return FALSE;
  }

  return GetExitCodeProcess(process, exit_code);
}

static void BuildIniPath() {
  DWORD length = GetModuleFileNameW(nullptr, ini_path, MAX_PATH);
  if (!length || length >= MAX_PATH) {
    ini_path[0] = 0;
    return;
  }

  WCHAR* last_separator = nullptr;
  for (WCHAR* cursor = ini_path; *cursor; ++cursor) {
    if (*cursor == L'\\' || *cursor == L'/') {
      last_separator = cursor;
    }
  }

  if (last_separator) {
    CopyString(last_separator + 1, L"RestrictedShell.ini",
               MAX_PATH - static_cast<int>(last_separator + 1 - ini_path));
  } else {
    CopyString(ini_path, L"RestrictedShell.ini", MAX_PATH);
  }
}

static void GetConfig(const WCHAR* key, const WCHAR* fallback,
                      WCHAR* output, DWORD output_chars) {
  static WCHAR global_value[kCommandBufferChars];

  global_value[0] = 0;
  GetPrivateProfileStringW(L"RestrictedShell", key, fallback, global_value,
                           kCommandBufferChars, ini_path);

  if (username[0]) {
    GetPrivateProfileStringW(username, key, global_value, output, output_chars,
                             ini_path);
  } else {
    CopyString(output, global_value, static_cast<int>(output_chars));
  }
}

static BOOL StartProcess(const WCHAR* executable, const WCHAR* arguments,
                         const WCHAR* working_directory,
                         BOOL restrict_children, HANDLE* output_process) {
  if (!BuildCommandLine(executable, arguments)) {
    return FALSE;
  }

  PROCESS_INFORMATION process_info;
  memset(&process_info, 0, sizeof(process_info));
  BOOL success = FALSE;

  if (!restrict_children) {
    STARTUPINFOW startup_info;
    memset(&startup_info, 0, sizeof(startup_info));
    startup_info.cb = sizeof(startup_info);

    success = CreateProcessW(
        executable, command_line, nullptr, nullptr, FALSE, 0, nullptr,
        working_directory && working_directory[0] ? working_directory : nullptr,
        &startup_info, &process_info);
  } else {
    SIZE_T attribute_bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
    if (!attribute_bytes) {
      return FALSE;
    }

    auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
        HeapAlloc(GetProcessHeap(), 0, attribute_bytes));
    if (!attributes) {
      return FALSE;
    }

    STARTUPINFOEXW startup_info;
    memset(&startup_info, 0, sizeof(startup_info));
    startup_info.StartupInfo.cb = sizeof(startup_info);
    startup_info.lpAttributeList = attributes;

    if (InitializeProcThreadAttributeList(attributes, 1, 0,
                                          &attribute_bytes)) {
      DWORD policy = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
      if (UpdateProcThreadAttribute(
              attributes, 0, PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY,
              &policy, sizeof(policy), nullptr, nullptr)) {
        success = CreateProcessW(
            executable, command_line, nullptr, nullptr, FALSE,
            EXTENDED_STARTUPINFO_PRESENT, nullptr,
            working_directory && working_directory[0] ? working_directory
                                                       : nullptr,
            &startup_info.StartupInfo, &process_info);
      }
      DeleteProcThreadAttributeList(attributes);
    }

    HeapFree(GetProcessHeap(), 0, attributes);
  }

  if (!success) {
    return FALSE;
  }

  CloseHandle(process_info.hThread);
  *output_process = process_info.hProcess;
  return TRUE;
}

static BOOL RunPreLaunchCommand() {
  WCHAR pre_run_executable[MAX_PATH];
  pre_run_executable[0] = 0;
  GetConfig(L"PreRunExecutable", L"", pre_run_executable, MAX_PATH);
  if (!pre_run_executable[0]) {
    return TRUE;
  }

  pre_run_arguments[0] = 0;
  GetConfig(L"PreRunArguments", L"", pre_run_arguments,
            kCommandBufferChars);

  WCHAR executable[MAX_PATH];
  WCHAR working_directory[MAX_PATH];
  GetWorkingDirectory(pre_run_executable, working_directory);
  CopyString(executable, pre_run_executable, MAX_PATH);
  const WCHAR* arguments = pre_run_arguments;

  if (EndsWithCaseInsensitive(pre_run_executable, L".bat") ||
      EndsWithCaseInsensitive(pre_run_executable, L".cmd")) {
    if (!GetSystemExecutable(L"\\System32\\cmd.exe", executable)) {
      return FALSE;
    }

    pre_run_command[0] = 0;
    if (!AppendString(pre_run_command, kCommandBufferChars, L"/d /s /c \"\"") ||
        !AppendString(pre_run_command, kCommandBufferChars,
                      pre_run_executable) ||
        !AppendString(pre_run_command, kCommandBufferChars, L"\"") ||
        (pre_run_arguments[0] &&
         (!AppendString(pre_run_command, kCommandBufferChars, L" ") ||
          !AppendString(pre_run_command, kCommandBufferChars,
                        pre_run_arguments))) ||
        !AppendString(pre_run_command, kCommandBufferChars, L"\"")) {
      return FALSE;
    }
    arguments = pre_run_command;
  } else if (EndsWithCaseInsensitive(pre_run_executable, L".ps1")) {
    if (!GetSystemExecutable(
            L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            executable)) {
      return FALSE;
    }

    pre_run_command[0] = 0;
    if (!AppendString(pre_run_command, kCommandBufferChars,
                      L"-NoProfile -ExecutionPolicy Bypass -File \"") ||
        !AppendString(pre_run_command, kCommandBufferChars,
                      pre_run_executable) ||
        !AppendString(pre_run_command, kCommandBufferChars, L"\"") ||
        (pre_run_arguments[0] &&
         (!AppendString(pre_run_command, kCommandBufferChars, L" ") ||
          !AppendString(pre_run_command, kCommandBufferChars,
                        pre_run_arguments)))) {
      return FALSE;
    }
    arguments = pre_run_command;
  } else if (EndsWithCaseInsensitive(pre_run_executable, L".py") ||
             EndsWithCaseInsensitive(pre_run_executable, L".pyw")) {
    executable[0] = 0;
    GetConfig(L"PreRunInterpreter", L"", executable, MAX_PATH);
    if (!executable[0]) {
      return FALSE;
    }

    pre_run_command[0] = 0;
    if (!AppendString(pre_run_command, kCommandBufferChars, L"\"") ||
        !AppendString(pre_run_command, kCommandBufferChars,
                      pre_run_executable) ||
        !AppendString(pre_run_command, kCommandBufferChars, L"\"") ||
        (pre_run_arguments[0] &&
         (!AppendString(pre_run_command, kCommandBufferChars, L" ") ||
          !AppendString(pre_run_command, kCommandBufferChars,
                        pre_run_arguments)))) {
      return FALSE;
    }
    arguments = pre_run_command;
  }

  HANDLE process = nullptr;
  if (!StartProcess(executable, arguments, working_directory, FALSE, &process)) {
    return FALSE;
  }

  DWORD exit_code = 1;
  BOOL success = WaitForProcessExit(process, &exit_code) && exit_code == 0;
  CloseHandle(process);
  return success;
}

static BOOL LaunchTarget(const WCHAR* executable) {
  target_arguments[0] = 0;
  GetConfig(L"Arguments", L"", target_arguments, kCommandBufferChars);

  WCHAR working_directory[MAX_PATH];
  GetWorkingDirectory(executable, working_directory);

  return StartProcess(executable, target_arguments, working_directory,
                      prevent_child_processes, &child_process);
}

static void Cleanup() {
  if (keyboard_hook) {
    UnhookWindowsHookEx(keyboard_hook);
    keyboard_hook = nullptr;
  }

  if (shell_hook_registered && message_window) {
    DeregisterShellHookWindow(message_window);
    shell_hook_registered = FALSE;
  }

  RestoreShellMetrics();

  if (child_process) {
    CloseHandle(child_process);
    child_process = nullptr;
  }

  if (device_enumerator) {
    device_enumerator->Release();
    device_enumerator = nullptr;
  }

  CoUninitialize();
}

extern "C" void WINAPI entry() {
  HINSTANCE instance = GetModuleHandleW(nullptr);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  BuildIniPath();

  username[0] = 0;
  DWORD username_chars =
      static_cast<DWORD>(sizeof(username) / sizeof(username[0]));
  if (!GetUserNameW(username, &username_chars)) {
    username[0] = 0;
  }

  WCHAR config_value[16];

  GetConfig(L"LogoffOnExit", L"1", config_value, 16);
  logoff_on_exit = !(config_value[0] == L'0' && config_value[1] == 0);

  GetConfig(L"BlockShellHotkeys", L"1", config_value, 16);
  block_shell_hotkeys = !(config_value[0] == L'0' && config_value[1] == 0);

  GetConfig(L"PreventChildProcesses", L"0", config_value, 16);
  prevent_child_processes =
      !(config_value[0] == L'0' && config_value[1] == 0);

  GetConfig(L"StandardKeyboardVolumeShortcuts", L"0", config_value, 16);
  standard_keyboard_volume_shortcuts =
      !(config_value[0] == L'0' && config_value[1] == 0);

  WNDCLASSW message_class;
  WNDCLASSW osd_class;
  memset(&message_class, 0, sizeof(message_class));
  memset(&osd_class, 0, sizeof(osd_class));

  message_class.lpfnWndProc = MessageWindowProc;
  message_class.hInstance = instance;
  message_class.lpszClassName = L"RSM";
  RegisterClassW(&message_class);

  osd_class.lpfnWndProc = OsdWindowProc;
  osd_class.hInstance = instance;
  osd_class.lpszClassName = L"RSO";
  RegisterClassW(&osd_class);

  message_window = CreateWindowExW(WS_EX_TOOLWINDOW, L"RSM", L"", WS_POPUP,
                                   0, 0, 0, 0, nullptr, nullptr, instance,
                                   nullptr);
  osd_window = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"RSO", L"",
      WS_POPUP, 0, 0, 360, 104, nullptr, nullptr, instance, nullptr);

  InitializeAudio();

  keyboard_hook =
      SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHookProc, instance, 0);
  if (!keyboard_hook) {
    MessageBoxW(nullptr, L"Could not install keyboard hook.",
                L"Restricted Shell", MB_ICONERROR);
    Cleanup();
    ExitProcess(3);
  }

  if (!RunPreLaunchCommand()) {
    MessageBoxW(nullptr,
                L"The configured pre-run program failed or returned an error.",
                L"Restricted Shell", MB_ICONERROR);
    Cleanup();
    ExitProcess(4);
  }

  EnableShellHook();

  WCHAR target_executable[MAX_PATH];
  target_executable[0] = 0;
  GetConfig(L"Executable", L"", target_executable, MAX_PATH);
  if (!target_executable[0] || !LaunchTarget(target_executable)) {
    MessageBoxW(nullptr,
                L"Could not launch Executable in RestrictedShell.ini.",
                L"Restricted Shell", MB_ICONERROR);
    Cleanup();
    ExitProcess(2);
  }

  SetTimer(message_window, kProcessTimerId, 500, nullptr);

  MSG message;
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }

  UINT exit_code = static_cast<UINT>(message.wParam);
  Cleanup();
  ExitProcess(exit_code);
}
