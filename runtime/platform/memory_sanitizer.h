// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_PLATFORM_MEMORY_SANITIZER_H_
#define RUNTIME_PLATFORM_MEMORY_SANITIZER_H_

#include "platform/globals.h"

// Allow the use of Msan (MemorySanitizer). This is needed as Msan needs to be
// told about areas that are initialized by generated code.
#if defined(__has_feature)
#if __has_feature(memory_sanitizer)
#define USING_MEMORY_SANITIZER
#endif
#if __has_feature(hwaddress_sanitizer)
#define USING_HWADDRESS_SANITIZER
#endif
#endif

#if defined(USING_HWADDRESS_SANITIZER)
extern "C" void __hwasan_handle_longjmp(const void* sp_dst);
#define HWASAN_HANDLE_LONGJMP(sp_dst) __hwasan_handle_longjmp(sp_dst)
#else
#define HWASAN_HANDLE_LONGJMP(sp_dst)                                          \
  do {                                                                         \
  } while (false && (sp_dst) == nullptr)
#endif

#if defined(USING_MEMORY_SANITIZER)
extern "C" void __msan_poison(const volatile void*, size_t);
extern "C" void __msan_unpoison(const volatile void*, size_t);
extern "C" void __msan_unpoison_param(size_t);
extern "C" void __msan_check_mem_is_initialized(const volatile void*, size_t);
#define MSAN_POISON(ptr, len) __msan_poison(ptr, len)
#define MSAN_UNPOISON(ptr, len) __msan_unpoison(ptr, len)
#define MSAN_CHECK_INITIALIZED(ptr, len)                                       \
  __msan_check_mem_is_initialized(ptr, len)
#define NO_SANITIZE_MEMORY __attribute__((no_sanitize("memory")))
#else  // defined(USING_MEMORY_SANITIZER)
#define MSAN_POISON(ptr, len)                                                  \
  do {                                                                         \
  } while (false && (ptr) == nullptr && (len) == 0)
#define MSAN_UNPOISON(ptr, len)                                                \
  do {                                                                         \
  } while (false && (ptr) == nullptr && (len) == 0)
#define MSAN_CHECK_INITIALIZED(ptr, len)                                       \
  do {                                                                         \
  } while (false && (ptr) == nullptr && (len) == 0)
#endif  // defined(USING_MEMORY_SANITIZER)

#endif  // RUNTIME_PLATFORM_MEMORY_SANITIZER_H_
