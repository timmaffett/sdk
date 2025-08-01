// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/globals.h"
#if defined(DART_HOST_OS_WINDOWS)

#include "vm/os.h"

#include <malloc.h>   // NOLINT
#include <process.h>  // NOLINT
#include <psapi.h>    // NOLINT
#include <time.h>     // NOLINT

#include "platform/assert.h"
#include "platform/utils.h"
#include "vm/image_snapshot.h"
#include "vm/os_thread.h"
#include "vm/zone.h"

namespace dart {

// Defined in vm/os_thread_win.cc
extern bool private_flag_windows_run_tls_destructors;

intptr_t OS::ProcessId() {
  return static_cast<intptr_t>(GetCurrentProcessId());
}

// 100-nanoseconds intervals from from 1601-01-01 to 1970-01-01.
const int64_t kTimeEpoc = 116444736000000000LL;

static bool LocalTime(int64_t seconds_since_epoch, tm* tm_result) {
  SYSTEMTIME systemTime;
  union {
    FILETIME fileTime;
    ULARGE_INTEGER ulargeInt;
  };
  const int64_t kTimeScaler = 10 * 1000 * 1000;  // 100 ns to s.
  const int64_t hundreds_us = seconds_since_epoch * kTimeScaler;
  ulargeInt.QuadPart = kTimeEpoc + hundreds_us;

  if (!FileTimeToSystemTime(&fileTime, &systemTime)) {
    return false;
  }

  TIME_ZONE_INFORMATION timeZoneInformation;
  if (!GetTimeZoneInformationForYear(systemTime.wYear, nullptr,
                                     &timeZoneInformation)) {
    return false;
  }

  SYSTEMTIME localTime;
  if (!SystemTimeToTzSpecificLocalTime(&timeZoneInformation, &systemTime,
                                       &localTime)) {
    return false;
  }
  // To determine whether the date is in DST or not, if tz has daylight
  // bias set, we run convert system  time to tz-specific time twice: first
  // with the original bias, then with bias reset 0 and compare the result
  // time. If they match, we are oustide of DST, if they don't - we are inside.
  ASSERT(tm_result != nullptr);
  if (timeZoneInformation.DaylightBias == 0) {
    tm_result->tm_isdst = 0;
  } else {
    const auto hourWithDaylightBias = localTime.wHour;
    timeZoneInformation.DaylightBias = 0;
    if (!SystemTimeToTzSpecificLocalTime(&timeZoneInformation, &systemTime,
                                         &localTime)) {
      return false;
    }
    const auto hourWithoutDaylightBias = localTime.wHour;
    tm_result->tm_isdst = hourWithDaylightBias != hourWithoutDaylightBias;
  }

  // Populate the rest of the fields even though they are not really used
  // in this module.
  tm_result->tm_year = localTime.wYear;
  tm_result->tm_mon = localTime.wMonth;
  tm_result->tm_hour = localTime.wHour;
  tm_result->tm_wday = localTime.wDayOfWeek;
  tm_result->tm_mday = localTime.wDay;
  tm_result->tm_min = localTime.wMinute;
  tm_result->tm_sec = localTime.wSecond;
  tm_result->tm_yday = 0;  // Seemingly no easily-available source for this.
  return true;
}

static int GetDaylightSavingBiasInSeconds() {
  TIME_ZONE_INFORMATION zone_information;
  memset(&zone_information, 0, sizeof(zone_information));
  if (GetTimeZoneInformation(&zone_information) == TIME_ZONE_ID_INVALID) {
    // By default the daylight saving offset is an hour.
    return -60 * 60;
  } else {
    return static_cast<int>(zone_information.DaylightBias * 60);
  }
}

const char* OS::GetTimeZoneName(int64_t seconds_since_epoch) {
  TIME_ZONE_INFORMATION zone_information;
  memset(&zone_information, 0, sizeof(zone_information));

  // Initialize and grab the time zone data.
  _tzset();
  DWORD status = GetTimeZoneInformation(&zone_information);
  if (status == TIME_ZONE_ID_INVALID) {
    // If we can't get the time zone data, the Windows docs indicate that we
    // are probably out of memory. Return an empty string.
    return "";
  }

  // Figure out whether we're in standard or daylight.
  tm local_time;
  if (!LocalTime(seconds_since_epoch, &local_time)) {
    return "";
  }
  const bool daylight_savings = (local_time.tm_isdst == 1);

  // Convert the wchar string to a null-terminated utf8 string.
  wchar_t* wchar_name = daylight_savings ? zone_information.DaylightName
                                         : zone_information.StandardName;
  intptr_t utf8_len = WideCharToMultiByte(CP_UTF8, 0, wchar_name, -1, nullptr,
                                          0, nullptr, nullptr);
  char* name = ThreadState::Current()->zone()->Alloc<char>(utf8_len + 1);
  WideCharToMultiByte(CP_UTF8, 0, wchar_name, -1, name, utf8_len, nullptr,
                      nullptr);
  name[utf8_len] = '\0';
  return name;
}

int OS::GetTimeZoneOffsetInSeconds(int64_t seconds_since_epoch) {
  tm decomposed;
  bool succeeded = LocalTime(seconds_since_epoch, &decomposed);
  if (succeeded) {
    int inDaylightSavingsTime = decomposed.tm_isdst;
    ASSERT(inDaylightSavingsTime == 0 || inDaylightSavingsTime == 1);
    tzset();
    // Dart and Windows disagree on the sign of the bias.
    int offset = static_cast<int>(-_timezone);
    if (inDaylightSavingsTime == 1) {
      static int daylight_bias = GetDaylightSavingBiasInSeconds();
      // Subtract because windows and Dart disagree on the sign.
      offset = offset - daylight_bias;
    }
    return offset;
  } else {
    // Return zero like V8 does.
    return 0;
  }
}

int64_t OS::GetCurrentTimeMillis() {
  return GetCurrentTimeMicros() / 1000;
}

int64_t OS::GetCurrentTimeMicros() {
  const int64_t kTimeScaler = 10;  // 100 ns to us.

  // Although win32 uses 64-bit integers for representing timestamps,
  // these are packed into a FILETIME structure. The FILETIME
  // structure is just a struct representing a 64-bit integer. The
  // TimeStamp union allows access to both a FILETIME and an integer
  // representation of the timestamp. The Windows timestamp is in
  // 100-nanosecond intervals since January 1, 1601.
  union TimeStamp {
    FILETIME ft_;
    int64_t t_;
  };
  TimeStamp time;
  GetSystemTimeAsFileTime(&time.ft_);
  return (time.t_ - kTimeEpoc) / kTimeScaler;
}

static int64_t qpc_ticks_per_second = 0;

int64_t OS::GetCurrentMonotonicTicks() {
  if (qpc_ticks_per_second == 0) {
    // QueryPerformanceCounter not supported, fallback.
    return GetCurrentTimeMicros();
  }
  // Grab performance counter value.
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  return static_cast<int64_t>(now.QuadPart);
}

int64_t OS::GetCurrentMonotonicFrequency() {
  if (qpc_ticks_per_second == 0) {
    // QueryPerformanceCounter not supported, fallback.
    return kMicrosecondsPerSecond;
  }
  return qpc_ticks_per_second;
}

int64_t OS::GetCurrentMonotonicMicros() {
  int64_t ticks = GetCurrentMonotonicTicks();
  int64_t frequency = GetCurrentMonotonicFrequency();

  // Convert to microseconds.
  int64_t seconds = ticks / frequency;
  int64_t leftover_ticks = ticks - (seconds * frequency);
  int64_t result = seconds * kMicrosecondsPerSecond;
  result += ((leftover_ticks * kMicrosecondsPerSecond) / frequency);
  return result;
}

int64_t OS::GetCurrentThreadCPUMicros() {
  // TODO(johnmccutchan): Implement. See base/time_win.cc for details.
  return -1;
}

int64_t OS::GetCurrentMonotonicMicrosForTimeline() {
#if defined(SUPPORT_TIMELINE)
  return OS::GetCurrentMonotonicMicros();
#else
  return -1;
#endif
}

intptr_t OS::ActivationFrameAlignment() {
#if defined(TARGET_ARCH_ARM64)
  return 16;
#elif defined(TARGET_ARCH_ARM)
  return 8;
#elif defined(_WIN64)
  // Windows 64-bit ABI requires the stack to be 16-byte aligned.
  return 16;
#else
  // No requirements on Win32.
  return 1;
#endif
}

int OS::NumberOfAvailableProcessors() {
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return info.dwNumberOfProcessors;
}

uintptr_t OS::CurrentRSS() {
// Although the documentation at
// https://docs.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo
// claims that GetProcessMemoryInfo is UWP compatible, it is actually not
// hence this function cannot work when compiled in UWP mode.
#ifdef DART_TARGET_OS_WINDOWS_UWP
  return 0;
#else
  PROCESS_MEMORY_COUNTERS pmc;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
    return 0;
  }
  return pmc.WorkingSetSize;
#endif
}

void OS::Sleep(int64_t millis) {
  ::Sleep(millis);
}

void OS::SleepMicros(int64_t micros) {
  // Windows only supports millisecond sleeps.
  if (micros < kMicrosecondsPerMillisecond) {
    // Calling ::Sleep with 0 has no determined behaviour, round up.
    micros = kMicrosecondsPerMillisecond;
  }
  OS::Sleep(micros / kMicrosecondsPerMillisecond);
}

void OS::DebugBreak() {
#if defined(_MSC_VER)
  // Microsoft Visual C/C++ or drop-in replacement.
  __debugbreak();
#elif defined(__GCC__)
  __builtin_trap();
#else
  // Microsoft style assembly.
  __asm {
    int 3
  }
#endif
}

DART_NOINLINE uintptr_t OS::GetProgramCounter() {
  return reinterpret_cast<uintptr_t>(_ReturnAddress());
}

void OS::Print(const char* format, ...) {
  va_list args;
  va_start(args, format);
  VFPrint(stdout, format, args);
  va_end(args);
}

void OS::VFPrint(FILE* stream, const char* format, va_list args) {
  vfprintf(stream, format, args);
  fflush(stream);
}

char* OS::SCreate(Zone* zone, const char* format, ...) {
  va_list args;
  va_start(args, format);
  char* buffer = VSCreate(zone, format, args);
  va_end(args);
  return buffer;
}

char* OS::VSCreate(Zone* zone, const char* format, va_list args) {
  // Measure.
  va_list measure_args;
  va_copy(measure_args, args);
  intptr_t len = Utils::VSNPrint(nullptr, 0, format, measure_args);
  va_end(measure_args);

  char* buffer;
  if (zone) {
    buffer = zone->Alloc<char>(len + 1);
  } else {
    buffer = reinterpret_cast<char*>(malloc(len + 1));
  }
  ASSERT(buffer != nullptr);

  // Print.
  va_list print_args;
  va_copy(print_args, args);
  Utils::VSNPrint(buffer, len + 1, format, print_args);
  va_end(print_args);
  return buffer;
}

bool OS::ParseInitialInt64(const char* str, int64_t* value, char** end) {
  ASSERT(str != nullptr && strlen(str) > 0 && value != nullptr &&
         end != nullptr);
  int32_t base = 10;
  int i = 0;
  if (str[0] == '-') {
    i = 1;
  } else if (str[0] == '+') {
    i = 1;
  }
  if ((str[i] == '0') && (str[i + 1] == 'x' || str[i + 1] == 'X') &&
      (str[i + 2] != '\0')) {
    base = 16;
  }
  errno = 0;
  if (base == 16) {
    // Unsigned 64-bit hexadecimal integer literals are allowed but
    // immediately interpreted as signed 64-bit integers.
    *value = static_cast<int64_t>(_strtoui64(str, end, base));
  } else {
    *value = _strtoi64(str, end, base);
  }
  return (errno == 0) && (*end != str);
}

void OS::RegisterCodeObservers() {}

void OS::PrintErr(const char* format, ...) {
  va_list args;
  va_start(args, format);
  VFPrint(stderr, format, args);
  va_end(args);
}

void OS::Init() {
  static bool init_once_called = false;
  if (init_once_called) {
    return;
  }
  init_once_called = true;
  // Do not pop up a message box when abort is called.
  _set_abort_behavior(0, _WRITE_ABORT_MSG);
  ThreadLocalData::Init();
  LARGE_INTEGER ticks_per_sec;
  if (!QueryPerformanceFrequency(&ticks_per_sec)) {
    qpc_ticks_per_second = 0;
  } else {
    qpc_ticks_per_second = static_cast<int64_t>(ticks_per_sec.QuadPart);
  }
}

void OS::Cleanup() {
  // TODO(zra): Enable once VM can shutdown cleanly.
  // ThreadLocalData::Cleanup();
}

void OS::PrepareToAbort() {
  // TODO(zra): Remove once VM shuts down cleanly.
  private_flag_windows_run_tls_destructors = false;
}

void OS::Abort() {
  PrepareToAbort();
  abort();
}

void OS::Exit(int code) {
  // TODO(zra): Remove once VM shuts down cleanly.
  private_flag_windows_run_tls_destructors = false;
  // On Windows we use ExitProcess so that threads can't clobber the exit_code.
  // See: https://code.google.com/p/nativeclient/issues/detail?id=2870
  ::ExitProcess(code);
}

OS::BuildId OS::GetAppBuildId(const uint8_t* snapshot_instructions) {
  // Return the build ID information from the instructions image if available.
  const Image instructions_image(snapshot_instructions);
  if (auto* const image_build_id = instructions_image.build_id()) {
    return {instructions_image.build_id_length(), image_build_id};
  }
  return {0, nullptr};
}

}  // namespace dart

#endif  // defined(DART_HOST_OS_WINDOWS)
