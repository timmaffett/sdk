// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/dart_api_impl.h"

#include <thread>  // NOLINT(build/c++11)

#include "bin/builtin.h"
#include "bin/dartutils.h"
#include "include/dart_api.h"
#include "include/dart_native_api.h"
#include "include/dart_tools_api.h"
#include "platform/assert.h"
#include "platform/text_buffer.h"
#include "platform/utils.h"
#include "vm/class_finalizer.h"
#include "vm/compiler/jit/compiler.h"
#include "vm/dart.h"
#include "vm/dart_api_state.h"
#include "vm/debugger_api_impl_test.h"
#include "vm/flags.h"
#include "vm/heap/verifier.h"
#include "vm/lockers.h"
#include "vm/native_message_handler.h"
#include "vm/timeline.h"
#include "vm/unit_test.h"

namespace dart {

DECLARE_FLAG(bool, verify_acquired_data);
DECLARE_FLAG(bool, complete_timeline);

#ifndef PRODUCT

UNIT_TEST_CASE(DartAPI_DartInitializeAfterCleanup) {
  EXPECT(Dart_SetVMFlags(TesterState::argc, TesterState::argv) == nullptr);
  Dart_InitializeParams params;
  memset(&params, 0, sizeof(Dart_InitializeParams));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.vm_snapshot_data = TesterState::vm_snapshot_data;
  params.create_group = TesterState::create_callback;
  params.shutdown_isolate = TesterState::shutdown_callback;
  params.cleanup_group = TesterState::group_cleanup_callback;
  params.start_kernel_isolate = true;

  // Reinitialize and ensure we can execute Dart code.
  EXPECT(Dart_Initialize(&params) == nullptr);
  {
    TestIsolateScope scope;
    const char* kScriptChars =
        "@pragma('vm:entry-point', 'call')\n"
        "int testMain() {\n"
        "  return 42;\n"
        "}\n";
    Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
    EXPECT_VALID(lib);
    Dart_Handle result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
    EXPECT_VALID(result);
    int64_t value = 0;
    EXPECT_VALID(Dart_IntegerToInt64(result, &value));
    EXPECT_EQ(42, value);
  }
  EXPECT(Dart_Cleanup() == nullptr);
}

UNIT_TEST_CASE(DartAPI_DartInitializeCallsCodeObserver) {
  EXPECT(Dart_SetVMFlags(TesterState::argc, TesterState::argv) == nullptr);
  Dart_InitializeParams params;
  memset(&params, 0, sizeof(Dart_InitializeParams));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.vm_snapshot_data = TesterState::vm_snapshot_data;
  params.create_group = TesterState::create_callback;
  params.shutdown_isolate = TesterState::shutdown_callback;
  params.cleanup_group = TesterState::group_cleanup_callback;
  params.start_kernel_isolate = true;

  bool was_called = false;
  Dart_CodeObserver code_observer;
  code_observer.data = &was_called;
  code_observer.on_new_code = [](Dart_CodeObserver* observer, const char* name,
                                 uintptr_t base, uintptr_t size) {
    *static_cast<bool*>(observer->data) = true;
  };
  params.code_observer = &code_observer;

  // Reinitialize and ensure we can execute Dart code.
  EXPECT(Dart_Initialize(&params) == nullptr);

  // Wait for 5 seconds to let the kernel service load the snapshot,
  // which should trigger calls to the code observer.
  OS::Sleep(5);

  EXPECT(was_called);
  EXPECT(Dart_Cleanup() == nullptr);
}

UNIT_TEST_CASE(DartAPI_DartInitializeHeapSizes) {
  Dart_InitializeParams params;
  memset(&params, 0, sizeof(Dart_InitializeParams));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.vm_snapshot_data = TesterState::vm_snapshot_data;
  params.create_group = TesterState::create_callback;
  params.shutdown_isolate = TesterState::shutdown_callback;
  params.cleanup_group = TesterState::group_cleanup_callback;
  params.start_kernel_isolate = true;

  // Initialize with a normal heap size specification.
  const char* options_1[] = {"--old-gen-heap-size=3192",
                             "--new-gen-semi-max-size=32"};
  EXPECT(Dart_SetVMFlags(2, options_1) == nullptr);
  EXPECT(Dart_Initialize(&params) == nullptr);
  EXPECT(FLAG_old_gen_heap_size == 3192);
  EXPECT(FLAG_new_gen_semi_max_size == 32);
  EXPECT(Dart_Cleanup() == nullptr);

  const char* options_2[] = {"--old-gen-heap-size=16384",
                             "--new-gen-semi-max-size=16384"};
  EXPECT(Dart_SetVMFlags(2, options_2) == nullptr);
  EXPECT(Dart_Initialize(&params) == nullptr);
  if (kMaxAddrSpaceMB == 4096) {
    EXPECT(FLAG_old_gen_heap_size == 0);
    EXPECT(FLAG_new_gen_semi_max_size == kDefaultNewGenSemiMaxSize);
  } else {
    EXPECT(FLAG_old_gen_heap_size == 16384);
    EXPECT(FLAG_new_gen_semi_max_size == 16384);
  }
  EXPECT(Dart_Cleanup() == nullptr);

  const char* options_3[] = {"--old-gen-heap-size=30720",
                             "--new-gen-semi-max-size=30720"};
  EXPECT(Dart_SetVMFlags(2, options_3) == nullptr);
  EXPECT(Dart_Initialize(&params) == nullptr);
  if (kMaxAddrSpaceMB == 4096) {
    EXPECT(FLAG_old_gen_heap_size == 0);
    EXPECT(FLAG_new_gen_semi_max_size == kDefaultNewGenSemiMaxSize);
  } else {
    EXPECT(FLAG_old_gen_heap_size == 30720);
    EXPECT(FLAG_new_gen_semi_max_size == 30720);
  }
  EXPECT(Dart_Cleanup() == nullptr);
}

static RelaxedAtomic<intptr_t> pending_isolate_groups = 0;
static Dart_Isolate CreateCallback(const char* script_uri,
                                   const char* main,
                                   const char* package_root,
                                   const char* package_config,
                                   Dart_IsolateFlags* flags,
                                   void* isolate_data,
                                   char** error) {
  pending_isolate_groups++;
  return TesterState::create_callback(script_uri, main, package_root,
                                      package_config, flags, isolate_data,
                                      error);
}
static void CleanupCallback(void* isolate_group_data) {
  TesterState::group_cleanup_callback(isolate_group_data);
  OS::Sleep(3000);
  pending_isolate_groups--;
}

UNIT_TEST_CASE(DartAPI_DartCleanupWaitsForGroupCleanupCallbacks) {
  EXPECT(Dart_SetVMFlags(TesterState::argc, TesterState::argv) == nullptr);

  Dart_InitializeParams params;
  memset(&params, 0, sizeof(Dart_InitializeParams));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.vm_snapshot_data = TesterState::vm_snapshot_data;
  params.create_group = CreateCallback;
  params.shutdown_isolate = TesterState::shutdown_callback;
  params.cleanup_group = CleanupCallback;
  params.start_kernel_isolate = true;
  EXPECT(Dart_Initialize(&params) == nullptr);

  Monitor monitor;
  bool shutting_down = false;
  std::thread thread(
      [](Monitor* monitor, bool* shutting_down) {
        TestIsolateScope scope;
        const char* kScriptChars =
            "@pragma('vm:entry-point', 'call')\n"
            "int testMain() {\n"
            "  return 42;\n"
            "}\n";
        Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
        EXPECT_VALID(lib);
        Dart_Handle result =
            Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
        EXPECT_VALID(result);
        int64_t value = 0;
        EXPECT_VALID(Dart_IntegerToInt64(result, &value));
        EXPECT_EQ(42, value);

        MonitorLocker ml(monitor);
        *shutting_down = true;
        ml.Notify();
      },
      &monitor, &shutting_down);

  {
    MonitorLocker ml(&monitor);
    while (!shutting_down) {
      ml.Wait();
    }
  }

  EXPECT(Dart_Cleanup() == nullptr);
  EXPECT_EQ(0, pending_isolate_groups);

  thread.join();
}

TEST_CASE(Dart_KillIsolate) {
  const char* kScriptChars =
      "@pragma('vm:entry-point', 'call')\n"
      "int testMain() {\n"
      "  return 42;\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
  int64_t value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(result, &value));
  EXPECT_EQ(42, value);
  Dart_Isolate isolate = reinterpret_cast<Dart_Isolate>(Isolate::Current());
  Dart_KillIsolate(isolate);
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("isolate terminated by Isolate.kill", Dart_GetError(result));
}

class InfiniteLoopTask : public ThreadPool::Task {
 public:
  InfiniteLoopTask(Dart_Isolate* isolate, Monitor* monitor, bool* interrupted)
      : isolate_(isolate), monitor_(monitor), interrupted_(interrupted) {}
  virtual void Run() {
    TestIsolateScope scope;
    const char* kScriptChars =
        "@pragma('vm:entry-point', 'call')\n"
        "testMain() {\n"
        "  while(true) {};"
        "}\n";
    Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
    EXPECT_VALID(lib);
    *isolate_ = reinterpret_cast<Dart_Isolate>(Isolate::Current());
    {
      MonitorLocker ml(monitor_);
      ml.Notify();
    }
    Dart_Handle result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
    // Test should run an infinite loop and expect that to be killed.
    EXPECT(Dart_IsError(result));
    EXPECT_STREQ("isolate terminated by Isolate.kill", Dart_GetError(result));
    {
      MonitorLocker ml(monitor_);
      *interrupted_ = true;
      ml.Notify();
    }
  }

 private:
  Dart_Isolate* isolate_;
  Monitor* monitor_;
  bool* interrupted_;
};

TEST_CASE(Dart_KillIsolatePriority) {
  Monitor monitor;
  bool interrupted = false;
  Dart_Isolate isolate;
  Dart::thread_pool()->Run<InfiniteLoopTask>(&isolate, &monitor, &interrupted);
  {
    MonitorLocker ml(&monitor);
    ml.Wait();
  }

  Dart_KillIsolate(isolate);

  {
    MonitorLocker ml(&monitor);
    while (!interrupted) {
      ml.Wait();
    }
  }
  EXPECT(interrupted);
}

TEST_CASE(DartAPI_IsolateOwnership) {
  Dart_Handle lib = TestCase::LoadTestScript("", nullptr);
  EXPECT_VALID(lib);

  Dart_Isolate isolate = Dart_CurrentIsolate();

  NativeMessageHandler dummy_handler("test", nullptr, 1);
  Dart_Port dummy_port = PortMap::CreatePort(&dummy_handler);

  Dart_Port port = Dart_GetMainPortId();
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(dummy_port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(ILLEGAL_PORT));

  Dart_SetCurrentThreadOwnsIsolate();
  EXPECT_EQ(true, Dart_GetCurrentThreadOwnsIsolate(port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(dummy_port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(ILLEGAL_PORT));

  Dart_ExitIsolate();
  EXPECT_EQ(true, Dart_GetCurrentThreadOwnsIsolate(port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(dummy_port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(ILLEGAL_PORT));

  Dart_Port other_port;
  std::thread([port, dummy_port, isolate, &other_port]() {
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(port));
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(dummy_port));
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(ILLEGAL_PORT));

    char* error = nullptr;
    Dart_CreateIsolateInGroup(isolate, "other", nullptr, nullptr, nullptr,
                              &error);
    EXPECT_EQ(nullptr, error);
    other_port = Dart_GetMainPortId();
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(other_port));

    Dart_SetCurrentThreadOwnsIsolate();
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(port));
    EXPECT_EQ(true, Dart_GetCurrentThreadOwnsIsolate(other_port));
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(dummy_port));
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(ILLEGAL_PORT));

    Dart_ShutdownIsolate();
  }).join();

  EXPECT_EQ(true, Dart_GetCurrentThreadOwnsIsolate(port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(other_port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(dummy_port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(ILLEGAL_PORT));

  Dart_EnterIsolate(isolate);
  EXPECT_EQ(true, Dart_GetCurrentThreadOwnsIsolate(port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(other_port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(dummy_port));
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(ILLEGAL_PORT));

  Dart_ExitIsolate();
  PortMap::ClosePort(dummy_port);
  Dart_EnterIsolate(isolate);
}

TEST_CASE_WITH_EXPECTATION(DartAPI_IsolateOwnership_SetWhenAlreadyOwned,
                           "Crash") {
  Dart_Handle lib = TestCase::LoadTestScript("", nullptr);
  EXPECT_VALID(lib);

  Dart_Port port = Dart_GetMainPortId();
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(port));

  Dart_SetCurrentThreadOwnsIsolate();
  EXPECT_EQ(true, Dart_GetCurrentThreadOwnsIsolate(port));

  // Causes an assertion failure, because this thread already owns the isolate.
  Dart_SetCurrentThreadOwnsIsolate();
}

TEST_CASE_WITH_EXPECTATION(
    DartAPI_IsolateOwnership_EnterIsolateOwnedByOtherThread,
    "Crash") {
  Dart_Handle lib = TestCase::LoadTestScript("", nullptr);
  EXPECT_VALID(lib);

  Dart_Isolate isolate = Dart_CurrentIsolate();

  Dart_Port port = Dart_GetMainPortId();
  EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(port));

  Dart_SetCurrentThreadOwnsIsolate();
  EXPECT_EQ(true, Dart_GetCurrentThreadOwnsIsolate(port));

  Dart_ExitIsolate();

  std::thread([isolate, port]() {
    EXPECT_EQ(false, Dart_GetCurrentThreadOwnsIsolate(port));

    // Causes an assertion failure, because the isolate is already owned by
    // another thread.
    Dart_EnterIsolate(isolate);
  }).join();

  Dart_EnterIsolate(isolate);
}

TEST_CASE(DartAPI_ErrorHandleBasics) {
  const char* kScriptChars =
      "@pragma('vm:entry-point', 'call')\n"
      "void testMain() {\n"
      "  throw new Exception(\"bad news\");\n"
      "}\n";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle instance = Dart_True();
  Dart_Handle error = Api::NewError("myerror");
  Dart_Handle exception = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);

  EXPECT_VALID(instance);
  EXPECT(Dart_IsError(error));
  EXPECT(Dart_IsError(exception));

  EXPECT(!Dart_ErrorHasException(instance));
  EXPECT(!Dart_ErrorHasException(error));
  EXPECT(Dart_ErrorHasException(exception));

  EXPECT_STREQ("", Dart_GetError(instance));
  EXPECT_STREQ("myerror", Dart_GetError(error));
  EXPECT_STREQ(ZONE_STR("Unhandled exception:\n"
                        "Exception: bad news\n"
                        "#0      testMain (%s:3:3)",
                        TestCase::url()),
               Dart_GetError(exception));

  EXPECT(Dart_IsError(Dart_ErrorGetException(instance)));
  EXPECT(Dart_IsError(Dart_ErrorGetException(error)));
  EXPECT_VALID(Dart_ErrorGetException(exception));
  EXPECT(Dart_IsError(Dart_ErrorGetStackTrace(instance)));
  EXPECT(Dart_IsError(Dart_ErrorGetStackTrace(error)));
  EXPECT_VALID(Dart_ErrorGetStackTrace(exception));
}

TEST_CASE(DartAPI_StackTraceInfo) {
  const char* kScriptChars =
      "bar() => throw new Error();\n"
      "foo() => bar();\n"
      "@pragma('vm:entry-point', 'call')\n"
      "testMain() => foo();\n";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle error = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);

  EXPECT(Dart_IsError(error));

  Dart_StackTrace stacktrace;
  Dart_Handle result = Dart_GetStackTraceFromError(error, &stacktrace);
  EXPECT_VALID(result);

  intptr_t frame_count = 0;
  result = Dart_StackTraceLength(stacktrace, &frame_count);
  EXPECT_VALID(result);
  EXPECT_EQ(3, frame_count);

  Dart_Handle function_name;
  Dart_Handle script_url;
  intptr_t line_number = 0;
  intptr_t column_number = 0;
  const char* cstr = "";

  Dart_ActivationFrame frame;
  result = Dart_GetActivationFrame(stacktrace, 0, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("bar", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_SUBSTRING("test-lib", cstr);
  EXPECT_EQ(1, line_number);
  EXPECT_EQ(10, column_number);

  result = Dart_GetActivationFrame(stacktrace, 1, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("foo", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_SUBSTRING("test-lib", cstr);
  EXPECT_EQ(2, line_number);
  EXPECT_EQ(10, column_number);

  result = Dart_GetActivationFrame(stacktrace, 2, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("testMain", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_SUBSTRING("test-lib", cstr);
  EXPECT_EQ(4, line_number);
  EXPECT_EQ(15, column_number);

  // Out-of-bounds frames.
  result = Dart_GetActivationFrame(stacktrace, frame_count, &frame);
  EXPECT(Dart_IsError(result));
  result = Dart_GetActivationFrame(stacktrace, -1, &frame);
  EXPECT(Dart_IsError(result));
}

TEST_CASE(DartAPI_DeepStackTraceInfo) {
  const char* kScriptChars =
      "foo(n) => n == 1 ? throw new Error() : foo(n-1);\n"
      "@pragma('vm:entry-point', 'call')\n"
      "testMain() => foo(100);\n";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle error = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);

  EXPECT(Dart_IsError(error));

  Dart_StackTrace stacktrace;
  Dart_Handle result = Dart_GetStackTraceFromError(error, &stacktrace);
  EXPECT_VALID(result);

  intptr_t frame_count = 0;
  result = Dart_StackTraceLength(stacktrace, &frame_count);
  EXPECT_VALID(result);
  EXPECT_EQ(101, frame_count);
  // Test something bigger than the preallocated size to verify nothing was
  // truncated.
  EXPECT(101 > StackTrace::kFixedOOMStackdepth);

  Dart_Handle function_name;
  Dart_Handle script_url;
  intptr_t line_number = 0;
  intptr_t column_number = 0;
  const char* cstr = "";

  // Top frame at positioned at throw.
  Dart_ActivationFrame frame;
  result = Dart_GetActivationFrame(stacktrace, 0, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("foo", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_SUBSTRING("test-lib", cstr);
  EXPECT_EQ(1, line_number);
  EXPECT_EQ(20, column_number);

  // Middle frames positioned at the recursive call.
  for (intptr_t frame_index = 1; frame_index < (frame_count - 1);
       frame_index++) {
    result = Dart_GetActivationFrame(stacktrace, frame_index, &frame);
    EXPECT_VALID(result);
    result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                      &line_number, &column_number);
    EXPECT_VALID(result);
    Dart_StringToCString(function_name, &cstr);
    EXPECT_STREQ("foo", cstr);
    Dart_StringToCString(script_url, &cstr);
    EXPECT_SUBSTRING("test-lib", cstr);
    EXPECT_EQ(1, line_number);
    EXPECT_EQ(40, column_number);
  }

  // Bottom frame positioned at testMain().
  result = Dart_GetActivationFrame(stacktrace, frame_count - 1, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("testMain", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_SUBSTRING("test-lib", cstr);
  EXPECT_EQ(3, line_number);
  EXPECT_EQ(15, column_number);

  // Out-of-bounds frames.
  result = Dart_GetActivationFrame(stacktrace, frame_count, &frame);
  EXPECT(Dart_IsError(result));
  result = Dart_GetActivationFrame(stacktrace, -1, &frame);
  EXPECT(Dart_IsError(result));
}

void VerifyStackOverflowStackTraceInfo(const char* script,
                                       const char* top_frame_func_name,
                                       const char* entry_func_name,
                                       int expected_line_number,
                                       int expected_column_number) {
  Dart_Handle lib = TestCase::LoadTestScript(script, nullptr);
  Dart_Handle error;
  {
    SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
    error = Dart_Invoke(lib, NewString(entry_func_name), 0, nullptr);
  }
  EXPECT(Dart_IsError(error));

  Dart_StackTrace stacktrace;
  Dart_Handle result = Dart_GetStackTraceFromError(error, &stacktrace);
  EXPECT_VALID(result);

  intptr_t frame_count = 0;
  result = Dart_StackTraceLength(stacktrace, &frame_count);
  EXPECT_VALID(result);
  EXPECT_EQ(StackTrace::kFixedOOMStackdepth - 1, frame_count);

  Dart_Handle function_name;
  Dart_Handle script_url;
  intptr_t line_number = 0;
  intptr_t column_number = 0;
  const char* cstr = "";

  // Top frame at recursive call.
  Dart_ActivationFrame frame;
  result = Dart_GetActivationFrame(stacktrace, 0, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ(top_frame_func_name, cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_STREQ(TestCase::url(), cstr);
  EXPECT_EQ(expected_line_number, line_number);
  EXPECT_EQ(expected_column_number, column_number);

  // Out-of-bounds frames.
  result = Dart_GetActivationFrame(stacktrace, frame_count, &frame);
  EXPECT(Dart_IsError(result));
  result = Dart_GetActivationFrame(stacktrace, -1, &frame);
  EXPECT(Dart_IsError(result));
}

TEST_CASE(DartAPI_StackOverflowStackTraceInfoBraceFunction1) {
  int line = 2;
  int col = 3;
  VerifyStackOverflowStackTraceInfo(
      "class C {\n"
      "  static foo(int i) { foo(i); }\n"
      "}\n"
      "testMain() => C.foo(10);\n",
      "C.foo", "testMain", line, col);
}

TEST_CASE(DartAPI_StackOverflowStackTraceInfoBraceFunction2) {
  int line = 2;
  int col = 3;
  VerifyStackOverflowStackTraceInfo(
      "class C {\n"
      "  static foo(int i, int j) {\n"
      "    foo(i, j);\n"
      "  }\n"
      "}\n"
      "testMain() => C.foo(10, 11);\n",
      "C.foo", "testMain", line, col);
}

TEST_CASE(DartAPI_StackOverflowStackTraceInfoArrowFunction) {
  int line = 2;
  int col = 3;
  VerifyStackOverflowStackTraceInfo(
      "class C {\n"
      "  static foo(int i) => foo(i);\n"
      "}\n"
      "testMain() => C.foo(10);\n",
      "C.foo", "testMain", line, col);
}

TEST_CASE(DartAPI_OutOfMemoryStackTraceInfo) {
  const char* kScriptChars =
      "var number_of_ints = 134000000;\n"
      "@pragma('vm:entry-point', 'call')"
      "testMain() {\n"
      "  new List<int>(number_of_ints)\n"
      "}\n";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle error = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);

  EXPECT(Dart_IsError(error));

  Dart_StackTrace stacktrace;
  Dart_Handle result = Dart_GetStackTraceFromError(error, &stacktrace);
  EXPECT(Dart_IsError(result));  // No StackTrace for OutOfMemory.
}

void CurrentStackTraceNative(Dart_NativeArguments args) {
  Dart_EnterScope();

  Dart_StackTrace stacktrace;
  Dart_Handle result = Dart_GetStackTrace(&stacktrace);
  EXPECT_VALID(result);

  intptr_t frame_count = 0;
  result = Dart_StackTraceLength(stacktrace, &frame_count);
  EXPECT_VALID(result);
  EXPECT_EQ(102, frame_count);
  // Test something bigger than the preallocated size to verify nothing was
  // truncated.
  EXPECT(102 > StackTrace::kFixedOOMStackdepth);

  Dart_Handle function_name;
  Dart_Handle script_url;
  intptr_t line_number = 0;
  intptr_t column_number = 0;
  const char* cstr = "";
  const char* test_lib = "file:///test-lib";

  // Top frame is inspectStack().
  Dart_ActivationFrame frame;
  result = Dart_GetActivationFrame(stacktrace, 0, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("inspectStack", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_STREQ(test_lib, cstr);
  EXPECT_EQ(3, line_number);
  EXPECT_EQ(24, column_number);

  // Second frame is foo() positioned at call to inspectStack().
  result = Dart_GetActivationFrame(stacktrace, 1, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("foo", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_STREQ(test_lib, cstr);
  EXPECT_EQ(4, line_number);
  EXPECT_EQ(20, column_number);

  // Middle frames positioned at the recursive call.
  for (intptr_t frame_index = 2; frame_index < (frame_count - 1);
       frame_index++) {
    result = Dart_GetActivationFrame(stacktrace, frame_index, &frame);
    EXPECT_VALID(result);
    result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                      &line_number, &column_number);
    EXPECT_VALID(result);
    Dart_StringToCString(function_name, &cstr);
    EXPECT_STREQ("foo", cstr);
    Dart_StringToCString(script_url, &cstr);
    EXPECT_STREQ(test_lib, cstr);
    EXPECT_EQ(4, line_number);
    EXPECT_EQ(37, column_number);
  }

  // Bottom frame positioned at testMain().
  result = Dart_GetActivationFrame(stacktrace, frame_count - 1, &frame);
  EXPECT_VALID(result);
  result = Dart_ActivationFrameInfo(frame, &function_name, &script_url,
                                    &line_number, &column_number);
  EXPECT_VALID(result);
  Dart_StringToCString(function_name, &cstr);
  EXPECT_STREQ("testMain", cstr);
  Dart_StringToCString(script_url, &cstr);
  EXPECT_STREQ(test_lib, cstr);
  EXPECT_EQ(6, line_number);
  EXPECT_EQ(15, column_number);

  // Out-of-bounds frames.
  result = Dart_GetActivationFrame(stacktrace, frame_count, &frame);
  EXPECT(Dart_IsError(result));
  result = Dart_GetActivationFrame(stacktrace, -1, &frame);
  EXPECT(Dart_IsError(result));

  Dart_SetReturnValue(args, Dart_NewInteger(42));
  Dart_ExitScope();
}

static Dart_NativeFunction CurrentStackTraceNativeLookup(
    Dart_Handle name,
    int argument_count,
    bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return CurrentStackTraceNative;
}

TEST_CASE(DartAPI_CurrentStackTraceInfo) {
  const char* kScriptChars = R"(
@pragma("vm:external-name", "CurrentStackTraceNative")
external inspectStack();
foo(n) => n == 1 ? inspectStack() : foo(n-1);
@pragma("vm:entry-point", "call")
testMain() => foo(100);
  )";

  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &CurrentStackTraceNativeLookup);
  Dart_Handle result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  int64_t value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(result, &value));
  EXPECT_EQ(42, value);
}

#endif  // !PRODUCT

TEST_CASE(DartAPI_ErrorHandleTypes) {
  Dart_Handle not_error = NewString("NotError");
  Dart_Handle api_error = Dart_NewApiError("ApiError");
  Dart_Handle exception_error =
      Dart_NewUnhandledExceptionError(NewString("ExceptionError"));
  Dart_Handle compile_error = Dart_NewCompilationError("CompileError");
  Dart_Handle fatal_error;
  {
    TransitionNativeToVM transition(thread);
    const String& fatal_message = String::Handle(String::New("FatalError"));
    fatal_error = Api::NewHandle(thread, UnwindError::New(fatal_message));
  }

  EXPECT_VALID(not_error);
  EXPECT(Dart_IsError(api_error));
  EXPECT(Dart_IsError(exception_error));
  EXPECT(Dart_IsError(compile_error));
  EXPECT(Dart_IsError(fatal_error));

  EXPECT(!Dart_IsApiError(not_error));
  EXPECT(Dart_IsApiError(api_error));
  EXPECT(!Dart_IsApiError(exception_error));
  EXPECT(!Dart_IsApiError(compile_error));
  EXPECT(!Dart_IsApiError(fatal_error));

  EXPECT(!Dart_IsUnhandledExceptionError(not_error));
  EXPECT(!Dart_IsUnhandledExceptionError(api_error));
  EXPECT(Dart_IsUnhandledExceptionError(exception_error));
  EXPECT(!Dart_IsUnhandledExceptionError(compile_error));
  EXPECT(!Dart_IsUnhandledExceptionError(fatal_error));

  EXPECT(!Dart_IsCompilationError(not_error));
  EXPECT(!Dart_IsCompilationError(api_error));
  EXPECT(!Dart_IsCompilationError(exception_error));
  EXPECT(Dart_IsCompilationError(compile_error));
  EXPECT(!Dart_IsCompilationError(fatal_error));

  EXPECT(!Dart_IsFatalError(not_error));
  EXPECT(!Dart_IsFatalError(api_error));
  EXPECT(!Dart_IsFatalError(exception_error));
  EXPECT(!Dart_IsFatalError(compile_error));
  EXPECT(Dart_IsFatalError(fatal_error));

  EXPECT_STREQ("", Dart_GetError(not_error));
  EXPECT_STREQ("ApiError", Dart_GetError(api_error));
  EXPECT_SUBSTRING("Unhandled exception:\nExceptionError",
                   Dart_GetError(exception_error));
  EXPECT_STREQ("CompileError", Dart_GetError(compile_error));
  EXPECT_STREQ("FatalError", Dart_GetError(fatal_error));
}

TEST_CASE(DartAPI_UnhandleExceptionError) {
  const char* exception_cstr = "";

  // Test with an API Error.
  const char* kApiError = "Api Error Exception Test.";
  Dart_Handle api_error = Dart_NewApiError(kApiError);
  Dart_Handle exception_error = Dart_NewUnhandledExceptionError(api_error);
  EXPECT(!Dart_IsApiError(exception_error));
  EXPECT(Dart_IsUnhandledExceptionError(exception_error));
  EXPECT(Dart_IsString(Dart_ErrorGetException(exception_error)));
  EXPECT_VALID(Dart_StringToCString(Dart_ErrorGetException(exception_error),
                                    &exception_cstr));
  EXPECT_STREQ(kApiError, exception_cstr);

  // Test with a Compilation Error.
  const char* kCompileError = "CompileError Exception Test.";
  Dart_Handle compile_error = Dart_NewCompilationError(kCompileError);
  exception_error = Dart_NewUnhandledExceptionError(compile_error);
  EXPECT(!Dart_IsApiError(exception_error));
  EXPECT(Dart_IsUnhandledExceptionError(exception_error));
  EXPECT(Dart_IsString(Dart_ErrorGetException(exception_error)));
  EXPECT_VALID(Dart_StringToCString(Dart_ErrorGetException(exception_error),
                                    &exception_cstr));
  EXPECT_STREQ(kCompileError, exception_cstr);

  // Test with a Fatal Error.
  Dart_Handle fatal_error;
  {
    TransitionNativeToVM transition(thread);
    const String& fatal_message =
        String::Handle(String::New("FatalError Exception Test."));
    fatal_error = Api::NewHandle(thread, UnwindError::New(fatal_message));
  }
  exception_error = Dart_NewUnhandledExceptionError(fatal_error);
  EXPECT(Dart_IsError(exception_error));
  EXPECT(!Dart_IsUnhandledExceptionError(exception_error));

  // Test with a Regular object.
  const char* kRegularString = "Regular String Exception Test.";
  exception_error = Dart_NewUnhandledExceptionError(NewString(kRegularString));
  EXPECT(!Dart_IsApiError(exception_error));
  EXPECT(Dart_IsUnhandledExceptionError(exception_error));
  EXPECT(Dart_IsString(Dart_ErrorGetException(exception_error)));
  EXPECT_VALID(Dart_StringToCString(Dart_ErrorGetException(exception_error),
                                    &exception_cstr));
  EXPECT_STREQ(kRegularString, exception_cstr);
}

void JustPropagateErrorNative(Dart_NativeArguments args) {
  Dart_Handle closure = Dart_GetNativeArgument(args, 0);
  EXPECT(Dart_IsClosure(closure));
  Dart_Handle result = Dart_InvokeClosure(closure, 0, nullptr);
  EXPECT(Dart_IsError(result));
  Dart_PropagateError(result);
  UNREACHABLE();
}

static Dart_NativeFunction JustPropagateError_lookup(Dart_Handle name,
                                                     int argument_count,
                                                     bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return JustPropagateErrorNative;
}

TEST_CASE(DartAPI_EnsureUnwindErrorHandled_WhenKilled) {
  const char* kScriptChars = R"(
import 'dart:isolate';

exitRightNow() {
  Isolate.current.kill(priority: Isolate.immediate);
}

@pragma("vm:external-name", "Test_nativeFunc")
external void nativeFunc(closure);

@pragma("vm:entry-point", "call")
void Func1() {
  nativeFunc(() => exitRightNow());
}
)";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &JustPropagateError_lookup);
  Dart_Handle result;

  result = Dart_Invoke(lib, NewString("Func1"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("isolate terminated by Isolate.kill", Dart_GetError(result));

  result = Dart_Invoke(lib, NewString("Func1"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("No api calls are allowed while unwind is in progress",
                   Dart_GetError(result));
}

TEST_CASE(DartAPI_EnsureUnwindErrorHandled_WhenSendAndExit) {
  const char* kScriptChars = R"(
import 'dart:isolate';

sendAndExitNow() {
  final receivePort = ReceivePort();
  Isolate.exit(receivePort.sendPort, true);
}

@pragma("vm:external-name", "Test_nativeFunc")
external void nativeFunc(closure);

@pragma("vm:entry-point", "call")
void Func1() {
  nativeFunc(() => sendAndExitNow());
}
)";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &JustPropagateError_lookup);
  Dart_Handle result;

  result = Dart_Invoke(lib, NewString("Func1"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("isolate terminated by Isolate.exit", Dart_GetError(result));

  result = Dart_Invoke(lib, NewString("Func1"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("No api calls are allowed while unwind is in progress",
                   Dart_GetError(result));
}

// Should we propagate the error via Dart_SetReturnValue?
static bool use_set_return = false;

// Should we propagate the error via Dart_ThrowException?
static bool use_throw_exception = false;

void PropagateErrorNative(Dart_NativeArguments args) {
  Dart_Handle closure = Dart_GetNativeArgument(args, 0);
  EXPECT(Dart_IsClosure(closure));
  Dart_Handle result = Dart_InvokeClosure(closure, 0, nullptr);
  EXPECT(Dart_IsError(result));
  if (use_set_return) {
    Dart_SetReturnValue(args, result);
  } else if (use_throw_exception) {
    result = Dart_ThrowException(result);
    EXPECT_VALID(result);  // We do not expect to reach here.
    UNREACHABLE();
  } else {
    Dart_PropagateError(result);
    UNREACHABLE();
  }
}

static Dart_NativeFunction PropagateError_native_lookup(
    Dart_Handle name,
    int argument_count,
    bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return PropagateErrorNative;
}

TEST_CASE(DartAPI_PropagateCompileTimeError) {
  const char* kScriptChars = R"(
raiseCompileError() {
  return missing_semicolon
}

@pragma("vm:external-name", "Test_nativeFunc")
external void nativeFunc(closure);

@pragma("vm:entry-point", "call")
void Func1() {
  nativeFunc(() => raiseCompileError());
}
)";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &PropagateError_native_lookup);
  Dart_Handle result;

  // Use Dart_PropagateError to propagate the error.
  use_throw_exception = false;
  use_set_return = false;

  result = Dart_Invoke(lib, NewString("Func1"), 0, nullptr);
  EXPECT(Dart_IsError(result));

  EXPECT_SUBSTRING("Expected ';' after this.", Dart_GetError(result));

  // Use Dart_SetReturnValue to propagate the error.
  use_throw_exception = false;
  use_set_return = true;

  result = Dart_Invoke(lib, NewString("Func1"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("Expected ';' after this.", Dart_GetError(result));

  // Use Dart_ThrowException to propagate the error.
  use_throw_exception = true;
  use_set_return = false;

  result = Dart_Invoke(lib, NewString("Func1"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("Expected ';' after this.", Dart_GetError(result));
}

TEST_CASE(DartAPI_PropagateError) {
  const char* kScriptChars = R"(
void throwException() {
  throw new Exception('myException');
}

@pragma("vm:external-name", "Test_nativeFunc")
external void nativeFunc(closure);

@pragma("vm:entry-point", "call")
void Func2() {
  nativeFunc(() => throwException());
}
)";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &PropagateError_native_lookup);
  Dart_Handle result;

  // Use Dart_PropagateError to propagate the error.
  use_throw_exception = false;
  use_set_return = false;

  result = Dart_Invoke(lib, NewString("Func2"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("myException", Dart_GetError(result));

  // Use Dart_SetReturnValue to propagate the error.
  use_throw_exception = false;
  use_set_return = true;

  result = Dart_Invoke(lib, NewString("Func2"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("myException", Dart_GetError(result));

  // Use Dart_ThrowException to propagate the error.
  use_throw_exception = true;
  use_set_return = false;

  result = Dart_Invoke(lib, NewString("Func2"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("myException", Dart_GetError(result));
}

TEST_CASE(DartAPI_Error) {
  Dart_Handle error;
  {
    TransitionNativeToVM transition(thread);
    error = Api::NewError("An %s", "error");
  }
  EXPECT(Dart_IsError(error));
  EXPECT_STREQ("An error", Dart_GetError(error));
}

TEST_CASE(DartAPI_Null) {
  Dart_Handle null = Dart_Null();
  EXPECT_VALID(null);
  EXPECT(Dart_IsNull(null));

  Dart_Handle str = NewString("test");
  EXPECT_VALID(str);
  EXPECT(!Dart_IsNull(str));
}

TEST_CASE(DartAPI_EmptyString) {
  Dart_Handle empty = Dart_EmptyString();
  EXPECT_VALID(empty);
  EXPECT(!Dart_IsNull(empty));
  EXPECT(Dart_IsString(empty));
  intptr_t length = -1;
  EXPECT_VALID(Dart_StringLength(empty, &length));
  EXPECT_EQ(0, length);
}

TEST_CASE(DartAPI_TypeDynamic) {
  Dart_Handle type = Dart_TypeDynamic();
  EXPECT_VALID(type);
  EXPECT(Dart_IsType(type));

  Dart_Handle str = Dart_ToString(type);
  EXPECT_VALID(str);
  const char* cstr = nullptr;
  EXPECT_VALID(Dart_StringToCString(str, &cstr));
  EXPECT_STREQ("dynamic", cstr);
}

TEST_CASE(DartAPI_TypeVoid) {
  Dart_Handle type = Dart_TypeVoid();
  EXPECT_VALID(type);
  EXPECT(Dart_IsType(type));

  Dart_Handle str = Dart_ToString(type);
  EXPECT_VALID(str);
  const char* cstr = nullptr;
  EXPECT_VALID(Dart_StringToCString(str, &cstr));
  EXPECT_STREQ("void", cstr);
}

TEST_CASE(DartAPI_TypeNever) {
  Dart_Handle type = Dart_TypeNever();
  EXPECT_VALID(type);
  EXPECT(Dart_IsType(type));

  Dart_Handle str = Dart_ToString(type);
  EXPECT_VALID(str);
  const char* cstr = nullptr;
  EXPECT_VALID(Dart_StringToCString(str, &cstr));
  EXPECT_STREQ("Never", cstr);
}

TEST_CASE(DartAPI_IdentityEquals) {
  Dart_Handle five = Dart_NewInteger(5);
  Dart_Handle five_again = Dart_NewInteger(5);
  Dart_Handle mint = Dart_NewInteger(0xFFFFFFFF);
  Dart_Handle mint_again = Dart_NewInteger(0xFFFFFFFF);
  Dart_Handle abc = NewString("abc");
  Dart_Handle abc_again = NewString("abc");
  Dart_Handle xyz = NewString("xyz");
  Dart_Handle dart_core = NewString("dart:core");
  Dart_Handle dart_mirrors = NewString("dart:mirrors");

  // Same objects.
  EXPECT(Dart_IdentityEquals(five, five));
  EXPECT(Dart_IdentityEquals(mint, mint));
  EXPECT(Dart_IdentityEquals(abc, abc));
  EXPECT(Dart_IdentityEquals(xyz, xyz));

  // Equal objects with special spec rules.
  EXPECT(Dart_IdentityEquals(five, five_again));
  EXPECT(Dart_IdentityEquals(mint, mint_again));

  // Equal objects without special spec rules.
  EXPECT(!Dart_IdentityEquals(abc, abc_again));

  // Different objects.
  EXPECT(!Dart_IdentityEquals(five, mint));
  EXPECT(!Dart_IdentityEquals(abc, xyz));

  // Case where identical() is not the same as pointer equality.
  Dart_Handle nan1 = Dart_NewDouble(NAN);
  Dart_Handle nan2 = Dart_NewDouble(NAN);
  EXPECT(Dart_IdentityEquals(nan1, nan2));

  // Non-instance objects.
  {
    CHECK_API_SCOPE(thread);
    Dart_Handle lib1 = Dart_LookupLibrary(dart_core);
    Dart_Handle lib2 = Dart_LookupLibrary(dart_mirrors);

    EXPECT(Dart_IdentityEquals(lib1, lib1));
    EXPECT(Dart_IdentityEquals(lib2, lib2));
    EXPECT(!Dart_IdentityEquals(lib1, lib2));

    // Mix instance and non-instance.
    EXPECT(!Dart_IdentityEquals(lib1, nan1));
    EXPECT(!Dart_IdentityEquals(nan1, lib1));
  }
}

TEST_CASE(DartAPI_ObjectEquals) {
  bool equal = false;
  Dart_Handle five = NewString("5");
  Dart_Handle five_again = NewString("5");
  Dart_Handle seven = NewString("7");

  // Same objects.
  EXPECT_VALID(Dart_ObjectEquals(five, five, &equal));
  EXPECT(equal);

  // Equal objects.
  EXPECT_VALID(Dart_ObjectEquals(five, five_again, &equal));
  EXPECT(equal);

  // Different objects.
  EXPECT_VALID(Dart_ObjectEquals(five, seven, &equal));
  EXPECT(!equal);

  // Case where identity is not equality.
  Dart_Handle nan = Dart_NewDouble(NAN);
  EXPECT_VALID(Dart_ObjectEquals(nan, nan, &equal));
  EXPECT(!equal);
}

TEST_CASE(DartAPI_InstanceValues) {
  EXPECT(Dart_IsInstance(NewString("test")));
  EXPECT(Dart_IsInstance(Dart_True()));

  // By convention, our Is*() functions exclude null.
  EXPECT(!Dart_IsInstance(Dart_Null()));
}

TEST_CASE(DartAPI_InstanceGetType) {
  Zone* zone = thread->zone();
  // Get the handle from a valid instance handle.
  Dart_Handle type = Dart_InstanceGetType(Dart_Null());
  EXPECT_VALID(type);
  EXPECT(Dart_IsType(type));
  {
    TransitionNativeToVM transition(thread);
    const Type& null_type_obj = Api::UnwrapTypeHandle(zone, type);
    EXPECT(null_type_obj.ptr() == Type::NullType());
  }

  Dart_Handle instance = Dart_True();
  type = Dart_InstanceGetType(instance);
  EXPECT_VALID(type);
  EXPECT(Dart_IsType(type));
  {
    TransitionNativeToVM transition(thread);
    const Type& bool_type_obj = Api::UnwrapTypeHandle(zone, type);
    EXPECT(bool_type_obj.ptr() == Type::BoolType());
  }

  // Errors propagate.
  Dart_Handle error = Dart_NewApiError("MyError");
  Dart_Handle error_type = Dart_InstanceGetType(error);
  EXPECT_ERROR(error_type, "MyError");

  // Get the handle from a non-instance handle.
  Dart_Handle dart_core = NewString("dart:core");
  Dart_Handle obj = Dart_LookupLibrary(dart_core);
  Dart_Handle type_type = Dart_InstanceGetType(obj);
  EXPECT_ERROR(type_type,
               "Dart_InstanceGetType expects argument 'instance' to be of "
               "type Instance.");
}

TEST_CASE(DartAPI_FunctionName) {
  const char* kScriptChars = "int getInt() { return 1; }\n";
  // Create a test library and Load up a test script in it.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle closure = Dart_GetField(lib, NewString("getInt"));
  EXPECT_VALID(closure);
  if (Dart_IsClosure(closure)) {
    closure = Dart_ClosureFunction(closure);
    EXPECT_VALID(closure);
  }

  Dart_Handle name = Dart_FunctionName(closure);
  EXPECT_VALID(name);
  const char* result_str = "";
  Dart_StringToCString(name, &result_str);
  EXPECT_STREQ(result_str, "getInt");
}

TEST_CASE(DartAPI_FunctionOwner) {
  const char* kScriptChars = "int getInt() { return 1; }\n";
  // Create a test library and Load up a test script in it.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle closure = Dart_GetField(lib, NewString("getInt"));
  EXPECT_VALID(closure);
  if (Dart_IsClosure(closure)) {
    closure = Dart_ClosureFunction(closure);
    EXPECT_VALID(closure);
  }

  const char* url = "";
  Dart_Handle owner = Dart_FunctionOwner(closure);
  EXPECT_VALID(owner);
  Dart_Handle owner_url = Dart_LibraryUrl(owner);
  EXPECT_VALID(owner_url);
  Dart_StringToCString(owner_url, &url);

  const char* lib_url = "";
  Dart_Handle library_url = Dart_LibraryUrl(lib);
  EXPECT_VALID(library_url);
  Dart_StringToCString(library_url, &lib_url);

  EXPECT_STREQ(url, lib_url);
}

TEST_CASE(DartAPI_IsTearOff) {
  const char* kScriptChars =
      "int getInt() { return 1; }\n"
      "getTearOff() => getInt;\n"
      "Function foo = () { print('baz'); };\n"
      "class Baz {\n"
      "  static int foo() => 42;\n"
      "  getTearOff() => bar;\n"
      "  int bar() => 24;\n"
      "}\n"
      "Baz getBaz() => Baz();\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  // Check tear-off of top-level static method.
  Dart_Handle get_tear_off = Dart_GetField(lib, NewString("getTearOff"));
  EXPECT_VALID(get_tear_off);
  EXPECT(Dart_IsTearOff(get_tear_off));
  Dart_Handle tear_off = Dart_InvokeClosure(get_tear_off, 0, nullptr);
  EXPECT_VALID(tear_off);
  EXPECT(Dart_IsTearOff(tear_off));

  // Check anonymous closures are not considered tear-offs.
  Dart_Handle anonymous_closure = Dart_GetField(lib, NewString("foo"));
  EXPECT_VALID(anonymous_closure);
  EXPECT(!Dart_IsTearOff(anonymous_closure));

  Dart_Handle baz_cls = Dart_GetClass(lib, NewString("Baz"));
  EXPECT_VALID(baz_cls);

  // Check tear-off for a static method in a class.
  Dart_Handle closure =
      Dart_GetStaticMethodClosure(lib, baz_cls, NewString("foo"));
  EXPECT_VALID(closure);
  EXPECT(Dart_IsTearOff(closure));

  // Flutter will use Dart_IsTearOff in conjunction with Dart_ClosureFunction
  // and Dart_FunctionIsStatic to prevent anonymous closures from being used to
  // generate callback handles. We'll test that case here, just to be sure.
  Dart_Handle function = Dart_ClosureFunction(closure);
  EXPECT_VALID(function);
  bool is_static = false;
  Dart_Handle result = Dart_FunctionIsStatic(function, &is_static);
  EXPECT_VALID(result);
  EXPECT(is_static);

  // Check tear-off for an instance method in a class.
  Dart_Handle instance = Dart_Invoke(lib, NewString("getBaz"), 0, nullptr);
  EXPECT_VALID(instance);
  closure = Dart_Invoke(instance, NewString("getTearOff"), 0, nullptr);
  EXPECT_VALID(closure);
  EXPECT(Dart_IsTearOff(closure));
}

TEST_CASE(DartAPI_FunctionIsStatic) {
  const char* kScriptChars =
      "int getInt() { return 1; }\n"
      "class Foo { String getString() => 'foobar'; }\n";
  // Create a test library and Load up a test script in it.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle closure = Dart_GetField(lib, NewString("getInt"));
  EXPECT_VALID(closure);
  if (Dart_IsClosure(closure)) {
    closure = Dart_ClosureFunction(closure);
    EXPECT_VALID(closure);
  }

  bool is_static = false;
  Dart_Handle result = Dart_FunctionIsStatic(closure, &is_static);
  EXPECT_VALID(result);
  EXPECT(is_static);

  Dart_Handle klass =
      Dart_GetNonNullableType(lib, NewString("Foo"), 0, nullptr);
  EXPECT_VALID(klass);

  Dart_Handle instance = Dart_Allocate(klass);

  closure = Dart_GetField(instance, NewString("getString"));
  EXPECT_VALID(closure);
  if (Dart_IsClosure(closure)) {
    closure = Dart_ClosureFunction(closure);
    EXPECT_VALID(closure);
  }

  result = Dart_FunctionIsStatic(closure, &is_static);
  EXPECT_VALID(result);
  EXPECT(!is_static);
}

TEST_CASE(DartAPI_ClosureFunction) {
  const char* kScriptChars = "int getInt() { return 1; }\n";
  // Create a test library and Load up a test script in it.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle closure = Dart_GetField(lib, NewString("getInt"));
  EXPECT_VALID(closure);
  EXPECT(Dart_IsClosure(closure));
  Dart_Handle closure_str = Dart_ToString(closure);
  const char* result = "";
  Dart_StringToCString(closure_str, &result);
  EXPECT(strstr(result, "getInt") != nullptr);

  Dart_Handle function = Dart_ClosureFunction(closure);
  EXPECT_VALID(function);
  EXPECT(Dart_IsFunction(function));
  Dart_Handle func_str = Dart_ToString(function);
  Dart_StringToCString(func_str, &result);
  EXPECT(strstr(result, "getInt"));
}

TEST_CASE(DartAPI_GetStaticMethodClosure) {
  const char* kScriptChars = R"(
    @pragma("vm:entry-point")
    class Foo {
      static int getIntNoAnnotation() {
        return 1;
      }
      @pragma("vm:entry-point", "call")
      static int getIntCallOnly() {
        return 1;
      }
      @pragma("vm:entry-point", "get")
      static int getInt() {
        return 1;
      }
      @pragma("vm:entry-point", "get")
      double getDouble() {
        return 1.0;
      }
    }
  )";
  // Ensure entry points are checked.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, true);
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle foo_cls = Dart_GetClass(lib, NewString("Foo"));
  EXPECT_VALID(foo_cls);

  Dart_Handle closure =
      Dart_GetStaticMethodClosure(lib, foo_cls, NewString("getInt"));
  EXPECT_VALID(closure);
  EXPECT(Dart_IsClosure(closure));
  Dart_Handle closure_str = Dart_ToString(closure);
  const char* result = "";
  Dart_StringToCString(closure_str, &result);
  EXPECT_SUBSTRING("getInt", result);

  Dart_Handle function = Dart_ClosureFunction(closure);
  EXPECT_VALID(function);
  EXPECT(Dart_IsFunction(function));
  Dart_Handle func_str = Dart_ToString(function);
  Dart_StringToCString(func_str, &result);
  EXPECT_SUBSTRING("getInt", result);

  Dart_Handle cls = Dart_FunctionOwner(function);
  EXPECT_VALID(cls);
  EXPECT(Dart_IsInstance(cls));
  Dart_Handle cls_str = Dart_ClassName(cls);
  Dart_StringToCString(cls_str, &result);
  EXPECT_SUBSTRING("Foo", result);

  EXPECT_ERROR(Dart_ClassName(Dart_Null()),
               "Dart_ClassName expects argument 'cls_type' to be non-null.");
  EXPECT_ERROR(
      Dart_GetStaticMethodClosure(Dart_Null(), foo_cls, NewString("getInt")),
      "Dart_GetStaticMethodClosure expects argument 'library' to be non-null.");
  EXPECT_ERROR(
      Dart_GetStaticMethodClosure(lib, Dart_Null(), NewString("getInt")),
      "Dart_GetStaticMethodClosure expects argument 'cls_type' to be "
      "non-null.");
  EXPECT_ERROR(Dart_GetStaticMethodClosure(lib, foo_cls, Dart_Null()),
               "Dart_GetStaticMethodClosure expects argument 'function_name' "
               "to be non-null.");
  EXPECT_ERROR(
      Dart_GetStaticMethodClosure(lib, foo_cls,
                                  NewString("getIntNoAnnotation")),
      "To closurize 'file:///test-lib::Foo.getIntNoAnnotation' from native "
      "code, it must be annotated.");
  EXPECT_ERROR(
      Dart_GetStaticMethodClosure(lib, foo_cls, NewString("getIntCallOnly")),
      "To closurize 'file:///test-lib::Foo.getIntCallOnly' from native "
      "code, it must be annotated.");
}

TEST_CASE(DartAPI_ClassLibrary) {
  Dart_Handle lib = Dart_LookupLibrary(NewString("dart:core"));
  EXPECT_VALID(lib);
  Dart_Handle type = Dart_GetNonNullableType(lib, NewString("int"), 0, nullptr);
  EXPECT_VALID(type);
  Dart_Handle result = Dart_ClassLibrary(type);
  EXPECT_VALID(result);
  Dart_Handle lib_url = Dart_LibraryUrl(result);
  const char* str = nullptr;
  Dart_StringToCString(lib_url, &str);
  EXPECT_STREQ("dart:core", str);
}

TEST_CASE(DartAPI_BooleanValues) {
  Dart_Handle str = NewString("test");
  EXPECT(!Dart_IsBoolean(str));

  bool value = false;
  Dart_Handle result = Dart_BooleanValue(str, &value);
  EXPECT(Dart_IsError(result));

  Dart_Handle val1 = Dart_NewBoolean(true);
  EXPECT(Dart_IsBoolean(val1));

  result = Dart_BooleanValue(val1, &value);
  EXPECT_VALID(result);
  EXPECT(value);

  Dart_Handle val2 = Dart_NewBoolean(false);
  EXPECT(Dart_IsBoolean(val2));

  result = Dart_BooleanValue(val2, &value);
  EXPECT_VALID(result);
  EXPECT(!value);
}

TEST_CASE(DartAPI_BooleanConstants) {
  Dart_Handle true_handle = Dart_True();
  EXPECT_VALID(true_handle);
  EXPECT(Dart_IsBoolean(true_handle));

  bool value = false;
  Dart_Handle result = Dart_BooleanValue(true_handle, &value);
  EXPECT_VALID(result);
  EXPECT(value);

  Dart_Handle false_handle = Dart_False();
  EXPECT_VALID(false_handle);
  EXPECT(Dart_IsBoolean(false_handle));

  result = Dart_BooleanValue(false_handle, &value);
  EXPECT_VALID(result);
  EXPECT(!value);
}

TEST_CASE(DartAPI_DoubleValues) {
  const double kDoubleVal1 = 201.29;
  const double kDoubleVal2 = 101.19;
  Dart_Handle val1 = Dart_NewDouble(kDoubleVal1);
  EXPECT(Dart_IsDouble(val1));
  Dart_Handle val2 = Dart_NewDouble(kDoubleVal2);
  EXPECT(Dart_IsDouble(val2));
  double out1, out2;
  Dart_Handle result = Dart_DoubleValue(val1, &out1);
  EXPECT_VALID(result);
  EXPECT_EQ(kDoubleVal1, out1);
  result = Dart_DoubleValue(val2, &out2);
  EXPECT_VALID(result);
  EXPECT_EQ(kDoubleVal2, out2);
}

TEST_CASE(DartAPI_NumberValues) {
  // TODO(antonm): add various kinds of ints (smi, mint, bigint).
  const char* kScriptChars =
      "int getInt() { return 1; }\n"
      "double getDouble() { return 1.0; }\n"
      "bool getBool() { return false; }\n"
      "getNull() { return null; }\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle result;
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Check int case.
  result = Dart_Invoke(lib, NewString("getInt"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsNumber(result));

  // Check double case.
  result = Dart_Invoke(lib, NewString("getDouble"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsNumber(result));

  // Check bool case.
  result = Dart_Invoke(lib, NewString("getBool"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(!Dart_IsNumber(result));

  // Check null case.
  result = Dart_Invoke(lib, NewString("getNull"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(!Dart_IsNumber(result));
}

TEST_CASE(DartAPI_IntegerValues) {
  const int64_t kIntegerVal1 = 100;
  const int64_t kIntegerVal2 = 0xffffffff;
  const char* kIntegerVal3 = "0x123456789123456789123456789";
  const uint64_t kIntegerVal4 = 0xffffffffffffffff;
  const int64_t kIntegerVal5 = -0x7fffffffffffffff;

  Dart_Handle val1 = Dart_NewInteger(kIntegerVal1);
  EXPECT(Dart_IsInteger(val1));
  bool fits = false;
  Dart_Handle result = Dart_IntegerFitsIntoInt64(val1, &fits);
  EXPECT_VALID(result);
  EXPECT(fits);

  int64_t out = 0;
  result = Dart_IntegerToInt64(val1, &out);
  EXPECT_VALID(result);
  EXPECT_EQ(kIntegerVal1, out);

  Dart_Handle val2 = Dart_NewInteger(kIntegerVal2);
  EXPECT(Dart_IsInteger(val2));
  result = Dart_IntegerFitsIntoInt64(val2, &fits);
  EXPECT_VALID(result);
  EXPECT(fits);

  result = Dart_IntegerToInt64(val2, &out);
  EXPECT_VALID(result);
  EXPECT_EQ(kIntegerVal2, out);

  Dart_Handle val3 = Dart_NewIntegerFromHexCString(kIntegerVal3);
  EXPECT(Dart_IsApiError(val3));

  Dart_Handle val4 = Dart_NewIntegerFromUint64(kIntegerVal4);
  EXPECT(Dart_IsApiError(val4));

  Dart_Handle val5 = Dart_NewInteger(-1);
  EXPECT_VALID(val5);
  uint64_t out5 = 0;
  result = Dart_IntegerToUint64(val5, &out5);
  EXPECT(Dart_IsError(result));

  Dart_Handle val6 = Dart_NewInteger(kIntegerVal5);
  EXPECT_VALID(val6);
  uint64_t out6 = 0;
  result = Dart_IntegerToUint64(val6, &out6);
  EXPECT(Dart_IsError(result));
}

TEST_CASE(DartAPI_IntegerToHexCString) {
  const struct {
    int64_t i;
    const char* s;
  } kIntTestCases[] = {
      {0, "0x0"},
      {1, "0x1"},
      {-1, "-0x1"},
      {0x123, "0x123"},
      {-0xABCDEF, "-0xABCDEF"},
      {DART_INT64_C(-0x7FFFFFFFFFFFFFFF), "-0x7FFFFFFFFFFFFFFF"},
      {kMaxInt64, "0x7FFFFFFFFFFFFFFF"},
      {kMinInt64, "-0x8000000000000000"},
  };

  const size_t kNumberOfIntTestCases =
      sizeof(kIntTestCases) / sizeof(kIntTestCases[0]);

  for (size_t i = 0; i < kNumberOfIntTestCases; ++i) {
    Dart_Handle val = Dart_NewInteger(kIntTestCases[i].i);
    EXPECT_VALID(val);
    const char* chars = nullptr;
    Dart_Handle result = Dart_IntegerToHexCString(val, &chars);
    EXPECT_VALID(result);
    EXPECT_STREQ(kIntTestCases[i].s, chars);
  }
}

TEST_CASE(DartAPI_IntegerFitsIntoInt64) {
  Dart_Handle max = Dart_NewInteger(kMaxInt64);
  EXPECT(Dart_IsInteger(max));
  bool fits = false;
  Dart_Handle result = Dart_IntegerFitsIntoInt64(max, &fits);
  EXPECT_VALID(result);
  EXPECT(fits);

  Dart_Handle above_max = Dart_NewIntegerFromHexCString("0x10000000000000000");
  EXPECT(Dart_IsApiError(above_max));

  Dart_Handle min = Dart_NewInteger(kMinInt64);
  EXPECT(Dart_IsInteger(min));
  fits = false;
  result = Dart_IntegerFitsIntoInt64(min, &fits);
  EXPECT_VALID(result);
  EXPECT(fits);

  Dart_Handle below_min = Dart_NewIntegerFromHexCString("-0x10000000000000001");
  EXPECT(Dart_IsApiError(below_min));
}

TEST_CASE(DartAPI_IntegerFitsIntoUint64) {
  Dart_Handle max = Dart_NewIntegerFromUint64(kMaxUint64);
  EXPECT(Dart_IsApiError(max));

  Dart_Handle above_max = Dart_NewIntegerFromHexCString("0x10000000000000000");
  EXPECT(Dart_IsApiError(above_max));

  Dart_Handle min = Dart_NewInteger(0);
  EXPECT(Dart_IsInteger(min));
  bool fits = false;
  Dart_Handle result = Dart_IntegerFitsIntoUint64(min, &fits);
  EXPECT_VALID(result);
  EXPECT(fits);

  Dart_Handle below_min = Dart_NewIntegerFromHexCString("-1");
  EXPECT(Dart_IsInteger(below_min));
  fits = true;
  result = Dart_IntegerFitsIntoUint64(below_min, &fits);
  EXPECT_VALID(result);
  EXPECT(!fits);
}

TEST_CASE(DartAPI_ArrayValues) {
  EXPECT(!Dart_IsList(Dart_Null()));
  const int kArrayLength = 10;
  Dart_Handle str = NewString("test");
  EXPECT(!Dart_IsList(str));
  Dart_Handle val = Dart_NewList(kArrayLength);
  EXPECT(Dart_IsList(val));
  intptr_t len = 0;
  Dart_Handle result = Dart_ListLength(val, &len);
  EXPECT_VALID(result);
  EXPECT_EQ(kArrayLength, len);

  // Check invalid array access.
  result = Dart_ListSetAt(val, (kArrayLength + 10), Dart_NewInteger(10));
  EXPECT(Dart_IsError(result));
  result = Dart_ListSetAt(val, -10, Dart_NewInteger(10));
  EXPECT(Dart_IsError(result));
  result = Dart_ListGetAt(val, (kArrayLength + 10));
  EXPECT(Dart_IsError(result));
  result = Dart_ListGetAt(val, -10);
  EXPECT(Dart_IsError(result));

  for (int i = 0; i < kArrayLength; i++) {
    result = Dart_ListSetAt(val, i, Dart_NewInteger(i));
    EXPECT_VALID(result);
  }
  for (int i = 0; i < kArrayLength; i++) {
    result = Dart_ListGetAt(val, i);
    EXPECT_VALID(result);
    int64_t value;
    result = Dart_IntegerToInt64(result, &value);
    EXPECT_VALID(result);
    EXPECT_EQ(i, value);
  }
}

TEST_CASE(DartAPI_IsString) {
  uint8_t latin1[] = {'o', 'n', 'e', 0xC2, 0xA2};

  Dart_Handle latin1str = Dart_NewStringFromUTF8(latin1, ARRAY_SIZE(latin1));
  EXPECT_VALID(latin1str);
  EXPECT(Dart_IsString(latin1str));
  EXPECT(Dart_IsStringLatin1(latin1str));
  intptr_t len = -1;
  EXPECT_VALID(Dart_StringLength(latin1str, &len));
  EXPECT_EQ(4, len);
  intptr_t char_size;
  intptr_t str_len;
  void* peer;
  EXPECT_VALID(
      Dart_StringGetProperties(latin1str, &char_size, &str_len, &peer));
  EXPECT_EQ(1, char_size);
  EXPECT_EQ(4, str_len);
  EXPECT(!peer);

  uint8_t data8[] = {'o', 'n', 'e', 0x7F};

  Dart_Handle str8 = Dart_NewStringFromUTF8(data8, ARRAY_SIZE(data8));
  EXPECT_VALID(str8);
  EXPECT(Dart_IsString(str8));
  EXPECT(Dart_IsStringLatin1(str8));

  uint8_t latin1_array[] = {0, 0, 0, 0, 0};
  len = 5;
  Dart_Handle result = Dart_StringToLatin1(str8, latin1_array, &len);
  EXPECT_VALID(result);
  EXPECT_EQ(4, len);
  for (intptr_t i = 0; i < len; i++) {
    EXPECT_EQ(data8[i], latin1_array[i]);
  }

  uint16_t data16[] = {'t', 'w', 'o', 0xFFFF};

  Dart_Handle str16 = Dart_NewStringFromUTF16(data16, ARRAY_SIZE(data16));
  EXPECT_VALID(str16);
  EXPECT(Dart_IsString(str16));
  EXPECT(!Dart_IsStringLatin1(str16));
  EXPECT_VALID(Dart_StringGetProperties(str16, &char_size, &str_len, &peer));
  EXPECT_EQ(2, char_size);
  EXPECT_EQ(4, str_len);
  EXPECT(!peer);

  int32_t data32[] = {'f', 'o', 'u', 'r', 0x10FFFF};

  Dart_Handle str32 = Dart_NewStringFromUTF32(data32, ARRAY_SIZE(data32));
  EXPECT_VALID(str32);
  EXPECT(Dart_IsString(str32));
}

TEST_CASE(DartAPI_NewString) {
  const char* ascii = "string";
  Dart_Handle ascii_str = NewString(ascii);
  EXPECT_VALID(ascii_str);
  EXPECT(Dart_IsString(ascii_str));

  const char* null = nullptr;
  Dart_Handle null_str = NewString(null);
  EXPECT(Dart_IsError(null_str));

  uint8_t data[] = {0xE4, 0xBA, 0x8c};  // U+4E8C.
  Dart_Handle utf8_str = Dart_NewStringFromUTF8(data, ARRAY_SIZE(data));
  EXPECT_VALID(utf8_str);
  EXPECT(Dart_IsString(utf8_str));

  uint8_t invalid[] = {0xE4, 0xBA};  // underflow.
  Dart_Handle invalid_str =
      Dart_NewStringFromUTF8(invalid, ARRAY_SIZE(invalid));
  EXPECT(Dart_IsError(invalid_str));
}

TEST_CASE(DartAPI_MalformedStringToUTF8) {
  // 1D11E = treble clef
  // [0] should be high surrogate D834
  // [1] should be low surrogate DD1E
  // Strings are allowed to have individual or out of order surrogates, even
  // if that doesn't make sense as renderable characters.
  const char* kScriptChars =
      "@pragma('vm:entry-point', 'call')"
      "String lowSurrogate() {"
      "  return '\\u{1D11E}'[1];"
      "}"
      "String highSurrogate() {"
      "  return '\\u{1D11E}'[0];"
      "}"
      "@pragma('vm:entry-point', 'call')"
      "String reversed() => lowSurrogate() + highSurrogate();";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle str1 = Dart_Invoke(lib, NewString("lowSurrogate"), 0, nullptr);
  EXPECT_VALID(str1);

  uint8_t* utf8_encoded = nullptr;
  intptr_t utf8_length = 0;
  Dart_Handle result = Dart_StringToUTF8(str1, &utf8_encoded, &utf8_length);
  EXPECT_VALID(result);
  EXPECT_EQ(3, utf8_length);
  // Unpaired surrogate is encoded as replacement character.
  EXPECT_EQ(239, static_cast<intptr_t>(utf8_encoded[0]));
  EXPECT_EQ(191, static_cast<intptr_t>(utf8_encoded[1]));
  EXPECT_EQ(189, static_cast<intptr_t>(utf8_encoded[2]));

  Dart_Handle str2 = Dart_NewStringFromUTF8(utf8_encoded, utf8_length);
  EXPECT_VALID(str2);  // Replacement character, but still valid

  Dart_Handle reversed = Dart_Invoke(lib, NewString("reversed"), 0, nullptr);
  EXPECT_VALID(reversed);  // This is also allowed.
  uint8_t* utf8_encoded_reversed = nullptr;
  intptr_t utf8_length_reversed = 0;
  result = Dart_StringToUTF8(reversed, &utf8_encoded_reversed,
                             &utf8_length_reversed);
  EXPECT_VALID(result);
  EXPECT_EQ(6, utf8_length_reversed);
  // Two unpaired surrogates are encoded as two replacement characters.
  uint8_t expected[6] = {239, 191, 189, 239, 191, 189};
  for (int i = 0; i < 6; i++) {
    EXPECT_EQ(expected[i], utf8_encoded_reversed[i]);
  }
}

TEST_CASE(DartAPI_CopyUTF8EncodingOfString) {
  const char* kScriptChars =
      "@pragma('vm:entry-point', 'call')"
      "String lowSurrogate() {"
      "  return '\\u{1D11E}'[1];"
      "}";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle str1 = Dart_Invoke(lib, NewString("lowSurrogate"), 0, nullptr);
  EXPECT_VALID(str1);

  uint8_t* utf8_encoded = nullptr;
  intptr_t utf8_length = 0;
  Dart_Handle result = Dart_StringToUTF8(str1, &utf8_encoded, &utf8_length);
  EXPECT_VALID(result);
  EXPECT_EQ(3, utf8_length);

  intptr_t utf8_copy_length = 0;
  result = Dart_StringUTF8Length(str1, &utf8_copy_length);
  uint8_t* utf8_encoded_copy = Dart_ScopeAllocate(utf8_copy_length);
  result =
      Dart_CopyUTF8EncodingOfString(str1, utf8_encoded_copy, utf8_copy_length);
  EXPECT_VALID(result);
  EXPECT_EQ(0, memcmp(utf8_encoded, utf8_encoded_copy, utf8_length));
}

TEST_CASE(DartAPI_ExternalTypedDataPretenure) {
  {
    Dart_EnterScope();
    const int kBigLength = 16 * MB / 8;
    int64_t* big_data = new int64_t[kBigLength]();
    Dart_Handle big =
        Dart_NewExternalTypedData(Dart_TypedData_kInt64, big_data, kBigLength);
    EXPECT_VALID(big);
    const int kSmallLength = 16 * KB / 8;
    int64_t* small_data = new int64_t[kSmallLength]();
    Dart_Handle small = Dart_NewExternalTypedData(Dart_TypedData_kInt64,
                                                  small_data, kSmallLength);
    EXPECT_VALID(small);
    {
      CHECK_API_SCOPE(thread);
      TransitionNativeToVM transition(thread);
      HANDLESCOPE(thread);
      ExternalTypedData& handle = ExternalTypedData::Handle();
      handle ^= Api::UnwrapHandle(big);
      EXPECT(handle.IsOld());
      handle ^= Api::UnwrapHandle(small);
      EXPECT(handle.IsNew());
    }
    Dart_ExitScope();
    delete[] big_data;
    delete[] small_data;
  }
}

TEST_CASE(DartAPI_ListAccess) {
  const char* kScriptChars =
      "List testMain() {"
      "  List a = List.empty(growable: true);"
      "  a.add(10);"
      "  a.add(20);"
      "  a.add(30);"
      "  return a;"
      "}"
      ""
      "List immutable() {"
      "  return const [0, 1, 2];"
      "}";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle result;

  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Invoke a function which returns an object of type List.
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);

  // First ensure that the returned object is an array.
  Dart_Handle list_access_test_obj = result;

  EXPECT(Dart_IsList(list_access_test_obj));

  // Get length of array object.
  intptr_t len = 0;
  result = Dart_ListLength(list_access_test_obj, &len);
  EXPECT_VALID(result);
  EXPECT_EQ(3, len);

  // Access elements in the array.
  int64_t value;

  result = Dart_ListGetAt(list_access_test_obj, 0);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(10, value);

  result = Dart_ListGetAt(list_access_test_obj, 1);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(20, value);

  result = Dart_ListGetAt(list_access_test_obj, 2);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(30, value);

  // Set some elements in the array.
  result = Dart_ListSetAt(list_access_test_obj, 0, Dart_NewInteger(0));
  EXPECT_VALID(result);
  result = Dart_ListSetAt(list_access_test_obj, 1, Dart_NewInteger(1));
  EXPECT_VALID(result);
  result = Dart_ListSetAt(list_access_test_obj, 2, Dart_NewInteger(2));
  EXPECT_VALID(result);

  // Get length of array object.
  result = Dart_ListLength(list_access_test_obj, &len);
  EXPECT_VALID(result);
  EXPECT_EQ(3, len);

  // Now try and access these elements in the array.
  result = Dart_ListGetAt(list_access_test_obj, 0);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(0, value);

  result = Dart_ListGetAt(list_access_test_obj, 1);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(1, value);

  result = Dart_ListGetAt(list_access_test_obj, 2);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(2, value);

  uint8_t native_array[3];
  result = Dart_ListGetAsBytes(list_access_test_obj, 0, native_array, 3);
  EXPECT_VALID(result);
  EXPECT_EQ(0, native_array[0]);
  EXPECT_EQ(1, native_array[1]);
  EXPECT_EQ(2, native_array[2]);

  native_array[0] = 10;
  native_array[1] = 20;
  native_array[2] = 30;
  result = Dart_ListSetAsBytes(list_access_test_obj, 0, native_array, 3);
  EXPECT_VALID(result);
  result = Dart_ListGetAsBytes(list_access_test_obj, 0, native_array, 3);
  EXPECT_VALID(result);
  EXPECT_EQ(10, native_array[0]);
  EXPECT_EQ(20, native_array[1]);
  EXPECT_EQ(30, native_array[2]);
  result = Dart_ListGetAt(list_access_test_obj, 2);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(30, value);

  // Check if we get an exception when accessing beyond limit.
  result = Dart_ListGetAt(list_access_test_obj, 4);
  EXPECT(Dart_IsError(result));

  // Check if we can get a range of values.
  result = Dart_ListGetRange(list_access_test_obj, 8, 4, nullptr);
  EXPECT(Dart_IsError(result));
  const int kRangeOffset = 1;
  const int kRangeLength = 2;
  Dart_Handle values[kRangeLength];

  result = Dart_ListGetRange(list_access_test_obj, 8, 4, values);
  EXPECT(Dart_IsError(result));

  result = Dart_ListGetRange(list_access_test_obj, kRangeOffset, kRangeLength,
                             values);
  EXPECT_VALID(result);

  result = Dart_IntegerToInt64(values[0], &value);
  EXPECT_VALID(result);
  EXPECT_EQ(20, value);

  result = Dart_IntegerToInt64(values[1], &value);
  EXPECT_VALID(result);
  EXPECT_EQ(30, value);

  // Check that we get an exception (and not a fatal error) when
  // calling ListSetAt and ListSetAsBytes with an immutable list.
  list_access_test_obj = Dart_Invoke(lib, NewString("immutable"), 0, nullptr);
  EXPECT_VALID(list_access_test_obj);
  EXPECT(Dart_IsList(list_access_test_obj));

  result = Dart_ListSetAsBytes(list_access_test_obj, 0, native_array, 3);
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_IsUnhandledExceptionError(result));

  result = Dart_ListSetAt(list_access_test_obj, 0, Dart_NewInteger(42));
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_IsUnhandledExceptionError(result));
}

TEST_CASE(DartAPI_MapAccess) {
  EXPECT(!Dart_IsMap(Dart_Null()));
  const char* kScriptChars =
      "@pragma('vm:entry-point', 'call')"
      "Map testMain() {"
      "  return {"
      "    'a' : 1,"
      "    'b' : null,"
      "  };"
      "}";
  Dart_Handle result;

  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Invoke a function which returns an object of type Map.
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);

  // First ensure that the returned object is a map.
  Dart_Handle map = result;
  Dart_Handle a = NewString("a");
  Dart_Handle b = NewString("b");
  Dart_Handle c = NewString("c");

  EXPECT(Dart_IsMap(map));
  EXPECT(!Dart_IsMap(a));

  // Access values in the map.
  int64_t value;
  result = Dart_MapGetAt(map, a);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(value, 1);

  result = Dart_MapGetAt(map, b);
  EXPECT(Dart_IsNull(result));

  result = Dart_MapGetAt(map, c);
  EXPECT(Dart_IsNull(result));

  EXPECT(Dart_IsError(Dart_MapGetAt(a, a)));

  // Test for presence of keys.
  bool contains = false;
  result = Dart_MapContainsKey(map, a);
  EXPECT_VALID(result);
  result = Dart_BooleanValue(result, &contains);
  EXPECT_VALID(result);
  EXPECT(contains);

  contains = false;
  result = Dart_MapContainsKey(map, NewString("b"));
  EXPECT_VALID(result);
  result = Dart_BooleanValue(result, &contains);
  EXPECT_VALID(result);
  EXPECT(contains);

  contains = true;
  result = Dart_MapContainsKey(map, NewString("c"));
  EXPECT_VALID(result);
  result = Dart_BooleanValue(result, &contains);
  EXPECT_VALID(result);
  EXPECT(!contains);

  EXPECT(Dart_IsError(Dart_MapContainsKey(a, a)));

  // Enumerate keys. (Note literal maps guarantee key order.)
  Dart_Handle keys = Dart_MapKeys(map);
  EXPECT_VALID(keys);

  intptr_t len = 0;
  bool equals;
  result = Dart_ListLength(keys, &len);
  EXPECT_VALID(result);
  EXPECT_EQ(2, len);

  result = Dart_ListGetAt(keys, 0);
  EXPECT(Dart_IsString(result));
  equals = false;
  EXPECT_VALID(Dart_ObjectEquals(result, a, &equals));
  EXPECT(equals);

  result = Dart_ListGetAt(keys, 1);
  EXPECT(Dart_IsString(result));
  equals = false;
  EXPECT_VALID(Dart_ObjectEquals(result, b, &equals));
  EXPECT(equals);

  EXPECT(Dart_IsError(Dart_MapKeys(a)));
}

TEST_CASE(DartAPI_IsFuture) {
  const char* kScriptChars =
      "import 'dart:async';"
      "@pragma('vm:entry-point', 'call')"
      "Future testMain() {"
      "  return new Completer().future;"
      "}";
  Dart_Handle result;

  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Invoke a function which returns an object of type Future.
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsFuture(result));

  EXPECT(!Dart_IsFuture(lib));  // Non-instance.
  Dart_Handle anInteger = Dart_NewInteger(0);
  EXPECT(!Dart_IsFuture(anInteger));
  Dart_Handle aString = NewString("I am not a Future");
  EXPECT(!Dart_IsFuture(aString));
  Dart_Handle null = Dart_Null();
  EXPECT(!Dart_IsFuture(null));
}

TEST_CASE(DartAPI_TypedDataViewListGetAsBytes) {
  const int kSize = 1000;

  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "@pragma('vm:entry-point', 'call')\n"
      "List testMain(int size) {\n"
      "  var a = new Int8List(size);\n"
      "  var view = new Int8List.view(a.buffer, 0, size);\n"
      "  return view;\n"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Test with a typed data view object.
  Dart_Handle dart_args[1];
  dart_args[0] = Dart_NewInteger(kSize);
  Dart_Handle view_obj = Dart_Invoke(lib, NewString("testMain"), 1, dart_args);
  EXPECT_VALID(view_obj);
  for (intptr_t i = 0; i < kSize; ++i) {
    EXPECT_VALID(Dart_ListSetAt(view_obj, i, Dart_NewInteger(i & 0xff)));
  }
  uint8_t* data = new uint8_t[kSize];
  EXPECT_VALID(Dart_ListGetAsBytes(view_obj, 0, data, kSize));
  for (intptr_t i = 0; i < kSize; ++i) {
    EXPECT_EQ(i & 0xff, data[i]);
  }

  Dart_Handle result = Dart_ListGetAsBytes(view_obj, 0, data, kSize + 1);
  EXPECT(Dart_IsError(result));
  delete[] data;
}

TEST_CASE(DartAPI_TypedDataViewListIsTypedData) {
  const int kSize = 1000;

  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "@pragma('vm:entry-point', 'call')\n"
      "List testMain(int size) {\n"
      "  var a = new Int8List(size);\n"
      "  var view = new Int8List.view(a.buffer, 0, size);\n"
      "  return view;\n"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Create a typed data view object.
  Dart_Handle dart_args[1];
  dart_args[0] = Dart_NewInteger(kSize);
  Dart_Handle view_obj = Dart_Invoke(lib, NewString("testMain"), 1, dart_args);
  EXPECT_VALID(view_obj);
  // Test that the API considers it a TypedData object.
  EXPECT(Dart_IsTypedData(view_obj));
  EXPECT_EQ(Dart_TypedData_kInt8, Dart_GetTypeOfTypedData(view_obj));
}

TEST_CASE(DartAPI_UnmodifiableTypedDataViewListIsTypedData) {
  const int kSize = 1000;

  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "@pragma('vm:entry-point', 'call')\n"
      "List testMain(int size) {\n"
      "  var a = new Int8List(size);\n"
      "  var view = a.asUnmodifiableView();\n"
      "  return view;\n"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Create a typed data view object.
  Dart_Handle dart_args[1];
  dart_args[0] = Dart_NewInteger(kSize);
  Dart_Handle view_obj = Dart_Invoke(lib, NewString("testMain"), 1, dart_args);
  EXPECT_VALID(view_obj);
  // Test that the API considers it a TypedData object.
  EXPECT(Dart_IsTypedData(view_obj));
  EXPECT_EQ(Dart_TypedData_kInt8, Dart_GetTypeOfTypedData(view_obj));
}

TEST_CASE(DartAPI_TypedDataAccess) {
  EXPECT_EQ(Dart_TypedData_kInvalid, Dart_GetTypeOfTypedData(Dart_True()));
  EXPECT_EQ(Dart_TypedData_kInvalid,
            Dart_GetTypeOfExternalTypedData(Dart_False()));
  Dart_Handle byte_array1 = Dart_NewTypedData(Dart_TypedData_kUint8, 10);
  EXPECT_VALID(byte_array1);
  EXPECT_EQ(Dart_TypedData_kUint8, Dart_GetTypeOfTypedData(byte_array1));
  EXPECT_EQ(Dart_TypedData_kInvalid,
            Dart_GetTypeOfExternalTypedData(byte_array1));
  EXPECT(Dart_IsList(byte_array1));
  EXPECT(!Dart_IsTypedData(Dart_True()));
  EXPECT(Dart_IsTypedData(byte_array1));
  EXPECT(!Dart_IsByteBuffer(byte_array1));

  intptr_t length = 0;
  Dart_Handle result = Dart_ListLength(byte_array1, &length);
  EXPECT_VALID(result);
  EXPECT_EQ(10, length);

  result = Dart_ListSetAt(byte_array1, -1, Dart_NewInteger(1));
  EXPECT(Dart_IsError(result));

  result = Dart_ListSetAt(byte_array1, 10, Dart_NewInteger(1));
  EXPECT(Dart_IsError(result));

  // Set through the List API.
  for (intptr_t i = 0; i < 10; ++i) {
    EXPECT_VALID(Dart_ListSetAt(byte_array1, i, Dart_NewInteger(i + 1)));
  }
  for (intptr_t i = 0; i < 10; ++i) {
    // Get through the List API.
    Dart_Handle integer_obj = Dart_ListGetAt(byte_array1, i);
    EXPECT_VALID(integer_obj);
    int64_t int64_t_value = -1;
    EXPECT_VALID(Dart_IntegerToInt64(integer_obj, &int64_t_value));
    EXPECT_EQ(i + 1, int64_t_value);
  }

  Dart_Handle byte_array2 = Dart_NewTypedData(Dart_TypedData_kUint8, 10);
  bool is_equal = false;
  Dart_ObjectEquals(byte_array1, byte_array2, &is_equal);
  EXPECT(!is_equal);

  // Set through the List API.
  for (intptr_t i = 0; i < 10; ++i) {
    result = Dart_ListSetAt(byte_array1, i, Dart_NewInteger(i + 2));
    EXPECT_VALID(result);
    result = Dart_ListSetAt(byte_array2, i, Dart_NewInteger(i + 2));
    EXPECT_VALID(result);
  }
  for (intptr_t i = 0; i < 10; ++i) {
    // Get through the List API.
    Dart_Handle e1 = Dart_ListGetAt(byte_array1, i);
    Dart_Handle e2 = Dart_ListGetAt(byte_array2, i);
    is_equal = false;
    Dart_ObjectEquals(e1, e2, &is_equal);
    EXPECT(is_equal);
  }

  uint8_t data[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9};
  for (intptr_t i = 0; i < 10; ++i) {
    EXPECT_VALID(Dart_ListSetAt(byte_array1, i, Dart_NewInteger(10 - i)));
  }
  Dart_ListGetAsBytes(byte_array1, 0, data, 10);
  for (intptr_t i = 0; i < 10; ++i) {
    Dart_Handle integer_obj = Dart_ListGetAt(byte_array1, i);
    EXPECT_VALID(integer_obj);
    int64_t int64_t_value = -1;
    EXPECT_VALID(Dart_IntegerToInt64(integer_obj, &int64_t_value));
    EXPECT_EQ(10 - i, int64_t_value);
  }
}

TEST_CASE(DartAPI_ByteBufferAccess) {
  EXPECT(!Dart_IsByteBuffer(Dart_True()));
  Dart_Handle byte_array = Dart_NewTypedData(Dart_TypedData_kUint8, 10);
  EXPECT_VALID(byte_array);
  // Set through the List API.
  for (intptr_t i = 0; i < 10; ++i) {
    EXPECT_VALID(Dart_ListSetAt(byte_array, i, Dart_NewInteger(i + 1)));
  }
  Dart_Handle byte_buffer = Dart_NewByteBuffer(byte_array);
  EXPECT_VALID(byte_buffer);
  EXPECT(Dart_IsByteBuffer(byte_buffer));
  EXPECT(!Dart_IsTypedData(byte_buffer));

  Dart_Handle byte_buffer_data = Dart_GetDataFromByteBuffer(byte_buffer);
  EXPECT_VALID(byte_buffer_data);
  EXPECT(!Dart_IsByteBuffer(byte_buffer_data));
  EXPECT(Dart_IsTypedData(byte_buffer_data));

  intptr_t length = 0;
  Dart_Handle result = Dart_ListLength(byte_buffer_data, &length);
  EXPECT_VALID(result);
  EXPECT_EQ(10, length);

  for (intptr_t i = 0; i < 10; ++i) {
    // Get through the List API.
    Dart_Handle integer_obj = Dart_ListGetAt(byte_buffer_data, i);
    EXPECT_VALID(integer_obj);
    int64_t int64_t_value = -1;
    EXPECT_VALID(Dart_IntegerToInt64(integer_obj, &int64_t_value));
    EXPECT_EQ(i + 1, int64_t_value);
  }

  // Some negative tests.
  result = Dart_NewByteBuffer(Dart_True());
  EXPECT(Dart_IsError(result));
  result = Dart_NewByteBuffer(byte_buffer);
  EXPECT(Dart_IsError(result));
  result = Dart_GetDataFromByteBuffer(Dart_False());
  EXPECT(Dart_IsError(result));
  result = Dart_GetDataFromByteBuffer(byte_array);
  EXPECT(Dart_IsError(result));
}

static int kLength = 16;

static void ByteDataNativeFunction(Dart_NativeArguments args) {
  Dart_EnterScope();
  Dart_Handle byte_data = Dart_NewTypedData(Dart_TypedData_kByteData, kLength);
  EXPECT_VALID(byte_data);
  EXPECT_EQ(Dart_TypedData_kByteData, Dart_GetTypeOfTypedData(byte_data));
  Dart_SetReturnValue(args, byte_data);
  Dart_ExitScope();
}

static Dart_NativeFunction ByteDataNativeResolver(Dart_Handle name,
                                                  int arg_count,
                                                  bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return &ByteDataNativeFunction;
}

TEST_CASE(DartAPI_ByteDataAccess) {
  const char* kScriptChars = R"(
import 'dart:typed_data';
class Expect {
  static equals(a, b) {
    if (a != b) {
      throw 'not equal. expected: $a, got: $b';
    }
  }
}
@pragma("vm:external-name", "CreateByteData")
external ByteData createByteData();
ByteData main() {
  var length = 16;
  var a = createByteData();
  Expect.equals(length, a.lengthInBytes);
  for (int i = 0; i < length; i+=1) {
    a.setInt8(i, 0x42);
  }
  for (int i = 0; i < length; i+=2) {
    Expect.equals(0x4242, a.getInt16(i));
  }
  return a;
}
)";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle result =
      Dart_SetNativeResolver(lib, &ByteDataNativeResolver, nullptr);
  EXPECT_VALID(result);

  // Invoke 'main' function.
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

static constexpr intptr_t kExtLength = 16;
static int8_t data[kExtLength] = {
    0x41, 0x42, 0x41, 0x42, 0x41, 0x42, 0x41, 0x42,
    0x41, 0x42, 0x41, 0x42, 0x41, 0x42, 0x41, 0x42,
};

static void ExternalByteDataNativeFunction(Dart_NativeArguments args) {
  Dart_EnterScope();
  Dart_Handle external_byte_data =
      Dart_NewExternalTypedData(Dart_TypedData_kByteData, data, 16);
  EXPECT_VALID(external_byte_data);
  EXPECT_EQ(Dart_TypedData_kByteData,
            Dart_GetTypeOfTypedData(external_byte_data));
  Dart_SetReturnValue(args, external_byte_data);
  Dart_ExitScope();
}

static Dart_NativeFunction ExternalByteDataNativeResolver(
    Dart_Handle name,
    int arg_count,
    bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return &ExternalByteDataNativeFunction;
}

TEST_CASE(DartAPI_ExternalByteDataAccess) {
  // TODO(asiva): Once we have getInt16LE and getInt16BE support use the
  // appropriate getter instead of the host endian format used now.
  const char* kScriptChars = R"(
import 'dart:typed_data';
class Expect {
  static equals(a, b) {
    if (a != b) {
      throw 'not equal. expected: $a, got: $b';
    }
  }
}
@pragma("vm:external-name", "CreateExternalByteData")
external ByteData createExternalByteData();
ByteData main() {
  var length = 16;
  var a = createExternalByteData();
  Expect.equals(length, a.lengthInBytes);
  for (int i = 0; i < length; i+=2) {
    Expect.equals(0x4241, a.getInt16(i, Endian.little));
  }
  for (int i = 0; i < length; i+=2) {
    a.setInt8(i, 0x24);
    a.setInt8(i + 1, 0x28);
  }
  for (int i = 0; i < length; i+=2) {
    Expect.equals(0x2824, a.getInt16(i, Endian.little));
  }
  return a;
}
)";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle result =
      Dart_SetNativeResolver(lib, &ExternalByteDataNativeResolver, nullptr);
  EXPECT_VALID(result);

  // Invoke 'main' function.
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);

  for (intptr_t i = 0; i < kExtLength; i += 2) {
    EXPECT_EQ(0x24, data[i]);
    EXPECT_EQ(0x28, data[i + 1]);
  }
}

static bool byte_data_finalizer_run = false;
void ByteDataFinalizer(void* isolate_data, void* peer) {
  ASSERT(!byte_data_finalizer_run);
  free(peer);
  byte_data_finalizer_run = true;
}

TEST_CASE(DartAPI_ExternalByteDataFinalizer) {
  // Check finalizer associated with the underlying array instead of the
  // wrapper.
  const char* kScriptChars =
      "var array;\n"
      "@pragma('vm:entry-point', 'call')\n"
      "extractAndSaveArray(byteData) {\n"
      "  array = byteData.buffer.asUint8List();\n"
      "}\n"
      "@pragma('vm:entry-point', 'call')\n"
      "releaseArray() {\n"
      "  array = null;\n"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  {
    Dart_EnterScope();

    const intptr_t kBufferSize = 100;
    void* buffer = malloc(kBufferSize);
    // The buffer becomes readable by Dart, so ensure it is initialized to
    // satisfy our eager MSAN check.
    memset(buffer, 0, kBufferSize);
    Dart_Handle byte_data = Dart_NewExternalTypedDataWithFinalizer(
        Dart_TypedData_kByteData, buffer, kBufferSize, buffer, kBufferSize,
        ByteDataFinalizer);

    Dart_Handle result =
        Dart_Invoke(lib, NewString("extractAndSaveArray"), 1, &byte_data);
    EXPECT_VALID(result);

    // ByteData wrapper is still reachable from the scoped handle.
    EXPECT(!byte_data_finalizer_run);

    // The ByteData wrapper is now unreachable, but the underlying
    // ExternalUint8List is still alive.
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(Thread::Current());
    GCTestHelper::CollectAllGarbage();
  }

  EXPECT(!byte_data_finalizer_run);

  Dart_Handle result = Dart_Invoke(lib, NewString("releaseArray"), 0, nullptr);
  EXPECT_VALID(result);

  {
    TransitionNativeToVM transition(Thread::Current());
    GCTestHelper::CollectAllGarbage();
  }

  EXPECT(byte_data_finalizer_run);
}

static constexpr intptr_t kOptExtLength = 16;
static int8_t opt_data[kOptExtLength] = {
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
};

static void OptExternalByteDataNativeFunction(Dart_NativeArguments args) {
  Dart_EnterScope();
  Dart_Handle external_byte_data =
      Dart_NewExternalTypedData(Dart_TypedData_kByteData, opt_data, 16);
  EXPECT_VALID(external_byte_data);
  EXPECT_EQ(Dart_TypedData_kByteData,
            Dart_GetTypeOfTypedData(external_byte_data));
  Dart_SetReturnValue(args, external_byte_data);
  Dart_ExitScope();
}

static Dart_NativeFunction OptExternalByteDataNativeResolver(
    Dart_Handle name,
    int arg_count,
    bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return &OptExternalByteDataNativeFunction;
}

TEST_CASE(DartAPI_OptimizedExternalByteDataAccess) {
  TransitionNativeToVM transition1(thread);
  NoBackgroundCompilerScope no_background_compiler(thread);
  TransitionVMToNative transition2(thread);

  const char* kScriptChars = R"(
import 'dart:typed_data';
class Expect {
  static equals(a, b) {
    if (a != b) {
      throw 'not equal. expected: $a, got: $b';
    }
  }
}
@pragma("vm:external-name", "CreateExternalByteData")
external ByteData createExternalByteData();
access(ByteData a) {
  Expect.equals(0x04030201, a.getUint32(0, Endian.little));
  Expect.equals(0x08070605, a.getUint32(4, Endian.little));
  Expect.equals(0x0c0b0a09, a.getUint32(8, Endian.little));
  Expect.equals(0x100f0e0d, a.getUint32(12, Endian.little));
}
ByteData main() {
  var length = 16;
  var a = createExternalByteData();
  Expect.equals(length, a.lengthInBytes);
  for (int i = 0; i < 20; i++) {
    access(a);
  }
  return a;
}
)";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle result =
      Dart_SetNativeResolver(lib, &OptExternalByteDataNativeResolver, nullptr);
  EXPECT_VALID(result);

  // Invoke 'main' function.
  {
    SetFlagScope<int> sfs(&FLAG_optimization_counter_threshold, 5);
    result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  }
  EXPECT_VALID(result);
}

static void TestTypedDataDirectAccess() {
  Dart_Handle str = Dart_NewStringFromCString("junk");
  Dart_Handle byte_array = Dart_NewTypedData(Dart_TypedData_kUint8, 10);
  EXPECT_VALID(byte_array);
  Dart_Handle result;
  result = Dart_TypedDataAcquireData(byte_array, nullptr, nullptr, nullptr);
  EXPECT_ERROR(result,
               "Dart_TypedDataAcquireData expects argument 'type'"
               " to be non-null.");
  Dart_TypedData_Type type;
  result = Dart_TypedDataAcquireData(byte_array, &type, nullptr, nullptr);
  EXPECT_ERROR(result,
               "Dart_TypedDataAcquireData expects argument 'data'"
               " to be non-null.");
  void* data;
  result = Dart_TypedDataAcquireData(byte_array, &type, &data, nullptr);
  EXPECT_ERROR(result,
               "Dart_TypedDataAcquireData expects argument 'len'"
               " to be non-null.");
  intptr_t len;
  result = Dart_TypedDataAcquireData(Dart_Null(), &type, &data, &len);
  EXPECT_ERROR(result,
               "Dart_TypedDataAcquireData expects argument 'object'"
               " to be non-null.");
  result = Dart_TypedDataAcquireData(str, &type, &data, &len);
  EXPECT_ERROR(result,
               "Dart_TypedDataAcquireData expects argument 'object'"
               " to be of type 'TypedData'.");

  result = Dart_TypedDataReleaseData(Dart_Null());
  EXPECT_ERROR(result,
               "Dart_TypedDataReleaseData expects argument 'object'"
               " to be non-null.");
  result = Dart_TypedDataReleaseData(str);
  EXPECT_ERROR(result,
               "Dart_TypedDataReleaseData expects argument 'object'"
               " to be of type 'TypedData'.");
}

TEST_CASE(DartAPI_TypedDataDirectAccessUnverified) {
  FLAG_verify_acquired_data = false;
  TestTypedDataDirectAccess();
}

TEST_CASE(DartAPI_TypedDataDirectAccessVerified) {
  FLAG_verify_acquired_data = true;
  TestTypedDataDirectAccess();
}

static void TestDirectAccess(Dart_Handle lib,
                             Dart_Handle array,
                             Dart_TypedData_Type expected_type,
                             bool is_external) {
  Dart_Handle result;

  // Invoke the dart function that sets initial values.
  Dart_Handle dart_args[1];
  dart_args[0] = array;
  {
    SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
    result = Dart_Invoke(lib, NewString("setMain"), 1, dart_args);
  }
  EXPECT_VALID(result);

  // Now Get a direct access to this typed data object and check it's contents.
  const int kLength = 10;
  Dart_TypedData_Type type;
  void* data;
  intptr_t len;
  result = Dart_TypedDataAcquireData(array, &type, &data, &len);
  EXPECT(!Thread::Current()->IsAtSafepoint());
  EXPECT_VALID(result);
  EXPECT_EQ(expected_type, type);
  EXPECT_EQ(kLength, len);
  int8_t* dataP = reinterpret_cast<int8_t*>(data);
  for (int i = 0; i < kLength; i++) {
    EXPECT_EQ(i, dataP[i]);
  }

  // Now try allocating a string with outstanding Acquires and it should
  // return an error.
  result = NewString("We expect an error here");
  EXPECT_ERROR(result, "Callbacks into the Dart VM are currently prohibited");

  // Now modify the values in the directly accessible array and then check
  // it we see the changes back in dart.
  for (int i = 0; i < kLength; i++) {
    dataP[i] += 10;
  }

  // Release direct access to the typed data object.
  EXPECT(!Thread::Current()->IsAtSafepoint());
  result = Dart_TypedDataReleaseData(array);
  EXPECT_VALID(result);

  // Invoke the dart function in order to check the modified values.
  {
    SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
    result = Dart_Invoke(lib, NewString("testMain"), 1, dart_args);
  }
  EXPECT_VALID(result);
}

class BackgroundGCTask : public ThreadPool::Task {
 public:
  BackgroundGCTask(IsolateGroup* isolate_group, Monitor* monitor, bool* done)
      : isolate_group_(isolate_group), monitor_(monitor), done_(done) {}
  virtual void Run() {
    const bool kBypassSafepoint = false;
    Thread::EnterIsolateGroupAsHelper(isolate_group_, Thread::kUnknownTask,
                                      kBypassSafepoint);
    for (intptr_t i = 0; i < 10; i++) {
      GCTestHelper::CollectAllGarbage();
    }
    Thread::ExitIsolateGroupAsHelper(kBypassSafepoint);
    {
      MonitorLocker ml(monitor_);
      *done_ = true;
      ml.Notify();
    }
  }

 private:
  IsolateGroup* isolate_group_;
  Monitor* monitor_;
  bool* done_;
};

static void TestTypedDataDirectAccess1() {
  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "class Expect {\n"
      "  static equals(a, b) {\n"
      "    if (a != b) {\n"
      "      throw new Exception('not equal. expected: $a, got: $b');\n"
      "    }\n"
      "  }\n"
      "}\n"
      "void setMain(var a) {"
      "  for (var i = 0; i < 10; i++) {"
      "    a[i] = i;"
      "  }"
      "}\n"
      "bool testMain(var list) {"
      "  for (var i = 0; i < 10; i++) {"
      "    Expect.equals((10 + i), list[i]);"
      "  }\n"
      "  return true;"
      "}\n"
      "List main() {"
      "  var a = new Int8List(10);"
      "  return a;"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Monitor monitor;
  bool done = false;
  Dart::thread_pool()->Run<BackgroundGCTask>(IsolateGroup::Current(), &monitor,
                                             &done);

  for (intptr_t i = 0; i < 10; i++) {
    // Test with an regular typed data object.
    Dart_Handle list_access_test_obj;
    list_access_test_obj = Dart_Invoke(lib, NewString("main"), 0, nullptr);
    EXPECT_VALID(list_access_test_obj);
    TestDirectAccess(lib, list_access_test_obj, Dart_TypedData_kInt8, false);

    // Test with an external typed data object.
    uint8_t data[] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    intptr_t data_length = ARRAY_SIZE(data);
    Dart_Handle ext_list_access_test_obj;
    ext_list_access_test_obj =
        Dart_NewExternalTypedData(Dart_TypedData_kUint8, data, data_length);
    EXPECT_VALID(ext_list_access_test_obj);
    TestDirectAccess(lib, ext_list_access_test_obj, Dart_TypedData_kUint8,
                     true);
  }

  {
    MonitorLocker ml(&monitor);
    while (!done) {
      ml.Wait();
    }
  }
}

TEST_CASE(DartAPI_TypedDataDirectAccess1Unverified) {
  FLAG_verify_acquired_data = false;
  TestTypedDataDirectAccess1();
}

TEST_CASE(DartAPI_TypedDataDirectAccess1Verified) {
  FLAG_verify_acquired_data = true;
  TestTypedDataDirectAccess1();
}

static void TestTypedDataViewDirectAccess() {
  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "class Expect {\n"
      "  static equals(a, b) {\n"
      "    if (a != b) {\n"
      "      throw 'not equal. expected: $a, got: $b';\n"
      "    }\n"
      "  }\n"
      "}\n"
      "void setMain(var list) {"
      "  Expect.equals(10, list.length);"
      "  for (var i = 0; i < 10; i++) {"
      "    list[i] = i;"
      "  }"
      "}\n"
      "bool testMain(var list) {"
      "  Expect.equals(10, list.length);"
      "  for (var i = 0; i < 10; i++) {"
      "    Expect.equals((10 + i), list[i]);"
      "  }"
      "  return true;"
      "}\n"
      "List main() {"
      "  var a = new Int8List(100);"
      "  var view = new Int8List.view(a.buffer, 50, 10);"
      "  return view;"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Test with a typed data view object.
  Dart_Handle list_access_test_obj;
  list_access_test_obj = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(list_access_test_obj);
  TestDirectAccess(lib, list_access_test_obj, Dart_TypedData_kInt8, false);
}

TEST_CASE(DartAPI_TypedDataViewDirectAccessUnverified) {
  FLAG_verify_acquired_data = false;
  TestTypedDataViewDirectAccess();
}

TEST_CASE(DartAPI_TypedDataViewDirectAccessVerified) {
  FLAG_verify_acquired_data = true;
  TestTypedDataViewDirectAccess();
}

static void TestUnmodifiableTypedDataViewDirectAccess() {
  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "List main() {"
      "  var list = new Int8List(100);"
      "  for (var i = 0; i < 100; i++) {"
      "    list[i] = i;"
      "  }"
      "  return list.asUnmodifiableView();"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Test with a typed data view object.
  Dart_Handle view_obj;
  view_obj = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(view_obj);

  const int kLength = 100;
  Dart_TypedData_Type type;
  void* data;
  intptr_t len;
  Dart_Handle result = Dart_TypedDataAcquireData(view_obj, &type, &data, &len);
  EXPECT(!Thread::Current()->IsAtSafepoint());
  EXPECT_VALID(result);
  EXPECT_EQ(Dart_TypedData_kInt8, type);
  EXPECT_EQ(kLength, len);
  int8_t* dataP = reinterpret_cast<int8_t*>(data);
  for (int i = 0; i < kLength; i++) {
    EXPECT_EQ(i, dataP[i]);
  }

  // Now try allocating a string with outstanding Acquires and it should
  // return an error.
  result = NewString("We expect an error here");
  EXPECT_ERROR(result, "Callbacks into the Dart VM are currently prohibited");

  // Release direct access to the typed data object.
  EXPECT(!Thread::Current()->IsAtSafepoint());
  result = Dart_TypedDataReleaseData(view_obj);
  EXPECT_VALID(result);
}

TEST_CASE(DartAPI_UnmodifiableTypedDataViewDirectAccessUnverified) {
  FLAG_verify_acquired_data = false;
  TestUnmodifiableTypedDataViewDirectAccess();
}

TEST_CASE(DartAPI_UnmodifiableTypedDataViewDirectAccessVerified) {
  FLAG_verify_acquired_data = true;
  TestUnmodifiableTypedDataViewDirectAccess();
}

static void TestByteDataDirectAccess() {
  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "class Expect {\n"
      "  static equals(a, b) {\n"
      "    if (a != b) {\n"
      "      throw 'not equal. expected: $a, got: $b';\n"
      "    }\n"
      "  }\n"
      "}\n"
      "void setMain(var list) {"
      "  Expect.equals(10, list.length);"
      "  for (var i = 0; i < 10; i++) {"
      "    list.setInt8(i, i);"
      "  }"
      "}\n"
      "bool testMain(var list) {"
      "  Expect.equals(10, list.length);"
      "  for (var i = 0; i < 10; i++) {"
      "    Expect.equals((10 + i), list.getInt8(i));"
      "  }"
      "  return true;"
      "}\n"
      "ByteData main() {"
      "  var a = new Int8List(100);"
      "  var view = new ByteData.view(a.buffer, 50, 10);"
      "  return view;"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Test with a typed data view object.
  Dart_Handle list_access_test_obj;
  list_access_test_obj = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(list_access_test_obj);
  TestDirectAccess(lib, list_access_test_obj, Dart_TypedData_kByteData, false);
}

TEST_CASE(DartAPI_ByteDataDirectAccessUnverified) {
  FLAG_verify_acquired_data = false;
  TestByteDataDirectAccess();
}

TEST_CASE(DartAPI_ByteDataDirectAccessVerified) {
  FLAG_verify_acquired_data = true;
  TestByteDataDirectAccess();
}

TEST_CASE(DartAPI_NewUnmodifiableExternalTypedDataWithFinalizer) {
  const char* kScriptChars = R"(
class Expect {
  static equals(a, b) {
    if (a != b) {
      throw 'not equal. expected: $a, got: $b';
    }
  }
  static throws(block) {
    bool threw = false;
    try { block(); } catch (e) { threw = true; }
    if (!threw) throw 'did not throw';
  }
}
@pragma('vm:entry-point', 'call')
testList(data) {
  for (var i = 0; i < data.length; i++) {
    Expect.equals(i, data[i]);
    Expect.throws(() => data[i] = 0);
  }
}
@pragma('vm:entry-point', 'call')
testBytes(data) {
  for (var i = 0; i < data.length; i++) {
    Expect.equals(i, data.getUint8(i));
    Expect.throws(() => data.setUint8(i, 0));
  }
})";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  {
    uint8_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kUint8, &data[0], ARRAY_SIZE(data), nullptr, 0, nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kUint8, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    int8_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kInt8, &data[0], ARRAY_SIZE(data), nullptr, 0, nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kInt8, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    uint16_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kUint16, &data[0], ARRAY_SIZE(data), nullptr, 0,
        nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kUint16, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    int16_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kInt16, &data[0], ARRAY_SIZE(data), nullptr, 0, nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kInt16, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    uint32_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kUint32, &data[0], ARRAY_SIZE(data), nullptr, 0,
        nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kUint32, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    int32_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kInt32, &data[0], ARRAY_SIZE(data), nullptr, 0, nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kInt32, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    uint64_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kUint64, &data[0], ARRAY_SIZE(data), nullptr, 0,
        nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kUint64, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    int64_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kInt64, &data[0], ARRAY_SIZE(data), nullptr, 0, nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kInt64, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    float data[] = {0.0f, 1.0f, 2.0f, 3.0f};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kFloat32, &data[0], ARRAY_SIZE(data), nullptr, 0,
        nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kFloat32, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), 1, &typed_data);
    EXPECT_VALID(result);
    EXPECT_VALID(result);
  }

  {
    double data[] = {0.0, 1.0, 2.0, 3.0};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kFloat64, &data[0], ARRAY_SIZE(data), nullptr, 0,
        nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kFloat64, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testList"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }

  {
    uint8_t data[] = {0, 1, 2, 3};
    Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
        Dart_TypedData_kByteData, &data[0], ARRAY_SIZE(data), nullptr, 0,
        nullptr);
    EXPECT_VALID(typed_data);
    EXPECT_EQ(Dart_TypedData_kByteData, Dart_GetTypeOfTypedData(typed_data));
    Dart_Handle args[1];
    args[0] = typed_data;
    Dart_Handle result =
        Dart_Invoke(lib, NewString("testBytes"), ARRAY_SIZE(args), args);
    EXPECT_VALID(result);
  }
}

TEST_CASE(DartAPI_UnmodifiableTypedData_PassByReference) {
  const char* kScriptChars = R"(
import 'dart:isolate';
@pragma('vm:entry-point', 'call')
test(original) {
  var port = new RawReceivePort();
  port.handler = (msg) {
    port.close();
    if (!identical(original, msg)) throw "got a copy";
  };
  port.sendPort.send(original);
})";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  uint8_t data[] = {0, 1, 2, 3};
  Dart_Handle typed_data = Dart_NewUnmodifiableExternalTypedDataWithFinalizer(
      Dart_TypedData_kUint8, &data[0], ARRAY_SIZE(data), nullptr, 0, nullptr);
  EXPECT_VALID(typed_data);
  EXPECT_EQ(Dart_TypedData_kUint8, Dart_GetTypeOfTypedData(typed_data));
  Dart_Handle args[1];
  args[0] = typed_data;
  Dart_Handle result =
      Dart_Invoke(lib, NewString("test"), ARRAY_SIZE(args), args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT_VALID(result);
}

static void NopCallback(void* isolate_callback_data, void* peer) {}

TEST_CASE(DartAPI_ExternalAllocationDuringNoCallbackScope) {
  Dart_Handle bytes = Dart_NewTypedData(Dart_TypedData_kUint8, 100);
  EXPECT_VALID(bytes);

  intptr_t gc_count_before = Thread::Current()->heap()->Collections(Heap::kNew);

  Dart_TypedData_Type type;
  void* data;
  intptr_t len;
  Dart_Handle result = Dart_TypedDataAcquireData(bytes, &type, &data, &len);
  EXPECT_VALID(result);

  Dart_WeakPersistentHandle weak =
      Dart_NewWeakPersistentHandle(bytes, nullptr, 100 * MB, NopCallback);
  EXPECT_VALID(reinterpret_cast<Dart_Handle>(weak));

  EXPECT_EQ(gc_count_before,
            Thread::Current()->heap()->Collections(Heap::kNew));

  result = Dart_TypedDataReleaseData(bytes);
  EXPECT_VALID(result);

  EXPECT_LT(gc_count_before,
            Thread::Current()->heap()->Collections(Heap::kNew));
}

static void ExternalTypedDataAccessTests(Dart_Handle obj,
                                         Dart_TypedData_Type expected_type,
                                         uint8_t data[],
                                         intptr_t data_length) {
  EXPECT_VALID(obj);
  EXPECT_EQ(expected_type, Dart_GetTypeOfExternalTypedData(obj));
  EXPECT(Dart_IsList(obj));

  void* raw_data = nullptr;
  intptr_t len;
  Dart_TypedData_Type type;
  EXPECT_VALID(Dart_TypedDataAcquireData(obj, &type, &raw_data, &len));
  EXPECT(raw_data == data);
  EXPECT_EQ(data_length, len);
  EXPECT_EQ(expected_type, type);
  EXPECT_VALID(Dart_TypedDataReleaseData(obj));

  intptr_t list_length = 0;
  EXPECT_VALID(Dart_ListLength(obj, &list_length));
  EXPECT_EQ(data_length, list_length);

  // Load and check values from underlying array and API.
  for (intptr_t i = 0; i < list_length; ++i) {
    EXPECT_EQ(11 * i, data[i]);
    Dart_Handle elt = Dart_ListGetAt(obj, i);
    EXPECT_VALID(elt);
    int64_t value = 0;
    EXPECT_VALID(Dart_IntegerToInt64(elt, &value));
    EXPECT_EQ(data[i], value);
  }

  // Write values through the underlying array.
  for (intptr_t i = 0; i < data_length; ++i) {
    data[i] *= 2;
  }
  // Read them back through the API.
  for (intptr_t i = 0; i < list_length; ++i) {
    Dart_Handle elt = Dart_ListGetAt(obj, i);
    EXPECT_VALID(elt);
    int64_t value = 0;
    EXPECT_VALID(Dart_IntegerToInt64(elt, &value));
    EXPECT_EQ(22 * i, value);
  }

  // Write values through the API.
  for (intptr_t i = 0; i < list_length; ++i) {
    Dart_Handle value = Dart_NewInteger(33 * i);
    EXPECT_VALID(value);
    EXPECT_VALID(Dart_ListSetAt(obj, i, value));
  }
  // Read them back through the underlying array.
  for (intptr_t i = 0; i < data_length; ++i) {
    EXPECT_EQ(33 * i, data[i]);
  }
}

TEST_CASE(DartAPI_ExternalTypedDataAccess) {
  uint8_t data[] = {0, 11, 22, 33, 44, 55, 66, 77};
  intptr_t data_length = ARRAY_SIZE(data);

  Dart_Handle obj =
      Dart_NewExternalTypedData(Dart_TypedData_kUint8, data, data_length);
  ExternalTypedDataAccessTests(obj, Dart_TypedData_kUint8, data, data_length);
}

TEST_CASE(DartAPI_ExternalClampedTypedDataAccess) {
  uint8_t data[] = {0, 11, 22, 33, 44, 55, 66, 77};
  intptr_t data_length = ARRAY_SIZE(data);

  Dart_Handle obj = Dart_NewExternalTypedData(Dart_TypedData_kUint8Clamped,
                                              data, data_length);
  ExternalTypedDataAccessTests(obj, Dart_TypedData_kUint8Clamped, data,
                               data_length);
}

TEST_CASE(DartAPI_ExternalUint8ClampedArrayAccess) {
  const char* kScriptChars =
      "@pragma('vm:entry-point', 'call')\n"
      "testClamped(List a) {\n"
      "  if (a[1] != 11) return false;\n"
      "  a[1] = 3;\n"
      "  if (a[1] != 3) return false;\n"
      "  a[1] = -12;\n"
      "  if (a[1] != 0) return false;\n"
      "  a[1] = 1200;\n"
      "  if (a[1] != 255) return false;\n"
      "  return true;\n"
      "}\n";

  uint8_t data[] = {0, 11, 22, 33, 44, 55, 66, 77};
  intptr_t data_length = ARRAY_SIZE(data);
  Dart_Handle obj = Dart_NewExternalTypedData(Dart_TypedData_kUint8Clamped,
                                              data, data_length);
  EXPECT_VALID(obj);
  Dart_Handle result;
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle args[1];
  args[0] = obj;
  result = Dart_Invoke(lib, NewString("testClamped"), 1, args);

  // Check that result is true.
  EXPECT_VALID(result);
  EXPECT(Dart_IsBoolean(result));
  bool value = false;
  result = Dart_BooleanValue(result, &value);
  EXPECT_VALID(result);
  EXPECT(value);
}

static void UnreachedCallback(void* isolate_callback_data, void* peer) {
  UNREACHABLE();
}

static void ExternalTypedDataFinalizer(void* isolate_callback_data,
                                       void* peer) {
  *static_cast<int*>(peer) = 42;
}

TEST_CASE(DartAPI_ExternalTypedDataCallback) {
  int peer = 0;
  {
    Dart_EnterScope();
    uint8_t data[] = {1, 2, 3, 4};
    Dart_Handle obj = Dart_NewExternalTypedDataWithFinalizer(
        Dart_TypedData_kUint8, data, ARRAY_SIZE(data), &peer, sizeof(data),
        ExternalTypedDataFinalizer);
    EXPECT_VALID(obj);
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    EXPECT(peer == 0);
    GCTestHelper::CollectNewSpace();
    EXPECT(peer == 42);
  }
}

static void SlowFinalizer(void* isolate_callback_data, void* peer) {
  OS::Sleep(10);
  intptr_t* count = reinterpret_cast<intptr_t*>(peer);
  (*count)++;
}

TEST_CASE(DartAPI_SlowFinalizer) {
  intptr_t count = 0;
  for (intptr_t i = 0; i < 10; i++) {
    Dart_EnterScope();
    Dart_Handle str1 = Dart_NewStringFromCString("Live fast");
    Dart_NewFinalizableHandle(str1, &count, 0, SlowFinalizer);
    Dart_Handle str2 = Dart_NewStringFromCString("Die young");
    Dart_NewFinalizableHandle(str2, &count, 0, SlowFinalizer);
    Dart_ExitScope();

    {
      TransitionNativeToVM transition(thread);
      GCTestHelper::CollectAllGarbage();
    }
  }

  EXPECT_EQ(20, count);
}

static void SlowWeakPersistentHandle(void* isolate_callback_data, void* peer) {
  OS::Sleep(10);
  intptr_t* count = reinterpret_cast<intptr_t*>(peer);
  (*count)++;
}

TEST_CASE(DartAPI_SlowWeakPersistentHandle) {
  Dart_WeakPersistentHandle handles[20];
  intptr_t count = 0;

  for (intptr_t i = 0; i < 10; i++) {
    Dart_EnterScope();
    Dart_Handle str1 = Dart_NewStringFromCString("Live fast");
    handles[i] =
        Dart_NewWeakPersistentHandle(str1, &count, 0, SlowWeakPersistentHandle);
    Dart_Handle str2 = Dart_NewStringFromCString("Die young");
    handles[i + 10] =
        Dart_NewWeakPersistentHandle(str2, &count, 0, SlowWeakPersistentHandle);
    Dart_ExitScope();

    {
      TransitionNativeToVM transition(thread);
      GCTestHelper::CollectAllGarbage();
    }
  }

  EXPECT_EQ(20, count);

  for (intptr_t i = 0; i < 20; i++) {
    Dart_DeleteWeakPersistentHandle(handles[i]);
  }
}

static void CheckFloat32x4Data(Dart_Handle obj) {
  void* raw_data = nullptr;
  intptr_t len;
  Dart_TypedData_Type type;
  EXPECT_VALID(Dart_TypedDataAcquireData(obj, &type, &raw_data, &len));
  EXPECT_EQ(Dart_TypedData_kFloat32x4, type);
  EXPECT_EQ(len, 10);
  float* float_data = reinterpret_cast<float*>(raw_data);
  for (int i = 0; i < len * 4; i++) {
    EXPECT_EQ(0.0, float_data[i]);
  }
  EXPECT_VALID(Dart_TypedDataReleaseData(obj));
}

TEST_CASE(DartAPI_Float32x4List) {
  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "@pragma('vm:entry-point', 'call')\n"
      "Float32x4List float32x4() {\n"
      "  return new Float32x4List(10);\n"
      "}\n";
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle obj = Dart_Invoke(lib, NewString("float32x4"), 0, nullptr);
  EXPECT_VALID(obj);
  CheckFloat32x4Data(obj);

  obj = Dart_NewTypedData(Dart_TypedData_kFloat32x4, 10);
  EXPECT_VALID(obj);
  CheckFloat32x4Data(obj);

  int peer = 0;
  float data[] = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                  0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                  0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                  0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
  // Push a scope so that we can collect the local handle created as part of
  // Dart_NewExternalTypedData.
  Dart_EnterScope();
  {
    Dart_Handle lcl = Dart_NewExternalTypedDataWithFinalizer(
        Dart_TypedData_kFloat32x4, data, 10, &peer, sizeof(data),
        ExternalTypedDataFinalizer);
    CheckFloat32x4Data(lcl);
  }
  Dart_ExitScope();
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    EXPECT(peer == 42);
  }
}

// Unit test for entering a scope, creating a local handle and exiting
// the scope.
VM_UNIT_TEST_CASE(DartAPI_EnterExitScope) {
  TestIsolateScope __test_isolate__;

  Thread* thread = Thread::Current();
  EXPECT(thread != nullptr);
  ApiLocalScope* scope = thread->api_top_scope();
  Dart_EnterScope();
  {
    EXPECT(thread->api_top_scope() != nullptr);
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    String& str1 = String::Handle();
    str1 = String::New("Test String");
    Dart_Handle ref = Api::NewHandle(thread, str1.ptr());
    String& str2 = String::Handle();
    str2 ^= Api::UnwrapHandle(ref);
    EXPECT(str1.Equals(str2));
  }
  Dart_ExitScope();
  EXPECT(scope == thread->api_top_scope());
}

// Unit test for creating and deleting persistent handles.
VM_UNIT_TEST_CASE(DartAPI_PersistentHandles) {
  const char* kTestString1 = "Test String1";
  const char* kTestString2 = "Test String2";
  TestCase::CreateTestIsolate();
  Thread* thread = Thread::Current();
  Isolate* isolate = thread->isolate();
  EXPECT(isolate != nullptr);
  ApiState* state = isolate->group()->api_state();
  EXPECT(state != nullptr);
  ApiLocalScope* scope = thread->api_top_scope();

  const intptr_t handle_count_start = state->CountPersistentHandles();

  Dart_PersistentHandle handles[2000];
  Dart_EnterScope();
  {
    CHECK_API_SCOPE(thread);
    Dart_Handle ref1 = Dart_NewStringFromCString(kTestString1);
    for (int i = 0; i < 1000; i++) {
      handles[i] = Dart_NewPersistentHandle(ref1);
    }
    Dart_EnterScope();
    Dart_Handle ref2 = Dart_NewStringFromCString(kTestString2);
    for (int i = 1000; i < 2000; i++) {
      handles[i] = Dart_NewPersistentHandle(ref2);
    }
    for (int i = 500; i < 1500; i++) {
      Dart_DeletePersistentHandle(handles[i]);
    }
    for (int i = 500; i < 1000; i++) {
      handles[i] = Dart_NewPersistentHandle(ref2);
    }
    for (int i = 1000; i < 1500; i++) {
      handles[i] = Dart_NewPersistentHandle(ref1);
    }
    Dart_ExitScope();
  }
  Dart_ExitScope();
  {
    TransitionNativeToVM transition(thread);
    StackZone zone(thread);
    for (int i = 0; i < 500; i++) {
      String& str = String::Handle();
      str ^= PersistentHandle::Cast(handles[i])->ptr();
      EXPECT(str.Equals(kTestString1));
    }
    for (int i = 500; i < 1000; i++) {
      String& str = String::Handle();
      str ^= PersistentHandle::Cast(handles[i])->ptr();
      EXPECT(str.Equals(kTestString2));
    }
    for (int i = 1000; i < 1500; i++) {
      String& str = String::Handle();
      str ^= PersistentHandle::Cast(handles[i])->ptr();
      EXPECT(str.Equals(kTestString1));
    }
    for (int i = 1500; i < 2000; i++) {
      String& str = String::Handle();
      str ^= PersistentHandle::Cast(handles[i])->ptr();
      EXPECT(str.Equals(kTestString2));
    }
  }
  EXPECT(scope == thread->api_top_scope());
  EXPECT_EQ(handle_count_start + 2000, state->CountPersistentHandles());
  Dart_ShutdownIsolate();
}

// Test that we are able to create a persistent handle from a
// persistent handle.
VM_UNIT_TEST_CASE(DartAPI_NewPersistentHandle_FromPersistentHandle) {
  TestIsolateScope __test_isolate__;

  Isolate* isolate = Isolate::Current();
  EXPECT(isolate != nullptr);
  ApiState* state = isolate->group()->api_state();
  EXPECT(state != nullptr);
  Thread* thread = Thread::Current();
  CHECK_API_SCOPE(thread);

  // Start with a known persistent handle.
  Dart_PersistentHandle obj1 = Dart_NewPersistentHandle(Dart_True());
  EXPECT(state->IsValidPersistentHandle(obj1));

  // And use it to allocate a second persistent handle.
  Dart_Handle obj2 = Dart_HandleFromPersistent(obj1);
  Dart_PersistentHandle obj3 = Dart_NewPersistentHandle(obj2);
  EXPECT(state->IsValidPersistentHandle(obj3));

  // Make sure that the value transferred.
  Dart_Handle obj4 = Dart_HandleFromPersistent(obj3);
  EXPECT(Dart_IsBoolean(obj4));
  bool value = false;
  Dart_Handle result = Dart_BooleanValue(obj4, &value);
  EXPECT_VALID(result);
  EXPECT(value);
}

// Test that we can assign to a persistent handle.
VM_UNIT_TEST_CASE(DartAPI_AssignToPersistentHandle) {
  const char* kTestString1 = "Test String1";
  const char* kTestString2 = "Test String2";
  TestIsolateScope __test_isolate__;

  Thread* T = Thread::Current();
  CHECK_API_SCOPE(T);
  Isolate* isolate = T->isolate();
  EXPECT(isolate != nullptr);
  ApiState* state = isolate->group()->api_state();
  EXPECT(state != nullptr);

  // Start with a known persistent handle.
  Dart_Handle ref1 = Dart_NewStringFromCString(kTestString1);
  Dart_PersistentHandle obj = Dart_NewPersistentHandle(ref1);
  EXPECT(state->IsValidPersistentHandle(obj));
  {
    TransitionNativeToVM transition(T);
    HANDLESCOPE(T);
    String& str = String::Handle();
    str ^= PersistentHandle::Cast(obj)->ptr();
    EXPECT(str.Equals(kTestString1));
  }

  // Now create another local handle and assign it to the persistent handle.
  Dart_Handle ref2 = Dart_NewStringFromCString(kTestString2);
  Dart_SetPersistentHandle(obj, ref2);
  {
    TransitionNativeToVM transition(T);
    HANDLESCOPE(T);
    String& str = String::Handle();
    str ^= PersistentHandle::Cast(obj)->ptr();
    EXPECT(str.Equals(kTestString2));
  }

  // Now assign Null to the persistent handle and check.
  Dart_SetPersistentHandle(obj, Dart_Null());
  EXPECT(Dart_IsNull(obj));
}

static Dart_Handle AllocateNewString(const char* c_str) {
  Thread* thread = Thread::Current();
  TransitionNativeToVM transition(thread);
  return Api::NewHandle(thread, String::New(c_str, Heap::kNew));
}

static Dart_Handle AllocateOldString(const char* c_str) {
  Thread* thread = Thread::Current();
  TransitionNativeToVM transition(thread);
  return Api::NewHandle(thread, String::New(c_str, Heap::kOld));
}

static Dart_Handle AsHandle(Dart_PersistentHandle weak) {
  return Dart_HandleFromPersistent(weak);
}

static Dart_Handle AsHandle(Dart_WeakPersistentHandle weak) {
  return Dart_HandleFromWeakPersistent(weak);
}

TEST_CASE(DartAPI_WeakPersistentHandle) {
  Dart_WeakPersistentHandle weak_new_ref = nullptr;
  Dart_WeakPersistentHandle weak_old_ref = nullptr;

  {
    Dart_EnterScope();

    Dart_Handle new_ref, old_ref;
    {
      // GCs due to allocations or weak handle creation can cause early
      // promotion and interfere with the scenario this test is verifying.
      ForceGrowthScope force_growth(thread);

      // Create an object in new space.
      new_ref = AllocateNewString("new string");
      EXPECT_VALID(new_ref);

      // Create an object in old space.
      old_ref = AllocateOldString("old string");
      EXPECT_VALID(old_ref);

      // Create a weak ref to the new space object.
      weak_new_ref =
          Dart_NewWeakPersistentHandle(new_ref, nullptr, 0, NopCallback);
      EXPECT_VALID(AsHandle(weak_new_ref));
      EXPECT(!Dart_IsNull(AsHandle(weak_new_ref)));

      // Create a weak ref to the old space object.
      weak_old_ref =
          Dart_NewWeakPersistentHandle(old_ref, nullptr, 0, NopCallback);

      EXPECT_VALID(AsHandle(weak_old_ref));
      EXPECT(!Dart_IsNull(AsHandle(weak_old_ref)));
    }

    {
      TransitionNativeToVM transition(thread);
      // Garbage collect new space.
      GCTestHelper::CollectNewSpace();
    }

    // Nothing should be invalidated or cleared.
    EXPECT_VALID(new_ref);
    EXPECT(!Dart_IsNull(new_ref));
    EXPECT_VALID(old_ref);
    EXPECT(!Dart_IsNull(old_ref));

    EXPECT_VALID(AsHandle(weak_new_ref));
    EXPECT(!Dart_IsNull(AsHandle(weak_new_ref)));
    EXPECT(Dart_IdentityEquals(new_ref, AsHandle(weak_new_ref)));

    EXPECT_VALID(AsHandle(weak_old_ref));
    EXPECT(!Dart_IsNull(AsHandle(weak_old_ref)));
    EXPECT(Dart_IdentityEquals(old_ref, AsHandle(weak_old_ref)));

    {
      TransitionNativeToVM transition(thread);
      // Garbage collect old space.
      GCTestHelper::CollectOldSpace();
    }

    // Nothing should be invalidated or cleared.
    EXPECT_VALID(new_ref);
    EXPECT(!Dart_IsNull(new_ref));
    EXPECT_VALID(old_ref);
    EXPECT(!Dart_IsNull(old_ref));

    EXPECT_VALID(AsHandle(weak_new_ref));
    EXPECT(!Dart_IsNull(AsHandle(weak_new_ref)));
    EXPECT(Dart_IdentityEquals(new_ref, AsHandle(weak_new_ref)));

    EXPECT_VALID(AsHandle(weak_old_ref));
    EXPECT(!Dart_IsNull(AsHandle(weak_old_ref)));
    EXPECT(Dart_IdentityEquals(old_ref, AsHandle(weak_old_ref)));

    // Delete local (strong) references.
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(thread);
    // Garbage collect new space again.
    GCTestHelper::CollectNewSpace();
  }

  {
    Dart_EnterScope();
    // Weak ref to new space object should now be cleared.
    EXPECT_VALID(AsHandle(weak_new_ref));
    EXPECT(Dart_IsNull(AsHandle(weak_new_ref)));
    EXPECT_VALID(AsHandle(weak_old_ref));
    EXPECT(!Dart_IsNull(AsHandle(weak_old_ref)));
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(thread);
    // Garbage collect old space again.
    GCTestHelper::CollectOldSpace();
  }

  {
    Dart_EnterScope();
    // Weak ref to old space object should now be cleared.
    EXPECT_VALID(AsHandle(weak_new_ref));
    EXPECT(Dart_IsNull(AsHandle(weak_new_ref)));
    EXPECT_VALID(AsHandle(weak_old_ref));
    EXPECT(Dart_IsNull(AsHandle(weak_old_ref)));
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(thread);
    // Garbage collect one last time to revisit deleted handles.
    GCTestHelper::CollectAllGarbage();
  }

  Dart_DeleteWeakPersistentHandle(weak_new_ref);
  Dart_DeleteWeakPersistentHandle(weak_old_ref);
}

static Dart_FinalizableHandle finalizable_new_ref = nullptr;
static void* finalizable_new_ref_peer = 0;
static Dart_FinalizableHandle finalizable_old_ref = nullptr;
static void* finalizable_old_ref_peer = 0;

static void FinalizableHandleCallback(void* isolate_callback_data, void* peer) {
  if (peer == finalizable_new_ref_peer) {
    finalizable_new_ref_peer = 0;
    finalizable_new_ref = nullptr;
  } else if (peer == finalizable_old_ref_peer) {
    finalizable_old_ref_peer = 0;
    finalizable_old_ref = nullptr;
  }
}

TEST_CASE(DartAPI_FinalizableHandle) {
  void* peer = reinterpret_cast<void*>(0);
  Dart_Handle local_new_ref = Dart_Null();
  finalizable_new_ref = Dart_NewFinalizableHandle(local_new_ref, peer, 0,
                                                  FinalizableHandleCallback);
  finalizable_new_ref_peer = peer;

  peer = reinterpret_cast<void*>(1);
  Dart_Handle local_old_ref = Dart_Null();
  finalizable_old_ref = Dart_NewFinalizableHandle(local_old_ref, peer, 0,
                                                  FinalizableHandleCallback);
  finalizable_old_ref_peer = peer;

  {
    Dart_EnterScope();

    Dart_Handle new_ref, old_ref;
    {
      // GCs due to allocations or weak handle creation can cause early
      // promotion and interfere with the scenario this test is verifying.
      ForceGrowthScope force_growth(thread);

      // Create an object in new space.
      new_ref = AllocateNewString("new string");
      EXPECT_VALID(new_ref);

      // Create an object in old space.
      old_ref = AllocateOldString("old string");
      EXPECT_VALID(old_ref);

      // Create a weak ref to the new space object.
      peer = reinterpret_cast<void*>(2);
      finalizable_new_ref = Dart_NewFinalizableHandle(
          new_ref, peer, 0, FinalizableHandleCallback);
      finalizable_new_ref_peer = peer;

      // Create a weak ref to the old space object.
      peer = reinterpret_cast<void*>(3);
      finalizable_old_ref = Dart_NewFinalizableHandle(
          old_ref, peer, 0, FinalizableHandleCallback);
      finalizable_old_ref_peer = peer;
    }

    {
      TransitionNativeToVM transition(thread);
      // Garbage collect new space.
      GCTestHelper::CollectNewSpace();
    }

    // Nothing should be invalidated or cleared.
    EXPECT_VALID(new_ref);
    EXPECT(!Dart_IsNull(new_ref));
    EXPECT_VALID(old_ref);
    EXPECT(!Dart_IsNull(old_ref));

    {
      TransitionNativeToVM transition(thread);
      // Garbage collect old space.
      GCTestHelper::CollectOldSpace();
    }

    // Nothing should be invalidated or cleared.
    EXPECT_VALID(new_ref);
    EXPECT(!Dart_IsNull(new_ref));
    EXPECT_VALID(old_ref);
    EXPECT(!Dart_IsNull(old_ref));

    // Delete local (strong) references.
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(thread);
    // Garbage collect new space again.
    GCTestHelper::CollectNewSpace();
  }

  {
    Dart_EnterScope();
    // Weak ref to new space object should now be cleared.
    EXPECT(finalizable_new_ref == nullptr);
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(thread);
    // Garbage collect old space again.
    GCTestHelper::CollectOldSpace();
  }

  {
    Dart_EnterScope();
    // Weak ref to old space object should now be cleared.
    EXPECT(finalizable_new_ref == nullptr);
    EXPECT(finalizable_old_ref == nullptr);
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectAllGarbage();
  }
}

TEST_CASE(DartAPI_WeakPersistentHandleErrors) {
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_EnterScope();

  // nullptr callback.
  Dart_Handle obj1 = NewString("new string");
  EXPECT_VALID(obj1);
  Dart_WeakPersistentHandle ref1 =
      Dart_NewWeakPersistentHandle(obj1, nullptr, 0, nullptr);
  EXPECT_EQ(ref1, static_cast<void*>(nullptr));

  // Immediate object.
  Dart_Handle obj2 = Dart_NewInteger(0);
  EXPECT_VALID(obj2);
  Dart_WeakPersistentHandle ref2 =
      Dart_NewWeakPersistentHandle(obj2, nullptr, 0, NopCallback);
  EXPECT_EQ(ref2, static_cast<void*>(nullptr));

  // Pointer object.
  Dart_Handle ffi_lib = Dart_LookupLibrary(NewString("dart:ffi"));
  Dart_Handle pointer_type =
      Dart_GetNonNullableType(ffi_lib, NewString("Pointer"), 0, nullptr);
  Dart_Handle obj3 = Dart_Allocate(pointer_type);
  EXPECT_VALID(obj3);
  Dart_WeakPersistentHandle ref3 =
      Dart_NewWeakPersistentHandle(obj3, nullptr, 0, FinalizableHandleCallback);
  EXPECT_EQ(ref3, static_cast<void*>(nullptr));

  // Subtype of Struct or Union object.
  const char* kScriptChars = R"(
      import 'dart:ffi';

      final class MyStruct extends Struct {
        external Pointer notEmpty;
      }

      final class MyUnion extends Union {
        external Pointer notEmpty;
      }
  )";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle my_struct_type =
      Dart_GetNonNullableType(lib, NewString("MyStruct"), 0, nullptr);
  Dart_Handle obj4 = Dart_Allocate(my_struct_type);
  EXPECT_VALID(obj4);
  Dart_WeakPersistentHandle ref4 =
      Dart_NewWeakPersistentHandle(obj4, nullptr, 0, FinalizableHandleCallback);
  EXPECT_EQ(ref4, static_cast<void*>(nullptr));

  Dart_Handle my_union_type =
      Dart_GetNonNullableType(lib, NewString("MyUnion"), 0, nullptr);
  Dart_Handle obj5 = Dart_Allocate(my_union_type);
  EXPECT_VALID(obj5);
  Dart_WeakPersistentHandle ref5 =
      Dart_NewWeakPersistentHandle(obj4, nullptr, 0, FinalizableHandleCallback);
  EXPECT_EQ(ref5, static_cast<void*>(nullptr));

  Dart_ExitScope();
}

TEST_CASE(DartAPI_FinalizableHandleErrors) {
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_EnterScope();

  // nullptr callback.
  Dart_Handle obj1 = NewString("new string");
  EXPECT_VALID(obj1);
  Dart_FinalizableHandle ref1 =
      Dart_NewFinalizableHandle(obj1, nullptr, 0, nullptr);
  EXPECT_EQ(ref1, static_cast<void*>(nullptr));

  // Immediate object.
  Dart_Handle obj2 = Dart_NewInteger(0);
  EXPECT_VALID(obj2);
  Dart_FinalizableHandle ref2 =
      Dart_NewFinalizableHandle(obj2, nullptr, 0, FinalizableHandleCallback);
  EXPECT_EQ(ref2, static_cast<void*>(nullptr));

  // Pointer object.
  Dart_Handle ffi_lib = Dart_LookupLibrary(NewString("dart:ffi"));
  Dart_Handle pointer_type =
      Dart_GetNonNullableType(ffi_lib, NewString("Pointer"), 0, nullptr);
  Dart_Handle obj3 = Dart_Allocate(pointer_type);
  EXPECT_VALID(obj3);
  Dart_FinalizableHandle ref3 =
      Dart_NewFinalizableHandle(obj3, nullptr, 0, FinalizableHandleCallback);
  EXPECT_EQ(ref3, static_cast<void*>(nullptr));

  // Subtype of Struct or Union object.
  const char* kScriptChars = R"(
      import 'dart:ffi';

      final class MyStruct extends Struct {
        external Pointer notEmpty;
      }

      final class MyUnion extends Union {
        external Pointer notEmpty;
      }
  )";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle my_struct_type =
      Dart_GetNonNullableType(lib, NewString("MyStruct"), 0, nullptr);
  Dart_Handle obj4 = Dart_Allocate(my_struct_type);
  EXPECT_VALID(obj4);
  Dart_FinalizableHandle ref4 =
      Dart_NewFinalizableHandle(obj4, nullptr, 0, FinalizableHandleCallback);
  EXPECT_EQ(ref4, static_cast<void*>(nullptr));

  Dart_Handle my_union_type =
      Dart_GetNonNullableType(lib, NewString("MyUnion"), 0, nullptr);
  Dart_Handle obj5 = Dart_Allocate(my_union_type);
  EXPECT_VALID(obj5);
  Dart_FinalizableHandle ref5 =
      Dart_NewFinalizableHandle(obj4, nullptr, 0, FinalizableHandleCallback);
  EXPECT_EQ(ref5, static_cast<void*>(nullptr));

  Dart_ExitScope();
}

static Dart_PersistentHandle persistent_handle1;
static Dart_WeakPersistentHandle weak_persistent_handle2;
static Dart_WeakPersistentHandle weak_persistent_handle3;

static void WeakPersistentHandlePeerCleanupEnsuresIGFinalizer(
    void* isolate_callback_data,
    void* peer) {
  ASSERT(IsolateGroup::Current() != nullptr);
}

TEST_CASE(DartAPI_WeakPersistentHandleCleanupFinalizerAtShutdown) {
  const char* kTestString1 = "Test String1";
  int peer3 = 0;
  Dart_EnterScope();
  CHECK_API_SCOPE(thread);
  Dart_Handle ref3 = Dart_NewStringFromCString(kTestString1);
  weak_persistent_handle3 = Dart_NewWeakPersistentHandle(
      ref3, &peer3, 0, WeakPersistentHandlePeerCleanupEnsuresIGFinalizer);
  Dart_ExitScope();
}

static void WeakPersistentHandlePeerCleanupFinalizer(
    void* isolate_callback_data,
    void* peer) {
  Dart_DeletePersistentHandle(persistent_handle1);
  Dart_DeleteWeakPersistentHandle(weak_persistent_handle2);
  *static_cast<int*>(peer) = 42;
}

TEST_CASE(DartAPI_WeakPersistentHandleCleanupFinalizer) {
  Heap* heap = IsolateGroup::Current()->heap();

  const char* kTestString1 = "Test String1";
  Dart_EnterScope();
  CHECK_API_SCOPE(thread);
  Dart_Handle ref1 = Dart_NewStringFromCString(kTestString1);
  persistent_handle1 = Dart_NewPersistentHandle(ref1);
  Dart_Handle ref2 = Dart_NewStringFromCString(kTestString1);
  int peer2 = 0;
  weak_persistent_handle2 =
      Dart_NewWeakPersistentHandle(ref2, &peer2, 0, NopCallback);
  int peer3 = 0;
  {
    Dart_EnterScope();
    Dart_Handle ref3 = Dart_NewStringFromCString(kTestString1);
    weak_persistent_handle3 = Dart_NewWeakPersistentHandle(
        ref3, &peer3, 0, WeakPersistentHandlePeerCleanupFinalizer);
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectAllGarbage();
    EXPECT(heap->ExternalInWords(Heap::kOld) == 0);
    EXPECT(peer3 == 42);
  }
  Dart_ExitScope();

  Dart_DeleteWeakPersistentHandle(weak_persistent_handle3);
}

static Dart_FinalizableHandle finalizable_handle3;

static void FinalizableHandlePeerCleanupFinalizer(void* isolate_callback_data,
                                                  void* peer) {
  Dart_DeletePersistentHandle(persistent_handle1);
  Dart_DeleteWeakPersistentHandle(weak_persistent_handle2);
  *static_cast<int*>(peer) = 42;
}

TEST_CASE(DartAPI_FinalizableHandleCleanupFinalizer) {
  Heap* heap = IsolateGroup::Current()->heap();

  const char* kTestString1 = "Test String1";
  Dart_EnterScope();
  CHECK_API_SCOPE(thread);
  Dart_Handle ref1 = Dart_NewStringFromCString(kTestString1);
  persistent_handle1 = Dart_NewPersistentHandle(ref1);
  Dart_Handle ref2 = Dart_NewStringFromCString(kTestString1);
  int peer2 = 0;
  weak_persistent_handle2 =
      Dart_NewWeakPersistentHandle(ref2, &peer2, 0, NopCallback);
  int peer3 = 0;
  {
    Dart_EnterScope();
    Dart_Handle ref3 = Dart_NewStringFromCString(kTestString1);
    finalizable_handle3 = Dart_NewFinalizableHandle(
        ref3, &peer3, 0, FinalizableHandlePeerCleanupFinalizer);
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectAllGarbage();
    EXPECT(heap->ExternalInWords(Heap::kOld) == 0);
    EXPECT(peer3 == 42);
  }
  Dart_ExitScope();
}

static void WeakPersistentHandlePeerFinalizer(void* isolate_callback_data,
                                              void* peer) {
  *static_cast<int*>(peer) = 42;
}

TEST_CASE(DartAPI_WeakPersistentHandleCallback) {
  Dart_WeakPersistentHandle weak_ref = nullptr;
  int peer = 0;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("new string");
    EXPECT_VALID(obj);
    weak_ref = Dart_NewWeakPersistentHandle(obj, &peer, 0,
                                            WeakPersistentHandlePeerFinalizer);
    EXPECT_VALID(AsHandle(weak_ref));
    EXPECT(peer == 0);
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    EXPECT(peer == 42);
  }
  Dart_DeleteWeakPersistentHandle(weak_ref);
}

static void FinalizableHandlePeerFinalizer(void* isolate_callback_data,
                                           void* peer) {
  *static_cast<int*>(peer) = 42;
}

TEST_CASE(DartAPI_FinalizableHandleCallback) {
  int peer = 0;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("new string");
    EXPECT_VALID(obj);
    Dart_NewFinalizableHandle(obj, &peer, 0, FinalizableHandlePeerFinalizer);
    EXPECT(peer == 0);
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    EXPECT(peer == 42);
  }
}

TEST_CASE(DartAPI_WeakPersistentHandleNoCallback) {
  Dart_WeakPersistentHandle weak_ref = nullptr;
  int peer = 0;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("new string");
    EXPECT_VALID(obj);
    weak_ref = Dart_NewWeakPersistentHandle(obj, &peer, 0,
                                            WeakPersistentHandlePeerFinalizer);
    Dart_ExitScope();
  }
  // A finalizer is not invoked on a deleted handle.  Therefore, the
  // peer value should not change after the referent is collected.
  Dart_DeleteWeakPersistentHandle(weak_ref);
  EXPECT(peer == 0);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT(peer == 0);
    GCTestHelper::CollectNewSpace();
    EXPECT(peer == 0);
  }
}

TEST_CASE(DartAPI_FinalizableHandleNoCallback) {
  Dart_FinalizableHandle weak_ref = nullptr;
  Dart_PersistentHandle strong_ref = nullptr;
  int peer = 0;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("new string");
    EXPECT_VALID(obj);
    weak_ref = Dart_NewFinalizableHandle(obj, &peer, 0,
                                         FinalizableHandlePeerFinalizer);
    strong_ref = Dart_NewPersistentHandle(obj);
    Dart_ExitScope();
  }
  // A finalizer is not invoked on a deleted handle.  Therefore, the
  // peer value should not change after the referent is collected.
  Dart_DeleteFinalizableHandle(weak_ref, strong_ref);
  Dart_DeletePersistentHandle(strong_ref);
  EXPECT(peer == 0);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT(peer == 0);
    GCTestHelper::CollectNewSpace();
    EXPECT(peer == 0);
  }
}

Dart_WeakPersistentHandle delete_on_finalization;

static void DeleteWeakHandleOnFinalization(void* isolate_callback_data,
                                           void* peer) {
  *static_cast<int*>(peer) = 42;
  Dart_DeleteWeakPersistentHandle(delete_on_finalization);
  delete_on_finalization = nullptr;
}

static void DontDeleteWeakHandleOnFinalization(void* isolate_callback_data,
                                               void* peer) {
  *static_cast<int*>(peer) = 42;
  delete_on_finalization = nullptr;
}

// Mimicking the old handle behavior by deleting the handle itself in the
// finalizer.
TEST_CASE(DartAPI_WeakPersistentHandleCallbackSelfDelete) {
  int peer = 0;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("new string");
    EXPECT_VALID(obj);
    delete_on_finalization = Dart_NewWeakPersistentHandle(
        obj, &peer, 0, DeleteWeakHandleOnFinalization);
    EXPECT_VALID(AsHandle(delete_on_finalization));
    EXPECT(peer == 0);
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    EXPECT(peer == 42);
    ASSERT(delete_on_finalization == nullptr);
  }
}

// Checking that the finalizer gets run on shutdown, but that the delete
// handle does not get invoked. (The handles have already been deleted by
// releasing the LocalApiState.)
VM_UNIT_TEST_CASE(DartAPI_WeakPersistentHandlesCallbackShutdown) {
  TestCase::CreateTestIsolate();
  Dart_EnterScope();
  Dart_Handle ref = Dart_True();
  int peer = 1234;
  delete_on_finalization = Dart_NewWeakPersistentHandle(
      ref, &peer, 0, DontDeleteWeakHandleOnFinalization);
  Dart_ExitScope();
  Dart_ShutdownIsolate();
  EXPECT(peer == 42);
}

VM_UNIT_TEST_CASE(DartAPI_FinalizableHandlesCallbackShutdown) {
  TestCase::CreateTestIsolate();
  Dart_EnterScope();
  Dart_Handle ref = Dart_True();
  int peer = 1234;
  Dart_NewFinalizableHandle(ref, &peer, 0, FinalizableHandlePeerFinalizer);
  Dart_ExitScope();
  Dart_ShutdownIsolate();
  EXPECT(peer == 42);
}

TEST_CASE(DartAPI_WeakPersistentHandleExternalAllocationSize) {
  Heap* heap = IsolateGroup::Current()->heap();
  EXPECT_EQ(heap->ExternalInWords(Heap::kNew), 0);
  EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
  Dart_WeakPersistentHandle weak1 = nullptr;
  const intptr_t kWeak1ExternalSize = 1 * KB;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("weakly referenced string");
    EXPECT_VALID(obj);
    weak1 = Dart_NewWeakPersistentHandle(obj, nullptr, kWeak1ExternalSize,
                                         NopCallback);
    EXPECT_VALID(AsHandle(weak1));
    Dart_ExitScope();
  }
  Dart_PersistentHandle strong_ref = nullptr;
  Dart_WeakPersistentHandle weak2 = nullptr;
  const intptr_t kWeak2ExternalSize = 2 * KB;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("strongly referenced string");
    EXPECT_VALID(obj);
    strong_ref = Dart_NewPersistentHandle(obj);
    weak2 = Dart_NewWeakPersistentHandle(obj, nullptr, kWeak2ExternalSize,
                                         NopCallback);
    EXPECT_VALID(AsHandle(strong_ref));
    EXPECT_VALID(AsHandle(weak2));
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew),
              (kWeak1ExternalSize + kWeak2ExternalSize) / kWordSize);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
    // Collect weakly referenced string.
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew),
              kWeak2ExternalSize / kWordSize);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
    // Promote strongly referenced string.
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew), 0);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld),
              kWeak2ExternalSize / kWordSize);
  }
  Dart_DeletePersistentHandle(strong_ref);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew), 0);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
  }
  Dart_DeleteWeakPersistentHandle(weak1);
  Dart_DeleteWeakPersistentHandle(weak2);
}

TEST_CASE(DartAPI_FinalizableHandleExternalAllocationSize) {
  Heap* heap = IsolateGroup::Current()->heap();
  EXPECT_EQ(heap->ExternalInWords(Heap::kNew), 0);
  EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
  const intptr_t kWeak1ExternalSize = 1 * KB;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("weakly referenced string");
    EXPECT_VALID(obj);
    Dart_NewFinalizableHandle(obj, nullptr, kWeak1ExternalSize, NopCallback);
    Dart_ExitScope();
  }
  Dart_PersistentHandle strong_ref = nullptr;
  const intptr_t kWeak2ExternalSize = 2 * KB;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("strongly referenced string");
    EXPECT_VALID(obj);
    strong_ref = Dart_NewPersistentHandle(obj);
    Dart_NewFinalizableHandle(obj, nullptr, kWeak2ExternalSize, NopCallback);
    EXPECT_VALID(AsHandle(strong_ref));
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew),
              (kWeak1ExternalSize + kWeak2ExternalSize) / kWordSize);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
    // Collect weakly referenced string.
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew),
              kWeak2ExternalSize / kWordSize);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
    // Promote strongly referenced string.
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew), 0);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld),
              kWeak2ExternalSize / kWordSize);
  }
  Dart_DeletePersistentHandle(strong_ref);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(heap->ExternalInWords(Heap::kNew), 0);
    EXPECT_EQ(heap->ExternalInWords(Heap::kOld), 0);
  }
}

TEST_CASE(DartAPI_WeakPersistentHandleExternalAllocationSizeNewspaceGC) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_WeakPersistentHandle weak1 = nullptr;
  // Large enough to exceed any new space limit. Not actually allocated.
  const intptr_t kWeak1ExternalSize = 500 * MB;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("weakly referenced string");
    EXPECT_VALID(obj);
    // Triggers a scavenge immediately, since kWeak1ExternalSize is above limit.
    weak1 = Dart_NewWeakPersistentHandle(obj, nullptr, kWeak1ExternalSize,
                                         NopCallback);
    EXPECT_VALID(AsHandle(weak1));
    // ... but the object is still alive and not yet promoted, so external size
    // in new space is still above the limit. Thus, even the following tiny
    // external allocation will trigger another scavenge.
    Dart_WeakPersistentHandle trigger =
        Dart_NewWeakPersistentHandle(obj, nullptr, 1, NopCallback);
    EXPECT_VALID(AsHandle(trigger));
    Dart_DeleteWeakPersistentHandle(trigger);
    // After the two scavenges above, 'obj' should now be promoted, hence its
    // external size charged to old space.
    {
      CHECK_API_SCOPE(thread);
      TransitionNativeToVM transition(thread);
      HANDLESCOPE(thread);
      String& handle = String::Handle(thread->zone());
      handle ^= Api::UnwrapHandle(obj);
      EXPECT(handle.IsOld());
    }
    EXPECT(heap->ExternalInWords(Heap::kNew) == 0);
    EXPECT(heap->ExternalInWords(Heap::kOld) == kWeak1ExternalSize / kWordSize);
    Dart_ExitScope();
  }
  Dart_DeleteWeakPersistentHandle(weak1);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  }
}

TEST_CASE(DartAPI_FinalizableHandleExternalAllocationSizeNewspaceGC) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_FinalizableHandle weak1 = nullptr;
  Dart_PersistentHandle strong1 = nullptr;
  // Large enough to exceed any new space limit. Not actually allocated.
  const intptr_t kWeak1ExternalSize = 500 * MB;
  {
    Dart_EnterScope();
    Dart_Handle obj = NewString("weakly referenced string");
    EXPECT_VALID(obj);
    // Triggers a scavenge immediately, since kWeak1ExternalSize is above limit.
    weak1 = Dart_NewFinalizableHandle(obj, nullptr, kWeak1ExternalSize,
                                      NopCallback);
    strong1 = Dart_NewPersistentHandle(obj);
    // ... but the object is still alive and not yet promoted, so external size
    // in new space is still above the limit. Thus, even the following tiny
    // external allocation will trigger another scavenge.
    Dart_FinalizableHandle trigger =
        Dart_NewFinalizableHandle(obj, nullptr, 1, NopCallback);
    Dart_DeleteFinalizableHandle(trigger, obj);
    // After the two scavenges above, 'obj' should now be promoted, hence its
    // external size charged to old space.
    {
      CHECK_API_SCOPE(thread);
      TransitionNativeToVM transition(thread);
      HANDLESCOPE(thread);
      String& handle = String::Handle(thread->zone());
      handle ^= Api::UnwrapHandle(obj);
      EXPECT(handle.IsOld());
    }
    EXPECT(heap->ExternalInWords(Heap::kNew) == 0);
    EXPECT(heap->ExternalInWords(Heap::kOld) == kWeak1ExternalSize / kWordSize);
    Dart_ExitScope();
  }
  Dart_DeleteFinalizableHandle(weak1, strong1);
  Dart_DeletePersistentHandle(strong1);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  }
}

TEST_CASE(DartAPI_WeakPersistentHandleExternalAllocationSizeOldspaceGC) {
  // Check that external allocation in old space can trigger GC.
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_EnterScope();
  Dart_Handle live = AllocateOldString("live");
  EXPECT_VALID(live);
  Dart_WeakPersistentHandle weak = nullptr;
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::WaitForGCTasks();  // Finalize GC for accurate live size.
    EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  }
  const intptr_t kSmallExternalSize = 1 * KB;
  {
    Dart_EnterScope();
    Dart_Handle dead = AllocateOldString("dead");
    EXPECT_VALID(dead);
    weak = Dart_NewWeakPersistentHandle(dead, nullptr, kSmallExternalSize,
                                        NopCallback);
    EXPECT_VALID(AsHandle(weak));
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::WaitForGCTasks();  // Finalize GC for accurate live size.
    EXPECT_EQ(kSmallExternalSize,
              heap->ExternalInWords(Heap::kOld) * kWordSize);
  }
  // Large enough to trigger GC in old space. Not actually allocated.
  const intptr_t kHugeExternalSize = (kWordSize == 4) ? 513 * MB : 1025 * MB;
  Dart_WeakPersistentHandle weak2 = Dart_NewWeakPersistentHandle(
      live, nullptr, kHugeExternalSize, NopCallback);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::WaitForGCTasks();  // Finalize GC for accurate live size.
    // Expect small garbage to be collected.
    EXPECT_EQ(kHugeExternalSize, heap->ExternalInWords(Heap::kOld) * kWordSize);
  }
  Dart_ExitScope();
  Dart_DeleteWeakPersistentHandle(weak);
  Dart_DeleteWeakPersistentHandle(weak2);
}

TEST_CASE(DartAPI_FinalizableHandleExternalAllocationSizeOldspaceGC) {
  // Check that external allocation in old space can trigger GC.
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_EnterScope();
  Dart_Handle live = AllocateOldString("live");
  EXPECT_VALID(live);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::WaitForGCTasks();  // Finalize GC for accurate live size.
    EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  }
  const intptr_t kSmallExternalSize = 1 * KB;
  {
    Dart_EnterScope();
    Dart_Handle dead = AllocateOldString("dead");
    EXPECT_VALID(dead);
    Dart_NewFinalizableHandle(dead, nullptr, kSmallExternalSize, NopCallback);
    Dart_ExitScope();
  }
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::WaitForGCTasks();  // Finalize GC for accurate live size.
    EXPECT_EQ(kSmallExternalSize,
              heap->ExternalInWords(Heap::kOld) * kWordSize);
  }
  // Large enough to trigger GC in old space. Not actually allocated.
  const intptr_t kHugeExternalSize = (kWordSize == 4) ? 513 * MB : 1025 * MB;
  Dart_NewFinalizableHandle(live, nullptr, kHugeExternalSize, NopCallback);
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::WaitForGCTasks();  // Finalize GC for accurate live size.
    // Expect small garbage to be collected.
    EXPECT_EQ(kHugeExternalSize, heap->ExternalInWords(Heap::kOld) * kWordSize);
  }
  Dart_ExitScope();
}

TEST_CASE(DartAPI_WeakPersistentHandleExternalAllocationSizeOddReferents) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_WeakPersistentHandle weak1 = nullptr;
  const intptr_t kWeak1ExternalSize = 1 * KB;
  Dart_WeakPersistentHandle weak2 = nullptr;
  const intptr_t kWeak2ExternalSize = 2 * KB;
  EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  {
    Dart_EnterScope();
    Dart_Handle dart_true = Dart_True();  // VM heap object.
    EXPECT_VALID(dart_true);
    weak1 = Dart_NewWeakPersistentHandle(dart_true, nullptr, kWeak1ExternalSize,
                                         UnreachedCallback);
    EXPECT_VALID(AsHandle(weak1));
    Dart_Handle zero = Dart_False();  // VM heap object.
    EXPECT_VALID(zero);
    weak2 = Dart_NewWeakPersistentHandle(zero, nullptr, kWeak2ExternalSize,
                                         UnreachedCallback);
    EXPECT_VALID(AsHandle(weak2));
    // Both should be charged to old space.
    EXPECT(heap->ExternalInWords(Heap::kOld) ==
           (kWeak1ExternalSize + kWeak2ExternalSize) / kWordSize);
    Dart_ExitScope();
  }
  Dart_DeleteWeakPersistentHandle(weak1);
  Dart_DeleteWeakPersistentHandle(weak2);
  EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  }
}

TEST_CASE(DartAPI_FinalizableHandleExternalAllocationSizeOddReferents) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_FinalizableHandle weak1 = nullptr;
  Dart_PersistentHandle strong1 = nullptr;
  const intptr_t kWeak1ExternalSize = 1 * KB;
  Dart_FinalizableHandle weak2 = nullptr;
  Dart_PersistentHandle strong2 = nullptr;
  const intptr_t kWeak2ExternalSize = 2 * KB;
  EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  {
    Dart_EnterScope();
    Dart_Handle dart_true = Dart_True();  // VM heap object.
    EXPECT_VALID(dart_true);
    weak1 = Dart_NewFinalizableHandle(dart_true, nullptr, kWeak1ExternalSize,
                                      UnreachedCallback);
    strong1 = Dart_NewPersistentHandle(dart_true);
    Dart_Handle zero = Dart_False();  // VM heap object.
    EXPECT_VALID(zero);
    weak2 = Dart_NewFinalizableHandle(zero, nullptr, kWeak2ExternalSize,
                                      UnreachedCallback);
    strong2 = Dart_NewPersistentHandle(zero);
    // Both should be charged to old space.
    EXPECT(heap->ExternalInWords(Heap::kOld) ==
           (kWeak1ExternalSize + kWeak2ExternalSize) / kWordSize);
    Dart_ExitScope();
  }
  Dart_DeleteFinalizableHandle(weak1, strong1);
  Dart_DeletePersistentHandle(strong1);
  Dart_DeleteFinalizableHandle(weak2, strong2);
  Dart_DeletePersistentHandle(strong2);
  EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(0, heap->ExternalInWords(Heap::kOld));
  }
}

void FUNCTION_NAME(SecretKeeper_KeepSecret)(Dart_NativeArguments native_args) {
  Dart_Handle receiver = Dart_GetNativeArgument(native_args, 0);
  int64_t secret = 0;
  Dart_GetNativeIntegerArgument(native_args, 1, &secret);
  EXPECT_VALID(Dart_SetNativeInstanceField(receiver, 0, secret));
}

static Dart_NativeFunction SecretKeeperNativeResolver(Dart_Handle name,
                                                      int argument_count,
                                                      bool* auto_setup_scope) {
  return reinterpret_cast<Dart_NativeFunction>(Builtin_SecretKeeper_KeepSecret);
}

static intptr_t ReturnPtrAsInt(void* ptr) {
  return reinterpret_cast<intptr_t>(ptr);
}

static void* SecretKeeperFfiNativeResolver(const char* name, uintptr_t argn) {
  if (strcmp(name, "returnPtrAsInt") == 0 && argn == 1) {
    return reinterpret_cast<void*>(&ReturnPtrAsInt);
  }
  return nullptr;
}

TEST_CASE(DartAPI_NativeFieldAccess) {
  const char* kScriptChars = R"(
    import 'dart:ffi';
    import 'dart:nativewrappers';
    base class SecretKeeper extends NativeFieldWrapperClass1 {
      SecretKeeper(int secret) { _keepSecret(secret); }
      @pragma("vm:external-name", "SecretKeeper_KeepSecret")
      external void _keepSecret(int secret);
    }
    // Argument auto-conversion will wrap `o` in `_getNativeField()`.
    @Native<IntPtr Function(Pointer<Void>)>(symbol: 'returnPtrAsInt')
    external int returnPtrAsInt(NativeFieldWrapperClass1 o);
    main() => returnPtrAsInt(SecretKeeper(321));
  )";

  Dart_Handle result;
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, SecretKeeperNativeResolver);

  result = Dart_SetFfiNativeResolver(lib, &SecretKeeperFfiNativeResolver);
  EXPECT_VALID(result);

  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);

  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(321, value);
}

// Test that trying to access an unset native field (internally through
// _getNativeField(..)) will result in a Dart exception (and not crash).
TEST_CASE(DartAPI_NativeFieldAccess_Throws) {
  const char* kScriptChars = R"(
    import 'dart:ffi';
    import 'dart:nativewrappers';
    base class ForgetfulSecretKeeper extends NativeFieldWrapperClass1 {
      ForgetfulSecretKeeper(int secret) { /* Forget to init. native field. */ }
    }
    // Argument auto-conversion will wrap `o` in `_getNativeField()`.
    @Native<IntPtr Function(Pointer<Void>)>(symbol: 'returnPtrAsInt')
    external int returnPtrAsInt(NativeFieldWrapperClass1 o);
    main() => returnPtrAsInt(ForgetfulSecretKeeper(321));
  )";

  Dart_Handle result;
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, SecretKeeperNativeResolver);

  result = Dart_SetFfiNativeResolver(lib, &SecretKeeperFfiNativeResolver);
  EXPECT_VALID(result);

  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);

  EXPECT(Dart_IsError(result));
  EXPECT(Dart_IsUnhandledExceptionError(result));
}

static Dart_WeakPersistentHandle weak1 = nullptr;
static Dart_WeakPersistentHandle weak2 = nullptr;
static Dart_WeakPersistentHandle weak3 = nullptr;

static void ImplicitReferencesCallback(void* isolate_callback_data,
                                       void* peer) {
  if (peer == &weak1) {
    weak1 = nullptr;
  } else if (peer == &weak2) {
    weak2 = nullptr;
  } else if (peer == &weak3) {
    weak3 = nullptr;
  }
}

TEST_CASE(DartAPI_ImplicitReferencesOldSpace) {
  Dart_PersistentHandle strong = nullptr;
  Dart_WeakPersistentHandle strong_weak = nullptr;

  Dart_EnterScope();
  {
    CHECK_API_SCOPE(thread);

    Dart_Handle local = AllocateOldString("strongly reachable");
    strong = Dart_NewPersistentHandle(local);
    strong_weak = Dart_NewWeakPersistentHandle(local, nullptr, 0, NopCallback);

    EXPECT(!Dart_IsNull(AsHandle(strong)));
    EXPECT_VALID(AsHandle(strong));
    EXPECT(!Dart_IsNull(AsHandle(strong_weak)));
    EXPECT_VALID(AsHandle(strong_weak));
    EXPECT(Dart_IdentityEquals(AsHandle(strong), AsHandle(strong_weak)))

    weak1 =
        Dart_NewWeakPersistentHandle(AllocateOldString("weakly reachable 1"),
                                     &weak1, 0, ImplicitReferencesCallback);
    EXPECT(!Dart_IsNull(AsHandle(weak1)));
    EXPECT_VALID(AsHandle(weak1));

    weak2 =
        Dart_NewWeakPersistentHandle(AllocateOldString("weakly reachable 2"),
                                     &weak2, 0, ImplicitReferencesCallback);
    EXPECT(!Dart_IsNull(AsHandle(weak2)));
    EXPECT_VALID(AsHandle(weak2));

    weak3 =
        Dart_NewWeakPersistentHandle(AllocateOldString("weakly reachable 3"),
                                     &weak3, 0, ImplicitReferencesCallback);
    EXPECT(!Dart_IsNull(AsHandle(weak3)));
    EXPECT_VALID(AsHandle(weak3));
  }
  Dart_ExitScope();

  {
    Dart_EnterScope();
    EXPECT_VALID(AsHandle(strong_weak));
    EXPECT_VALID(AsHandle(weak1));
    EXPECT_VALID(AsHandle(weak2));
    EXPECT_VALID(AsHandle(weak3));
    Dart_ExitScope();
  }

  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
  }

  {
    Dart_EnterScope();
    // New space collection should not affect old space objects
    EXPECT_VALID(AsHandle(strong_weak));
    EXPECT(!Dart_IsNull(AsHandle(weak1)));
    EXPECT(!Dart_IsNull(AsHandle(weak2)));
    EXPECT(!Dart_IsNull(AsHandle(weak3)));
    Dart_ExitScope();
  }

  Dart_DeleteWeakPersistentHandle(strong_weak);
  Dart_DeleteWeakPersistentHandle(weak1);
  Dart_DeleteWeakPersistentHandle(weak2);
  Dart_DeleteWeakPersistentHandle(weak3);
}

TEST_CASE(DartAPI_ImplicitReferencesNewSpace) {
  Dart_PersistentHandle strong = nullptr;
  Dart_WeakPersistentHandle strong_weak = nullptr;

  Dart_EnterScope();
  {
    CHECK_API_SCOPE(thread);

    Dart_Handle local = AllocateOldString("strongly reachable");
    strong = Dart_NewPersistentHandle(local);
    strong_weak = Dart_NewWeakPersistentHandle(local, nullptr, 0, NopCallback);

    EXPECT(!Dart_IsNull(AsHandle(strong)));
    EXPECT_VALID(AsHandle(strong));
    EXPECT(!Dart_IsNull(AsHandle(strong_weak)));
    EXPECT_VALID(AsHandle(strong_weak));
    EXPECT(Dart_IdentityEquals(AsHandle(strong), AsHandle(strong_weak)))

    weak1 =
        Dart_NewWeakPersistentHandle(AllocateNewString("weakly reachable 1"),
                                     &weak1, 0, ImplicitReferencesCallback);
    EXPECT(!Dart_IsNull(AsHandle(weak1)));
    EXPECT_VALID(AsHandle(weak1));

    weak2 =
        Dart_NewWeakPersistentHandle(AllocateNewString("weakly reachable 2"),
                                     &weak2, 0, ImplicitReferencesCallback);
    EXPECT(!Dart_IsNull(AsHandle(weak2)));
    EXPECT_VALID(AsHandle(weak2));

    weak3 =
        Dart_NewWeakPersistentHandle(AllocateNewString("weakly reachable 3"),
                                     &weak3, 0, ImplicitReferencesCallback);
    EXPECT(!Dart_IsNull(AsHandle(weak3)));
    EXPECT_VALID(AsHandle(weak3));
  }
  Dart_ExitScope();

  {
    Dart_EnterScope();
    EXPECT_VALID(AsHandle(strong_weak));
    EXPECT_VALID(AsHandle(weak1));
    EXPECT_VALID(AsHandle(weak2));
    EXPECT_VALID(AsHandle(weak3));
    Dart_ExitScope();
  }

  Dart_DeleteWeakPersistentHandle(strong_weak);
  Dart_DeleteWeakPersistentHandle(weak1);
  Dart_DeleteWeakPersistentHandle(weak2);
  Dart_DeleteWeakPersistentHandle(weak3);
}

// Unit test for creating multiple scopes and local handles within them.
// Ensure that the local handles get all cleaned out when exiting the
// scope.
VM_UNIT_TEST_CASE(DartAPI_LocalHandles) {
  TestCase::CreateTestIsolate();
  Thread* thread = Thread::Current();
  Isolate* isolate = thread->isolate();
  EXPECT(isolate != nullptr);
  ApiLocalScope* scope = thread->api_top_scope();
  Dart_Handle handles[300];
  {
    TransitionNativeToVM transition1(thread);
    StackZone zone(thread);
    Smi& val = Smi::Handle();
    TransitionVMToNative transition2(thread);

    // Start a new scope and allocate some local handles.
    Dart_EnterScope();
    {
      TransitionNativeToVM transition3(thread);
      for (int i = 0; i < 100; i++) {
        handles[i] = Api::NewHandle(thread, Smi::New(i));
      }
      EXPECT_EQ(100, thread->CountLocalHandles());
      for (int i = 0; i < 100; i++) {
        val ^= Api::UnwrapHandle(handles[i]);
        EXPECT_EQ(i, val.Value());
      }
    }
    // Start another scope and allocate some more local handles.
    {
      Dart_EnterScope();
      {
        TransitionNativeToVM transition3(thread);
        for (int i = 100; i < 200; i++) {
          handles[i] = Api::NewHandle(thread, Smi::New(i));
        }
        EXPECT_EQ(200, thread->CountLocalHandles());
        for (int i = 100; i < 200; i++) {
          val ^= Api::UnwrapHandle(handles[i]);
          EXPECT_EQ(i, val.Value());
        }
      }

      // Start another scope and allocate some more local handles.
      {
        Dart_EnterScope();
        {
          TransitionNativeToVM transition3(thread);
          for (int i = 200; i < 300; i++) {
            handles[i] = Api::NewHandle(thread, Smi::New(i));
          }
          EXPECT_EQ(300, thread->CountLocalHandles());
          for (int i = 200; i < 300; i++) {
            val ^= Api::UnwrapHandle(handles[i]);
            EXPECT_EQ(i, val.Value());
          }
          EXPECT_EQ(300, thread->CountLocalHandles());
        }
        Dart_ExitScope();
      }
      EXPECT_EQ(200, thread->CountLocalHandles());
      Dart_ExitScope();
    }
    EXPECT_EQ(100, thread->CountLocalHandles());
    Dart_ExitScope();
  }
  EXPECT_EQ(0, thread->CountLocalHandles());
  EXPECT(scope == thread->api_top_scope());
  Dart_ShutdownIsolate();
}

// Unit test for creating multiple scopes and allocating objects in the
// zone for the scope. Ensure that the memory is freed when the scope
// exits.
VM_UNIT_TEST_CASE(DartAPI_LocalZoneMemory) {
  TestCase::CreateTestIsolate();
  Thread* thread = Thread::Current();
  EXPECT(thread != nullptr);
  ApiLocalScope* scope = thread->api_top_scope();
  EXPECT_EQ(0, thread->ZoneSizeInBytes());
  {
    // Start a new scope and allocate some memory.
    Dart_EnterScope();
    EXPECT_EQ(0, thread->ZoneSizeInBytes());
    for (int i = 0; i < 100; i++) {
      Dart_ScopeAllocate(16);
    }
    EXPECT_EQ(1600, thread->ZoneSizeInBytes());
    // Start another scope and allocate some more memory.
    {
      Dart_EnterScope();
      for (int i = 0; i < 100; i++) {
        Dart_ScopeAllocate(16);
      }
      EXPECT_EQ(3200, thread->ZoneSizeInBytes());
      {
        // Start another scope and allocate some more memory.
        {
          Dart_EnterScope();
          for (int i = 0; i < 200; i++) {
            Dart_ScopeAllocate(16);
          }
          EXPECT_EQ(6400, thread->ZoneSizeInBytes());
          Dart_ExitScope();
        }
      }
      EXPECT_EQ(3200, thread->ZoneSizeInBytes());
      Dart_ExitScope();
    }
    EXPECT_EQ(1600, thread->ZoneSizeInBytes());
    Dart_ExitScope();
  }
  EXPECT_EQ(0, thread->ZoneSizeInBytes());
  EXPECT(scope == thread->api_top_scope());
  Dart_ShutdownIsolate();
}

VM_UNIT_TEST_CASE(DartAPI_Isolates) {
  // This test currently assumes that the Dart_Isolate type is an opaque
  // representation of Isolate*.
  Dart_Isolate iso_1 = TestCase::CreateTestIsolate();
  EXPECT_EQ(iso_1, Api::CastIsolate(Isolate::Current()));
  Dart_Isolate isolate = Dart_CurrentIsolate();
  EXPECT_EQ(iso_1, isolate);
  Dart_ExitIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolate());
  Dart_Isolate iso_2 = TestCase::CreateTestIsolate();
  EXPECT_EQ(iso_2, Dart_CurrentIsolate());
  Dart_ExitIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolate());
  Dart_EnterIsolate(iso_2);
  EXPECT_EQ(iso_2, Dart_CurrentIsolate());
  Dart_ShutdownIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolate());
  Dart_EnterIsolate(iso_1);
  EXPECT_EQ(iso_1, Dart_CurrentIsolate());
  Dart_ShutdownIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolate());
}

VM_UNIT_TEST_CASE(DartAPI_IsolateGroups) {
  Dart_Isolate iso_1 = TestCase::CreateTestIsolate();
  EXPECT_NOTNULL(Dart_CurrentIsolateGroup());
  Dart_ExitIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolateGroup());
  Dart_Isolate iso_2 = TestCase::CreateTestIsolate();
  EXPECT_NOTNULL(Dart_CurrentIsolateGroup());
  Dart_ExitIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolateGroup());
  Dart_EnterIsolate(iso_2);
  EXPECT_NOTNULL(Dart_CurrentIsolateGroup());
  Dart_ShutdownIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolateGroup());
  Dart_EnterIsolate(iso_1);
  EXPECT_NOTNULL(Dart_CurrentIsolateGroup());
  Dart_ShutdownIsolate();
  EXPECT_NULLPTR(Dart_CurrentIsolateGroup());
}

VM_UNIT_TEST_CASE(DartAPI_CurrentIsolateData) {
  Dart_IsolateShutdownCallback saved_shutdown = Isolate::ShutdownCallback();
  Dart_IsolateGroupCleanupCallback saved_cleanup =
      Isolate::GroupCleanupCallback();
  Isolate::SetShutdownCallback(nullptr);
  Isolate::SetGroupCleanupCallback(nullptr);

  intptr_t mydata = 12345;
  Dart_Isolate isolate =
      TestCase::CreateTestIsolate(nullptr, reinterpret_cast<void*>(mydata));
  EXPECT(isolate != nullptr);
  EXPECT_EQ(mydata, reinterpret_cast<intptr_t>(Dart_CurrentIsolateGroupData()));
  EXPECT_EQ(mydata, reinterpret_cast<intptr_t>(Dart_IsolateGroupData(isolate)));
  Dart_ShutdownIsolate();

  Isolate::SetShutdownCallback(saved_shutdown);
  Isolate::SetGroupCleanupCallback(saved_cleanup);
}

static Dart_Handle LoadScript(const char* url_str, const char* source) {
  const uint8_t* kernel_buffer = nullptr;
  intptr_t kernel_buffer_size = 0;
  char* error = TestCase::CompileTestScriptWithDFE(
      url_str, source, &kernel_buffer, &kernel_buffer_size);
  if (error != nullptr) {
    return Dart_NewApiError(error);
  }
  TestCaseBase::AddToKernelBuffers(kernel_buffer);
  return Dart_LoadScriptFromKernel(kernel_buffer, kernel_buffer_size);
}

TEST_CASE(DartAPI_DebugName) {
  Dart_Handle debug_name = Dart_DebugName();
  EXPECT_VALID(debug_name);
  EXPECT(Dart_IsString(debug_name));
}

TEST_CASE(DartAPI_IsolateServiceID) {
  Dart_Isolate isolate = Dart_CurrentIsolate();
  const char* id = Dart_IsolateServiceId(isolate);
  EXPECT(id != nullptr);
  int64_t main_port = Dart_GetMainPortId();
  EXPECT_STREQ(ZONE_STR("isolates/%" Pd64, main_port), id);
  free(const_cast<char*>(id));
}

static void MyMessageNotifyCallback(Dart_Isolate dest_isolate) {}

VM_UNIT_TEST_CASE(DartAPI_SetMessageCallbacks) {
  Dart_Isolate dart_isolate = TestCase::CreateTestIsolate();
  Dart_SetMessageNotifyCallback(&MyMessageNotifyCallback);
  Isolate* isolate = reinterpret_cast<Isolate*>(dart_isolate);
  EXPECT_EQ(&MyMessageNotifyCallback, isolate->message_notify_callback());
  Dart_ShutdownIsolate();
}

TEST_CASE(DartAPI_SetStickyError) {
  const char* kScriptChars = "main() => throw 'HI';";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle retobj = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT(Dart_IsError(retobj));
  EXPECT(Dart_IsUnhandledExceptionError(retobj));
  EXPECT(!Dart_HasStickyError());
  EXPECT(Dart_GetStickyError() == Dart_Null());
  Dart_SetStickyError(retobj);
  EXPECT(Dart_HasStickyError());
  EXPECT(Dart_GetStickyError() != Dart_Null());
  Dart_SetStickyError(Dart_Null());
  EXPECT(!Dart_HasStickyError());
  EXPECT(Dart_GetStickyError() == Dart_Null());
}

TEST_CASE(DartAPI_TypeGetNonParametricTypes) {
  const char* kScriptChars =
      "class MyClass0 {\n"
      "}\n"
      "\n"
      "class MyClass1 implements MyInterface1 {\n"
      "}\n"
      "\n"
      "class MyClass2 implements MyInterface0, MyInterface1 {\n"
      "}\n"
      "\n"
      "abstract class MyInterface0 {\n"
      "}\n"
      "\n"
      "abstract class MyInterface1 implements MyInterface0 {\n"
      "}\n"
      "MyClass0 getMyClass0() { return new MyClass0(); }\n"
      "MyClass1 getMyClass1() { return new MyClass1(); }\n"
      "MyClass2 getMyClass2() { return new MyClass2(); }\n"
      "Type getMyClass0Type() { return new MyClass0().runtimeType; }\n"
      "Type getMyClass1Type() { return new MyClass1().runtimeType; }\n"
      "Type getMyClass2Type() { return new MyClass2().runtimeType; }\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  bool instanceOf = false;

  // First get the type objects of these non parameterized types.
  Dart_Handle type0 =
      Dart_GetNonNullableType(lib, NewString("MyClass0"), 0, nullptr);
  EXPECT_VALID(type0);
  Dart_Handle type1 =
      Dart_GetNonNullableType(lib, NewString("MyClass1"), 0, nullptr);
  EXPECT_VALID(type1);
  Dart_Handle type2 =
      Dart_GetNonNullableType(lib, NewString("MyClass2"), 0, nullptr);
  EXPECT_VALID(type2);
  Dart_Handle type3 =
      Dart_GetNonNullableType(lib, NewString("MyInterface0"), 0, nullptr);
  EXPECT_VALID(type3);
  Dart_Handle type4 =
      Dart_GetNonNullableType(lib, NewString("MyInterface1"), 0, nullptr);
  EXPECT_VALID(type4);

  // Now create objects of these non parameterized types and check
  // that the validity of the type of the created object.
  // MyClass0 type.
  Dart_Handle type0_obj =
      Dart_Invoke(lib, NewString("getMyClass0"), 0, nullptr);
  EXPECT_VALID(type0_obj);
  EXPECT_VALID(Dart_ObjectIsType(type0_obj, type0, &instanceOf));
  EXPECT(instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type0_obj, type1, &instanceOf));
  EXPECT(!instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type0_obj, type2, &instanceOf));
  EXPECT(!instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type0_obj, type3, &instanceOf));
  EXPECT(!instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type0_obj, type4, &instanceOf));
  EXPECT(!instanceOf);
  type0_obj = Dart_Invoke(lib, NewString("getMyClass0Type"), 0, nullptr);
  EXPECT_VALID(type0_obj);
  EXPECT(Dart_IdentityEquals(type0, type0_obj));

  // MyClass1 type.
  Dart_Handle type1_obj =
      Dart_Invoke(lib, NewString("getMyClass1"), 0, nullptr);
  EXPECT_VALID(type1_obj);
  EXPECT_VALID(Dart_ObjectIsType(type1_obj, type1, &instanceOf));
  EXPECT(instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type1_obj, type0, &instanceOf));
  EXPECT(!instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type1_obj, type2, &instanceOf));
  EXPECT(!instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type1_obj, type3, &instanceOf));
  EXPECT(instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type1_obj, type4, &instanceOf));
  EXPECT(instanceOf);
  type1_obj = Dart_Invoke(lib, NewString("getMyClass1Type"), 0, nullptr);
  EXPECT_VALID(type1_obj);
  EXPECT(Dart_IdentityEquals(type1, type1_obj));

  // MyClass2 type.
  Dart_Handle type2_obj =
      Dart_Invoke(lib, NewString("getMyClass2"), 0, nullptr);
  EXPECT_VALID(type2_obj);
  EXPECT_VALID(Dart_ObjectIsType(type2_obj, type2, &instanceOf));
  EXPECT(instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type2_obj, type0, &instanceOf));
  EXPECT(!instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type2_obj, type1, &instanceOf));
  EXPECT(!instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type2_obj, type3, &instanceOf));
  EXPECT(instanceOf);
  EXPECT_VALID(Dart_ObjectIsType(type2_obj, type4, &instanceOf));
  EXPECT(instanceOf);
  type2_obj = Dart_Invoke(lib, NewString("getMyClass2Type"), 0, nullptr);
  EXPECT_VALID(type2_obj);
  EXPECT(Dart_IdentityEquals(type2, type2_obj));
}

TEST_CASE(DartAPI_TypeGetParameterizedTypes) {
  const char* kScriptChars =
      "class MyClass0<A, B> {\n"
      "}\n"
      "\n"
      "class MyClass1<A, C> {\n"
      "}\n"
      "Type type<T>() => T;"
      "MyClass0 getMyClass0() {\n"
      "  return new MyClass0<int, double>();\n"
      "}\n"
      "Type getMyClass0Type() {\n"
      "  return type<MyClass0<int, double>>();\n"
      "}\n"
      "MyClass1 getMyClass1() {\n"
      "  return new MyClass1<List<int>, List>();\n"
      "}\n"
      "Type getMyClass1Type() {\n"
      "  return type<MyClass1<List<int>, List>>();\n"
      "}\n"
      "MyClass0 getMyClass0_1() {\n"
      "  return new MyClass0<double, int>();\n"
      "}\n"
      "Type getMyClass0_1Type() {\n"
      "  return type<MyClass0<double, int>>();\n"
      "}\n"
      "MyClass1 getMyClass1_1() {\n"
      "  return new MyClass1<List<int>, List<double>>();\n"
      "}\n"
      "Type getMyClass1_1Type() {\n"
      "  return type<MyClass1<List<int>, List<double>>>();\n"
      "}\n"
      "Type getIntType() { return int; }\n"
      "Type getDoubleType() { return double; }\n"
      "Type getListIntType() { return type<List<int>>(); }\n"
      "Type getListType() { return List; }\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle corelib = Dart_LookupLibrary(NewString("dart:core"));
  EXPECT_VALID(corelib);

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Now instantiate MyClass0 and MyClass1 types with the same type arguments
  // used in the code above.
  Dart_Handle type_args = Dart_NewList(2);
  Dart_Handle int_type = Dart_Invoke(lib, NewString("getIntType"), 0, nullptr);
  EXPECT_VALID(int_type);
  EXPECT_VALID(Dart_ListSetAt(type_args, 0, int_type));
  Dart_Handle double_type =
      Dart_Invoke(lib, NewString("getDoubleType"), 0, nullptr);
  EXPECT_VALID(double_type);
  EXPECT_VALID(Dart_ListSetAt(type_args, 1, double_type));
  Dart_Handle myclass0_type =
      Dart_GetNonNullableType(lib, NewString("MyClass0"), 2, &type_args);
  EXPECT_VALID(myclass0_type);

  type_args = Dart_NewList(2);
  Dart_Handle list_int_type =
      Dart_Invoke(lib, NewString("getListIntType"), 0, nullptr);
  EXPECT_VALID(list_int_type);
  EXPECT_VALID(Dart_ListSetAt(type_args, 0, list_int_type));
  Dart_Handle list_type =
      Dart_Invoke(lib, NewString("getListType"), 0, nullptr);
  EXPECT_VALID(list_type);
  EXPECT_VALID(Dart_ListSetAt(type_args, 1, list_type));
  Dart_Handle myclass1_type =
      Dart_GetNonNullableType(lib, NewString("MyClass1"), 2, &type_args);
  EXPECT_VALID(myclass1_type);

  // Now create objects of the type and validate the object type matches
  // the one returned above. Also get the runtime type of the object and
  // verify that it matches the type returned above. Note: we use
  // Dart_ObjectEquals instead of Dart_IdentityEquals since we are comparing
  // type literals with non-literals which would fail in unsound null safety
  // mode.
  // MyClass0<int, double> type.
  Dart_Handle type0_obj =
      Dart_Invoke(lib, NewString("getMyClass0"), 0, nullptr);
  EXPECT_VALID(type0_obj);
  bool instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(type0_obj, myclass0_type, &instanceOf));
  EXPECT(instanceOf);
  type0_obj = Dart_Invoke(lib, NewString("getMyClass0Type"), 0, nullptr);
  EXPECT_VALID(type0_obj);

  bool equal = false;
  EXPECT_VALID(Dart_ObjectEquals(type0_obj, myclass0_type, &equal));
  EXPECT(equal);

  // MyClass1<List<int>, List> type.
  Dart_Handle type1_obj =
      Dart_Invoke(lib, NewString("getMyClass1"), 0, nullptr);
  EXPECT_VALID(type1_obj);
  EXPECT_VALID(Dart_ObjectIsType(type1_obj, myclass1_type, &instanceOf));
  EXPECT(instanceOf);
  type1_obj = Dart_Invoke(lib, NewString("getMyClass1Type"), 0, nullptr);
  EXPECT_VALID(type1_obj);

  EXPECT_VALID(Dart_ObjectEquals(type1_obj, myclass1_type, &equal));
  EXPECT(equal);

  // MyClass0<double, int> type.
  type0_obj = Dart_Invoke(lib, NewString("getMyClass0_1"), 0, nullptr);
  EXPECT_VALID(type0_obj);
  EXPECT_VALID(Dart_ObjectIsType(type0_obj, myclass0_type, &instanceOf));
  EXPECT(!instanceOf);
  type0_obj = Dart_Invoke(lib, NewString("getMyClass0_1Type"), 0, nullptr);
  EXPECT_VALID(type0_obj);
  EXPECT_VALID(Dart_ObjectEquals(type0_obj, myclass0_type, &equal));
  EXPECT(!equal);

  // MyClass1<List<int>, List<double>> type.
  type1_obj = Dart_Invoke(lib, NewString("getMyClass1_1"), 0, nullptr);
  EXPECT_VALID(type1_obj);
  EXPECT_VALID(Dart_ObjectIsType(type1_obj, myclass1_type, &instanceOf));
  EXPECT(instanceOf);
  type1_obj = Dart_Invoke(lib, NewString("getMyClass1_1Type"), 0, nullptr);
  EXPECT_VALID(type1_obj);
  EXPECT_VALID(Dart_ObjectEquals(type1_obj, myclass1_type, &equal));
  EXPECT(!equal);
}

static void TestFieldOk(Dart_Handle container,
                        Dart_Handle name,
                        bool final,
                        const char* initial_value) {
  Dart_Handle result;

  // Make sure we have the right initial value.
  result = Dart_GetField(container, name);
  EXPECT_VALID(result);
  const char* value = "";
  EXPECT_VALID(Dart_StringToCString(result, &value));
  EXPECT_STREQ(initial_value, value);

  // Use a unique expected value.
  static int counter = 0;
  char buffer[256];
  Utils::SNPrint(buffer, 256, "Expected%d", ++counter);

  // Try to change the field value.
  result = Dart_SetField(container, name, NewString(buffer));
  if (final) {
    EXPECT(Dart_IsError(result));
  } else {
    EXPECT_VALID(result);
  }

  // Make sure we have the right final value.
  result = Dart_GetField(container, name);
  EXPECT_VALID(result);
  EXPECT_VALID(Dart_StringToCString(result, &value));
  if (final) {
    EXPECT_STREQ(initial_value, value);
  } else {
    EXPECT_STREQ(buffer, value);
  }
}

static void TestFieldNotFound(Dart_Handle container, Dart_Handle name) {
  EXPECT_ERROR(Dart_GetField(container, name), "NoSuchMethodError");
  EXPECT_ERROR(Dart_SetField(container, name, Dart_Null()),
               "NoSuchMethodError");
}

TEST_CASE(DartAPI_FieldAccess) {
  const char* kScriptChars =
      "class BaseFields {\n"
      "  BaseFields()\n"
      "    : this.inherited_fld = 'inherited' {\n"
      "  }\n"
      "  var inherited_fld;\n"
      "  static var non_inherited_fld;\n"
      "}\n"
      "\n"
      "class Fields extends BaseFields {\n"
      "  Fields()\n"
      "    : this.instance_fld = 'instance',\n"
      "      this._instance_fld = 'hidden instance',\n"
      "      this.final_instance_fld = 'final instance',\n"
      "      this._final_instance_fld = 'hidden final instance' {\n"
      "    instance_getset_fld = 'instance getset';\n"
      "    _instance_getset_fld = 'hidden instance getset';\n"
      "  }\n"
      "\n"
      "  static Init() {\n"
      "    static_fld = 'static';\n"
      "    _static_fld = 'hidden static';\n"
      "    static_getset_fld = 'static getset';\n"
      "    _static_getset_fld = 'hidden static getset';\n"
      "  }\n"
      "\n"
      "  var instance_fld;\n"
      "  var _instance_fld;\n"
      "  final final_instance_fld;\n"
      "  final _final_instance_fld;\n"
      "  static var static_fld;\n"
      "  static var _static_fld;\n"
      "  static const const_static_fld = 'const static';\n"
      "  static const _const_static_fld = 'hidden const static';\n"
      "\n"
      "  get instance_getset_fld { return _gs_fld1; }\n"
      "  void set instance_getset_fld(var value) { _gs_fld1 = value; }\n"
      "  get _instance_getset_fld { return _gs_fld2; }\n"
      "  void set _instance_getset_fld(var value) { _gs_fld2 = value; }\n"
      "  var _gs_fld1;\n"
      "  var _gs_fld2;\n"
      "\n"
      "  static get static_getset_fld { return _gs_fld3; }\n"
      "  static void set static_getset_fld(var value) { _gs_fld3 = value; }\n"
      "  static get _static_getset_fld { return _gs_fld4; }\n"
      "  static void set _static_getset_fld(var value) { _gs_fld4 = value; }\n"
      "  static var _gs_fld3;\n"
      "  static var _gs_fld4;\n"
      "}\n"
      "var top_fld;\n"
      "var _top_fld;\n"
      "const const_top_fld = 'const top';\n"
      "const _const_top_fld = 'hidden const top';\n"
      "\n"
      "get top_getset_fld { return _gs_fld5; }\n"
      "void set top_getset_fld(var value) { _gs_fld5 = value; }\n"
      "get _top_getset_fld { return _gs_fld6; }\n"
      "void set _top_getset_fld(var value) { _gs_fld6 = value; }\n"
      "var _gs_fld5;\n"
      "var _gs_fld6;\n"
      "\n"
      "Fields test() {\n"
      "  Fields.Init();\n"
      "  top_fld = 'top';\n"
      "  _top_fld = 'hidden top';\n"
      "  top_getset_fld = 'top getset';\n"
      "  _top_getset_fld = 'hidden top getset';\n"
      "  return new Fields();\n"
      "}\n";
  const char* kImportedScriptChars =
      "library library_name;\n"
      "var imported_fld = 'imported';\n"
      "var _imported_fld = 'hidden imported';\n"
      "get imported_getset_fld { return _gs_fld1; }\n"
      "void set imported_getset_fld(var value) { _gs_fld1 = value; }\n"
      "get _imported_getset_fld { return _gs_fld2; }\n"
      "void set _imported_getset_fld(var value) { _gs_fld2 = value; }\n"
      "var _gs_fld1;\n"
      "var _gs_fld2;\n"
      "void test2() {\n"
      "  imported_getset_fld = 'imported getset';\n"
      "  _imported_getset_fld = 'hidden imported getset';\n"
      "}\n";

  // Shared setup.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("Fields"), 0, nullptr);
  EXPECT_VALID(type);
  Dart_Handle instance = Dart_Invoke(lib, NewString("test"), 0, nullptr);
  EXPECT_VALID(instance);
  Dart_Handle name;

  // Load imported lib.
  Dart_Handle imported_lib =
      TestCase::LoadTestLibrary("library_url", kImportedScriptChars);
  EXPECT_VALID(imported_lib);
  Dart_Handle result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  result = Dart_Invoke(imported_lib, NewString("test2"), 0, nullptr);
  EXPECT_VALID(result);

  // Instance field.
  name = NewString("instance_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(type, name);
  TestFieldOk(instance, name, false, "instance");

  // Hidden instance field.
  name = NewString("_instance_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(type, name);
  TestFieldOk(instance, name, false, "hidden instance");

  // Final instance field.
  name = NewString("final_instance_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(type, name);
  TestFieldOk(instance, name, true, "final instance");

  // Hidden final instance field.
  name = NewString("_final_instance_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(type, name);
  TestFieldOk(instance, name, true, "hidden final instance");

  // Inherited field.
  name = NewString("inherited_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(type, name);
  TestFieldOk(instance, name, false, "inherited");

  // Instance get/set field.
  name = NewString("instance_getset_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(type, name);
  TestFieldOk(instance, name, false, "instance getset");

  // Hidden instance get/set field.
  name = NewString("_instance_getset_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(type, name);
  TestFieldOk(instance, name, false, "hidden instance getset");

  // Static field.
  name = NewString("static_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(type, name, false, "static");

  // Hidden static field.
  name = NewString("_static_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(type, name, false, "hidden static");

  // Static final field.
  name = NewString("const_static_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(type, name, true, "const static");

  // Hidden static const field.
  name = NewString("_const_static_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(type, name, true, "hidden const static");

  // Static non-inherited field.  Not found at any level.
  name = NewString("non_inherited_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(instance, name);
  TestFieldNotFound(type, name);

  // Static get/set field.
  name = NewString("static_getset_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(type, name, false, "static getset");

  // Hidden static get/set field.
  name = NewString("_static_getset_fld");
  TestFieldNotFound(lib, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(type, name, false, "hidden static getset");

  // Top-Level field.
  name = NewString("top_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(lib, name, false, "top");

  // Hidden top-level field.
  name = NewString("_top_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(lib, name, false, "hidden top");

  // Top-Level final field.
  name = NewString("const_top_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(lib, name, true, "const top");

  // Hidden top-level final field.
  name = NewString("_const_top_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(lib, name, true, "hidden const top");

  // Top-Level get/set field.
  name = NewString("top_getset_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(lib, name, false, "top getset");

  // Hidden top-level get/set field.
  name = NewString("_top_getset_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldOk(lib, name, false, "hidden top getset");

  // Imported top-Level field.
  name = NewString("imported_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldNotFound(lib, name);

  // Hidden imported top-level field.  Not found at any level.
  name = NewString("_imported_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldNotFound(lib, name);

  // Imported top-Level get/set field.
  name = NewString("imported_getset_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldNotFound(lib, name);

  // Hidden imported top-level get/set field.  Not found at any level.
  name = NewString("_imported_getset_fld");
  TestFieldNotFound(type, name);
  TestFieldNotFound(instance, name);
  TestFieldNotFound(lib, name);
}

TEST_CASE(DartAPI_SetField_FunnyValue) {
  const char* kScriptChars =
      "@pragma('vm:entry-point')\n"
      "var top;\n";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle name = NewString("top");
  bool value;

  // Test that you can set the field to a good value.
  EXPECT_VALID(Dart_SetField(lib, name, Dart_True()));
  Dart_Handle result = Dart_GetField(lib, name);
  EXPECT_VALID(result);
  EXPECT(Dart_IsBoolean(result));
  EXPECT_VALID(Dart_BooleanValue(result, &value));
  EXPECT(value);

  // Test that you can set the field to null
  EXPECT_VALID(Dart_SetField(lib, name, Dart_Null()));
  result = Dart_GetField(lib, name);
  EXPECT_VALID(result);
  EXPECT(Dart_IsNull(result));

  // Pass a non-instance handle.
  result = Dart_SetField(lib, name, lib);
  EXPECT_ERROR(
      result, "Dart_SetField expects argument 'value' to be of type Instance.");

  // Pass an error handle.  The error is contagious.
  result = Dart_SetField(lib, name, Api::NewError("myerror"));
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("myerror", Dart_GetError(result));
}

TEST_CASE(DartAPI_SetField_BadType) {
  const char* kScriptChars =
      "@pragma('vm:entry-point', 'set')\n"
      "late int foo;\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle name = NewString("foo");
  Dart_Handle result = Dart_SetField(lib, name, Dart_True());
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("type 'bool' is not a subtype of type 'int' of 'foo'",
                   Dart_GetError(result));
}

void NativeFieldLookup(Dart_NativeArguments args) {
  UNREACHABLE();
}

static Dart_NativeFunction native_field_lookup(Dart_Handle name,
                                               int argument_count,
                                               bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = false;
  return NativeFieldLookup;
}

TEST_CASE(DartAPI_InjectNativeFields2) {
  // clang-format off
  const char* kScriptChars =
                  "class NativeFields extends NativeFieldsWrapper {\n"
                  "  NativeFields(int i, int j) : fld1 = i, fld2 = j {}\n"
                  "  int fld1;\n"
                  "  final int fld;\n"
                  "  static int? fld3;\n"
                  "  static const int fld4 = 10;\n"
                  "}\n"
                  "@pragma('vm:entry-point', 'call')\n"
                  "NativeFields testMain() {\n"
                  "  NativeFields obj = new NativeFields(10, 20);\n"
                  "  return obj;\n"
                  "}\n";
  // clang-format on

  Dart_Handle result;
  // Create a test library and Load up a test script in it.
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, nullptr, USER_TEST_URI, false);

  // Invoke a function which returns an object of type NativeFields.
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);

  // We expect this to fail as class "NativeFields" extends
  // "NativeFieldsWrapper" and there is no definition of it either
  // in the dart code or through the native field injection mechanism.
  EXPECT(Dart_IsError(result));
}

TEST_CASE(DartAPI_InjectNativeFields3) {
  // clang-format off
  const char* kScriptChars =
                  "import 'dart:nativewrappers';"
                  "final class NativeFields "
                  "extends NativeFieldWrapperClass2 {\n"
                  "  NativeFields(int i, int j) : fld1 = i, fld2 = j {}\n"
                  "  int fld1;\n"
                  "  final int fld2;\n"
                  "  static int? fld3;\n"
                  "  static const int fld4 = 10;\n"
                  "}\n"
                  "@pragma('vm:entry-point', 'call')\n"
                  "NativeFields testMain() {\n"
                  "  NativeFields obj = new NativeFields(10, 20);\n"
                  "  return obj;\n"
                  "}\n";
  // clang-format on
  Dart_Handle result;
  const int kNumNativeFields = 2;

  // Load up a test script in the test library.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, native_field_lookup);

  // Invoke a function which returns an object of type NativeFields.
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
  CHECK_API_SCOPE(thread);
  TransitionNativeToVM transition(thread);
  HANDLESCOPE(thread);
  Instance& obj = Instance::Handle();
  obj ^= Api::UnwrapHandle(result);
  const Class& cls = Class::Handle(obj.clazz());
  // We expect the newly created "NativeFields" object to have
  // 2 dart instance fields (fld1, fld2) and a reference to the native fields.
  // Hence the size of an instance of "NativeFields" should be
  // (1 + 2) * kWordSize + size of object header.
  // We check to make sure the instance size computed by the VM matches
  // our expectations.
  intptr_t header_size = sizeof(UntaggedObject);
  EXPECT_EQ(
      Utils::RoundUp(((1 + 2) * kWordSize) + header_size, kObjectAlignment),
      cls.host_instance_size());
  EXPECT_EQ(kNumNativeFields, cls.num_native_fields());
}

TEST_CASE(DartAPI_InjectNativeFields4) {
  // clang-format off
  const char* kScriptChars =
                  "class NativeFields extends NativeFieldsWrapperClass2 {\n"
                  "  NativeFields(int i, int j) : fld1 = i, fld2 = j {}\n"
                  "  int fld1;\n"
                  "  final int fld;\n"
                  "  static int? fld3;\n"
                  "  static const int fld4 = 10;\n"
                  "}\n"
                  "@pragma('vm:entry-point', 'call')\n"
                  "NativeFields testMain() {\n"
                  "  NativeFields obj = new NativeFields(10, 20);\n"
                  "  return obj;\n"
                  "}\n";
  // clang-format on
  Dart_Handle result;
  // Load up a test script in the test library.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Invoke a function which returns an object of type NativeFields.
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);

  USE(result);
#if 0
  // TODO(12455) Need better validation.
  // We expect the test script to fail finalization with the error below:
  EXPECT(Dart_IsError(result));
  Dart_Handle expected_error = DartUtils::NewError(
      "'dart:test-lib': Error: line 1 pos 36: "
      "class 'NativeFields' is trying to extend a native fields class, "
      "but library '%s' has no native resolvers",
      TestCase::url());
  EXPECT_SUBSTRING(Dart_GetError(expected_error), Dart_GetError(result));
#endif
}

static constexpr int kTestNumNativeFields = 2;
static constexpr intptr_t kNativeField1Value = 30;
static constexpr intptr_t kNativeField2Value = 40;

void TestNativeFieldsAccess_init(Dart_NativeArguments args) {
  Dart_Handle receiver = Dart_GetNativeArgument(args, 0);
  Dart_SetNativeInstanceField(receiver, 0, kNativeField1Value);
  Dart_SetNativeInstanceField(receiver, 1, kNativeField2Value);
}

void TestNativeFieldsAccess_access(Dart_NativeArguments args) {
  intptr_t field_values[kTestNumNativeFields];
  Dart_Handle result = Dart_GetNativeFieldsOfArgument(
      args, 0, kTestNumNativeFields, field_values);
  EXPECT_VALID(result);
  EXPECT_EQ(kNativeField1Value, field_values[0]);
  EXPECT_EQ(kNativeField2Value, field_values[1]);
  result = Dart_GetNativeFieldsOfArgument(args, 1, kTestNumNativeFields,
                                          field_values);
  EXPECT_VALID(result);
  EXPECT_EQ(0, field_values[0]);
  EXPECT_EQ(0, field_values[1]);
}

void TestNativeFieldsAccess_invalidAccess(Dart_NativeArguments args) {
  intptr_t field_values[kTestNumNativeFields];
  Dart_Handle result = Dart_GetNativeFieldsOfArgument(
      args, 0, kTestNumNativeFields, field_values);
  EXPECT_ERROR(result,
               "Dart_GetNativeFieldsOfArgument: "
               "expected 0 'num_fields' but was passed in 2");
}

static Dart_NativeFunction TestNativeFieldsAccess_lookup(Dart_Handle name,
                                                         int argument_count,
                                                         bool* auto_scope) {
  ASSERT(auto_scope != nullptr);
  *auto_scope = true;
  TransitionNativeToVM transition(Thread::Current());
  const Object& obj = Object::Handle(Api::UnwrapHandle(name));
  if (!obj.IsString()) {
    return nullptr;
  }
  const char* function_name = obj.ToCString();
  ASSERT(function_name != nullptr);
  if (strcmp(function_name, "TestNativeFieldsAccess_init") == 0) {
    return TestNativeFieldsAccess_init;
  } else if (strcmp(function_name, "TestNativeFieldsAccess_access") == 0) {
    return TestNativeFieldsAccess_access;
  } else if (strcmp(function_name, "TestNativeFieldsAccess_invalidAccess") ==
             0) {
    return TestNativeFieldsAccess_invalidAccess;
  } else {
    return nullptr;
  }
}

TEST_CASE(DartAPI_TestNativeFieldsAccess) {
  // clang-format off
  const char* kScriptChars = R"(
          import 'dart:nativewrappers';
          base class NativeFields extends NativeFieldWrapperClass2 {
            NativeFields(int i, int j) : fld1 = i, fld2 = j {}
            int fld1;
            final int fld2;
            static int? fld3;
            static const int fld4 = 10;
            @pragma('vm:external-name', 'TestNativeFieldsAccess_init')
            external int? initNativeFlds();
            @pragma('vm:external-name', 'TestNativeFieldsAccess_access')
            external int? accessNativeFlds(int? i);
          }
          class NoNativeFields {
            int neitherATypedDataNorNull = 0;
            @pragma('vm:external-name', 'TestNativeFieldsAccess_invalidAccess')
            external invalidAccess();
          }
          @pragma('vm:entry-point', 'call')
          NativeFields testMain() {
            NativeFields obj = new NativeFields(10, 20);
            obj.initNativeFlds();
            obj.accessNativeFlds(null);
            new NoNativeFields().invalidAccess();
            return obj;
          }
          )";
  // clang-format on

  // Load up a test script in the test library.
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, TestNativeFieldsAccess_lookup);

  // Invoke a function which returns an object of type NativeFields.
  Dart_Handle result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
}

TEST_CASE(DartAPI_InjectNativeFieldsSuperClass) {
  const char* kScriptChars =
      "import 'dart:nativewrappers';"
      "base class NativeFieldsSuper extends NativeFieldWrapperClass1 {\n"
      "  NativeFieldsSuper() : fld1 = 42 {}\n"
      "  int fld1;\n"
      "}\n"
      "base class NativeFields extends NativeFieldsSuper {\n"
      "  fld() => fld1;\n"
      "}\n"
      "@pragma('vm:entry-point', 'call')\n"
      "int testMain() {\n"
      "  NativeFields obj = new NativeFields();\n"
      "  return obj.fld();\n"
      "}\n";
  Dart_Handle result;
  // Load up a test script in the test library.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, native_field_lookup);

  // Invoke a function which returns an object of type NativeFields.
  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);

  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(42, value);
}

static void TestNativeFields(Dart_Handle retobj) {
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  // Access and set various instance fields of the object.
  Dart_Handle result = Dart_GetField(retobj, NewString("fld3"));
  EXPECT(Dart_IsError(result));
  result = Dart_GetField(retobj, NewString("fld0"));
  EXPECT_VALID(result);
  EXPECT(Dart_IsNull(result));
  result = Dart_GetField(retobj, NewString("fld1"));
  EXPECT_VALID(result);
  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(10, value);
  result = Dart_GetField(retobj, NewString("fld2"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(20, value);
  result = Dart_SetField(retobj, NewString("fld2"), Dart_NewInteger(40));
  EXPECT(Dart_IsError(result));
  result = Dart_SetField(retobj, NewString("fld1"), Dart_NewInteger(40));
  EXPECT_VALID(result);
  result = Dart_GetField(retobj, NewString("fld1"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(40, value);

  // Now access and set various native instance fields of the returned object.
  const int kNativeFld0 = 0;
  const int kNativeFld1 = 1;
  const int kNativeFld2 = 2;
  const int kNativeFld3 = 3;
  const int kNativeFld4 = 4;
  int field_count = 0;
  intptr_t field_value = 0;
  EXPECT_VALID(Dart_GetNativeInstanceFieldCount(retobj, &field_count));
  EXPECT_EQ(4, field_count);
  result = Dart_GetNativeInstanceField(retobj, kNativeFld4, &field_value);
  EXPECT(Dart_IsError(result));
  result = Dart_GetNativeInstanceField(retobj, kNativeFld0, &field_value);
  EXPECT_VALID(result);
  EXPECT_EQ(0, field_value);
  result = Dart_GetNativeInstanceField(retobj, kNativeFld1, &field_value);
  EXPECT_VALID(result);
  EXPECT_EQ(0, field_value);
  result = Dart_GetNativeInstanceField(retobj, kNativeFld2, &field_value);
  EXPECT_VALID(result);
  EXPECT_EQ(0, field_value);
  result = Dart_GetNativeInstanceField(retobj, kNativeFld3, &field_value);
  EXPECT_VALID(result);
  EXPECT_EQ(0, field_value);
  result = Dart_SetNativeInstanceField(retobj, kNativeFld4, 40);
  EXPECT(Dart_IsError(result));
  result = Dart_SetNativeInstanceField(retobj, kNativeFld0, 4);
  EXPECT_VALID(result);
  result = Dart_SetNativeInstanceField(retobj, kNativeFld1, 40);
  EXPECT_VALID(result);
  result = Dart_SetNativeInstanceField(retobj, kNativeFld2, 400);
  EXPECT_VALID(result);
  result = Dart_SetNativeInstanceField(retobj, kNativeFld3, 4000);
  EXPECT_VALID(result);
  result = Dart_GetNativeInstanceField(retobj, kNativeFld3, &field_value);
  EXPECT_VALID(result);
  EXPECT_EQ(4000, field_value);

  // Now re-access various dart instance fields of the returned object
  // to ensure that there was no corruption while setting native fields.
  result = Dart_GetField(retobj, NewString("fld1"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(40, value);
  result = Dart_GetField(retobj, NewString("fld2"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(20, value);
}

TEST_CASE(DartAPI_ImplicitNativeFieldAccess) {
  // clang-format off
  const char* kScriptChars =
                  "import 'dart:nativewrappers';"
                  "final class NativeFields extends "
                  "NativeFieldWrapperClass4 {\n"
                  "  NativeFields(int i, int j) : fld1 = i, fld2 = j {}\n"
                  "  int? fld0;\n"
                  "  int fld1;\n"
                  "  final int fld2;\n"
                  "  static int? fld3;\n"
                  "  static const int fld4 = 10;\n"
                  "}\n"
                  "@pragma('vm:entry-point', 'call')\n"
                  "NativeFields testMain() {\n"
                  "  NativeFields obj = new NativeFields(10, 20);\n"
                  "  return obj;\n"
                  "}\n";
  // clang-format on
  // Load up a test script in the test library.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, native_field_lookup);

  // Invoke a function which returns an object of type NativeFields.
  Dart_Handle retobj = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(retobj);

  // Now access and set various instance fields of the returned object.
  TestNativeFields(retobj);
}

TEST_CASE(DartAPI_NegativeNativeFieldAccess) {
  // clang-format off
  const char* kScriptChars =
                  "import 'dart:nativewrappers';\n"
                  "class NativeFields {\n"
                  "  NativeFields(int i, int j) : fld1 = i, fld2 = j {}\n"
                  "  int fld1;\n"
                  "  final int fld2;\n"
                  "  static int? fld3;\n"
                  "  static const int fld4 = 10;\n"
                  "}\n"
                  "@pragma('vm:entry-point', 'call')\n"
                  "NativeFields testMain1() {\n"
                  "  NativeFields obj = new NativeFields(10, 20);\n"
                  "  return obj;\n"
                  "}\n"
                  "@pragma('vm:entry-point', 'call')\n"
                  "Function testMain2() {\n"
                  "  return () {};\n"
                  "}\n";
  // clang-format on

  Dart_Handle result;
  CHECK_API_SCOPE(thread);

  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Invoke a function which returns an object of type NativeFields.
  Dart_Handle retobj = Dart_Invoke(lib, NewString("testMain1"), 0, nullptr);
  EXPECT_VALID(retobj);

  // Now access and set various native instance fields of the returned object.
  // All of these tests are expected to return failure as there are no
  // native fields in an instance of NativeFields.
  const int kNativeFld0 = 0;
  const int kNativeFld1 = 1;
  const int kNativeFld2 = 2;
  const int kNativeFld3 = 3;
  const int kNativeFld4 = 4;
  intptr_t value = 0;
  result = Dart_GetNativeInstanceField(retobj, kNativeFld4, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_GetNativeInstanceField(retobj, kNativeFld0, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_GetNativeInstanceField(retobj, kNativeFld1, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_GetNativeInstanceField(retobj, kNativeFld2, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_SetNativeInstanceField(retobj, kNativeFld4, 40);
  EXPECT(Dart_IsError(result));
  result = Dart_SetNativeInstanceField(retobj, kNativeFld3, 40);
  EXPECT(Dart_IsError(result));
  result = Dart_SetNativeInstanceField(retobj, kNativeFld0, 400);
  EXPECT(Dart_IsError(result));

  // Invoke a function which returns a closure object.
  retobj = Dart_Invoke(lib, NewString("testMain2"), 0, nullptr);
  EXPECT_VALID(retobj);

  result = Dart_GetNativeInstanceField(retobj, kNativeFld4, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_GetNativeInstanceField(retobj, kNativeFld0, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_GetNativeInstanceField(retobj, kNativeFld1, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_GetNativeInstanceField(retobj, kNativeFld2, &value);
  EXPECT(Dart_IsError(result));
  result = Dart_SetNativeInstanceField(retobj, kNativeFld4, 40);
  EXPECT(Dart_IsError(result));
  result = Dart_SetNativeInstanceField(retobj, kNativeFld3, 40);
  EXPECT(Dart_IsError(result));
  result = Dart_SetNativeInstanceField(retobj, kNativeFld0, 400);
  EXPECT(Dart_IsError(result));
}

TEST_CASE(DartAPI_GetStaticField_RunsInitializer) {
  const char* kScriptChars =
      "class TestClass  {\n"
      "  static const int fld1 = 7;\n"
      "  static int fld2 = 11;\n"
      "  static void testMain() {\n"
      "  }\n"
      "}\n";
  Dart_Handle result;
  // Create a test library and Load up a test script in it.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("TestClass"), 0, nullptr);
  EXPECT_VALID(type);

  // Invoke a function which returns an object.
  result = Dart_Invoke(type, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);

  // For uninitialized fields, the getter is returned
  result = Dart_GetField(type, NewString("fld1"));
  EXPECT_VALID(result);
  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(7, value);

  result = Dart_GetField(type, NewString("fld2"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(11, value);

  // Overwrite fld2
  result = Dart_SetField(type, NewString("fld2"), Dart_NewInteger(13));
  EXPECT_VALID(result);

  // We now get the new value for fld2, not the initializer
  result = Dart_GetField(type, NewString("fld2"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(13, value);
}

TEST_CASE(DartAPI_GetField_CheckIsolate) {
  const char* kScriptChars =
      "class TestClass  {\n"
      "  static int fld2 = 11;\n"
      "  static void testMain() {\n"
      "  }\n"
      "}\n";
  Dart_Handle result;
  int64_t value = 0;

  // Create a test library and Load up a test script in it.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("TestClass"), 0, nullptr);
  EXPECT_VALID(type);

  result = Dart_GetField(type, NewString("fld2"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(11, value);
}

TEST_CASE(DartAPI_SetField_CheckIsolate) {
  const char* kScriptChars =
      "class TestClass  {\n"
      "  static int fld2 = 11;\n"
      "  static void testMain() {\n"
      "  }\n"
      "}\n";
  Dart_Handle result;
  int64_t value = 0;

  // Create a test library and Load up a test script in it.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("TestClass"), 0, nullptr);
  EXPECT_VALID(type);

  result = Dart_SetField(type, NewString("fld2"), Dart_NewInteger(13));
  EXPECT_VALID(result);

  result = Dart_GetField(type, NewString("fld2"));
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(13, value);
}

TEST_CASE(DartAPI_New) {
  const char* kScriptChars =
      "class MyClass implements MyExtraHop {\n"
      "  MyClass() : foo = 7 {}\n"
      "  MyClass.named(value) : foo = value {}\n"
      "  MyClass._hidden(value) : foo = -value {}\n"
      "  MyClass.exception(value) : foo = value {\n"
      "    throw 'ConstructorDeath';\n"
      "  }\n"
      "  factory MyClass.multiply(value) {\n"
      "    return new MyClass.named(value * 100);\n"
      "  }\n"
      "  var foo;\n"
      "}\n"
      "\n"
      "abstract class MyExtraHop implements MyInterface {\n"
      "  factory MyExtraHop.hop(value) = MyClass.named;\n"
      "}\n"
      "\n"
      "abstract class MyInterface {\n"
      "  factory MyInterface.named(value) = MyExtraHop.hop;\n"
      "  factory MyInterface.multiply(value) = MyClass.multiply;\n"
      "  MyInterface.notfound(value);\n"
      "}\n"
      "\n"
      "class _MyClass {\n"
      "  _MyClass._() : foo = 7 {}\n"
      "  var foo;\n"
      "}\n"
      "\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("MyClass"), 0, nullptr);
  EXPECT_VALID(type);
  Dart_Handle intf =
      Dart_GetNonNullableType(lib, NewString("MyInterface"), 0, nullptr);
  EXPECT_VALID(intf);
  Dart_Handle private_type =
      Dart_GetNonNullableType(lib, NewString("_MyClass"), 0, nullptr);
  EXPECT_VALID(private_type);

  Dart_Handle args[1];
  args[0] = Dart_NewInteger(11);
  Dart_Handle bad_args[1];
  bad_args[0] = Dart_NewApiError("myerror");

  // Allocate and Invoke the unnamed constructor passing in Dart_Null.
  Dart_Handle result = Dart_New(type, Dart_Null(), 0, nullptr);
  EXPECT_VALID(result);
  bool instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
  EXPECT(instanceOf);
  int64_t int_value = 0;
  Dart_Handle foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(7, int_value);

  // Allocate without a constructor.
  Dart_Handle obj = Dart_Allocate(type);
  EXPECT_VALID(obj);
  instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(obj, type, &instanceOf));
  EXPECT(instanceOf);
  foo = Dart_GetField(obj, NewString("foo"));
  EXPECT(Dart_IsNull(foo));

  // Allocate and Invoke the unnamed constructor passing in an empty string.
  result = Dart_New(type, Dart_EmptyString(), 0, nullptr);
  EXPECT_VALID(result);
  instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
  EXPECT(instanceOf);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(7, int_value);

  // Allocate object and invoke the unnamed constructor with an empty string.
  obj = Dart_Allocate(type);
  EXPECT_VALID(obj);
  instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(obj, type, &instanceOf));
  EXPECT(instanceOf);
  // Use the empty string to invoke the unnamed constructor.
  result = Dart_InvokeConstructor(obj, Dart_EmptyString(), 0, nullptr);
  EXPECT_VALID(result);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(7, int_value);
  // use Dart_Null to invoke the unnamed constructor.
  result = Dart_InvokeConstructor(obj, Dart_Null(), 0, nullptr);
  EXPECT_VALID(result);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(7, int_value);

  // Invoke a named constructor.
  result = Dart_New(type, NewString("named"), 1, args);
  EXPECT_VALID(result);
  EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
  EXPECT(instanceOf);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(11, int_value);

  // Allocate object and invoke a named constructor.
  obj = Dart_Allocate(type);
  EXPECT_VALID(obj);
  instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(obj, type, &instanceOf));
  EXPECT(instanceOf);
  result = Dart_InvokeConstructor(obj, NewString("named"), 1, args);
  EXPECT_VALID(result);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(11, int_value);

  // Invoke a hidden named constructor.
  result = Dart_New(type, NewString("_hidden"), 1, args);
  EXPECT_VALID(result);
  EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
  EXPECT(instanceOf);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(-11, int_value);

  // Invoke a hidden named constructor on a hidden type.
  result = Dart_New(private_type, NewString("_"), 0, nullptr);
  EXPECT_VALID(result);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(7, int_value);

  // Allocate object and invoke a hidden named constructor.
  obj = Dart_Allocate(type);
  EXPECT_VALID(obj);
  instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(obj, type, &instanceOf));
  EXPECT(instanceOf);
  result = Dart_InvokeConstructor(obj, NewString("_hidden"), 1, args);
  EXPECT_VALID(result);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(-11, int_value);

  // Allocate object and Invoke a constructor which throws an exception.
  obj = Dart_Allocate(type);
  EXPECT_VALID(obj);
  instanceOf = false;
  EXPECT_VALID(Dart_ObjectIsType(obj, type, &instanceOf));
  EXPECT(instanceOf);
  result = Dart_InvokeConstructor(obj, NewString("exception"), 1, args);
  EXPECT_ERROR(result, "ConstructorDeath");

  // Invoke a factory constructor.
  result = Dart_New(type, NewString("multiply"), 1, args);
  EXPECT_VALID(result);
  EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
  EXPECT(instanceOf);
  int_value = 0;
  foo = Dart_GetField(result, NewString("foo"));
  EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
  EXPECT_EQ(1100, int_value);

  // Pass an error class object.  Error is passed through.
  result = Dart_New(Dart_NewApiError("myerror"), NewString("named"), 1, args);
  EXPECT_ERROR(result, "myerror");

  // Pass a bad class object.
  result = Dart_New(Dart_Null(), NewString("named"), 1, args);
  EXPECT_ERROR(result, "Dart_New expects argument 'type' to be non-null.");

  // Pass a negative arg count.
  result = Dart_New(type, NewString("named"), -1, args);
  EXPECT_ERROR(
      result,
      "Dart_New expects argument 'number_of_arguments' to be non-negative.");

  // Pass the wrong arg count.
  result = Dart_New(type, NewString("named"), 0, nullptr);
  EXPECT_ERROR(
      result,
      "Dart_New: wrong argument count for constructor 'MyClass.named': "
      "0 passed, 1 expected.");

  // Pass a bad argument.  Error is passed through.
  result = Dart_New(type, NewString("named"), 1, bad_args);
  EXPECT_ERROR(result, "myerror");

  // Pass a bad constructor name.
  result = Dart_New(type, Dart_NewInteger(55), 1, args);
  EXPECT_ERROR(
      result,
      "Dart_New expects argument 'constructor_name' to be of type String.");

  // Invoke a missing constructor.
  result = Dart_New(type, NewString("missing"), 1, args);
  EXPECT_ERROR(result,
               "Dart_New: could not find constructor 'MyClass.missing'.");

  // Invoke a constructor which throws an exception.
  result = Dart_New(type, NewString("exception"), 1, args);
  EXPECT_ERROR(result, "ConstructorDeath");

  // Invoke a constructor that is missing in the interface.
  result = Dart_New(intf, Dart_Null(), 0, nullptr);
  EXPECT_ERROR(result, "Dart_New: could not find constructor 'MyInterface.'.");

  // Invoke abstract constructor that is present in the interface.
  result = Dart_New(intf, NewString("notfound"), 1, args);
  EXPECT_VALID(result);
  EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
  EXPECT(!instanceOf);
}

// These two cases below currently fail because of issue
// https://github.com/dart-lang/sdk/issues/42939
TEST_CASE(DartAPI_New_Issue42939) {
  const char* kScriptChars =
      "class MyClass implements MyExtraHop {\n"
      "  MyClass() : foo = 7 {}\n"
      "  MyClass.named(value) : foo = value {}\n"
      "  MyClass._hidden(value) : foo = -value {}\n"
      "  MyClass.exception(value) : foo = value {\n"
      "    throw 'ConstructorDeath';\n"
      "  }\n"
      "  factory MyClass.multiply(value) {\n"
      "    return new MyClass.named(value * 100);\n"
      "  }\n"
      "  var foo;\n"
      "}\n"
      "\n"
      "abstract class MyExtraHop implements MyInterface {\n"
      "  factory MyExtraHop.hop(value) = MyClass.named;\n"
      "}\n"
      "\n"
      "abstract class MyInterface {\n"
      "  factory MyInterface.named(value) = MyExtraHop.hop;\n"
      "  factory MyInterface.multiply(value) = MyClass.multiply;\n"
      "  MyInterface.notfound(value);\n"
      "}\n"
      "\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("MyClass"), 0, nullptr);
  EXPECT_VALID(type);
  Dart_Handle intf =
      Dart_GetNonNullableType(lib, NewString("MyInterface"), 0, nullptr);
  EXPECT_VALID(intf);

  Dart_Handle args[1];
  args[0] = Dart_NewInteger(11);

  // Invoke two-hop redirecting factory constructor.
  bool instanceOf = false;
  Dart_Handle result = Dart_New(intf, NewString("named"), 1, args);
  EXPECT_VALID(result);
  if (!Dart_IsError(result)) {
    EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
    EXPECT(instanceOf);
    int64_t int_value = 0;
    Dart_Handle foo = Dart_GetField(result, NewString("foo"));
    EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
    EXPECT_EQ(11, int_value);
  }

  // Invoke one-hop redirecting factory constructor.
  result = Dart_New(intf, NewString("multiply"), 1, args);
  EXPECT_VALID(result);
  if (!Dart_IsError(result)) {
    EXPECT_VALID(Dart_ObjectIsType(result, type, &instanceOf));
    EXPECT(instanceOf);
    int64_t int_value = 0;
    Dart_Handle foo = Dart_GetField(result, NewString("foo"));
    EXPECT_VALID(Dart_IntegerToInt64(foo, &int_value));
    EXPECT_EQ(1100, int_value);
  }
}

TEST_CASE(DartAPI_New_Issue44205) {
  const char* kScriptChars =
      "class MyIntClass {\n"
      "  MyIntClass(this.value);\n"
      "  int value;\n"
      "}\n"
      "\n"
      "class MyClass<T> {\n"
      "  T value;\n"
      "  MyClass(this.value);\n"
      "  factory MyClass.foo(T x) => MyClass<T>(x);\n"
      "}\n"
      "\n"
      "Type getIntType() { return int; }\n"
      "\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle int_wrapper_type =
      Dart_GetNonNullableType(lib, NewString("MyIntClass"), 0, nullptr);
  EXPECT_VALID(int_wrapper_type);

  Dart_Handle args[1];
  args[0] = Dart_EmptyString();

  Dart_Handle result = Dart_New(int_wrapper_type, Dart_EmptyString(), 1, args);
  EXPECT_ERROR(result, "String' is not a subtype of type 'int' of 'value'");

  Dart_Handle int_type = Dart_Invoke(lib, NewString("getIntType"), 0, args);
  EXPECT_VALID(int_type);
  Dart_Handle type_args = Dart_NewList(1);
  EXPECT_VALID(type_args);
  EXPECT_VALID(Dart_ListSetAt(type_args, 0, int_type));
  Dart_Handle my_class_type =
      Dart_GetNonNullableType(lib, NewString("MyClass"), 1, &type_args);
  EXPECT_VALID(my_class_type);

  // Generic generative constructor
  args[0] = Dart_EmptyString();
  result = Dart_New(my_class_type, Dart_EmptyString(), 1, args);
  EXPECT_ERROR(result, "String' is not a subtype of type 'int' of 'value'");

  // Generic factory constructor
  result = Dart_New(my_class_type, NewString("foo"), 1, args);
  EXPECT_ERROR(result, "String' is not a subtype of type 'int' of 'x'");
}

TEST_CASE(DartAPI_InvokeConstructor_Issue44205) {
  const char* kScriptChars =
      "class MyIntClass {\n"
      "  MyIntClass(this.value);\n"
      "  int value;\n"
      "}\n"
      "\n"
      "class MyClass<T> {\n"
      "  T value;\n"
      "  MyClass(this.value);\n"
      "}\n"
      "\n"
      "Type getIntType() { return int; }\n"
      "\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle int_wrapper_type =
      Dart_GetNonNullableType(lib, NewString("MyIntClass"), 0, nullptr);
  EXPECT_VALID(int_wrapper_type);

  Dart_Handle args[1];
  args[0] = Dart_EmptyString();
  Dart_Handle result = Dart_Allocate(int_wrapper_type);
  EXPECT_VALID(result);

  result = Dart_InvokeConstructor(result, Dart_EmptyString(), 1, args);
  EXPECT_ERROR(result, "String' is not a subtype of type 'int' of 'value'");

  Dart_Handle int_type = Dart_Invoke(lib, NewString("getIntType"), 0, args);
  EXPECT_VALID(int_type);
  Dart_Handle type_args = Dart_NewList(1);
  EXPECT_VALID(type_args);
  EXPECT_VALID(Dart_ListSetAt(type_args, 0, int_type));
  Dart_Handle my_class_type =
      Dart_GetNonNullableType(lib, NewString("MyClass"), 1, &type_args);
  EXPECT_VALID(my_class_type);

  result = Dart_Allocate(my_class_type);
  EXPECT_VALID(result);
  result = Dart_InvokeConstructor(result, Dart_EmptyString(), 1, args);
  EXPECT_ERROR(result, "String' is not a subtype of type 'int' of 'value'");
}

TEST_CASE(DartAPI_InvokeClosure_Issue44205) {
  const char* kScriptChars =
      "class InvokeClosure {\n"
      "  InvokeClosure(int i, int j) : fld1 = i, fld2 = j {}\n"
      "  Function method1(int i) {\n"
      "    f(int j) => j + i + fld1 + fld2 + fld4; \n"
      "    return f;\n"
      "  }\n"
      "  int fld1;\n"
      "  final int fld2;\n"
      "  static const int fld4 = 10;\n"
      "}\n"
      "@pragma('vm:entry-point', 'call')\n"
      "Function testMain1() {\n"
      "  InvokeClosure obj = new InvokeClosure(10, 20);\n"
      "  return obj.method1(10);\n"
      "}\n";
  Dart_Handle result;
  CHECK_API_SCOPE(thread);

  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  // Invoke a function which returns a closure.
  Dart_Handle retobj = Dart_Invoke(lib, NewString("testMain1"), 0, nullptr);
  EXPECT_VALID(retobj);

  // Now invoke the closure and check the result.
  Dart_Handle dart_arguments[1];
  dart_arguments[0] = Dart_EmptyString();
  result = Dart_InvokeClosure(retobj, 1, dart_arguments);
  EXPECT_ERROR(result, "String' is not a subtype of type 'int' of 'j'");
}

TEST_CASE(DartAPI_NewListOfType) {
  const char* kScriptChars =
      "class ZXHandle {}\n"
      "class ChannelReadResult {\n"
      "  final List<ZXHandle?> handles;\n"
      "  ChannelReadResult(this.handles);\n"
      "}\n"
      "void expectListOfString(List<String> _) {}\n"
      "void expectListOfDynamic(List<dynamic> _) {}\n"
      "void expectListOfVoid(List<void> _) {}\n"
      "void expectListOfNever(List<Never> _) {}\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle zxhandle_type =
      Dart_GetNullableType(lib, NewString("ZXHandle"), 0, nullptr);
  EXPECT_VALID(zxhandle_type);

  Dart_Handle zxhandle = Dart_New(zxhandle_type, Dart_Null(), 0, nullptr);
  EXPECT_VALID(zxhandle);

  Dart_Handle zxhandle_list = Dart_NewListOfType(zxhandle_type, 1);
  EXPECT_VALID(zxhandle_list);

  EXPECT_VALID(Dart_ListSetAt(zxhandle_list, 0, zxhandle));

  Dart_Handle readresult_type =
      Dart_GetNonNullableType(lib, NewString("ChannelReadResult"), 0, nullptr);
  EXPECT_VALID(zxhandle_type);

  const int kNumArgs = 1;
  Dart_Handle args[kNumArgs];
  args[0] = zxhandle_list;
  EXPECT_VALID(Dart_New(readresult_type, Dart_Null(), kNumArgs, args));

  EXPECT_ERROR(
      Dart_NewListOfType(Dart_Null(), 1),
      "Dart_NewListOfType expects argument 'element_type' to be non-null.");
  EXPECT_ERROR(
      Dart_NewListOfType(Dart_True(), 1),
      "Dart_NewListOfType expects argument 'element_type' to be of type Type.");

  Dart_Handle dart_core = Dart_LookupLibrary(NewString("dart:core"));
  EXPECT_VALID(dart_core);

  Dart_Handle string_type =
      Dart_GetNonNullableType(dart_core, NewString("String"), 0, nullptr);
  EXPECT_VALID(string_type);
  Dart_Handle string_list = Dart_NewListOfType(string_type, 0);
  EXPECT_VALID(string_list);
  args[0] = string_list;
  EXPECT_VALID(
      Dart_Invoke(lib, NewString("expectListOfString"), kNumArgs, args));

  Dart_Handle dynamic_type = Dart_TypeDynamic();
  EXPECT_VALID(dynamic_type);
  Dart_Handle dynamic_list = Dart_NewListOfType(dynamic_type, 0);
  EXPECT_VALID(dynamic_list);
  args[0] = dynamic_list;
  EXPECT_VALID(
      Dart_Invoke(lib, NewString("expectListOfDynamic"), kNumArgs, args));

  Dart_Handle void_type = Dart_TypeVoid();
  EXPECT_VALID(void_type);
  Dart_Handle void_list = Dart_NewListOfType(void_type, 0);
  EXPECT_VALID(void_list);
  args[0] = void_list;
  EXPECT_VALID(Dart_Invoke(lib, NewString("expectListOfVoid"), kNumArgs, args));

  Dart_Handle never_type = Dart_TypeNever();
  EXPECT_VALID(never_type);
  Dart_Handle never_list = Dart_NewListOfType(never_type, 0);
  EXPECT_VALID(never_list);
  args[0] = never_list;
  EXPECT_VALID(
      Dart_Invoke(lib, NewString("expectListOfNever"), kNumArgs, args));
}

TEST_CASE(DartAPI_NewListOfTypeFilled) {
  const char* kScriptChars =
      "class ZXHandle {}\n"
      "class ChannelReadResult {\n"
      "  final List<ZXHandle> handles;\n"
      "  ChannelReadResult(this.handles);\n"
      "}\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  Dart_Handle zxhandle_type =
      Dart_GetNonNullableType(lib, NewString("ZXHandle"), 0, nullptr);
  EXPECT_VALID(zxhandle_type);

  Dart_Handle nullable_zxhandle_type =
      Dart_GetNullableType(lib, NewString("ZXHandle"), 0, nullptr);
  EXPECT_VALID(nullable_zxhandle_type);

  Dart_Handle integer = Dart_NewInteger(42);
  EXPECT_VALID(integer);

  Dart_Handle zxhandle = Dart_New(zxhandle_type, Dart_Null(), 0, nullptr);
  EXPECT_VALID(zxhandle);

  Dart_Handle zxhandle_list =
      Dart_NewListOfTypeFilled(zxhandle_type, zxhandle, 1);
  EXPECT_VALID(zxhandle_list);

  Dart_Handle result = Dart_ListGetAt(zxhandle_list, 0);
  EXPECT_VALID(result);

  EXPECT(Dart_IdentityEquals(result, zxhandle));

  Dart_Handle readresult_type =
      Dart_GetNonNullableType(lib, NewString("ChannelReadResult"), 0, nullptr);
  EXPECT_VALID(zxhandle_type);

  const int kNumArgs = 1;
  Dart_Handle args[kNumArgs];
  args[0] = zxhandle_list;
  EXPECT_VALID(Dart_New(readresult_type, Dart_Null(), kNumArgs, args));

  EXPECT_ERROR(Dart_NewListOfTypeFilled(Dart_Null(), Dart_Null(), 1),
               "Dart_NewListOfTypeFilled expects argument 'element_type' to be "
               "non-null.");
  EXPECT_ERROR(Dart_NewListOfTypeFilled(Dart_True(), Dart_Null(), 1),
               "Dart_NewListOfTypeFilled expects argument 'element_type' to be "
               "of type Type.");
  EXPECT_ERROR(
      Dart_NewListOfTypeFilled(zxhandle_type, Dart_Null(), 1),
      "Dart_NewListOfTypeFilled expects argument 'fill_object' to be non-null"
      " for a non-nullable 'element_type'");
  EXPECT_ERROR(
      Dart_NewListOfTypeFilled(zxhandle_type, integer, 1),
      "Dart_NewListOfTypeFilled expects argument 'fill_object' to have the same"
      " type as 'element_type'.");

  EXPECT_VALID(
      Dart_NewListOfTypeFilled(nullable_zxhandle_type, Dart_Null(), 1));

  // Null is always valid as the fill argument if we're creating an empty list.
  EXPECT_VALID(Dart_NewListOfTypeFilled(zxhandle_type, Dart_Null(), 0));

  // Test creation of a non nullable list of strings.
  Dart_Handle corelib = Dart_LookupLibrary(NewString("dart:core"));
  EXPECT_VALID(corelib);
  Dart_Handle string_type =
      Dart_GetNonNullableType(corelib, NewString("String"), 0, nullptr);
  EXPECT_VALID(Dart_NewListOfTypeFilled(string_type, Dart_EmptyString(), 2));
}

static Dart_Handle PrivateLibName(Dart_Handle lib, const char* str) {
  EXPECT(Dart_IsLibrary(lib));
  Thread* thread = Thread::Current();
  TransitionNativeToVM transition(thread);
  const Library& library_obj = Api::UnwrapLibraryHandle(thread->zone(), lib);
  const String& name = String::Handle(String::New(str));
  return Api::NewHandle(thread, library_obj.PrivateName(name));
}

TEST_CASE(DartAPI_Invoke) {
  const char* kScriptChars =
      "class BaseMethods {\n"
      "  inheritedMethod(arg) => 'inherited $arg';\n"
      "  static nonInheritedMethod(arg) => 'noninherited $arg';\n"
      "}\n"
      "\n"
      "class Methods extends BaseMethods {\n"
      "  instanceMethod(arg) => 'instance $arg';\n"
      "  _instanceMethod(arg) => 'hidden instance $arg';\n"
      "  static staticMethod(arg) => 'static $arg';\n"
      "  static _staticMethod(arg) => 'hidden static $arg';\n"
      "}\n"
      "\n"
      "topMethod(arg) => 'top $arg';\n"
      "_topMethod(arg) => 'hidden top $arg';\n"
      "\n"
      "Methods test() {\n"
      "  return new Methods();\n"
      "}\n";

  // Shared setup.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("Methods"), 0, nullptr);
  EXPECT_VALID(type);
  Dart_Handle instance = Dart_Invoke(lib, NewString("test"), 0, nullptr);
  EXPECT_VALID(instance);
  Dart_Handle args[1];
  args[0] = NewString("!!!");
  Dart_Handle bad_args[2];
  bad_args[0] = NewString("bad1");
  bad_args[1] = NewString("bad2");
  Dart_Handle result;
  Dart_Handle name;
  const char* str;

  // Instance method.
  name = NewString("instanceMethod");
  EXPECT(Dart_IsError(Dart_Invoke(lib, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(type, name, 1, args)));
  result = Dart_Invoke(instance, name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("instance !!!", str);

  // Instance method, wrong arg count.
  EXPECT_ERROR(Dart_Invoke(instance, name, 2, bad_args),
               "Class 'Methods' has no instance method 'instanceMethod'"
               " with matching arguments");

  name = PrivateLibName(lib, "_instanceMethod");
  EXPECT(Dart_IsError(Dart_Invoke(lib, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(type, name, 1, args)));
  result = Dart_Invoke(instance, name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("hidden instance !!!", str);

  // Inherited method.
  name = NewString("inheritedMethod");
  EXPECT(Dart_IsError(Dart_Invoke(lib, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(type, name, 1, args)));
  result = Dart_Invoke(instance, name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("inherited !!!", str);

  // Static method.
  name = NewString("staticMethod");
  EXPECT(Dart_IsError(Dart_Invoke(lib, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(instance, name, 1, args)));
  result = Dart_Invoke(type, name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("static !!!", str);

  // Static method, wrong arg count.
  EXPECT_ERROR(Dart_Invoke(type, name, 2, bad_args),
               "NoSuchMethodError: No static method 'staticMethod' with "
               "matching arguments");

  // Hidden static method.
  name = NewString("_staticMethod");
  EXPECT(Dart_IsError(Dart_Invoke(lib, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(instance, name, 1, args)));
  result = Dart_Invoke(type, name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("hidden static !!!", str);

  // Static non-inherited method.  Not found at any level.
  name = NewString("non_inheritedMethod");
  EXPECT(Dart_IsError(Dart_Invoke(lib, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(instance, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(type, name, 1, args)));

  // Top-Level method.
  name = NewString("topMethod");
  EXPECT(Dart_IsError(Dart_Invoke(type, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(instance, name, 1, args)));
  result = Dart_Invoke(lib, name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("top !!!", str);

  // Top-level method, wrong arg count.
  EXPECT_ERROR(Dart_Invoke(lib, name, 2, bad_args),
               "NoSuchMethodError: No top-level method 'topMethod' with "
               "matching arguments");

  // Hidden top-level method.
  name = NewString("_topMethod");
  EXPECT(Dart_IsError(Dart_Invoke(type, name, 1, args)));
  EXPECT(Dart_IsError(Dart_Invoke(instance, name, 1, args)));
  result = Dart_Invoke(lib, name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("hidden top !!!", str);
}

TEST_CASE(DartAPI_Invoke_PrivateStatic) {
  const char* kScriptChars =
      "class Methods {\n"
      "  static _staticMethod(arg) => 'hidden static $arg';\n"
      "}\n"
      "\n";

  // Shared setup.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("Methods"), 0, nullptr);
  Dart_Handle result;
  EXPECT_VALID(type);
  Dart_Handle name = NewString("_staticMethod");
  EXPECT_VALID(name);

  Dart_Handle args[1];
  args[0] = NewString("!!!");
  result = Dart_Invoke(type, name, 1, args);
  EXPECT_VALID(result);

  const char* str = nullptr;
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("hidden static !!!", str);
}

TEST_CASE(DartAPI_MissingEntryPoints) {
  const char* kScriptChars = R"(
class C {
  final cx = 1;
  int cy = 2;
  @pragma('vm:entry-point', 'get')
  int cz = 3;
  @pragma('vm:entry-point', 'set')
  int cw = 4;

  void c1() {}

  @pragma('vm:entry-point', 'call')
  void c2() {}

  @pragma('vm:entry-point', 'get')
  void c3() {}
}

@pragma('vm:entry-point')
class D {
  static final dx = 1;
  static int dy = 2;
  @pragma('vm:entry-point', 'get')
  static int dz = 3;
  @pragma('vm:entry-point', 'set')
  static int dw = 4;

  static void d1() {}

  @pragma('vm:entry-point', 'call')
  static void d2() {}

  @pragma('vm:entry-point', 'get')
  static void d3() {
    print('Okay to closurize.');
  }
}

final x = 1;
int y = 2;
@pragma('vm:entry-point', 'get')
int z = 3;
@pragma('vm:entry-point', 'set')
int w = 4;

void test1() {}

@pragma('vm:entry-point', 'call')
void test2() {}

@pragma('vm:entry-point', 'get')
void test3() {}

@pragma('vm:entry-point', 'call')
C newC() => C();
  )";

  // Shared setup.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, true);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle instance = Dart_Invoke(lib, NewString("newC"), 0, nullptr);
  EXPECT_VALID(instance);
  Dart_Handle d_class = Dart_GetClass(lib, NewString("D"));
  EXPECT_VALID(d_class);
  Dart_Handle value = Dart_NewInteger(0);
  Dart_Handle name;

  // Top level method, not annotated for calling or closurization.
  name = NewString("test1");
  EXPECT_ERROR(Dart_Invoke(lib, name, 0, nullptr), "entry_point_pragma.md");
  EXPECT_ERROR(Dart_GetField(lib, name), "entry_point_pragma.md");

  // Top level method annotated for calling, not closurization.
  name = NewString("test2");
  EXPECT_VALID(Dart_Invoke(lib, name, 0, nullptr));
  EXPECT_ERROR(Dart_GetField(lib, name), "entry_point_pragma.md");

  // Top level method annotated for closurization, not calling.
  name = NewString("test3");
  EXPECT_ERROR(Dart_Invoke(lib, name, 0, nullptr), "entry_point_pragma.md");
  EXPECT_VALID(Dart_GetField(lib, name));

  // Final top level field, not annotated for getting.
  name = NewString("x");
  EXPECT_ERROR(Dart_GetField(lib, name), "entry_point_pragma.md");

  // Top level field, not annotated for getting or setting.
  name = NewString("y");
  EXPECT_ERROR(Dart_GetField(lib, name), "entry_point_pragma.md");
  EXPECT_ERROR(Dart_SetField(lib, name, value), "entry_point_pragma.md");

  // Top level field annotated for getting, not setting.
  name = NewString("z");
  EXPECT_VALID(Dart_GetField(lib, name));
  EXPECT_ERROR(Dart_SetField(lib, name, value), "entry_point_pragma.md");

  // Top level field annotated for setting, not getting.
  name = NewString("w");
  EXPECT_ERROR(Dart_GetField(lib, name), "entry_point_pragma.md");
  EXPECT_VALID(Dart_SetField(lib, name, value));

  // Instance method, not annotated for calling or closurization.
  name = NewString("c1");
  EXPECT_ERROR(Dart_Invoke(instance, name, 0, nullptr),
               "entry_point_pragma.md");
  EXPECT_ERROR(Dart_GetField(instance, name), "entry_point_pragma.md");

  // Instance method annotated for calling, not closurization.
  name = NewString("c2");
  EXPECT_VALID(Dart_Invoke(instance, name, 0, nullptr));
  EXPECT_ERROR(Dart_GetField(instance, name), "entry_point_pragma.md");

  // Instance method annotated for closurization, not calling.
  name = NewString("c3");
  EXPECT_ERROR(Dart_Invoke(instance, name, 0, nullptr),
               "entry_point_pragma.md");
  EXPECT_VALID(Dart_GetField(instance, name));

  // Final instance field, not annotated for getting.
  name = NewString("cx");
  EXPECT_ERROR(Dart_GetField(instance, name), "entry_point_pragma.md");

  // Instance field, not annotated for getting or setting.
  name = NewString("cy");
  EXPECT_ERROR(Dart_GetField(instance, name), "entry_point_pragma.md");
  EXPECT_ERROR(Dart_SetField(instance, name, value), "entry_point_pragma.md");

  // Instance field annotated for getting, not setting.
  name = NewString("cz");
  EXPECT_VALID(Dart_GetField(instance, name));
  EXPECT_ERROR(Dart_SetField(instance, name, value), "entry_point_pragma.md");

  // Instance field annotated for setting, not getting.
  name = NewString("cw");
  EXPECT_ERROR(Dart_GetField(instance, name), "entry_point_pragma.md");
  EXPECT_VALID(Dart_SetField(instance, name, value));

  // Class, not annotated for access.
  name = NewString("C");
  EXPECT_ERROR(Dart_GetClass(lib, name), "entry_point_pragma.md");

  // Static method, not annotated for calling or closurization.
  name = NewString("d1");
  EXPECT_ERROR(Dart_Invoke(d_class, name, 0, nullptr), "entry_point_pragma.md");
  EXPECT_ERROR(Dart_GetField(d_class, name), "entry_point_pragma.md");

  // Instance method annotated for calling, not closurization.
  name = NewString("d2");
  EXPECT_VALID(Dart_Invoke(d_class, name, 0, nullptr));
  EXPECT_ERROR(Dart_GetField(d_class, name), "entry_point_pragma.md");

  // Instance method annotated for closurization, not calling.
  name = NewString("d3");
  EXPECT_ERROR(Dart_Invoke(d_class, name, 0, nullptr), "entry_point_pragma.md");
  EXPECT_VALID(Dart_GetField(d_class, name));

  // Final static field, getter.
  name = NewString("dx");
  EXPECT_ERROR(Dart_GetField(d_class, name), "entry_point_pragma.md");

  // Static field, not annotated for getting or setting.
  name = NewString("dy");
  value = Dart_NewInteger(0);
  EXPECT_ERROR(Dart_GetField(d_class, name), "entry_point_pragma.md");
  EXPECT_ERROR(Dart_SetField(d_class, name, value), "entry_point_pragma.md");

  // Static field annotated for getting, not setting.
  name = NewString("dz");
  EXPECT_VALID(Dart_GetField(d_class, name));
  EXPECT_ERROR(Dart_SetField(d_class, name, value), "entry_point_pragma.md");

  // Static field annotated for setting, not getting.
  name = NewString("dw");
  EXPECT_ERROR(Dart_GetField(d_class, name), "entry_point_pragma.md");
  EXPECT_VALID(Dart_SetField(d_class, name, value));
}

TEST_CASE(DartAPI_Invoke_FunnyArgs) {
  const char* kScriptChars = "test(arg) => 'hello $arg';\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle func_name = NewString("test");
  Dart_Handle args[1];
  const char* str;

  // Make sure that valid args yield valid results.
  args[0] = NewString("!!!");
  Dart_Handle result = Dart_Invoke(lib, func_name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("hello !!!", str);

  // Make sure that null is legal.
  args[0] = Dart_Null();
  result = Dart_Invoke(lib, func_name, 1, args);
  EXPECT_VALID(result);
  result = Dart_StringToCString(result, &str);
  EXPECT_STREQ("hello null", str);

  // Pass an error handle as the target.  The error is propagated.
  result = Dart_Invoke(Api::NewError("myerror"), func_name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("myerror", Dart_GetError(result));

  // Pass an error handle as the function name.  The error is propagated.
  result = Dart_Invoke(lib, Api::NewError("myerror"), 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("myerror", Dart_GetError(result));

  // Pass a non-instance handle as a parameter..
  args[0] = lib;
  result = Dart_Invoke(lib, func_name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("Dart_Invoke expects arguments[0] to be an Instance handle.",
               Dart_GetError(result));

  // Pass an error handle as a parameter.  The error is propagated.
  args[0] = Api::NewError("myerror");
  result = Dart_Invoke(lib, func_name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("myerror", Dart_GetError(result));
}

TEST_CASE(DartAPI_Invoke_BadArgs) {
  const char* kScriptChars =
      "class BaseMethods {\n"
      "  inheritedMethod(int arg) => 'inherited $arg';\n"
      "  static nonInheritedMethod(int arg) => 'noninherited $arg';\n"
      "}\n"
      "\n"
      "class Methods extends BaseMethods {\n"
      "  instanceMethod(int arg) => 'instance $arg';\n"
      "  _instanceMethod(int arg) => 'hidden instance $arg';\n"
      "  static staticMethod(int arg) => 'static $arg';\n"
      "  static _staticMethod(int arg) => 'hidden static $arg';\n"
      "}\n"
      "\n"
      "topMethod(int arg) => 'top $arg';\n"
      "_topMethod(int arg) => 'hidden top $arg';\n"
      "\n"
      "Methods test() {\n"
      "  return new Methods();\n"
      "}\n";

#if defined(PRODUCT)
  const char* error_msg =
      "type '_OneByteString' is not a subtype of type 'int' of 'arg'";
#else
  const char* error_msg =
      "type 'String' is not a subtype of type 'int' of 'arg'";
#endif  // defined(PRODUCT)

  // Shared setup.
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("Methods"), 0, nullptr);
  EXPECT_VALID(type);
  Dart_Handle instance = Dart_Invoke(lib, NewString("test"), 0, nullptr);
  EXPECT_VALID(instance);
  Dart_Handle args[1];
  args[0] = NewString("!!!");
  Dart_Handle result;
  Dart_Handle name;

  // Instance method.
  name = NewString("instanceMethod");
  result = Dart_Invoke(instance, name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING(error_msg, Dart_GetError(result));

  name = PrivateLibName(lib, "_instanceMethod");
  result = Dart_Invoke(instance, name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING(error_msg, Dart_GetError(result));

  // Inherited method.
  name = NewString("inheritedMethod");
  result = Dart_Invoke(instance, name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING(error_msg, Dart_GetError(result));

  // Static method.
  name = NewString("staticMethod");
  result = Dart_Invoke(type, name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING(error_msg, Dart_GetError(result));

  // Hidden static method.
  name = NewString("_staticMethod");
  result = Dart_Invoke(type, name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING(error_msg, Dart_GetError(result));

  // Top-Level method.
  name = NewString("topMethod");
  result = Dart_Invoke(lib, name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING(error_msg, Dart_GetError(result));

  // Hidden top-level method.
  name = NewString("_topMethod");
  result = Dart_Invoke(lib, name, 1, args);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING(error_msg, Dart_GetError(result));
}

TEST_CASE(DartAPI_Invoke_Null) {
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle result =
      Dart_Invoke(Dart_Null(), NewString("toString"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsString(result));

  const char* value = "";
  EXPECT_VALID(Dart_StringToCString(result, &value));
  EXPECT_STREQ("null", value);

  Dart_Handle function_name = NewString("NoNoNo");
  result = Dart_Invoke(Dart_Null(), function_name, 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));

  result = Dart_GetField(Dart_Null(), NewString("toString"));
  EXPECT_VALID(result);
  EXPECT(Dart_IsClosure(result));

  result =
      Dart_SetField(Dart_Null(), NewString("nullHasNoSetters"), Dart_Null());
  // Not that Dart_SetField expects a non-null receiver.
  EXPECT_ERROR(
      result,
      "NoSuchMethodError: The setter 'nullHasNoSetters=' was called on null");
}

TEST_CASE(DartAPI_InvokeNoSuchMethod) {
  const char* kScriptChars =
      "class Expect {\n"
      "  static equals(a, b) {\n"
      "    if (a != b) {\n"
      "      throw 'not equal. expected: $a, got: $b';\n"
      "    }\n"
      "  }\n"
      "}\n"
      "class TestClass {\n"
      "  static int fld1 = 0;\n"
      "  void noSuchMethod(Invocation invocation) {\n"
      // This relies on the Symbol.toString() method returning a String of the
      // form 'Symbol("name")'. This is to avoid having to import
      // dart:_internal just to get access to the name of the symbol.
      "    var name = invocation.memberName.toString();\n"
      "    name = name.split('\"')[1];\n"
      "    if (name == 'fld') {\n"
      "      Expect.equals(true, invocation.isGetter);\n"
      "      Expect.equals(false, invocation.isMethod);\n"
      "      Expect.equals(false, invocation.isSetter);\n"
      "    } else if (name == 'setfld') {\n"
      "      Expect.equals(true, invocation.isSetter);\n"
      "      Expect.equals(false, invocation.isMethod);\n"
      "      Expect.equals(false, invocation.isGetter);\n"
      "    } else if (name == 'method') {\n"
      "      Expect.equals(true, invocation.isMethod);\n"
      "      Expect.equals(false, invocation.isSetter);\n"
      "      Expect.equals(false, invocation.isGetter);\n"
      "    }\n"
      "    TestClass.fld1 += 1;\n"
      "  }\n"
      "  static TestClass testMain() {\n"
      "    return new TestClass();\n"
      "  }\n"
      "}\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle result;
  Dart_Handle instance;
  // Create a test library and Load up a test script in it.
  // The test library must have a dart: url so it can import dart:_internal.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("TestClass"), 0, nullptr);
  EXPECT_VALID(type);

  // Invoke a function which returns an object.
  instance = Dart_Invoke(type, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(instance);

  // Try to get a field that does not exist, should call noSuchMethod.
  result = Dart_GetField(instance, NewString("fld"));
  EXPECT_VALID(result);

  // Try to set a field that does not exist, should call noSuchMethod.
  result = Dart_SetField(instance, NewString("setfld"), Dart_NewInteger(13));
  EXPECT_VALID(result);

  // Try to invoke a method that does not exist, should call noSuchMethod.
  result = Dart_Invoke(instance, NewString("method"), 0, nullptr);
  EXPECT_VALID(result);

  result = Dart_GetField(type, NewString("fld1"));
  EXPECT_VALID(result);
  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(3, value);
}

TEST_CASE(DartAPI_InvokeClosure) {
  const char* kScriptChars =
      "class InvokeClosure {\n"
      "  InvokeClosure(int i, int j) : fld1 = i, fld2 = j {}\n"
      "  Function method1(int i) {\n"
      "    f(int j) => j + i + fld1 + fld2 + fld4; \n"
      "    return f;\n"
      "  }\n"
      "  static Function method2(int i) {\n"
      "    n(int j) { throw new Exception('I am an exception'); return 1; }\n"
      "    return n;\n"
      "  }\n"
      "  int fld1;\n"
      "  final int fld2;\n"
      "  static const int fld4 = 10;\n"
      "}\n"
      "Function testMain1() {\n"
      "  InvokeClosure obj = new InvokeClosure(10, 20);\n"
      "  return obj.method1(10);\n"
      "}\n"
      "Function testMain2() {\n"
      "  return InvokeClosure.method2(10);\n"
      "}\n";
  Dart_Handle result;
  CHECK_API_SCOPE(thread);

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Invoke a function which returns a closure.
  Dart_Handle retobj = Dart_Invoke(lib, NewString("testMain1"), 0, nullptr);
  EXPECT_VALID(retobj);

  EXPECT(Dart_IsClosure(retobj));
  EXPECT(!Dart_IsClosure(Dart_NewInteger(101)));

  // Now invoke the closure and check the result.
  Dart_Handle dart_arguments[1];
  dart_arguments[0] = Dart_NewInteger(1);
  result = Dart_InvokeClosure(retobj, 1, dart_arguments);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_EQ(51, value);

  // Invoke closure with wrong number of args, should result in exception.
  result = Dart_InvokeClosure(retobj, 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));

  // Invoke a function which returns a closure.
  retobj = Dart_Invoke(lib, NewString("testMain2"), 0, nullptr);
  EXPECT_VALID(retobj);

  EXPECT(Dart_IsClosure(retobj));
  EXPECT(!Dart_IsClosure(NewString("abcdef")));

  // Now invoke the closure and check the result (should be an exception).
  dart_arguments[0] = Dart_NewInteger(1);
  result = Dart_InvokeClosure(retobj, 1, dart_arguments);
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
}

void ExceptionNative(Dart_NativeArguments args) {
  Dart_EnterScope();
  Dart_ThrowException(NewString("Hello from ExceptionNative!"));
  UNREACHABLE();
}

static Dart_NativeFunction native_lookup(Dart_Handle name,
                                         int argument_count,
                                         bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return ExceptionNative;
}

TEST_CASE(DartAPI_ThrowException) {
  const char* kScriptChars =
      R"(
      @pragma('vm:external-name', 'ThrowException_native')
      @pragma('vm:entry-point', 'call')
      external int test();
    )";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle result;
  intptr_t size = thread->ZoneSizeInBytes();
  Dart_EnterScope();  // Start a Dart API scope for invoking API functions.

  // Load up a test script which extends the native wrapper class.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, native_lookup);

  // Throwing an exception here should result in an error.
  result = Dart_ThrowException(NewString("This doesn't work"));
  EXPECT_ERROR(result, "No Dart frames on stack, cannot throw exception");
  EXPECT(!Dart_ErrorHasException(result));

  // Invoke 'test' and check for an uncaught exception.
  result = Dart_Invoke(lib, NewString("test"), 0, nullptr);
  EXPECT_ERROR(result, "Hello from ExceptionNative!");
  EXPECT(Dart_ErrorHasException(result));

  Dart_ExitScope();  // Exit the Dart API scope.
  EXPECT_EQ(size, thread->ZoneSizeInBytes());
}

static intptr_t kNativeArgumentNativeField1Value = 30;
static intptr_t kNativeArgumentNativeField2Value = 40;
static void NativeArgumentCreate(Dart_NativeArguments args) {
  Dart_Handle lib = Dart_LookupLibrary(NewString(TestCase::url()));
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("MyObject"), 0, nullptr);
  EXPECT_VALID(type);

  // Allocate without a constructor.
  const int num_native_fields = 2;
  const intptr_t native_fields[] = {kNativeArgumentNativeField1Value,
                                    kNativeArgumentNativeField2Value};
  // Allocate and Setup native fields.
  Dart_Handle obj =
      Dart_AllocateWithNativeFields(type, num_native_fields, native_fields);
  EXPECT_VALID(obj);

  kNativeArgumentNativeField1Value *= 2;
  kNativeArgumentNativeField2Value *= 2;
  Dart_SetReturnValue(args, obj);
}

static void NativeArgumentAccess(Dart_NativeArguments args) {
  const int kNumNativeFields = 2;

  // Test different argument types with a valid descriptor set.
  {
    const char* cstr = nullptr;
    intptr_t native_fields1[kNumNativeFields];
    intptr_t native_fields2[kNumNativeFields];
    const Dart_NativeArgument_Descriptor arg_descriptors[9] = {
        {Dart_NativeArgument_kNativeFields, 0},
        {Dart_NativeArgument_kInt32, 1},
        {Dart_NativeArgument_kUint64, 2},
        {Dart_NativeArgument_kBool, 3},
        {Dart_NativeArgument_kDouble, 4},
        {Dart_NativeArgument_kString, 5},
        {Dart_NativeArgument_kString, 6},
        {Dart_NativeArgument_kNativeFields, 7},
        {Dart_NativeArgument_kInstance, 7},
    };
    Dart_NativeArgument_Value arg_values[9];
    arg_values[0].as_native_fields.num_fields = kNumNativeFields;
    arg_values[0].as_native_fields.values = native_fields1;
    arg_values[7].as_native_fields.num_fields = kNumNativeFields;
    arg_values[7].as_native_fields.values = native_fields2;
    Dart_Handle result =
        Dart_GetNativeArguments(args, 9, arg_descriptors, arg_values);
    EXPECT_VALID(result);

    EXPECT(arg_values[0].as_native_fields.values[0] == 30);
    EXPECT(arg_values[0].as_native_fields.values[1] == 40);

    EXPECT(arg_values[1].as_int32 == 77);

    // When wrapped-around, this value should not fit into int32, because this
    // unit test verifies that getting it as int32 produces error.
    EXPECT(arg_values[2].as_uint64 == 0x8000000000000000LL);

    EXPECT(arg_values[3].as_bool == true);

    EXPECT(arg_values[4].as_double == 3.14);

    EXPECT_VALID(arg_values[5].as_string.dart_str);
    EXPECT(Dart_IsString(arg_values[5].as_string.dart_str));
    EXPECT_VALID(Dart_StringToCString(arg_values[5].as_string.dart_str, &cstr));
    EXPECT_STREQ("abcdefg", cstr);
    EXPECT(arg_values[5].as_string.peer == nullptr);

    EXPECT_VALID(arg_values[6].as_string.dart_str);
    EXPECT(Dart_IsString(arg_values[6].as_string.dart_str));
    EXPECT_VALID(Dart_StringToCString(arg_values[6].as_string.dart_str, &cstr));
    EXPECT_STREQ("string", cstr);
    EXPECT(arg_values[6].as_string.peer == nullptr);

    EXPECT(arg_values[7].as_native_fields.values[0] == 60);
    EXPECT(arg_values[7].as_native_fields.values[1] == 80);

    EXPECT_VALID(arg_values[8].as_instance);
    EXPECT(Dart_IsInstance(arg_values[8].as_instance));
    int field_count = 0;
    EXPECT_VALID(Dart_GetNativeInstanceFieldCount(arg_values[8].as_instance,
                                                  &field_count));
    EXPECT(field_count == 2);
  }

  // Test with an invalid descriptor set (invalid type).
  {
    const Dart_NativeArgument_Descriptor arg_descriptors[8] = {
        {Dart_NativeArgument_kInt32, 1},
        {Dart_NativeArgument_kUint64, 2},
        {Dart_NativeArgument_kString, 3},
        {Dart_NativeArgument_kDouble, 4},
        {Dart_NativeArgument_kString, 5},
        {Dart_NativeArgument_kString, 6},
        {Dart_NativeArgument_kNativeFields, 0},
        {Dart_NativeArgument_kNativeFields, 7},
    };
    Dart_NativeArgument_Value arg_values[8];
    Dart_Handle result =
        Dart_GetNativeArguments(args, 8, arg_descriptors, arg_values);
    EXPECT(Dart_IsError(result));
  }

  // Test with an invalid range error.
  {
    const Dart_NativeArgument_Descriptor arg_descriptors[8] = {
        {Dart_NativeArgument_kInt32, 2},
        {Dart_NativeArgument_kUint64, 2},
        {Dart_NativeArgument_kBool, 3},
        {Dart_NativeArgument_kDouble, 4},
        {Dart_NativeArgument_kString, 5},
        {Dart_NativeArgument_kString, 6},
        {Dart_NativeArgument_kNativeFields, 0},
        {Dart_NativeArgument_kNativeFields, 7},
    };
    Dart_NativeArgument_Value arg_values[8];
    Dart_Handle result =
        Dart_GetNativeArguments(args, 8, arg_descriptors, arg_values);
    EXPECT(Dart_IsError(result));
  }

  Dart_SetIntegerReturnValue(args, 0);
}

static Dart_NativeFunction native_args_lookup(Dart_Handle name,
                                              int argument_count,
                                              bool* auto_scope_setup) {
  TransitionNativeToVM transition(Thread::Current());
  const Object& obj = Object::Handle(Api::UnwrapHandle(name));
  if (!obj.IsString()) {
    return nullptr;
  }
  ASSERT(auto_scope_setup != nullptr);
  *auto_scope_setup = true;
  const char* function_name = obj.ToCString();
  ASSERT(function_name != nullptr);
  if (strcmp(function_name, "NativeArgument_Create") == 0) {
    return NativeArgumentCreate;
  } else if (strcmp(function_name, "NativeArgument_Access") == 0) {
    return NativeArgumentAccess;
  }
  return nullptr;
}

TEST_CASE(DartAPI_GetNativeArguments) {
  const char* kScriptChars = R"(
import 'dart:nativewrappers';
base class MyObject extends NativeFieldWrapperClass2 {
  @pragma("vm:external-name", "NativeArgument_Create")
  external static MyObject createObject();
  @pragma("vm:external-name", "NativeArgument_Access")
  external int accessFields(int arg1,
                   int arg2,
                   bool arg3,
                   double arg4,
                   String arg5,
                   String arg6,
                   MyObject arg7);
}
int testMain(String extstr) {
  String str = 'abcdefg';
  MyObject obj1 = MyObject.createObject();
  MyObject obj2 = MyObject.createObject();
  return obj1.accessFields(77,
                           0x8000000000000000,
                           true,
                           3.14,
                           str,
                           extstr,
                           obj2);
})";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, native_args_lookup);

  const char* ascii_str = "string";
  intptr_t ascii_str_length = strlen(ascii_str);
  Dart_Handle str = Dart_NewStringFromUTF8(
      reinterpret_cast<const uint8_t*>(ascii_str), ascii_str_length);

  Dart_Handle args[1];
  args[0] = str;
  Dart_Handle result = Dart_Invoke(lib, NewString("testMain"), 1, args);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
}

static void NativeArgumentCounter(Dart_NativeArguments args) {
  Dart_EnterScope();
  int count = Dart_GetNativeArgumentCount(args);
  Dart_SetReturnValue(args, Dart_NewInteger(count));
  Dart_ExitScope();
}

static Dart_NativeFunction gnac_lookup(Dart_Handle name,
                                       int argument_count,
                                       bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = true;
  return NativeArgumentCounter;
}

TEST_CASE(DartAPI_GetNativeArgumentCount) {
  const char* kScriptChars = R"(
class MyObject {
  @pragma("vm:external-name", "Name_Does_Not_Matter")
  external int method1(int i, int j);
}
@pragma('vm:entry-point', 'call')
testMain() {
  MyObject obj = new MyObject();
  return obj.method1(77, 125);
})";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, gnac_lookup);

  Dart_Handle result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));

  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(3, value);
}

TEST_CASE(DartAPI_TypeToNullability) {
  const char* kScriptChars =
      "library testlib;\n"
      "class Class {\n"
      "  static var name = 'Class';\n"
      "}\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  const Dart_Handle name = NewString("Class");
  // Lookup the legacy type for Class.
  Dart_Handle type = Dart_GetType(lib, name, 0, nullptr);
  EXPECT_ERROR(type,
               "Cannot use legacy types with --sound-null-safety enabled. "
               "Use Dart_GetNullableType or Dart_GetNonNullableType instead.");

  Dart_Handle nonNullableType = Dart_GetNonNullableType(lib, name, 0, nullptr);
  EXPECT_VALID(nonNullableType);
  Dart_Handle nullableType = Dart_GetNullableType(lib, name, 0, nullptr);
  EXPECT_VALID(nullableType);

  // Nullable -> Non-Nullable
  EXPECT(Dart_IdentityEquals(
      nonNullableType,
      Dart_TypeToNonNullableType(Dart_GetNullableType(lib, name, 0, nullptr))));

  // Non-Nullable -> Nullable
  EXPECT(Dart_IdentityEquals(
      nullableType,
      Dart_TypeToNullableType(Dart_GetNonNullableType(lib, name, 0, nullptr))));
}

TEST_CASE(DartAPI_GetNullableType) {
  const char* kScriptChars =
      "library testlib;\n"
      "class Class {\n"
      "  static var name = 'Class';\n"
      "}\n"
      "\n"
      "class _Class {\n"
      "  static var name = '_Class';\n"
      "}\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Lookup a class.
  Dart_Handle type = Dart_GetNullableType(lib, NewString("Class"), 0, nullptr);
  EXPECT_VALID(type);
  bool result = false;
  EXPECT_VALID(Dart_IsNullableType(type, &result));
  EXPECT(result);
  Dart_Handle name = Dart_ToString(type);
  EXPECT_VALID(name);
  const char* name_cstr = "";
  EXPECT_VALID(Dart_StringToCString(name, &name_cstr));
  EXPECT_STREQ("Class?", name_cstr);

  name = Dart_GetField(type, NewString("name"));
  EXPECT_VALID(name);
  EXPECT_VALID(Dart_StringToCString(name, &name_cstr));
  EXPECT_STREQ("Class", name_cstr);

  // Lookup a private class.
  type = Dart_GetNullableType(lib, NewString("_Class"), 0, nullptr);
  EXPECT_VALID(type);
  result = false;
  EXPECT_VALID(Dart_IsNullableType(type, &result));

  name = Dart_GetField(type, NewString("name"));
  EXPECT_VALID(name);
  name_cstr = "";
  EXPECT_VALID(Dart_StringToCString(name, &name_cstr));
  EXPECT_STREQ("_Class", name_cstr);

  // Lookup a class that does not exist.
  type = Dart_GetNullableType(lib, NewString("DoesNotExist"), 0, nullptr);
  EXPECT(Dart_IsError(type));
  EXPECT_STREQ("Type 'DoesNotExist' not found in library 'testlib'.",
               Dart_GetError(type));

  // Lookup a class from an error library.  The error propagates.
  type = Dart_GetNullableType(Api::NewError("myerror"), NewString("Class"), 0,
                              nullptr);
  EXPECT(Dart_IsError(type));
  EXPECT_STREQ("myerror", Dart_GetError(type));

  // Lookup a type using an error class name.  The error propagates.
  type = Dart_GetNullableType(lib, Api::NewError("myerror"), 0, nullptr);
  EXPECT(Dart_IsError(type));
  EXPECT_STREQ("myerror", Dart_GetError(type));
}

TEST_CASE(DartAPI_GetNonNullableType) {
  const char* kScriptChars =
      "library testlib;\n"
      "class Class {\n"
      "  static var name = 'Class';\n"
      "}\n"
      "\n"
      "class _Class {\n"
      "  static var name = '_Class';\n"
      "}\n";

  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Lookup a class.
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("Class"), 0, nullptr);
  EXPECT_VALID(type);
  bool result = false;
  EXPECT_VALID(Dart_IsNonNullableType(type, &result));
  EXPECT(result);
  Dart_Handle name = Dart_ToString(type);
  EXPECT_VALID(name);
  const char* name_cstr = "";
  EXPECT_VALID(Dart_StringToCString(name, &name_cstr));
  EXPECT_STREQ("Class", name_cstr);

  name = Dart_GetField(type, NewString("name"));
  EXPECT_VALID(name);
  EXPECT_VALID(Dart_StringToCString(name, &name_cstr));
  EXPECT_STREQ("Class", name_cstr);

  // Lookup a private class.
  type = Dart_GetNonNullableType(lib, NewString("_Class"), 0, nullptr);
  EXPECT_VALID(type);
  result = false;
  EXPECT_VALID(Dart_IsNonNullableType(type, &result));
  EXPECT(result);

  name = Dart_GetField(type, NewString("name"));
  EXPECT_VALID(name);
  name_cstr = "";
  EXPECT_VALID(Dart_StringToCString(name, &name_cstr));
  EXPECT_STREQ("_Class", name_cstr);

  // Lookup a class that does not exist.
  type = Dart_GetNonNullableType(lib, NewString("DoesNotExist"), 0, nullptr);
  EXPECT(Dart_IsError(type));
  EXPECT_STREQ("Type 'DoesNotExist' not found in library 'testlib'.",
               Dart_GetError(type));

  // Lookup a class from an error library.  The error propagates.
  type = Dart_GetNonNullableType(Api::NewError("myerror"), NewString("Class"),
                                 0, nullptr);
  EXPECT(Dart_IsError(type));
  EXPECT_STREQ("myerror", Dart_GetError(type));

  // Lookup a type using an error class name.  The error propagates.
  type = Dart_GetNonNullableType(lib, Api::NewError("myerror"), 0, nullptr);
  EXPECT(Dart_IsError(type));
  EXPECT_STREQ("myerror", Dart_GetError(type));
}

TEST_CASE(DartAPI_InstanceOf) {
  const char* kScriptChars =
      "class OtherClass {\n"
      "  static returnNull() { return null; }\n"
      "}\n"
      "class InstanceOfTest {\n"
      "  InstanceOfTest() {}\n"
      "  static InstanceOfTest testMain() {\n"
      "    return new InstanceOfTest();\n"
      "  }\n"
      "}\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle result;
  // Create a test library and Load up a test script in it.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  // Fetch InstanceOfTest class.
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("InstanceOfTest"), 0, nullptr);
  EXPECT_VALID(type);

  // Invoke a function which returns an object of type InstanceOf..
  Dart_Handle instanceOfTestObj =
      Dart_Invoke(type, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(instanceOfTestObj);

  // Now check instanceOfTestObj reported as an instance of
  // InstanceOfTest class.
  bool is_instance = false;
  result = Dart_ObjectIsType(instanceOfTestObj, type, &is_instance);
  EXPECT_VALID(result);
  EXPECT(is_instance);

  // Fetch OtherClass and check if instanceOfTestObj is instance of it.
  Dart_Handle otherType =
      Dart_GetNonNullableType(lib, NewString("OtherClass"), 0, nullptr);
  EXPECT_VALID(otherType);

  result = Dart_ObjectIsType(instanceOfTestObj, otherType, &is_instance);
  EXPECT_VALID(result);
  EXPECT(!is_instance);

  // Check that primitives are not instances of InstanceOfTest class.
  result = Dart_ObjectIsType(NewString("a string"), otherType, &is_instance);
  EXPECT_VALID(result);
  EXPECT(!is_instance);

  result = Dart_ObjectIsType(Dart_NewInteger(42), otherType, &is_instance);
  EXPECT_VALID(result);
  EXPECT(!is_instance);

  result = Dart_ObjectIsType(Dart_NewBoolean(true), otherType, &is_instance);
  EXPECT_VALID(result);
  EXPECT(!is_instance);

  // Check that null is not an instance of InstanceOfTest class.
  Dart_Handle null =
      Dart_Invoke(otherType, NewString("returnNull"), 0, nullptr);
  EXPECT_VALID(null);

  result = Dart_ObjectIsType(null, otherType, &is_instance);
  EXPECT_VALID(result);
  EXPECT(!is_instance);

  // Check that error is returned if null is passed as a class argument.
  result = Dart_ObjectIsType(null, null, &is_instance);
  EXPECT(Dart_IsError(result));
}

TEST_CASE(DartAPI_RootLibrary) {
  const char* kScriptChars =
      "library testlib;"
      "main() {"
      "  return 12345;"
      "}";

  Dart_Handle root_lib = Dart_RootLibrary();
  EXPECT_VALID(root_lib);
  EXPECT(Dart_IsNull(root_lib));

  // Load a script.
  EXPECT_VALID(LoadScript(TestCase::url(), kScriptChars));

  root_lib = Dart_RootLibrary();
  Dart_Handle lib_uri = Dart_LibraryUrl(root_lib);
  EXPECT_VALID(lib_uri);
  EXPECT(!Dart_IsNull(lib_uri));
  const char* uri_cstr = "";
  EXPECT_VALID(Dart_StringToCString(lib_uri, &uri_cstr));
  EXPECT_STREQ(TestCase::url(), uri_cstr);

  Dart_Handle core_uri = Dart_NewStringFromCString("dart:core");
  Dart_Handle core_lib = Dart_LookupLibrary(core_uri);
  EXPECT_VALID(core_lib);
  EXPECT(Dart_IsLibrary(core_lib));

  Dart_Handle result = Dart_SetRootLibrary(core_uri);  // Not a library.
  EXPECT(Dart_IsError(result));
  root_lib = Dart_RootLibrary();
  lib_uri = Dart_LibraryUrl(root_lib);
  EXPECT_VALID(Dart_StringToCString(lib_uri, &uri_cstr));
  EXPECT_STREQ(TestCase::url(), uri_cstr);  // Root library didn't change.

  result = Dart_SetRootLibrary(core_lib);
  EXPECT_VALID(result);
  root_lib = Dart_RootLibrary();
  lib_uri = Dart_LibraryUrl(root_lib);
  EXPECT_VALID(Dart_StringToCString(lib_uri, &uri_cstr));
  EXPECT_STREQ("dart:core", uri_cstr);  // Root library did change.

  result = Dart_SetRootLibrary(Dart_Null());
  EXPECT_VALID(result);
  root_lib = Dart_RootLibrary();
  EXPECT(Dart_IsNull(root_lib));  // Root library did change.
}

TEST_CASE(DartAPI_RootLibraryMissingMain) {
  const char* kScriptChars =
      "notMain() {"
      "  return 12345;"
      "}";

  Dart_Handle result = LoadScript(TestCase::url(), kScriptChars);

  EXPECT_ERROR(result,
               "Invoked Dart programs must have a 'main' function defined:\n"
               "https://dart.dev/to/main-function");
}

TEST_CASE(DartAPI_LookupLibrary) {
  const char* kScriptChars =
      "import 'library1_dart';"
      "main() {}";
  const char* kLibrary1 = "file:///library1_dart";
  const char* kLibrary1Chars =
      "library library1;"
      "final x = 0;";

  Dart_Handle url;
  Dart_Handle result;

  // Create a test library and load up a test script in it.
  TestCase::AddTestLib("file:///library1_dart", kLibrary1Chars);
  // LoadTestScript resets the LibraryTagHandler, which we don't want when
  // using the VM compiler, so we only use it with the Dart frontend for this
  // test.
  result = TestCase::LoadTestScript(kScriptChars, nullptr, TestCase::url());
  EXPECT_VALID(result);

  url = NewString(kLibrary1);
  result = Dart_LookupLibrary(url);
  EXPECT_VALID(result);

  result = Dart_LookupLibrary(Dart_Null());
  EXPECT_ERROR(result,
               "Dart_LookupLibrary expects argument 'url' to be non-null.");

  result = Dart_LookupLibrary(Dart_True());
  EXPECT_ERROR(
      result,
      "Dart_LookupLibrary expects argument 'url' to be of type String.");

  result = Dart_LookupLibrary(Dart_NewApiError("incoming error"));
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("incoming error", Dart_GetError(result));

  url = NewString("noodles.dart");
  result = Dart_LookupLibrary(url);
  EXPECT_ERROR(result, "Dart_LookupLibrary: library 'noodles.dart' not found.");
}

TEST_CASE(DartAPI_LibraryUrl) {
  const char* kLibrary1Chars = "library library1_name;";
  Dart_Handle lib = TestCase::LoadTestLibrary("library1_url", kLibrary1Chars);
  Dart_Handle error = Dart_NewApiError("incoming error");
  EXPECT_VALID(lib);

  Dart_Handle result = Dart_LibraryUrl(Dart_Null());
  EXPECT_ERROR(result,
               "Dart_LibraryUrl expects argument 'library' to be non-null.");

  result = Dart_LibraryUrl(Dart_True());
  EXPECT_ERROR(
      result,
      "Dart_LibraryUrl expects argument 'library' to be of type Library.");

  result = Dart_LibraryUrl(error);
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("incoming error", Dart_GetError(result));

  result = Dart_LibraryUrl(lib);
  EXPECT_VALID(result);
  EXPECT(Dart_IsString(result));
  const char* cstr = nullptr;
  EXPECT_VALID(Dart_StringToCString(result, &cstr));
  EXPECT_SUBSTRING("library1_url", cstr);
}

static void MyNativeFunction1(Dart_NativeArguments args) {
  Dart_EnterScope();
  Dart_SetReturnValue(args, Dart_NewInteger(654321));
  Dart_ExitScope();
}

static void MyNativeFunction2(Dart_NativeArguments args) {
  Dart_EnterScope();
  Dart_SetReturnValue(args, Dart_NewInteger(123456));
  Dart_ExitScope();
}

static Dart_NativeFunction MyNativeResolver1(Dart_Handle name,
                                             int arg_count,
                                             bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = false;
  return &MyNativeFunction1;
}

static Dart_NativeFunction MyNativeResolver2(Dart_Handle name,
                                             int arg_count,
                                             bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = false;
  return &MyNativeFunction2;
}

TEST_CASE(DartAPI_SetNativeResolver) {
  const char* kScriptChars =
      R"(
      class Test {
        @pragma('vm:external-name', 'SomeNativeFunction')
        external static foo();

        @pragma('vm:external-name', 'SomeNativeFunction2')
        external static bar();

        @pragma('vm:external-name', 'SomeNativeFunction3')
        external static baz();
      }
  )";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle error = Dart_NewApiError("incoming error");
  Dart_Handle result;

  // Load a test script.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  EXPECT(Dart_IsLibrary(lib));
  Dart_Handle type =
      Dart_GetNonNullableType(lib, NewString("Test"), 0, nullptr);
  EXPECT_VALID(type);

  result = Dart_SetNativeResolver(Dart_Null(), &MyNativeResolver1, nullptr);
  EXPECT_ERROR(
      result,
      "Dart_SetNativeResolver expects argument 'library' to be non-null.");

  result = Dart_SetNativeResolver(Dart_True(), &MyNativeResolver1, nullptr);
  EXPECT_ERROR(result,
               "Dart_SetNativeResolver expects argument 'library' to be of "
               "type Library.");

  result = Dart_SetNativeResolver(error, &MyNativeResolver1, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_STREQ("incoming error", Dart_GetError(result));

  result = Dart_SetNativeResolver(lib, &MyNativeResolver1, nullptr);
  EXPECT_VALID(result);

  // Call a function and make sure native resolution works.
  result = Dart_Invoke(type, NewString("foo"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  int64_t value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(result, &value));
  EXPECT_EQ(654321, value);

  // A second call succeeds.
  result = Dart_SetNativeResolver(lib, &MyNativeResolver2, nullptr);
  EXPECT_VALID(result);

  // 'foo' has already been resolved so gets the old value.
  result = Dart_Invoke(type, NewString("foo"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(result, &value));
  EXPECT_EQ(654321, value);

  // 'bar' has not yet been resolved so gets the new value.
  result = Dart_Invoke(type, NewString("bar"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(result, &value));
  EXPECT_EQ(123456, value);

  // A nullptr resolver is okay, but resolution will fail.
  result = Dart_SetNativeResolver(lib, nullptr, nullptr);
  EXPECT_VALID(result);

  EXPECT_ERROR(Dart_Invoke(type, NewString("baz"), 0, nullptr),
               "native function 'SomeNativeFunction3' (0 arguments) "
               "cannot be found");
}

// Test that an imported name does not clash with the same name defined
// in the importing library.
TEST_CASE(DartAPI_ImportLibrary2) {
  const char* kScriptChars =
      "import 'library1_dart';\n"
      "var foo;\n"
      "main() { foo = 0; }\n";
  const char* kLibrary1Chars =
      "library library1_dart;\n"
      "import 'library2_dart';\n"
      "var foo;\n";
  const char* kLibrary2Chars =
      "library library2_dart;\n"
      "import 'library1_dart';\n"
      "var foo;\n";
  Dart_Handle result;
  Dart_Handle lib;

  // Create a test library and Load up a test script in it.
  Dart_SourceFile sourcefiles[] = {
      {RESOLVED_USER_TEST_URI, kScriptChars},
      {"file:///library1_dart", kLibrary1Chars},
      {"file:///library2_dart", kLibrary2Chars},
  };
  int sourcefiles_count = sizeof(sourcefiles) / sizeof(Dart_SourceFile);
  lib = TestCase::LoadTestScriptWithDFE(sourcefiles_count, sourcefiles, nullptr,
                                        true);
  EXPECT_VALID(lib);

  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

// Test that if the same name is imported from two libraries, it is
// an error if that name is referenced.
TEST_CASE(DartAPI_ImportLibrary3) {
  const char* kScriptChars =
      "import 'file:///library2_dart';\n"
      "import 'file:///library1_dart';\n"
      "var foo_top = 10;  // foo has dup def. So should be an error.\n"
      "main() { foo = 0; }\n";
  const char* kLibrary1Chars =
      "library library1_dart;\n"
      "var foo;";
  const char* kLibrary2Chars =
      "library library2_dart;\n"
      "var foo;";
  Dart_Handle result;
  Dart_Handle lib;

  // Create a test library and Load up a test script in it.
  Dart_SourceFile sourcefiles[] = {
      {RESOLVED_USER_TEST_URI, kScriptChars},
      {"file:///library2_dart", kLibrary2Chars},
      {"file:///library1_dart", kLibrary1Chars},
  };
  int sourcefiles_count = sizeof(sourcefiles) / sizeof(Dart_SourceFile);
  lib = TestCase::LoadTestScriptWithDFE(sourcefiles_count, sourcefiles, nullptr,
                                        true);
  EXPECT_ERROR(lib,
               "Compilation failed /test-lib:4:10:"
               " Error: Setter not found: 'foo'");
  return;

  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT(Dart_IsError(result));
  EXPECT_SUBSTRING("NoSuchMethodError", Dart_GetError(result));
}

// Test that if the same name is imported from two libraries, it is
// not an error if that name is not used.
TEST_CASE(DartAPI_ImportLibrary4) {
  const char* kScriptChars =
      "import 'library2_dart';\n"
      "import 'library1_dart';\n"
      "main() {  }\n";
  const char* kLibrary1Chars =
      "library library1_dart;\n"
      "var foo;";
  const char* kLibrary2Chars =
      "library library2_dart;\n"
      "var foo;";
  Dart_Handle result;
  Dart_Handle lib;

  // Create a test library and Load up a test script in it.
  Dart_SourceFile sourcefiles[] = {
      {RESOLVED_USER_TEST_URI, kScriptChars},
      {"file:///library2_dart", kLibrary2Chars},
      {"file:///library1_dart", kLibrary1Chars},
  };
  int sourcefiles_count = sizeof(sourcefiles) / sizeof(Dart_SourceFile);
  lib = TestCase::LoadTestScriptWithDFE(sourcefiles_count, sourcefiles, nullptr,
                                        true);
  EXPECT_VALID(lib);

  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

TEST_CASE(DartAPI_ImportLibrary5) {
  const char* kScriptChars =
      "import 'lib.dart';\n"
      "abstract class Y {\n"
      "  void set handler(void callback(List<int> x));\n"
      "}\n"
      "void main() {}\n";
  const char* kLibraryChars =
      "library lib.dart;\n"
      "abstract class X {\n"
      "  void set handler(void callback(List<int> x));\n"
      "}\n";
  Dart_Handle result;
  Dart_Handle lib;

  // Create a test library and Load up a test script in it.
  Dart_SourceFile sourcefiles[] = {
      {RESOLVED_USER_TEST_URI, kScriptChars},
      {"file:///lib.dart", kLibraryChars},
  };
  int sourcefiles_count = sizeof(sourcefiles) / sizeof(Dart_SourceFile);
  lib = TestCase::LoadTestScriptWithDFE(sourcefiles_count, sourcefiles, nullptr,
                                        true);
  EXPECT_VALID(lib);

  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

TEST_CASE(DartAPI_Multiroot_Valid) {
  const char* kScriptChars =
      "import 'lib.dart';\n"
      "void main() {}\n";
  const char* kLibraryChars = "library lib.dart;\n";
  Dart_Handle result;
  Dart_Handle lib;

  Dart_SourceFile sourcefiles[] = {
      {"file:///bar/main.dart", kScriptChars},
      {"file:///baz/lib.dart", kLibraryChars},
      {"file:///bar/.packages", ""},
  };
  int sourcefiles_count = sizeof(sourcefiles) / sizeof(Dart_SourceFile);
  lib = TestCase::LoadTestScriptWithDFE(
      sourcefiles_count, sourcefiles, nullptr, /* finalize= */ true,
      /* incrementally= */ true, "foo:///main.dart",
      /* multiroot_filepaths= */ "/bar,/baz",
      /* multiroot_scheme= */ "foo");
  EXPECT_VALID(lib);
  {
    TransitionNativeToVM transition(thread);
    Library& lib_obj = Library::Handle();
    lib_obj ^= Api::UnwrapHandle(lib);
    EXPECT_STREQ("foo:///main.dart", String::Handle(lib_obj.url()).ToCString());
    const Array& lib_scripts = Array::Handle(lib_obj.LoadedScripts());
    Script& script = Script::Handle();
    String& uri = String::Handle();
    for (intptr_t i = 0; i < lib_scripts.Length(); i++) {
      script ^= lib_scripts.At(i);
      uri = script.url();
      const char* uri_str = uri.ToCString();
      EXPECT(strstr(uri_str, "foo:///") == uri_str);
    }
  }
  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

TEST_CASE(DartAPI_Multiroot_FailWhenUriIsWrong) {
  const char* kScriptChars =
      "import 'lib.dart';\n"
      "void main() {}\n";
  const char* kLibraryChars = "library lib.dart;\n";
  Dart_Handle lib;

  Dart_SourceFile sourcefiles[] = {
      {"file:///bar/main.dart", kScriptChars},
      {"file:///baz/lib.dart", kLibraryChars},
      {"file:///bar/.packages", "untitled:/"},
  };
  int sourcefiles_count = sizeof(sourcefiles) / sizeof(Dart_SourceFile);
  lib = TestCase::LoadTestScriptWithDFE(
      sourcefiles_count, sourcefiles, nullptr, /* finalize= */ true,
      /* incrementally= */ true, "foo1:///main.dart",
      /* multiroot_filepaths= */ "/bar,/baz",
      /* multiroot_scheme= */ "foo");
  EXPECT_ERROR(lib,
               "Compilation failed Invalid argument(s): Exception when reading "
               "'foo1:///.dart_tool");
}

static void NewNativePort_send123(Dart_Port dest_port_id,
                                  Dart_CObject* message) {
  // Gets a send port message.
  EXPECT_NOTNULL(message);
  EXPECT_EQ(Dart_CObject_kArray, message->type);
  EXPECT_EQ(Dart_CObject_kSendPort, message->value.as_array.values[0]->type);

  // Post integer value.
  Dart_CObject* response =
      reinterpret_cast<Dart_CObject*>(Dart_ScopeAllocate(sizeof(Dart_CObject)));
  response->type = Dart_CObject_kInt32;
  response->value.as_int32 = 123;
  Dart_PostCObject(message->value.as_array.values[0]->value.as_send_port.id,
                   response);
}

static void NewNativePort_send321(Dart_Port dest_port_id,
                                  Dart_CObject* message) {
  // Gets a null message.
  EXPECT_NOTNULL(message);
  EXPECT_EQ(Dart_CObject_kArray, message->type);
  EXPECT_EQ(Dart_CObject_kSendPort, message->value.as_array.values[0]->type);

  // Post integer value.
  Dart_CObject* response =
      reinterpret_cast<Dart_CObject*>(Dart_ScopeAllocate(sizeof(Dart_CObject)));
  response->type = Dart_CObject_kInt32;
  response->value.as_int32 = 321;
  Dart_PostCObject(message->value.as_array.values[0]->value.as_send_port.id,
                   response);
}

TEST_CASE(DartAPI_IllegalNewSendPort) {
  Dart_Handle error = Dart_NewSendPort(ILLEGAL_PORT);
  EXPECT(Dart_IsError(error));
  EXPECT(Dart_IsApiError(error));
}

TEST_CASE(DartAPI_IllegalPost) {
  Dart_Handle message = Dart_True();
  bool success = Dart_Post(ILLEGAL_PORT, message);
  EXPECT(!success);
}

static void UnreachableFinalizer(void* isolate_callback_data, void* peer) {
  UNREACHABLE();
}

TEST_CASE(DartAPI_PostCObject_DoesNotRunFinalizerOnFailure) {
  char* my_str =
      Utils::StrDup("Ownership of this memory remains with the caller");

  Dart_CObject message;
  message.type = Dart_CObject_kExternalTypedData;
  message.value.as_external_typed_data.type = Dart_TypedData_kUint8;
  message.value.as_external_typed_data.length = strlen(my_str);
  message.value.as_external_typed_data.data =
      reinterpret_cast<uint8_t*>(my_str);
  message.value.as_external_typed_data.peer = my_str;
  message.value.as_external_typed_data.callback = UnreachableFinalizer;

  bool success = Dart_PostCObject(ILLEGAL_PORT, &message);
  EXPECT(!success);

  free(my_str);  // Never a double-free.
}

VM_UNIT_TEST_CASE(DartAPI_NewNativePort) {
  // Create a port with a bogus handler.
  Dart_Port error_port = Dart_NewNativePort("Foo", nullptr, true);
  EXPECT_EQ(ILLEGAL_PORT, error_port);

  // Create the port w/o a current isolate, just to make sure that works.
  Dart_Port port_id1 =
      Dart_NewNativePort("Port123", NewNativePort_send123, true);

  TestIsolateScope __test_isolate__;
  const char* kScriptChars =
      "import 'dart:isolate';\n"
      "@pragma('vm:entry-point', 'call')"
      "void callPort(SendPort port) {\n"
      "  var receivePort = new RawReceivePort();\n"
      "  var replyPort = receivePort.sendPort;\n"
      "  port.send(<dynamic>[replyPort]);\n"
      "  receivePort.handler = (message) {\n"
      "    receivePort.close();\n"
      "    throw new Exception(message);\n"
      "  };\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_EnterScope();

  // Create a port w/ a current isolate, to make sure that works too.
  Dart_Port port_id2 =
      Dart_NewNativePort("Port321", NewNativePort_send321, true);

  Dart_Handle send_port1 = Dart_NewSendPort(port_id1);
  EXPECT_VALID(send_port1);
  Dart_Handle send_port2 = Dart_NewSendPort(port_id2);
  EXPECT_VALID(send_port2);

  // Test first port.
  Dart_Handle dart_args[1];
  dart_args[0] = send_port1;
  Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("Exception: 123\n", Dart_GetError(result));

  // result second port.
  dart_args[0] = send_port2;
  result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("Exception: 321\n", Dart_GetError(result));

  Dart_ExitScope();

  // Delete the native ports.
  EXPECT(Dart_CloseNativePort(port_id1));
  EXPECT(Dart_CloseNativePort(port_id2));
}

static void NewNativePort_sendInteger123(Dart_Port dest_port_id,
                                         Dart_CObject* message) {
  // Gets a send port message.
  EXPECT_NOTNULL(message);
  EXPECT_EQ(Dart_CObject_kArray, message->type);
  EXPECT_EQ(Dart_CObject_kSendPort, message->value.as_array.values[0]->type);

  // Post integer value.
  Dart_PostInteger(message->value.as_array.values[0]->value.as_send_port.id,
                   123);
}

static void NewNativePort_sendInteger321(Dart_Port dest_port_id,
                                         Dart_CObject* message) {
  // Gets a null message.
  EXPECT_NOTNULL(message);
  EXPECT_EQ(Dart_CObject_kArray, message->type);
  EXPECT_EQ(Dart_CObject_kSendPort, message->value.as_array.values[0]->type);

  // Post integer value.
  Dart_PostInteger(message->value.as_array.values[0]->value.as_send_port.id,
                   321);
}

TEST_CASE(DartAPI_NativePortPostInteger) {
  const char* kScriptChars =
      "import 'dart:isolate';\n"
      "@pragma('vm:entry-point', 'call')"
      "void callPort(SendPort port) {\n"
      "  var receivePort = new RawReceivePort();\n"
      "  var replyPort = receivePort.sendPort;\n"
      "  port.send(<dynamic>[replyPort]);\n"
      "  receivePort.handler = (message) {\n"
      "    receivePort.close();\n"
      "    throw new Exception(message);\n"
      "  };\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_EnterScope();

  Dart_Port port_id1 =
      Dart_NewNativePort("Port123", NewNativePort_sendInteger123, true);
  Dart_Port port_id2 =
      Dart_NewNativePort("Port321", NewNativePort_sendInteger321, true);

  Dart_Handle send_port1 = Dart_NewSendPort(port_id1);
  EXPECT_VALID(send_port1);
  Dart_Handle send_port2 = Dart_NewSendPort(port_id2);
  EXPECT_VALID(send_port2);

  // Test first port.
  Dart_Handle dart_args[1];
  dart_args[0] = send_port1;
  Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("Exception: 123\n", Dart_GetError(result));

  // result second port.
  dart_args[0] = send_port2;
  result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("Exception: 321\n", Dart_GetError(result));

  Dart_ExitScope();

  // Delete the native ports.
  EXPECT(Dart_CloseNativePort(port_id1));
  EXPECT(Dart_CloseNativePort(port_id2));
}

static void NewNativePort_Transferrable1(Dart_Port dest_port_id,
                                         Dart_CObject* message) {
  // Gets a send port message.
  EXPECT_NOTNULL(message);
  EXPECT_EQ(Dart_CObject_kTypedData, message->type);
  EXPECT_EQ(Dart_TypedData_kUint8, message->value.as_typed_data.type);
  EXPECT_EQ(10, message->value.as_typed_data.length);
  EXPECT_EQ(42, message->value.as_typed_data.values[0]);
  free(const_cast<uint8_t*>(message->value.as_typed_data.values));
}

static void NewNativePort_Transferrable2(Dart_Port dest_port_id,
                                         Dart_CObject* message) {
  // Gets a send port message.
  EXPECT_NOTNULL(message);
  EXPECT_EQ(Dart_CObject_kArray, message->type);
  EXPECT_EQ(1, message->value.as_array.length);
  Dart_CObject* cobj = message->value.as_array.values[0];
  EXPECT_EQ(Dart_CObject_kTypedData, cobj->type);
  EXPECT_EQ(Dart_TypedData_kUint8, cobj->value.as_typed_data.type);
  EXPECT_EQ(10, cobj->value.as_typed_data.length);
  EXPECT_EQ(42, cobj->value.as_typed_data.values[0]);
  free(const_cast<uint8_t*>(cobj->value.as_typed_data.values));
}

TEST_CASE(DartAPI_NativePortPostTransferrableTypedData) {
  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "import 'dart:isolate';\n"
      "@pragma('vm:entry-point', 'call')"
      "void callPort(SendPort port1, SendPort port2) {\n"
      "  final td1 ="
      "     TransferableTypedData.fromList([Uint8List(10)..[0] = 42]);\n"
      "  final td2 ="
      "     TransferableTypedData.fromList([Uint8List(10)..[0] = 42]);\n"
      "  port1.send(td1);\n"
      "  port2.send([td2]);\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_EnterScope();

  Dart_Port port_id1 =
      Dart_NewNativePort("Port123", NewNativePort_Transferrable1, true);
  Dart_Port port_id2 =
      Dart_NewNativePort("Port321", NewNativePort_Transferrable2, true);

  Dart_Handle send_port1 = Dart_NewSendPort(port_id1);
  EXPECT_VALID(send_port1);
  Dart_Handle send_port2 = Dart_NewSendPort(port_id2);
  EXPECT_VALID(send_port2);

  // Test first port.
  Dart_Handle dart_args[2];
  dart_args[0] = send_port1;
  dart_args[1] = send_port2;
  Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 2, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT_VALID(result);

  Dart_ExitScope();

  // Delete the native ports.
  EXPECT(Dart_CloseNativePort(port_id1));
  EXPECT(Dart_CloseNativePort(port_id2));
}

static constexpr intptr_t kSendLength = 16;

static void NewNativePort_ExternalTypedData(Dart_Port dest_port_id,
                                            Dart_CObject* message) {
  // Gets a send port message.
  EXPECT_NOTNULL(message);
  EXPECT_EQ(Dart_CObject_kTypedData, message->type);
  EXPECT_EQ(Dart_TypedData_kUint8, message->value.as_typed_data.type);
  EXPECT_EQ(kSendLength, message->value.as_typed_data.length);
  for (intptr_t i = 0; i < kSendLength; i++) {
    EXPECT_EQ((0x41 + i), message->value.as_typed_data.values[i]);
  }
}

static void FinalizeTypedData(void* isolate_callback_data, void* peer) {
  delete[] reinterpret_cast<int8_t*>(peer);
}

TEST_CASE(DartAPI_NativePortPostExternalTypedData) {
  int8_t* extTypedData = new int8_t[kSendLength];
  for (int i = 0; i < kSendLength; i++) {
    extTypedData[i] = 0x41 + i;
  }
  const char* kScriptChars =
      "import 'dart:typed_data';\n"
      "import 'dart:isolate';\n"
      "@pragma('vm:entry-point', 'call')"
      "void callPort(SendPort port, Uint8List data) {\n"
      "  port.send(data);\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_EnterScope();

  Dart_Port port_id =
      Dart_NewNativePort("Port123", NewNativePort_ExternalTypedData, true);

  Dart_Handle send_port = Dart_NewSendPort(port_id);
  EXPECT_VALID(send_port);

  Dart_Handle extdata = Dart_NewExternalTypedDataWithFinalizer(
      Dart_TypedData_kUint8, extTypedData, kSendLength, extTypedData,
      kSendLength, FinalizeTypedData);
  EXPECT_VALID(extdata);

  // Test first port.
  Dart_Handle dart_args[2];
  dart_args[0] = send_port;
  dart_args[1] = extdata;
  Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 2, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT_VALID(result);

  Dart_ExitScope();

  // Delete the native ports.
  EXPECT(Dart_CloseNativePort(port_id));
}

static void UnreachableMessageHandler(Dart_Port dest_port_id,
                                      Dart_CObject* message) {
  UNREACHABLE();
}

TEST_CASE(DartAPI_NativePortPostUserClass) {
  const char* kScriptChars =
      "import 'dart:isolate';\n"
      "class ABC {}\n"
      "@pragma('vm:entry-point', 'call')"
      "void callPort(SendPort port) {\n"
      "  port.send(new ABC());\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_EnterScope();

  Dart_Port port_id =
      Dart_NewNativePort("Port123", UnreachableMessageHandler, true);

  // Test send with port open.
  {
    Dart_Handle send_port = Dart_NewSendPort(port_id);
    EXPECT_VALID(send_port);
    Dart_Handle dart_args[1];
    dart_args[0] = send_port;
    Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
    EXPECT_ERROR(result, "Invalid argument");
  }

  // Test send with port closed.
  {
    Dart_CloseNativePort(port_id);
    Dart_Handle send_port = Dart_NewSendPort(port_id);
    EXPECT_VALID(send_port);
    Dart_Handle dart_args[1];
    dart_args[0] = send_port;
    Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
    EXPECT_ERROR(result, "Invalid argument");
  }

  Dart_ExitScope();
}

static void NewNativePort_nativeReceiveNull(Dart_Port dest_port_id,
                                            Dart_CObject* message) {
  EXPECT_NOTNULL(message);

  if ((message->type == Dart_CObject_kArray) &&
      (message->value.as_array.values[0]->type == Dart_CObject_kSendPort)) {
    // Post integer value.
    Dart_PostInteger(message->value.as_array.values[0]->value.as_send_port.id,
                     123);
  } else {
    EXPECT_EQ(message->type, Dart_CObject_kNull);
  }
}

TEST_CASE(DartAPI_NativePortReceiveNull) {
  const char* kScriptChars =
      "import 'dart:isolate';\n"
      "@pragma('vm:entry-point', 'call')"
      "void callPort(SendPort port) {\n"
      "  var receivePort = new RawReceivePort();\n"
      "  var replyPort = receivePort.sendPort;\n"
      "  port.send(null);\n"
      "  port.send(<dynamic>[replyPort]);\n"
      "  receivePort.handler = (message) {\n"
      "    receivePort.close();\n"
      "    throw new Exception(message);\n"
      "  };\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_EnterScope();

  Dart_Port port_id1 =
      Dart_NewNativePort("PortNull", NewNativePort_nativeReceiveNull, true);
  Dart_Handle send_port1 = Dart_NewSendPort(port_id1);
  EXPECT_VALID(send_port1);

  // Test first port.
  Dart_Handle dart_args[1];
  dart_args[0] = send_port1;
  Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("Exception: 123\n", Dart_GetError(result));

  Dart_ExitScope();

  // Delete the native ports.
  EXPECT(Dart_CloseNativePort(port_id1));
}

static void NewNativePort_nativeReceiveInteger(Dart_Port dest_port_id,
                                               Dart_CObject* message) {
  EXPECT_NOTNULL(message);

  if ((message->type == Dart_CObject_kArray) &&
      (message->value.as_array.values[0]->type == Dart_CObject_kSendPort)) {
    // Post integer value.
    Dart_PostInteger(message->value.as_array.values[0]->value.as_send_port.id,
                     123);
  } else {
    EXPECT_EQ(message->type, Dart_CObject_kInt32);
    EXPECT_EQ(message->value.as_int32, 321);
  }
}

TEST_CASE(DartAPI_NativePortReceiveInteger) {
  const char* kScriptChars =
      "import 'dart:isolate';\n"
      "@pragma('vm:entry-point', 'call')"
      "void callPort(SendPort port) {\n"
      "  var receivePort = new RawReceivePort();\n"
      "  var replyPort = receivePort.sendPort;\n"
      "  port.send(321);\n"
      "  port.send(<dynamic>[replyPort]);\n"
      "  receivePort.handler = (message) {\n"
      "    receivePort.close();\n"
      "    throw new Exception(message);\n"
      "  };\n"
      "}\n";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_EnterScope();

  Dart_Port port_id1 =
      Dart_NewNativePort("PortNull", NewNativePort_nativeReceiveInteger, true);
  Dart_Handle send_port1 = Dart_NewSendPort(port_id1);
  EXPECT_VALID(send_port1);

  // Test first port.
  Dart_Handle dart_args[1];
  dart_args[0] = send_port1;
  Dart_Handle result = Dart_Invoke(lib, NewString("callPort"), 1, dart_args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  EXPECT(Dart_IsError(result));
  EXPECT(Dart_ErrorHasException(result));
  EXPECT_SUBSTRING("Exception: 123\n", Dart_GetError(result));

  Dart_ExitScope();

  // Delete the native ports.
  EXPECT(Dart_CloseNativePort(port_id1));
}

static Dart_Isolate RunLoopTestCallback(const char* script_name,
                                        const char* main,
                                        const char* package_root,
                                        const char* package_config,
                                        Dart_IsolateFlags* flags,
                                        void* data,
                                        char** error) {
  const char* kScriptChars =
      "import 'dart:isolate';\n"
      "void main(shouldThrowException) {\n"
      "  var rp = new RawReceivePort();\n"
      "  rp.handler = (msg) {\n"
      "    rp.close();\n"
      "    if (shouldThrowException) {\n"
      "      throw new Exception('ExceptionFromTimer');\n"
      "    }\n"
      "  };\n"
      "  rp.sendPort.send(1);\n"
      "}\n";

  if (Dart_CurrentIsolate() != nullptr) {
    Dart_ExitIsolate();
  }
  Dart_Isolate isolate = TestCase::CreateTestIsolate(script_name);
  ASSERT(isolate != nullptr);
  if (Dart_IsServiceIsolate(isolate)) {
    return isolate;
  }
  Dart_EnterScope();
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);
  Dart_ExitScope();
  Dart_ExitIsolate();
  char* err_msg = Dart_IsolateMakeRunnable(isolate);
  EXPECT(err_msg == nullptr);
  return isolate;
}

// Common code for RunLoop_Success/RunLoop_Failure.
static void RunLoopTest(bool throw_exception) {
  Dart_IsolateGroupCreateCallback saved = Isolate::CreateGroupCallback();
  Isolate::SetCreateGroupCallback(RunLoopTestCallback);
  Dart_Isolate isolate = RunLoopTestCallback(nullptr, nullptr, nullptr, nullptr,
                                             nullptr, nullptr, nullptr);

  Dart_EnterIsolate(isolate);
  Dart_EnterScope();
  Dart_Handle lib = Dart_LookupLibrary(NewString(TestCase::url()));
  EXPECT_VALID(lib);

  Dart_Handle result;
  Dart_Handle args[1];
  args[0] = (throw_exception ? Dart_True() : Dart_False());
  result = Dart_Invoke(lib, NewString("main"), 1, args);
  EXPECT_VALID(result);
  result = Dart_RunLoop();
  if (throw_exception) {
    EXPECT_ERROR(result, "Exception: ExceptionFromTimer");
  } else {
    EXPECT_VALID(result);
  }

  Dart_ExitScope();
  Dart_ShutdownIsolate();

  Isolate::SetCreateGroupCallback(saved);
}

VM_UNIT_TEST_CASE(DartAPI_RunLoop_Success) {
  RunLoopTest(false);
}

VM_UNIT_TEST_CASE(DartAPI_RunLoop_Exception) {
  RunLoopTest(true);
}

static void* shutdown_isolate_group_data;
static void* shutdown_isolate_data;
static void* cleanup_isolate_group_data;
static void* cleanup_isolate_data;

// Called on isolate shutdown time (which is still allowed to run Dart code)
static void IsolateShutdownTestCallback(void* group_data, void* isolate_data) {
  // Shutdown runs before cleanup.
  EXPECT(cleanup_isolate_group_data == nullptr);
  EXPECT(cleanup_isolate_data == nullptr);

  // Shutdown must have a current isolate (since it is allowed to execute Dart
  // code)
  EXPECT(Dart_CurrentIsolate() != nullptr);
  EXPECT(Dart_CurrentIsolateGroupData() == group_data);
  EXPECT(Dart_CurrentIsolateData() == isolate_data);

  shutdown_isolate_group_data = group_data;
  shutdown_isolate_data = isolate_data;
}

// Called on isolate cleanup time (which is after the isolate has been
// destroyed)
static void IsolateCleanupTestCallback(void* group_data, void* isolate_data) {
  // Cleanup runs after shutdown.
  EXPECT(shutdown_isolate_group_data != nullptr);
  EXPECT(shutdown_isolate_data != nullptr);

  // The isolate was destroyed and there should not be a current isolate.
  EXPECT(Dart_CurrentIsolate() == nullptr);

  cleanup_isolate_group_data = group_data;
  cleanup_isolate_data = isolate_data;
}

// Called on isolate group cleanup time (once all isolates have been destroyed)
static void* cleanup_group_callback_data;
static void IsolateGroupCleanupTestCallback(void* callback_data) {
  cleanup_group_callback_data = callback_data;
}

VM_UNIT_TEST_CASE(DartAPI_IsolateShutdownAndCleanup) {
  Dart_IsolateShutdownCallback saved_shutdown = Isolate::ShutdownCallback();
  Dart_IsolateGroupCleanupCallback saved_cleanup =
      Isolate::GroupCleanupCallback();
  Isolate::SetShutdownCallback(IsolateShutdownTestCallback);
  Isolate::SetCleanupCallback(IsolateCleanupTestCallback);
  Isolate::SetGroupCleanupCallback(IsolateGroupCleanupTestCallback);

  shutdown_isolate_group_data = nullptr;
  shutdown_isolate_data = nullptr;
  cleanup_group_callback_data = nullptr;
  void* my_group_data = reinterpret_cast<void*>(123);
  void* my_data = reinterpret_cast<void*>(456);

  // Create an isolate.
  Dart_Isolate isolate =
      TestCase::CreateTestIsolate(nullptr, my_group_data, my_data);
  EXPECT(isolate != nullptr);

  // The shutdown callback has not been called.
  EXPECT(nullptr == shutdown_isolate_data);
  EXPECT(nullptr == shutdown_isolate_group_data);
  EXPECT(nullptr == cleanup_group_callback_data);

  // The isolate is the active isolate which allows us to access the isolate
  // specific and isolate-group specific data.
  EXPECT(Dart_CurrentIsolateData() == my_data);
  EXPECT(Dart_CurrentIsolateGroupData() == my_group_data);

  // Shutdown the isolate.
  Dart_ShutdownIsolate();

  // The shutdown & cleanup callbacks have been called.
  EXPECT(my_data == shutdown_isolate_data);
  EXPECT(my_group_data == shutdown_isolate_group_data);
  EXPECT(my_data == cleanup_isolate_data);
  EXPECT(my_group_data == cleanup_isolate_group_data);
  EXPECT(my_group_data == cleanup_group_callback_data);

  Isolate::SetShutdownCallback(saved_shutdown);
  Isolate::SetGroupCleanupCallback(saved_cleanup);
}

static int64_t add_result = 0;
static void IsolateShutdownRunDartCodeTestCallback(void* isolate_group_data,
                                                   void* isolate_data) {
  Dart_Isolate isolate = Dart_CurrentIsolate();
  if (Dart_IsKernelIsolate(isolate) || Dart_IsServiceIsolate(isolate)) {
    return;
  } else {
    ASSERT(add_result == 0);
  }
  Dart_EnterScope();
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = Dart_RootLibrary();
  EXPECT_VALID(lib);
  Dart_Handle arg1 = Dart_NewInteger(90);
  EXPECT_VALID(arg1);
  Dart_Handle arg2 = Dart_NewInteger(9);
  EXPECT_VALID(arg2);
  Dart_Handle dart_args[2] = {arg1, arg2};
  Dart_Handle result = Dart_Invoke(lib, NewString("add"), 2, dart_args);
  EXPECT_VALID(result);
  result = Dart_IntegerToInt64(result, &add_result);
  EXPECT_VALID(result);
  Dart_ExitScope();
}

VM_UNIT_TEST_CASE(DartAPI_IsolateShutdownRunDartCode) {
  const char* kScriptChars =
      "int add(int a, int b) {\n"
      "  return a + b;\n"
      "}\n"
      "\n"
      "void main() {\n"
      "  add(4, 5);\n"
      "}\n";

  // Create an isolate.
  auto isolate = reinterpret_cast<Isolate*>(TestCase::CreateTestIsolate());
  EXPECT(isolate != nullptr);

  isolate->set_on_shutdown_callback(IsolateShutdownRunDartCodeTestCallback);

  {
    Dart_EnterScope();
    Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
    EXPECT_VALID(lib);
    Dart_Handle result = Dart_SetLibraryTagHandler(TestCase::library_handler);
    EXPECT_VALID(result);
    result = Dart_FinalizeLoading(false);
    EXPECT_VALID(result);
    result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
    EXPECT_VALID(result);
    Dart_ExitScope();
  }

  // The shutdown callback has not been called.
  EXPECT_EQ(0, add_result);

  // Shutdown the isolate.
  Dart_ShutdownIsolate();

  // The shutdown callback has been called and ran Dart code.
  EXPECT_EQ(99, add_result);
}

static int64_t GetValue(Dart_Handle arg) {
  EXPECT_VALID(arg);
  EXPECT(Dart_IsInteger(arg));
  int64_t value;
  EXPECT_VALID(Dart_IntegerToInt64(arg, &value));
  return value;
}

static void NativeFoo1(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(1, i);
  Dart_Handle arg = Dart_GetNativeArgument(args, 0);
  EXPECT_VALID(arg);
  Dart_SetReturnValue(args, Dart_NewInteger(1));
  Dart_ExitScope();
}

static void NativeFoo2(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(2, i);
  Dart_Handle arg1 = Dart_GetNativeArgument(args, 1);
  EXPECT_VALID(arg1);
  int64_t value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(arg1, &value));
  int64_t integer_value = 0;
  Dart_Handle result = Dart_GetNativeIntegerArgument(args, 1, &integer_value);
  EXPECT_VALID(result);
  EXPECT_EQ(value, integer_value);
  double double_value;
  result = Dart_GetNativeDoubleArgument(args, 1, &double_value);
  EXPECT_VALID(result);
  bool bool_value;
  result = Dart_GetNativeBooleanArgument(args, 1, &bool_value);
  EXPECT(Dart_IsError(result));
  Dart_SetReturnValue(args, Dart_NewInteger(GetValue(arg1)));
  Dart_ExitScope();
}

static void NativeFoo3(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(3, i);
  Dart_Handle arg1 = Dart_GetNativeArgument(args, 1);
  Dart_Handle arg2 = Dart_GetNativeArgument(args, 2);
  Dart_SetReturnValue(args, Dart_NewInteger(GetValue(arg1) + GetValue(arg2)));
  Dart_ExitScope();
}

static void NativeFoo4(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(4, i);
  Dart_Handle arg1 = Dart_GetNativeArgument(args, 1);
  Dart_Handle arg2 = Dart_GetNativeArgument(args, 2);
  Dart_Handle arg3 = Dart_GetNativeArgument(args, 3);
  Dart_SetReturnValue(
      args, Dart_NewInteger(GetValue(arg1) + GetValue(arg2) + GetValue(arg3)));
  Dart_ExitScope();
}

static Dart_NativeFunction MyNativeClosureResolver(Dart_Handle name,
                                                   int arg_count,
                                                   bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = false;
  TransitionNativeToVM transition(Thread::Current());
  const Object& obj = Object::Handle(Api::UnwrapHandle(name));
  if (!obj.IsString()) {
    return nullptr;
  }
  const char* function_name = obj.ToCString();
  const char* kNativeFoo1 = "NativeFoo1";
  const char* kNativeFoo2 = "NativeFoo2";
  const char* kNativeFoo3 = "NativeFoo3";
  const char* kNativeFoo4 = "NativeFoo4";
  if (strncmp(function_name, kNativeFoo1, strlen(kNativeFoo1)) == 0) {
    return &NativeFoo1;
  } else if (strncmp(function_name, kNativeFoo2, strlen(kNativeFoo2)) == 0) {
    return &NativeFoo2;
  } else if (strncmp(function_name, kNativeFoo3, strlen(kNativeFoo3)) == 0) {
    return &NativeFoo3;
  } else if (strncmp(function_name, kNativeFoo4, strlen(kNativeFoo4)) == 0) {
    return &NativeFoo4;
  } else {
    UNREACHABLE();
    return nullptr;
  }
}

TEST_CASE(DartAPI_NativeFunctionClosure) {
  const char* kScriptChars =
      R"(
      class Test {
        @pragma('vm:external-name', 'NativeFoo1')
        external int foo1();

        @pragma('vm:external-name', 'NativeFoo2')
        external int foo2(int i);

        @pragma('vm:external-name', 'NativeFoo3')
        external int foo3([int k = 10000, int l = 1]);

        @pragma('vm:external-name', 'NativeFoo4')
        external int foo4(int i, [int j = 10, int k = 1]);

        int bar1() { var func = foo1; return func(); }
        int bar2(int i) { var func = foo2; return func(i); }
        int bar30() { var func = foo3; return func(); }
        int bar31(int i) { var func = foo3; return func(i); }
        int bar32(int i, int j) { var func = foo3; return func(i, j); }
        int bar41(int i) {
          var func = foo4; return func(i); }
        int bar42(int i, int j) {
          var func = foo4; return func(i, j); }
        int bar43(int i, int j, int k) {
          var func = foo4; return func(i, j, k); }
      }
      class Expect {
        static equals(a, b) {
          if (a != b) {
            throw 'not equal. expected: $a, got: $b';
          }
        }
      }
      @pragma('vm:entry-point', 'call')
      int testMain() {
        Test obj = new Test();
        Expect.equals(1, obj.foo1());
        Expect.equals(1, obj.bar1());

        Expect.equals(10, obj.foo2(10));
        Expect.equals(10, obj.bar2(10));

        Expect.equals(10001, obj.foo3());
        Expect.equals(10001, obj.bar30());
        Expect.equals(2, obj.foo3(1));
        Expect.equals(2, obj.bar31(1));
        Expect.equals(4, obj.foo3(2, 2));
        Expect.equals(4, obj.bar32(2, 2));

        Expect.equals(12, obj.foo4(1));
        Expect.equals(12, obj.bar41(1));
        Expect.equals(3, obj.foo4(1, 1));
        Expect.equals(3, obj.bar42(1, 1));
        Expect.equals(6, obj.foo4(2, 2, 2));
        Expect.equals(6, obj.bar43(2, 2, 2));

        return 0;
      }
  )";

  Dart_Handle result;

  // Load a test script.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  EXPECT(Dart_IsLibrary(lib));
  result = Dart_SetNativeResolver(lib, &MyNativeClosureResolver, nullptr);
  EXPECT_VALID(result);
  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);

  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  int64_t value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(result, &value));
  EXPECT_EQ(0, value);
}

static void StaticNativeFoo1(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(0, i);
  Dart_SetReturnValue(args, Dart_NewInteger(0));
  Dart_ExitScope();
}

static void StaticNativeFoo2(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(1, i);
  Dart_Handle arg = Dart_GetNativeArgument(args, 0);
  Dart_SetReturnValue(args, Dart_NewInteger(GetValue(arg)));
  Dart_ExitScope();
}

static void StaticNativeFoo3(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(2, i);
  Dart_Handle arg1 = Dart_GetNativeArgument(args, 0);
  Dart_Handle arg2 = Dart_GetNativeArgument(args, 1);
  Dart_SetReturnValue(args, Dart_NewInteger(GetValue(arg1) + GetValue(arg2)));
  Dart_ExitScope();
}

static void StaticNativeFoo4(Dart_NativeArguments args) {
  Dart_EnterScope();
  intptr_t i = Dart_GetNativeArgumentCount(args);
  EXPECT_EQ(3, i);
  Dart_Handle arg1 = Dart_GetNativeArgument(args, 0);
  Dart_Handle arg2 = Dart_GetNativeArgument(args, 1);
  Dart_Handle arg3 = Dart_GetNativeArgument(args, 2);
  Dart_SetReturnValue(
      args, Dart_NewInteger(GetValue(arg1) + GetValue(arg2) + GetValue(arg3)));
  Dart_ExitScope();
}

static Dart_NativeFunction MyStaticNativeClosureResolver(
    Dart_Handle name,
    int arg_count,
    bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = false;
  TransitionNativeToVM transition(Thread::Current());
  const Object& obj = Object::Handle(Api::UnwrapHandle(name));
  if (!obj.IsString()) {
    return nullptr;
  }
  const char* function_name = obj.ToCString();
  const char* kNativeFoo1 = "StaticNativeFoo1";
  const char* kNativeFoo2 = "StaticNativeFoo2";
  const char* kNativeFoo3 = "StaticNativeFoo3";
  const char* kNativeFoo4 = "StaticNativeFoo4";
  if (strncmp(function_name, kNativeFoo1, strlen(kNativeFoo1)) == 0) {
    return &StaticNativeFoo1;
  } else if (strncmp(function_name, kNativeFoo2, strlen(kNativeFoo2)) == 0) {
    return &StaticNativeFoo2;
  } else if (strncmp(function_name, kNativeFoo3, strlen(kNativeFoo3)) == 0) {
    return &StaticNativeFoo3;
  } else if (strncmp(function_name, kNativeFoo4, strlen(kNativeFoo4)) == 0) {
    return &StaticNativeFoo4;
  } else {
    UNREACHABLE();
    return nullptr;
  }
}

TEST_CASE(DartAPI_NativeStaticFunctionClosure) {
  const char* kScriptChars =
      R"(
      class Test {
        @pragma('vm:external-name', 'StaticNativeFoo1')
        external static int foo1();

        @pragma('vm:external-name', 'StaticNativeFoo2')
        external static int foo2(int i);

        @pragma('vm:external-name', 'StaticNativeFoo3')
        external static int foo3([int k = 10000, int l = 1]);

        @pragma('vm:external-name', 'StaticNativeFoo4')
        external static int foo4(int i, [int j = 10, int k = 1]);

        int bar1() { var func = foo1; return func(); }
        int bar2(int i) { var func = foo2; return func(i); }
        int bar30() { var func = foo3; return func(); }
        int bar31(int i) { var func = foo3; return func(i); }
        int bar32(int i, int j) { var func = foo3; return func(i, j); }
        int bar41(int i) {
          var func = foo4; return func(i); }
        int bar42(int i, int j) {
          var func = foo4; return func(i, j); }
        int bar43(int i, int j, int k) {
          var func = foo4; return func(i, j, k); }
      }
      class Expect {
        static equals(a, b) {
          if (a != b) {
            throw 'not equal. expected: $a, got: $b';
          }
        }
      }
      @pragma('vm:entry-point', 'call')
      int testMain() {
        Test obj = new Test();
        Expect.equals(0, Test.foo1());
        Expect.equals(0, obj.bar1());

        Expect.equals(10, Test.foo2(10));
        Expect.equals(10, obj.bar2(10));

        Expect.equals(10001, Test.foo3());
        Expect.equals(10001, obj.bar30());
        Expect.equals(2, Test.foo3(1));
        Expect.equals(2, obj.bar31(1));
        Expect.equals(4, Test.foo3(2, 2));
        Expect.equals(4, obj.bar32(2, 2));

        Expect.equals(12, Test.foo4(1));
        Expect.equals(12, obj.bar41(1));
        Expect.equals(3, Test.foo4(1, 1));
        Expect.equals(3, obj.bar42(1, 1));
        Expect.equals(6, Test.foo4(2, 2, 2));
        Expect.equals(6, obj.bar43(2, 2, 2));

        return 0;
      }
  )";

  Dart_Handle result;

  // Load a test script.
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);
  EXPECT(Dart_IsLibrary(lib));
  result = Dart_SetNativeResolver(lib, &MyStaticNativeClosureResolver, nullptr);
  EXPECT_VALID(result);
  result = Dart_FinalizeLoading(false);
  EXPECT_VALID(result);

  result = Dart_Invoke(lib, NewString("testMain"), 0, nullptr);
  EXPECT_VALID(result);
  EXPECT(Dart_IsInteger(result));
  int64_t value = 0;
  EXPECT_VALID(Dart_IntegerToInt64(result, &value));
  EXPECT_EQ(0, value);
}

TEST_CASE(DartAPI_RangeLimits) {
  uint8_t chars8[1] = {'a'};
  uint16_t chars16[1] = {'a'};
  int32_t chars32[1] = {'a'};

  EXPECT_ERROR(Dart_NewList(-1),
               "expects argument 'length' to be in the range");
  EXPECT_ERROR(Dart_NewList(Array::kMaxElements + 1),
               "expects argument 'length' to be in the range");
  EXPECT_ERROR(Dart_NewStringFromUTF8(chars8, -1),
               "expects argument 'length' to be in the range");
  EXPECT_ERROR(Dart_NewStringFromUTF8(chars8, OneByteString::kMaxElements + 1),
               "expects argument 'length' to be in the range");
  EXPECT_ERROR(Dart_NewStringFromUTF16(chars16, -1),
               "expects argument 'length' to be in the range");
  EXPECT_ERROR(
      Dart_NewStringFromUTF16(chars16, TwoByteString::kMaxElements + 1),
      "expects argument 'length' to be in the range");
  EXPECT_ERROR(Dart_NewStringFromUTF32(chars32, -1),
               "expects argument 'length' to be in the range");
  EXPECT_ERROR(
      Dart_NewStringFromUTF32(chars32, TwoByteString::kMaxElements + 1),
      "expects argument 'length' to be in the range");
}

TEST_CASE(DartAPI_NewString_Null) {
  Dart_Handle str = Dart_NewStringFromUTF8(nullptr, 0);
  EXPECT_VALID(str);
  EXPECT(Dart_IsString(str));
  intptr_t len = -1;
  EXPECT_VALID(Dart_StringLength(str, &len));
  EXPECT_EQ(0, len);

  str = Dart_NewStringFromUTF16(nullptr, 0);
  EXPECT_VALID(str);
  EXPECT(Dart_IsString(str));
  len = -1;
  EXPECT_VALID(Dart_StringLength(str, &len));
  EXPECT_EQ(0, len);

  str = Dart_NewStringFromUTF32(nullptr, 0);
  EXPECT_VALID(str);
  EXPECT(Dart_IsString(str));
  len = -1;
  EXPECT_VALID(Dart_StringLength(str, &len));
  EXPECT_EQ(0, len);
}

// Try to allocate a peer with a handles to objects of prohibited
// subtypes.
TEST_CASE(DartAPI_InvalidGetSetPeer) {
  void* out = &out;
  EXPECT(Dart_IsError(Dart_GetPeer(Dart_Null(), &out)));
  EXPECT(out == &out);
  EXPECT(Dart_IsError(Dart_SetPeer(Dart_Null(), &out)));
  out = &out;
  EXPECT(Dart_IsError(Dart_GetPeer(Dart_True(), &out)));
  EXPECT(out == &out);
  EXPECT(Dart_IsError(Dart_SetPeer(Dart_True(), &out)));
  out = &out;
  EXPECT(Dart_IsError(Dart_GetPeer(Dart_False(), &out)));
  EXPECT(out == &out);
  EXPECT(Dart_IsError(Dart_SetPeer(Dart_False(), &out)));
  out = &out;
  Dart_Handle smi = Dart_NewInteger(0);
  EXPECT(Dart_IsError(Dart_GetPeer(smi, &out)));
  EXPECT(out == &out);
  EXPECT(Dart_IsError(Dart_SetPeer(smi, &out)));
  out = &out;
  Dart_Handle big = Dart_NewIntegerFromHexCString("0x10000000000000000");
  EXPECT(Dart_IsApiError(big));
  out = &out;
  Dart_Handle dbl = Dart_NewDouble(0.0);
  EXPECT(Dart_IsError(Dart_GetPeer(dbl, &out)));
  EXPECT(out == &out);
  EXPECT(Dart_IsError(Dart_SetPeer(dbl, &out)));
}

// Allocates an object in new space and assigns it a peer.  Removes
// the peer and checks that the count of peer objects is decremented
// by one.
TEST_CASE(DartAPI_OneNewSpacePeer) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_Handle str = NewString("a string");
  EXPECT_VALID(str);
  EXPECT(Dart_IsString(str));
  EXPECT_EQ(0, heap->PeerCount());
  void* out = &out;
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == nullptr);
  int peer = 1234;
  EXPECT_VALID(Dart_SetPeer(str, &peer));
  EXPECT_EQ(1, heap->PeerCount());
  out = &out;
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == reinterpret_cast<void*>(&peer));
  EXPECT_VALID(Dart_SetPeer(str, nullptr));
  out = &out;
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == nullptr);
  EXPECT_EQ(0, heap->PeerCount());
}

// Allocates an object in new space and assigns it a peer.  Allows the
// peer referent to be garbage collected and checks that the count of
// peer objects is decremented by one.
TEST_CASE(DartAPI_CollectOneNewSpacePeer) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_EnterScope();
  {
    CHECK_API_SCOPE(thread);
    Dart_Handle str = NewString("a string");
    EXPECT_VALID(str);
    EXPECT(Dart_IsString(str));
    EXPECT_EQ(0, heap->PeerCount());
    void* out = &out;
    EXPECT_VALID(Dart_GetPeer(str, &out));
    EXPECT(out == nullptr);
    int peer = 1234;
    EXPECT_VALID(Dart_SetPeer(str, &peer));
    EXPECT_EQ(1, heap->PeerCount());
    out = &out;
    EXPECT_VALID(Dart_GetPeer(str, &out));
    EXPECT(out == reinterpret_cast<void*>(&peer));
    {
      TransitionNativeToVM transition(thread);
      GCTestHelper::CollectNewSpace();
      EXPECT_EQ(1, heap->PeerCount());
    }
    out = &out;
    EXPECT_VALID(Dart_GetPeer(str, &out));
    EXPECT(out == reinterpret_cast<void*>(&peer));
  }
  Dart_ExitScope();
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(0, heap->PeerCount());
  }
}

// Allocates two objects in new space and assigns them peers.  Removes
// the peers and checks that the count of peer objects is decremented
// by two.
TEST_CASE(DartAPI_TwoNewSpacePeers) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_Handle s1 = NewString("s1");
  EXPECT_VALID(s1);
  EXPECT(Dart_IsString(s1));
  void* o1 = &o1;
  EXPECT_VALID(Dart_GetPeer(s1, &o1));
  EXPECT(o1 == nullptr);
  EXPECT_EQ(0, heap->PeerCount());
  int p1 = 1234;
  EXPECT_VALID(Dart_SetPeer(s1, &p1));
  EXPECT_EQ(1, heap->PeerCount());
  EXPECT_VALID(Dart_GetPeer(s1, &o1));
  EXPECT(o1 == reinterpret_cast<void*>(&p1));
  Dart_Handle s2 = NewString("a string");
  EXPECT_VALID(s2);
  EXPECT(Dart_IsString(s2));
  EXPECT_EQ(1, heap->PeerCount());
  void* o2 = &o2;
  EXPECT(Dart_GetPeer(s2, &o2));
  EXPECT(o2 == nullptr);
  int p2 = 5678;
  EXPECT_VALID(Dart_SetPeer(s2, &p2));
  EXPECT_EQ(2, heap->PeerCount());
  EXPECT_VALID(Dart_GetPeer(s2, &o2));
  EXPECT(o2 == reinterpret_cast<void*>(&p2));
  EXPECT_VALID(Dart_SetPeer(s1, nullptr));
  EXPECT_EQ(1, heap->PeerCount());
  EXPECT(Dart_GetPeer(s1, &o1));
  EXPECT(o1 == nullptr);
  EXPECT_VALID(Dart_SetPeer(s2, nullptr));
  EXPECT_EQ(0, heap->PeerCount());
  EXPECT(Dart_GetPeer(s2, &o2));
  EXPECT(o2 == nullptr);
}

// Allocates two objects in new space and assigns them a peer.  Allow
// the peer referents to be garbage collected and check that the count
// of peer objects is decremented by two.
TEST_CASE(DartAPI_CollectTwoNewSpacePeers) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_EnterScope();
  {
    CHECK_API_SCOPE(thread);
    Dart_Handle s1 = NewString("s1");
    EXPECT_VALID(s1);
    EXPECT(Dart_IsString(s1));
    EXPECT_EQ(0, heap->PeerCount());
    void* o1 = &o1;
    EXPECT(Dart_GetPeer(s1, &o1));
    EXPECT(o1 == nullptr);
    int p1 = 1234;
    EXPECT_VALID(Dart_SetPeer(s1, &p1));
    EXPECT_EQ(1, heap->PeerCount());
    EXPECT_VALID(Dart_GetPeer(s1, &o1));
    EXPECT(o1 == reinterpret_cast<void*>(&p1));
    Dart_Handle s2 = NewString("s2");
    EXPECT_VALID(s2);
    EXPECT(Dart_IsString(s2));
    EXPECT_EQ(1, heap->PeerCount());
    void* o2 = &o2;
    EXPECT(Dart_GetPeer(s2, &o2));
    EXPECT(o2 == nullptr);
    int p2 = 5678;
    EXPECT_VALID(Dart_SetPeer(s2, &p2));
    EXPECT_EQ(2, heap->PeerCount());
    EXPECT_VALID(Dart_GetPeer(s2, &o2));
    EXPECT(o2 == reinterpret_cast<void*>(&p2));
  }
  Dart_ExitScope();
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(0, heap->PeerCount());
  }
}

// Allocates several objects in new space.  Performs successive
// garbage collections and checks that the peer count is stable.
TEST_CASE(DartAPI_CopyNewSpacePeers) {
  const int kPeerCount = 10;
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_Handle s[kPeerCount];
  for (int i = 0; i < kPeerCount; ++i) {
    s[i] = NewString("a string");
    EXPECT_VALID(s[i]);
    EXPECT(Dart_IsString(s[i]));
    void* o = &o;
    EXPECT_VALID(Dart_GetPeer(s[i], &o));
    EXPECT(o == nullptr);
  }
  EXPECT_EQ(0, heap->PeerCount());
  int p[kPeerCount];
  for (int i = 0; i < kPeerCount; ++i) {
    EXPECT_VALID(Dart_SetPeer(s[i], &p[i]));
    EXPECT_EQ(i + 1, heap->PeerCount());
    void* o = &o;
    EXPECT_VALID(Dart_GetPeer(s[i], &o));
    EXPECT(o == reinterpret_cast<void*>(&p[i]));
  }
  EXPECT_EQ(kPeerCount, heap->PeerCount());
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(kPeerCount, heap->PeerCount());
    GCTestHelper::CollectNewSpace();
    EXPECT_EQ(kPeerCount, heap->PeerCount());
  }
}

// Allocates an object in new space and assigns it a peer.  Promotes
// the peer to old space.  Removes the peer and check that the count
// of peer objects is decremented by one.
TEST_CASE(DartAPI_OnePromotedPeer) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_Handle str = NewString("a string");
  EXPECT_VALID(str);
  EXPECT(Dart_IsString(str));
  EXPECT_EQ(0, heap->PeerCount());
  void* out = &out;
  EXPECT(Dart_GetPeer(str, &out));
  EXPECT(out == nullptr);
  int peer = 1234;
  EXPECT_VALID(Dart_SetPeer(str, &peer));
  out = &out;
  EXPECT(Dart_GetPeer(str, &out));
  EXPECT(out == reinterpret_cast<void*>(&peer));
  EXPECT_EQ(1, heap->PeerCount());
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectNewSpace();
    GCTestHelper::CollectNewSpace();
  }
  {
    CHECK_API_SCOPE(thread);
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    String& handle = String::Handle();
    handle ^= Api::UnwrapHandle(str);
    EXPECT(handle.IsOld());
  }
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == reinterpret_cast<void*>(&peer));
  EXPECT_EQ(1, heap->PeerCount());
  EXPECT_VALID(Dart_SetPeer(str, nullptr));
  out = &out;
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == nullptr);
  EXPECT_EQ(0, heap->PeerCount());
}

// Allocates an object in old space and assigns it a peer.  Removes
// the peer and checks that the count of peer objects is decremented
// by one.
TEST_CASE(DartAPI_OneOldSpacePeer) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_Handle str = AllocateOldString("str");
  EXPECT_VALID(str);
  EXPECT(Dart_IsString(str));
  EXPECT_EQ(0, heap->PeerCount());
  void* out = &out;
  EXPECT(Dart_GetPeer(str, &out));
  EXPECT(out == nullptr);
  int peer = 1234;
  EXPECT_VALID(Dart_SetPeer(str, &peer));
  EXPECT_EQ(1, heap->PeerCount());
  out = &out;
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == reinterpret_cast<void*>(&peer));
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(1, heap->PeerCount());
  }
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == reinterpret_cast<void*>(&peer));
  EXPECT_VALID(Dart_SetPeer(str, nullptr));
  out = &out;
  EXPECT_VALID(Dart_GetPeer(str, &out));
  EXPECT(out == nullptr);
  EXPECT_EQ(0, heap->PeerCount());
}

// Allocates an object in old space and assigns it a peer.  Allow the
// peer referent to be garbage collected and check that the count of
// peer objects is decremented by one.
TEST_CASE(DartAPI_CollectOneOldSpacePeer) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_EnterScope();
  {
    Thread* T = Thread::Current();
    CHECK_API_SCOPE(T);
    Dart_Handle str = AllocateOldString("str");
    EXPECT_VALID(str);
    EXPECT(Dart_IsString(str));
    EXPECT_EQ(0, heap->PeerCount());
    void* out = &out;
    EXPECT(Dart_GetPeer(str, &out));
    EXPECT(out == nullptr);
    int peer = 1234;
    EXPECT_VALID(Dart_SetPeer(str, &peer));
    EXPECT_EQ(1, heap->PeerCount());
    out = &out;
    EXPECT_VALID(Dart_GetPeer(str, &out));
    EXPECT(out == reinterpret_cast<void*>(&peer));
    {
      TransitionNativeToVM transition(thread);
      GCTestHelper::CollectOldSpace();
      EXPECT_EQ(1, heap->PeerCount());
    }
    EXPECT_VALID(Dart_GetPeer(str, &out));
    EXPECT(out == reinterpret_cast<void*>(&peer));
  }
  Dart_ExitScope();
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(0, heap->PeerCount());
  }
}

// Allocates two objects in old space and assigns them peers.  Removes
// the peers and checks that the count of peer objects is decremented
// by two.
TEST_CASE(DartAPI_TwoOldSpacePeers) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_Handle s1 = AllocateOldString("s1");
  EXPECT_VALID(s1);
  EXPECT(Dart_IsString(s1));
  EXPECT_EQ(0, heap->PeerCount());
  void* o1 = &o1;
  EXPECT(Dart_GetPeer(s1, &o1));
  EXPECT(o1 == nullptr);
  int p1 = 1234;
  EXPECT_VALID(Dart_SetPeer(s1, &p1));
  EXPECT_EQ(1, heap->PeerCount());
  o1 = &o1;
  EXPECT_VALID(Dart_GetPeer(s1, &o1));
  EXPECT(o1 == reinterpret_cast<void*>(&p1));
  Dart_Handle s2 = AllocateOldString("s2");
  EXPECT_VALID(s2);
  EXPECT(Dart_IsString(s2));
  EXPECT_EQ(1, heap->PeerCount());
  void* o2 = &o2;
  EXPECT(Dart_GetPeer(s2, &o2));
  EXPECT(o2 == nullptr);
  int p2 = 5678;
  EXPECT_VALID(Dart_SetPeer(s2, &p2));
  EXPECT_EQ(2, heap->PeerCount());
  o2 = &o2;
  EXPECT_VALID(Dart_GetPeer(s2, &o2));
  EXPECT(o2 == reinterpret_cast<void*>(&p2));
  EXPECT_VALID(Dart_SetPeer(s1, nullptr));
  EXPECT_EQ(1, heap->PeerCount());
  o1 = &o1;
  EXPECT(Dart_GetPeer(s1, &o1));
  EXPECT(o1 == nullptr);
  EXPECT_VALID(Dart_SetPeer(s2, nullptr));
  EXPECT_EQ(0, heap->PeerCount());
  o2 = &o2;
  EXPECT_VALID(Dart_GetPeer(s2, &o2));
  EXPECT(o2 == nullptr);
}

// Allocates two objects in old space and assigns them a peer.  Allows
// the peer referents to be garbage collected and checks that the
// count of peer objects is decremented by two.
TEST_CASE(DartAPI_CollectTwoOldSpacePeers) {
  Heap* heap = IsolateGroup::Current()->heap();
  Dart_EnterScope();
  {
    Thread* T = Thread::Current();
    CHECK_API_SCOPE(T);
    Dart_Handle s1 = AllocateOldString("s1");
    EXPECT_VALID(s1);
    EXPECT(Dart_IsString(s1));
    EXPECT_EQ(0, heap->PeerCount());
    void* o1 = &o1;
    EXPECT(Dart_GetPeer(s1, &o1));
    EXPECT(o1 == nullptr);
    int p1 = 1234;
    EXPECT_VALID(Dart_SetPeer(s1, &p1));
    EXPECT_EQ(1, heap->PeerCount());
    o1 = &o1;
    EXPECT_VALID(Dart_GetPeer(s1, &o1));
    EXPECT(o1 == reinterpret_cast<void*>(&p1));
    Dart_Handle s2 = AllocateOldString("s2");
    EXPECT_VALID(s2);
    EXPECT(Dart_IsString(s2));
    EXPECT_EQ(1, heap->PeerCount());
    void* o2 = &o2;
    EXPECT(Dart_GetPeer(s2, &o2));
    EXPECT(o2 == nullptr);
    int p2 = 5678;
    EXPECT_VALID(Dart_SetPeer(s2, &p2));
    EXPECT_EQ(2, heap->PeerCount());
    o2 = &o2;
    EXPECT_VALID(Dart_GetPeer(s2, &o2));
    EXPECT(o2 == reinterpret_cast<void*>(&p2));
  }
  Dart_ExitScope();
  {
    TransitionNativeToVM transition(thread);
    GCTestHelper::CollectOldSpace();
    EXPECT_EQ(0, heap->PeerCount());
  }
}

TEST_CASE(DartAPI_StringFromExternalTypedData) {
  const char* kScriptChars =
      "test(external) {\n"
      "  var str1 = new String.fromCharCodes(external);\n"
      "  var str2 = new String.fromCharCodes(new List.from(external));\n"
      "  if (str2 != str1) throw 'FAIL';\n"
      "  return str1;\n"
      "}\n"
      "testView8(external) {\n"
      "  return test(external.buffer.asUint8List());\n"
      "}\n"
      "testView16(external) {\n"
      "  return test(external.buffer.asUint16List());\n"
      "}\n";
  SetFlagScope<bool> sfs(&FLAG_verify_entry_points, false);
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);

  {
    uint8_t data[64];
    for (int i = 0; i < 64; i++) {
      data[i] = i * 4;
    }
    // LATIN-1 in external Uint8List.
    Dart_Handle external =
        Dart_NewExternalTypedData(Dart_TypedData_kUint8, data, 64);
    EXPECT_VALID(external);
    Dart_Handle dart_args[1];
    dart_args[0] = external;
    Dart_Handle result = Dart_Invoke(lib, NewString("test"), 1, dart_args);
    EXPECT_VALID(result);
    EXPECT(Dart_IsString(result));

    result = Dart_Invoke(lib, NewString("testView8"), 1, dart_args);
    EXPECT_VALID(result);
    EXPECT(Dart_IsString(result));
  }

  {
    uint16_t data[64];
    for (int i = 0; i < 64; i++) {
      data[i] = i * 4;
    }
    // LATIN-1 in external Uint16List.
    Dart_Handle external =
        Dart_NewExternalTypedData(Dart_TypedData_kUint16, data, 64);
    EXPECT_VALID(external);
    Dart_Handle dart_args[1];
    dart_args[0] = external;
    Dart_Handle result = Dart_Invoke(lib, NewString("test"), 1, dart_args);
    EXPECT_VALID(result);
    EXPECT(Dart_IsString(result));

    result = Dart_Invoke(lib, NewString("testView16"), 1, dart_args);
    EXPECT_VALID(result);
    EXPECT(Dart_IsString(result));
  }

  {
    uint16_t data[64];
    for (int i = 0; i < 64; i++) {
      data[i] = 0x2000 + i * 4;
    }
    // Non-LATIN-1 in external Uint16List.
    Dart_Handle external =
        Dart_NewExternalTypedData(Dart_TypedData_kUint16, data, 64);
    EXPECT_VALID(external);
    Dart_Handle dart_args[1];
    dart_args[0] = external;
    Dart_Handle result = Dart_Invoke(lib, NewString("test"), 1, dart_args);
    EXPECT_VALID(result);
    EXPECT(Dart_IsString(result));

    result = Dart_Invoke(lib, NewString("testView16"), 1, dart_args);
    EXPECT_VALID(result);
    EXPECT(Dart_IsString(result));
  }
}

#ifndef PRODUCT

TEST_CASE(DartAPI_TimelineDuration) {
  Isolate* isolate = Isolate::Current();
  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is enabled.
  stream->set_enabled(true);
  // Add a duration event.
  Dart_RecordTimelineEvent("testDurationEvent", 500, 1500, 0, nullptr,
                           Dart_Timeline_Event_Duration, 0, nullptr, nullptr);
  // Check that it is in the output.
  TimelineEventRecorder* recorder = Timeline::recorder();
  JSONStream js;
  IsolateTimelineEventFilter filter(isolate->main_port());
  recorder->PrintJSON(&js, &filter);
  const char* json = js.ToCString();
  EXPECT_SUBSTRING("\"name\":\"testDurationEvent\"", json);
  EXPECT_SUBSTRING("\"ph\":\"X\"", json);
  EXPECT_SUBSTRING("\"ts\":500", json);
  EXPECT_SUBSTRING("\"dur\":1000", json);
}

TEST_CASE(DartAPI_TimelineBegin) {
  Isolate* isolate = Isolate::Current();
  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is enabled.
  stream->set_enabled(true);
  // Add a begin event.
  Dart_RecordTimelineEvent("testBeginEvent", 1000, 1, 0, nullptr,
                           Dart_Timeline_Event_Begin, 0, nullptr, nullptr);
  // Check that it is in the output.
  TimelineEventRecorder* recorder = Timeline::recorder();
  JSONStream js;
  IsolateTimelineEventFilter filter(isolate->main_port());
  recorder->PrintJSON(&js, &filter);
  const char* json = js.ToCString();
  EXPECT_SUBSTRING("\"name\":\"testBeginEvent\"", json);
  EXPECT_SUBSTRING("\"ph\":\"B\"", json);
  EXPECT_SUBSTRING("\"ts\":1000", json);
}

TEST_CASE(DartAPI_TimelineEnd) {
  Isolate* isolate = Isolate::Current();
  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is enabled.
  stream->set_enabled(true);
  // Add a begin event.
  Dart_RecordTimelineEvent("testEndEvent", 1000, 1, 0, nullptr,
                           Dart_Timeline_Event_End, 0, nullptr, nullptr);
  // Check that it is in the output.
  TimelineEventRecorder* recorder = Timeline::recorder();
  JSONStream js;
  IsolateTimelineEventFilter filter(isolate->main_port());
  recorder->PrintJSON(&js, &filter);
  const char* json = js.ToCString();
  EXPECT_SUBSTRING("\"name\":\"testEndEvent\"", json);
  EXPECT_SUBSTRING("\"ph\":\"E\"", json);
  EXPECT_SUBSTRING("\"ts\":1000", json);
}

TEST_CASE(DartAPI_TimelineInstant) {
  Isolate* isolate = Isolate::Current();
  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is enabled.
  stream->set_enabled(true);
  Dart_RecordTimelineEvent("testInstantEvent", 1000, 1, 0, nullptr,
                           Dart_Timeline_Event_Instant, 0, nullptr, nullptr);
  // Check that it is in the output.
  TimelineEventRecorder* recorder = Timeline::recorder();
  JSONStream js;
  IsolateTimelineEventFilter filter(isolate->main_port());
  recorder->PrintJSON(&js, &filter);
  const char* json = js.ToCString();
  EXPECT_SUBSTRING("\"name\":\"testInstantEvent\"", json);
  EXPECT_SUBSTRING("\"ph\":\"i\"", json);
  EXPECT_SUBSTRING("\"ts\":1000", json);
}

TEST_CASE(DartAPI_TimelineAsyncDisabled) {
  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is disabled.
  stream->set_enabled(false);
  int64_t async_id = 99;
  Dart_RecordTimelineEvent("testAsyncEvent", 0, async_id, 0, nullptr,
                           Dart_Timeline_Event_Async_Begin, 0, nullptr,
                           nullptr);
  // Check that testAsync is not in the output.
  TimelineEventRecorder* recorder = Timeline::recorder();
  JSONStream js;
  TimelineEventFilter filter;
  recorder->PrintJSON(&js, &filter);
  EXPECT_NOTSUBSTRING("testAsyncEvent", js.ToCString());
}

TEST_CASE(DartAPI_TimelineAsync) {
  Isolate* isolate = Isolate::Current();
  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is enabled.
  stream->set_enabled(true);
  int64_t async_id = 99;
  Dart_RecordTimelineEvent("testAsyncEvent", 1000, async_id, 0, nullptr,
                           Dart_Timeline_Event_Async_Begin, 0, nullptr,
                           nullptr);

  // Check that it is in the output.
  TimelineEventRecorder* recorder = Timeline::recorder();
  JSONStream js;
  IsolateTimelineEventFilter filter(isolate->main_port());
  recorder->PrintJSON(&js, &filter);
  const char* json = js.ToCString();
  EXPECT_SUBSTRING("\"name\":\"testAsyncEvent\"", json);
  EXPECT_SUBSTRING("\"ph\":\"b\"", json);
  EXPECT_SUBSTRING("\"ts\":1000", json);
  EXPECT_SUBSTRING("\"id\":\"63\"", json);  // Hex for some reason.
}

#if defined(SUPPORT_PERFETTO) && !defined(PRODUCT)
TEST_CASE(DartAPI_TimelineAsyncInstantRace) {
  struct ReportAsyncEventArguments {
    Monitor& synchronization_monitor;
    ThreadJoinId join_id = OSThread::kInvalidThreadJoinId;
  };

  Monitor synchronization_monitor;
  ReportAsyncEventArguments report_async_event_1_arguments{
      synchronization_monitor};
  ReportAsyncEventArguments report_async_event_2_arguments{
      synchronization_monitor};
  TimelineEventRecorder& recorder = *Timeline::recorder();
  JSONStream js;
  TimelineEventFilter filter;

  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is enabled.
  stream->set_enabled(true);
  // Try concurrently writing async events and reading from the async track
  // metadata map. It is not possible to assert anything about the outcome,
  // because of scheduling uncertainty. This test is just used to ensure that
  // TSAN checks the async track metadata map code.
  OSThread::Start(
      "ReportAsyncEvent1",
      [](uword arguments_ptr) {
        ReportAsyncEventArguments& arguments =
            *reinterpret_cast<ReportAsyncEventArguments*>(arguments_ptr);
        Dart_RecordTimelineEvent("async1", /*timestamp0=*/0, /*async_id=*/1, 0,
                                 nullptr, Dart_Timeline_Event_Async_Instant,
                                 /*argument_count=*/0, nullptr, nullptr);
        MonitorLocker ml(&arguments.synchronization_monitor);
        arguments.join_id =
            OSThread::GetCurrentThreadJoinId(OSThread::Current());
        ml.Notify();
      },
      reinterpret_cast<uword>(&report_async_event_1_arguments));
  OSThread::Start(
      "ReportAsyncEvent2",
      [](uword arguments_ptr) {
        ReportAsyncEventArguments& arguments =
            *reinterpret_cast<ReportAsyncEventArguments*>(arguments_ptr);
        Dart_RecordTimelineEvent("async2", /*timestamp0=*/0, /*async_id=*/2, 0,
                                 nullptr, Dart_Timeline_Event_Async_Instant,
                                 /*argument_count=*/0, nullptr, nullptr);
        MonitorLocker ml(&arguments.synchronization_monitor);
        arguments.join_id =
            OSThread::GetCurrentThreadJoinId(OSThread::Current());
        ml.Notify();
      },
      reinterpret_cast<uword>(&report_async_event_2_arguments));
  recorder.PrintPerfettoTimeline(&js, filter);

  MonitorLocker ml(&synchronization_monitor);
  while (report_async_event_1_arguments.join_id ==
             OSThread::kInvalidThreadJoinId ||
         report_async_event_2_arguments.join_id ==
             OSThread::kInvalidThreadJoinId) {
    ml.Wait();
  }
  OSThread::Join(report_async_event_1_arguments.join_id);
  OSThread::Join(report_async_event_2_arguments.join_id);
}
#endif  // defined(SUPPORT_PERFETTO) && !defined(PRODUCT)

TEST_CASE(DartAPI_TimelineClock) {
  int64_t micros1 = Dart_TimelineGetMicros();
  int64_t ticks1 = Dart_TimelineGetTicks();
  int64_t frequency1 = Dart_TimelineGetTicksFrequency();
  OS::Sleep(1);
  int64_t micros2 = Dart_TimelineGetMicros();
  int64_t ticks2 = Dart_TimelineGetTicks();
  int64_t frequency2 = Dart_TimelineGetTicksFrequency();
  EXPECT_NE(micros1, micros2);
  EXPECT_NE(ticks1, ticks2);
  EXPECT_EQ(frequency1, frequency2);
}

TEST_CASE(DartAPI_TimelineCategories) {
  bool result;
  {
    result = Dart_SetEnabledTimelineCategory("all");
    EXPECT_EQ(true, result);
    JSONStream js;
    JSONObject obj(&js);
    JSONArray jstream(&obj, "available");
    Timeline::PrintFlagsToJSONArray(&jstream);
    const char* js_str = js.ToCString();
#define TIMELINE_STREAM_CHECK(name, ...) EXPECT_SUBSTRING(#name, js_str);
    TIMELINE_STREAM_LIST(TIMELINE_STREAM_CHECK)
#undef TIMELINE_STREAM_CHECK
  }

  {
    result = Dart_SetEnabledTimelineCategory(nullptr);
    EXPECT_EQ(false, result);
    result = Dart_SetEnabledTimelineCategory("GC,api,compiler");
    EXPECT_EQ(false, result);
  }

  {
    result = Dart_SetEnabledTimelineCategory("GC,API,Compiler");
    EXPECT_EQ(true, result);
    JSONStream js;
    JSONObject obj(&js);
    JSONArray jstream(&obj, "available");
    Timeline::PrintFlagsToJSONArray(&jstream);
    const char* js_str = js.ToCString();
    EXPECT_SUBSTRING("GC", js_str);
    EXPECT_SUBSTRING("API", js_str);
    EXPECT_SUBSTRING("Compiler", js_str);
    EXPECT_NOTSUBSTRING("CompilerVerbose", js_str);
    EXPECT_NOTSUBSTRING("Debugger", js_str);
    EXPECT_NOTSUBSTRING("Embedder", js_str);
    EXPECT_NOTSUBSTRING("Isolate", js_str);
    EXPECT_NOTSUBSTRING("Microtask", js_str);
    EXPECT_NOTSUBSTRING("VM", js_str);
  }

  {
    result = Dart_SetEnabledTimelineCategory("Isolate");
    EXPECT_EQ(true, result);
    JSONStream js;
    JSONObject obj(&js);
    JSONArray jstream(&obj, "available");
    Timeline::PrintFlagsToJSONArray(&jstream);
    const char* js_str = js.ToCString();
    EXPECT_NOTSUBSTRING("GC", js_str);
    EXPECT_NOTSUBSTRING("API", js_str);
    EXPECT_NOTSUBSTRING("Compiler", js_str);
    EXPECT_NOTSUBSTRING("CompilerVerbose", js_str);
    EXPECT_NOTSUBSTRING("Debugger", js_str);
    EXPECT_NOTSUBSTRING("Embedder", js_str);
    EXPECT_SUBSTRING("Isolate", js_str);
    EXPECT_NOTSUBSTRING("Microtask", js_str);
    EXPECT_NOTSUBSTRING("VM", js_str);
  }

  {
    result = Dart_SetEnabledTimelineCategory("");
    EXPECT_EQ(true, result);
    JSONStream js;
    JSONObject obj(&js);
    JSONArray jstream(&obj, "available");
    Timeline::PrintFlagsToJSONArray(&jstream);
    const char* js_str = js.ToCString();
    EXPECT_NOTSUBSTRING("GC", js_str);
    EXPECT_NOTSUBSTRING("API", js_str);
    EXPECT_NOTSUBSTRING("Compiler", js_str);
    EXPECT_NOTSUBSTRING("CompilerVerbose", js_str);
    EXPECT_NOTSUBSTRING("Debugger", js_str);
    EXPECT_NOTSUBSTRING("Embedder", js_str);
    EXPECT_NOTSUBSTRING("Isolate", js_str);
    EXPECT_NOTSUBSTRING("Microtask", js_str);
    EXPECT_NOTSUBSTRING("VM", js_str);
  }
}

static void NotifyIdleShortNative(Dart_NativeArguments args) {
  Dart_NotifyIdle(Dart_TimelineGetMicros() + 10 * kMicrosecondsPerMillisecond);
}

static Dart_NativeFunction NotifyIdleShort_native_lookup(
    Dart_Handle name,
    int argument_count,
    bool* auto_setup_scope) {
  return NotifyIdleShortNative;
}

TEST_CASE(DartAPI_NotifyIdleShort) {
  const char* kScriptChars = R"(
@pragma("vm:external-name", "Test_nativeFunc")
external void notifyIdle();
void main() {
  var v;
  for (var i = 0; i < 100; i++) {
    var t = [];
    for (var j = 0; j < 10000; j++) {
      t.add(List.filled(100, null));
    }
    v = t;
    notifyIdle();
  }
})";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &NotifyIdleShort_native_lookup);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

static void NotifyIdleLongNative(Dart_NativeArguments args) {
  Dart_NotifyIdle(Dart_TimelineGetMicros() + 100 * kMicrosecondsPerMillisecond);
}

static Dart_NativeFunction NotifyIdleLong_native_lookup(
    Dart_Handle name,
    int argument_count,
    bool* auto_setup_scope) {
  return NotifyIdleLongNative;
}

TEST_CASE(DartAPI_NotifyIdleLong) {
  const char* kScriptChars = R"(
@pragma("vm:external-name", "Test_nativeFunc")
external void notifyIdle();
void main() {
  var v;
  for (var i = 0; i < 100; i++) {
    var t = [];
    for (var j = 0; j < 10000; j++) {
      t.add(List.filled(100, null));
    }
    v = t;
    notifyIdle();
  }
}
)";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &NotifyIdleLong_native_lookup);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

static void NotifyDestroyedNative(Dart_NativeArguments args) {
  Dart_NotifyDestroyed();
}

static Dart_NativeFunction NotifyDestroyed_native_lookup(
    Dart_Handle name,
    int argument_count,
    bool* auto_setup_scope) {
  return NotifyDestroyedNative;
}

TEST_CASE(DartAPI_NotifyDestroyed) {
  const char* kScriptChars = R"(
import 'dart:isolate';
@pragma("vm:external-name", "Test_nativeFunc")
external void notifyDetach();
void main() {
  var v;
  for (var i = 0; i < 100; i++) {
    var t = [];
    for (var j = 0; j < 10000; j++) {
      t.add(List.filled(100, null));
    }
    v = t;
    notifyDetach();
  }
})";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &NotifyDestroyed_native_lookup);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

static void SetPerformanceModeDefault(Dart_NativeArguments args) {
  Dart_SetPerformanceMode(Dart_PerformanceMode_Default);
}
static void SetPerformanceModeLatency(Dart_NativeArguments args) {
  Dart_SetPerformanceMode(Dart_PerformanceMode_Latency);
}

static Dart_NativeFunction SetMode_native_lookup(Dart_Handle name,
                                                 int argument_count,
                                                 bool* auto_setup_scope) {
  const char* cstr = nullptr;
  Dart_StringToCString(name, &cstr);
  if (strcmp(cstr, "SetPerformanceModeDefault") == 0) {
    return SetPerformanceModeDefault;
  } else if (strcmp(cstr, "SetPerformanceModeLatency") == 0) {
    return SetPerformanceModeLatency;
  }
  return nullptr;
}

TEST_CASE(DartAPI_SetPerformanceMode) {
  const char* kScriptChars = R"(
import "dart:typed_data";
@pragma("vm:external-name", "SetPerformanceModeDefault")
external void setPerformanceModeDefault();
@pragma("vm:external-name", "SetPerformanceModeLatency")
external void setPerformanceModeLatency();
void main() {
  for (var i = 0; i < 10; i++) {
    setPerformanceModeLatency();
    var t = [];
    for (var j = 0; j < 32; j++) {
      t.add(Uint8List(1000000));
    }
    setPerformanceModeDefault();
  }
}
)";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &SetMode_native_lookup);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

static void NotifyLowMemoryNative(Dart_NativeArguments args) {
  Dart_NotifyLowMemory();
}

static Dart_NativeFunction NotifyLowMemory_native_lookup(
    Dart_Handle name,
    int argument_count,
    bool* auto_setup_scope) {
  return NotifyLowMemoryNative;
}

TEST_CASE(DartAPI_NotifyLowMemory) {
  const char* kScriptChars = R"(
import 'dart:isolate';
@pragma("vm:external-name", "Test_nativeFunc")
external void notifyLowMemory();
void main() {
  var v;
  for (var i = 0; i < 100; i++) {
    var t = [];
    for (var j = 0; j < 10000; j++) {
      t.add(List.filled(100, null));
    }
    v = t;
    notifyLowMemory();
  }
})";
  Dart_Handle lib =
      TestCase::LoadTestScript(kScriptChars, &NotifyLowMemory_native_lookup);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

// There exists another test by name DartAPI_Invoke_CrossLibrary.
// However, that currently fails for the dartk configuration as it
// uses Dart_LoadLibrary. This test here effectively tests the same
// functionality but invokes a function from an imported standard
// library.
TEST_CASE(DartAPI_InvokeImportedFunction) {
  const char* kScriptChars =
      "import 'dart:math';\n"
      "import 'dart:developer';\n"
      "main() {}";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle max = Dart_NewStringFromCString("max");

  Dart_Handle args[2] = {Dart_NewInteger(123), Dart_NewInteger(321)};
  Dart_Handle result = Dart_Invoke(lib, max, 2, args);
  EXPECT_ERROR(result,
               "NoSuchMethodError: No top-level method 'max' declared.");

  Dart_Handle getCurrentTag = Dart_NewStringFromCString("getCurrentTag");
  result = Dart_Invoke(lib, getCurrentTag, 0, nullptr);
  EXPECT_ERROR(
      result,
      "NoSuchMethodError: No top-level method 'getCurrentTag' declared.");
}

TEST_CASE(DartAPI_InvokeVMServiceMethod) {
  char buffer[1024];
  Utils::SNPrint(buffer, sizeof(buffer),
                 R"({
                  "jsonrpc": 2.0,
                  "id": "foo",
                  "method": "getVM",
                  "params": { }
                 })");
  uint8_t* response_json = nullptr;
  intptr_t response_json_length = 0;
  char* error = nullptr;
  const bool success = Dart_InvokeVMServiceMethod(
      reinterpret_cast<uint8_t*>(buffer), strlen(buffer), &response_json,
      &response_json_length, &error);
  EXPECT(success);
  EXPECT(error == nullptr);

  Dart_Handle bytes = Dart_NewExternalTypedDataWithFinalizer(
      Dart_TypedData_kUint8, response_json, response_json_length, response_json,
      response_json_length, [](void* ignored, void* peer) { free(peer); });
  EXPECT_VALID(bytes);

  // We don't have a C++ JSON decoder so we'll invoke dart to validate the
  // result.
  const char* kScript =
      R"(
        import 'dart:convert';
        import 'dart:typed_data';
        bool validate(bool condition) {
          if (!condition) {
            throw 'Failed to validate InvokeVMServiceMethod() response.';
          }
          return false;
        }
        @pragma('vm:entry-point', 'call')
        bool validateResult(Uint8List bytes) {
          final map = json.decode(utf8.decode(bytes));
          validate(map['jsonrpc'] == '2.0');
          validate(map['id'] == 'foo');
          validate(map['result']['name'] == 'vm');
          validate(map['result']['type'] == 'VM');
          validate(map['result'].containsKey('architectureBits'));
          validate(map['result'].containsKey('pid'));
          validate(map['result'].containsKey('startTime'));
          validate(map['result'].containsKey('hostCPU'));
          validate(map['result'].containsKey('targetCPU'));
          validate(map['result'].containsKey('version'));
          return true;
        }
      )";

  Dart_Handle lib = TestCase::LoadTestScript(kScript, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle result = Dart_Invoke(lib, NewString("validateResult"), 1, &bytes);
  EXPECT(Dart_IsBoolean(result));
  EXPECT(result == Dart_True());
}

static Monitor* loop_test_lock = new Monitor();
static bool loop_test_exit = false;
static bool loop_reset_count = false;

#if !defined(PRODUCT)
static void InvokeServiceMessages(uword param) {
  char buffer[1024];
  Utils::SNPrint(buffer, sizeof(buffer),
                 R"({
                  "jsonrpc": 2.0,
                  "id": "foo",
                  "method": "getVM",
                  "params": { }
                 })");
  uint8_t* response_json = nullptr;
  intptr_t response_json_length = 0;
  char* error = nullptr;
  uint32_t count = 0;
  do {
    error = nullptr;
    response_json = nullptr;
    response_json_length = 0;
    const bool success = Dart_InvokeVMServiceMethod(
        reinterpret_cast<uint8_t*>(buffer), strlen(buffer), &response_json,
        &response_json_length, &error);
    if (success) {
      MonitorLocker ml(loop_test_lock);
      EXPECT(error == nullptr);
      free(response_json);
      if (count == 10) {
        loop_test_exit = true;
        ml.Notify();
      }
      count++;
    } else {
      free(error);
    }
  } while (count < 100);
}

TEST_CASE(DartAPI_InvokeVMServiceMethod_Loop) {
  MonitorLocker ml(loop_test_lock);
  loop_test_exit = false;
  loop_reset_count = false;
  OSThread::Start("InvokeServiceMessages", InvokeServiceMessages, 0);
  while (!loop_test_exit) {
    ml.Wait();
  }
}
#endif  // !defined(PRODUCT)

static void HandleResponse(Dart_Port dest_port_id, Dart_CObject* message) {
  printf("Response received\n");
}

static void CreateNativePorts(uword param) {
  uint32_t count = 0;
  do {
    const Dart_Port port_id = Dart_NewNativePort("tst", &HandleResponse, false);
    if (port_id != ILLEGAL_PORT) {
      Dart_CloseNativePort(port_id);
      MonitorLocker ml(loop_test_lock);
      if (count == 10) {
        loop_test_exit = true;
        ml.Notify();
      }
      count++;
    }
  } while (count < 100);
}

TEST_CASE(DartAPI_NativePort_Loop) {
  MonitorLocker ml(loop_test_lock);
  loop_test_exit = false;
  loop_reset_count = false;
  OSThread::Start("NativePort", CreateNativePorts, 0);
  while (!loop_test_exit) {
    ml.Wait();
  }
}

#if !defined(PRODUCT)
static void ReportTimelineEvents() {
  intptr_t flow_id_count = 1;
  const int64_t flow_ids[1] = {123};

  Dart_RecordTimelineEvent("T1", 0, 1, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Begin, 0, nullptr, nullptr);
  Dart_RecordTimelineEvent("T1", 10, 1, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_End, /*argument_count=*/0,
                           nullptr, nullptr);

  Dart_RecordTimelineEvent("T2", 20, 2, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Instant, /*argument_count=*/0,
                           nullptr, nullptr);

  Dart_RecordTimelineEvent("T3", 30, /*timestamp1_or_id=*/40,
                           /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Duration,
                           /*argument_count=*/0, nullptr, nullptr);

  Dart_RecordTimelineEvent("T4", 50, 4, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Async_Begin,
                           /*argument_count=*/0, nullptr, nullptr);
  Dart_RecordTimelineEvent("T4", 60, 4, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Async_End, /*argument_count=*/0,
                           nullptr, nullptr);

  Dart_RecordTimelineEvent("T5", 70, 5, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Async_Instant,
                           /*argument_count=*/0, nullptr, nullptr);

  Dart_RecordTimelineEvent("T6", 80, -1, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Counter, /*argument_count=*/0,
                           nullptr, nullptr);

  Dart_RecordTimelineEvent("T7", 90, 7, flow_id_count, flow_ids,
                           Dart_Timeline_Event_Begin, /*argument_count=*/0,
                           nullptr, nullptr);
  Dart_RecordTimelineEvent("F", 90, 10, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Flow_Begin,
                           /*argument_count=*/0, nullptr, nullptr);
  Dart_RecordTimelineEvent("T7", 100, 7, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_End, /*argument_count=*/0,
                           nullptr, nullptr);

  Dart_RecordTimelineEvent("T8", 110, 8, flow_id_count, flow_ids,
                           Dart_Timeline_Event_Begin, 0, nullptr, nullptr);
  Dart_RecordTimelineEvent("F", 110, 10, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Flow_Step,
                           /*argument_count=*/0, nullptr, nullptr);
  Dart_RecordTimelineEvent("T8", 120, 8, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_End, /*argument_count=*/0,
                           nullptr, nullptr);

  Dart_RecordTimelineEvent("T9", 130, 9, flow_id_count, flow_ids,
                           Dart_Timeline_Event_Begin, /*argument_count=*/0,
                           nullptr, nullptr);
  Dart_RecordTimelineEvent("F", 130, 10, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Flow_End,
                           /*argument_count=*/0, nullptr, nullptr);
  Dart_RecordTimelineEvent("T9", 140, 9, /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_End, /*argument_count=*/0,
                           nullptr, nullptr);
}

TEST_CASE(DartAPI_TimelineEvents_Serialization) {
  // We do not check the contents of the JSON output here because we have
  // pkg/vm_service/test/get_perfetto_vm_timeline_rpc_test.dart for that.
  // This test is used to ensure that assertions in timeline code are checked
  // by debug tryjobs, and that the sanitizers run on the timeline code.

  // Grab embedder stream.
  TimelineStream* stream = Timeline::GetEmbedderStream();
  // Make sure it is enabled.
  stream->set_enabled(true);

  ReportTimelineEvents();
  TimelineEventRecorder* recorder = Timeline::recorder();
  JSONStream js_chrome_timeline;
  JSONStream js_perfetto_timeline;
  TimelineEventFilter filter;
  recorder->PrintJSON(&js_chrome_timeline, &filter);
#if defined(SUPPORT_PERFETTO)
  recorder->PrintPerfettoTimeline(&js_perfetto_timeline, filter);
#endif  // defined(SUPPORT_PERFETTO)
}

static void CreateTimelineEvents(uword param) {
  {
    MonitorLocker ml(loop_test_lock);
    loop_test_exit = true;
    ml.Notify();
  }
  do {
    ReportTimelineEvents();
  } while (true);
}

UNIT_TEST_CASE(DartAPI_TimelineEvents_Loop) {
  EXPECT(Dart_SetVMFlags(TesterState::argc, TesterState::argv) == nullptr);
  FLAG_complete_timeline = true;
  Dart_InitializeParams params;
  memset(&params, 0, sizeof(Dart_InitializeParams));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.vm_snapshot_data = TesterState::vm_snapshot_data;
  params.create_group = TesterState::create_callback;
  params.shutdown_isolate = TesterState::shutdown_callback;
  params.cleanup_group = TesterState::group_cleanup_callback;
  params.start_kernel_isolate = true;
  char* result = nullptr;

  result = Dart_Initialize(&params);
  EXPECT(result == nullptr);
  {
    MonitorLocker ml(loop_test_lock);
    loop_test_exit = false;
    loop_reset_count = false;
    OSThread::Start("TimelineEvents", CreateTimelineEvents, 0);
    while (!loop_test_exit) {
      printf("VM waiting for notification\n");
      ml.Wait();
    }
    loop_test_exit = false;
  }
  result = Dart_Cleanup();
  EXPECT(result == nullptr);
  for (intptr_t i = 0; i < 50; i++) {
    EXPECT(Dart_SetVMFlags(TesterState::argc, TesterState::argv) == nullptr);
    result = Dart_Initialize(&params);
    EXPECT(result == nullptr);
    result = Dart_Cleanup();
    EXPECT(result == nullptr);
  }
}

UNIT_TEST_CASE(DartAPI_TimelineEvents_NullFlowIdsHandledGracefully) {
  Dart_RecordTimelineEvent("T1", 0, 10, /*flow_id_count=*/1, nullptr,
                           Dart_Timeline_Event_Duration, /*argument_count=*/0,
                           nullptr, nullptr);
}
#endif  // !defined(PRODUCT)

static intptr_t EchoInt(double x) {
  return x;
}

static void* FfiNativeResolver(const char* name, uintptr_t args_n) {
  ASSERT(strcmp(name, "EchoInt") == 0);
  ASSERT(args_n == 1);
  return reinterpret_cast<void*>(EchoInt);
}

TEST_CASE(Dart_SetFfiNativeResolver) {
  const char* kScriptChars = R"(
    import 'dart:ffi';
    @Native<IntPtr Function(Double)>(symbol: 'EchoInt', isLeaf:true)
    external int echoInt(double x);
    main() => echoInt(7.0);
    )";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle result = Dart_SetFfiNativeResolver(lib, &FfiNativeResolver);
  EXPECT_VALID(result);

  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);

  int64_t value = 0;
  result = Dart_IntegerToInt64(result, &value);
  EXPECT_VALID(result);
  EXPECT_EQ(7, value);
}

TEST_CASE(Dart_SetFfiNativeResolver_MissingResolver) {
  const char* kScriptChars = R"(
    import 'dart:ffi';
    @Native<IntPtr Function(Double)>(symbol: 'EchoInt', isLeaf:true)
    external int echoInt(double x);
    main() => echoInt(7.0);
    )";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);

  // With no resolver, we resolve in process. Expect to not find the symbol
  // in processes. Error message depends on architecture.
  EXPECT_ERROR(result, "Invalid argument(s):");
}

static void* NopResolver(const char* name, uintptr_t args_n) {
  return nullptr;
}

TEST_CASE(Dart_SetFfiNativeResolver_DoesNotResolve) {
  const char* kScriptChars = R"(
    import 'dart:ffi';
    @Native<Void Function()>(symbol: 'DoesNotResolve')
    external void doesNotResolve();
    main() => doesNotResolve();
    )";
  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  Dart_Handle result = Dart_SetFfiNativeResolver(lib, &NopResolver);
  EXPECT_VALID(result);

  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_ERROR(result, "Couldn't resolve function: 'DoesNotResolve'");
}

TEST_CASE(DartAPI_UserTags) {
  Dart_Handle default_tag = Dart_GetDefaultUserTag();
  EXPECT_VALID(default_tag);

  CStringUniquePtr default_label(Dart_GetUserTagLabel(default_tag));
  EXPECT_STREQ(default_label.get(), "Default");

  Dart_Handle current_tag = Dart_GetCurrentUserTag();
  EXPECT(Dart_IdentityEquals(default_tag, current_tag));

  CStringUniquePtr current_label(Dart_GetUserTagLabel(current_tag));
  EXPECT_STREQ(default_label.get(), current_label.get());

  Dart_Handle new_tag = Dart_NewUserTag("Foo");
  EXPECT_VALID(new_tag);

  CStringUniquePtr new_tag_label(Dart_GetUserTagLabel(new_tag));
  EXPECT_STREQ(new_tag_label.get(), "Foo");

  Dart_Handle old_tag = Dart_SetCurrentUserTag(new_tag);
  EXPECT_VALID(old_tag);

  CStringUniquePtr old_label(Dart_GetUserTagLabel(old_tag));
  EXPECT_STREQ(old_label.get(), default_label.get());

  current_tag = Dart_GetCurrentUserTag();
  EXPECT(Dart_IdentityEquals(new_tag, current_tag));

  current_label.reset(Dart_GetUserTagLabel(current_tag));
  EXPECT_STREQ(current_label.get(), new_tag_label.get());

  EXPECT(Dart_GetUserTagLabel(Dart_Null()) == nullptr);

  EXPECT_ERROR(Dart_NewUserTag(nullptr),
               "Dart_NewUserTag expects argument 'label' to be non-null");

  EXPECT_ERROR(
      Dart_SetCurrentUserTag(Dart_Null()),
      "Dart_SetCurrentUserTag expects argument 'user_tag' to be non-null");
}

#endif  // !PRODUCT

#if !defined(PRODUCT) || defined(FORCE_INCLUDE_SAMPLING_HEAP_PROFILER)

static void* last_allocation_context = nullptr;
static const char* last_allocation_cls = nullptr;
static intptr_t heap_samples = 0;
static const char* expected_allocation_cls = nullptr;
static bool found_allocation = false;

static void* HeapSamplingCreate(Dart_Isolate isolate,
                                Dart_IsolateGroup isolate_group,
                                const char* cls_name,
                                intptr_t heap_size) {
  last_allocation_cls = cls_name;
  return strdup(cls_name);
}

static void HeapSamplingDelete(void* data) {
  free(data);
}

void HeapSamplingReport(void* context, void* data) {
  last_allocation_context = context;
  if (strcmp(reinterpret_cast<char*>(data), expected_allocation_cls) == 0) {
    found_allocation = true;
  }
  heap_samples++;
}

void ResetHeapSamplingState(const char* expected_cls = nullptr) {
  heap_samples = 0;
  expected_allocation_cls = expected_cls;
  found_allocation = false;
  last_allocation_context = nullptr;
  last_allocation_cls = nullptr;
}

// Threads won't pick up heap sampling profiler state changes until they
// process outstanding VM interrupts. Invoke this method after calling
// any of the following APIs in a test to ensure changes are applied:
//
//  - Dart_EnableHeapSampling()
//  - Dart_DisableHeapSampling()
//  - Dart_SetHeapSamplingPeriod(...)
void HandleInterrupts(Thread* thread) {
  TransitionNativeToVM transition(thread);
  thread->HandleInterrupts();
}

void InitHeapSampling(Thread* thread, const char* expected_cls) {
  ResetHeapSamplingState(expected_cls);
  Dart_RegisterHeapSamplingCallback(HeapSamplingCreate, HeapSamplingDelete);
  Dart_EnableHeapSampling();
  // Start with sampling on every byte allocated.
  Dart_SetHeapSamplingPeriod(1);
  HandleInterrupts(thread);
}

TEST_CASE(DartAPI_HeapSampling_UserDefinedClass) {
  DisableBackgroundCompilationScope scope;
  const char* kScriptChars = R"(
    class Bar {}
    final list = [];
    @pragma('vm:entry-point', 'call')
    foo() {
      for (int i = 0; i < 100000; ++i) {
        list.add(Bar());
      }
    }
    )";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  InitHeapSampling(thread, "Bar");
  Dart_Handle result = Dart_Invoke(lib, NewString("foo"), 0, nullptr);
  EXPECT_VALID(result);

  // Exit the isolate before getting the profile.
  Dart_Isolate isolate = Dart_CurrentIsolate();
  Dart_ExitIsolate();

  void* context = reinterpret_cast<void*>(42);  // Fake data, not used.
  Dart_ReportSurvivingAllocations(HeapSamplingReport, context,
                                  /*force_gc=*/true);
  EXPECT(heap_samples > 0);
  EXPECT(heap_samples < 100000);
  EXPECT(last_allocation_context == context);
  EXPECT(found_allocation);
  Dart_EnterIsolate(isolate);
}

TEST_CASE(DartAPI_HeapSampling_APIAllocations) {
  InitHeapSampling(thread, "List");

  // Some simple allocations
  EXPECT_VALID(Dart_NewList(100));

  // Exit the isolate before getting the profile.
  Dart_Isolate isolate = Dart_CurrentIsolate();
  EXPECT(isolate != nullptr);
  Dart_ExitIsolate();

  Dart_ReportSurvivingAllocations(HeapSamplingReport, nullptr,
                                  /*force_gc=*/true);
  EXPECT(heap_samples > 0);
#if !defined(PRODUCT)
  EXPECT_STREQ("List", last_allocation_cls);
  ResetHeapSamplingState("String");
#else
  EXPECT_STREQ("_List", last_allocation_cls);
  ResetHeapSamplingState("_OneByteString");
#endif

  // Re-enter the isolate.
  Dart_EnterIsolate(isolate);

  const intptr_t kNumAllocations = 1000;
  for (intptr_t i = 0; i < kNumAllocations; ++i) {
    EXPECT_VALID(AllocateOldString("str"));
  }

  // Exit the isolate after performing allocations.
  Dart_ExitIsolate();

  Dart_ReportSurvivingAllocations(HeapSamplingReport, nullptr,
                                  /*force_gc=*/true);
  EXPECT(heap_samples > 0);
  EXPECT(found_allocation);

#if !defined(PRODUCT)
  ResetHeapSamplingState("String");
#else
  ResetHeapSamplingState("_OneByteString");
#endif

  // Re-enter the isolate.
  Dart_EnterIsolate(isolate);

  EXPECT_VALID(Dart_NewStringFromCString("Foo"));

  // Exit the isolate after performing allocations.
  Dart_ExitIsolate();

  Dart_ReportSurvivingAllocations(HeapSamplingReport, nullptr,
                                  /*force_gc=*/true);
  EXPECT(heap_samples > 0);
  EXPECT(found_allocation);

  ResetHeapSamplingState("Uint8List");

  // Re-enter the isolate.
  Dart_EnterIsolate(isolate);

  EXPECT_VALID(Dart_NewTypedData(Dart_TypedData_kUint8, 1000000));

  // Exit the isolate after performing allocations.
  Dart_ExitIsolate();

  Dart_ReportSurvivingAllocations(HeapSamplingReport, nullptr,
                                  /*force_gc=*/true);
  EXPECT(heap_samples > 0);
  EXPECT(found_allocation);

  Dart_EnterIsolate(isolate);
}

TEST_CASE(DartAPI_HeapSampling_NonTrivialSamplingPeriod) {
  DisableBackgroundCompilationScope scope;
  InitHeapSampling(thread, "List");

  // Increase the sampling period and check that we don't sample each
  // allocation. This should cause samples to be collected for approximately
  // every 1KiB allocated.
  Dart_SetHeapSamplingPeriod(1 << 10);
  HandleInterrupts(thread);

  // Allocate via the embedding API.
  const intptr_t kNumAllocations = 1000;
  for (intptr_t i = 0; i < kNumAllocations; ++i) {
    EXPECT_VALID(Dart_NewList(10));
  }

  // Exit the isolate before getting the profile.
  Dart_Isolate isolate = Dart_CurrentIsolate();
  EXPECT(isolate != nullptr);
  Dart_ExitIsolate();

  Dart_ReportSurvivingAllocations(HeapSamplingReport, nullptr,
                                  /*force_gc=*/true);
  EXPECT(heap_samples > 0);
  EXPECT(heap_samples < kNumAllocations);

  // Re-enter the isolate.
  Dart_EnterIsolate(isolate);

  const char* kScriptChars = R"(
    final list = [];
    @pragma('vm:entry-point', 'call')
    foo() {
      for (int i = 0; i < 1000; ++i) {
        list.add(List.filled(100, 0));
      }
    }
    )";
  Dart_DisableHeapSampling();
  HandleInterrupts(thread);

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  EXPECT_VALID(lib);

  ResetHeapSamplingState("List");

  Dart_EnableHeapSampling();
  HandleInterrupts(thread);

  // Allocate via Dart code.
  Dart_Handle result = Dart_Invoke(lib, NewString("foo"), 0, nullptr);
  EXPECT_VALID(result);

  // Exit the isolate after performing allocations.
  Dart_ExitIsolate();

  Dart_ReportSurvivingAllocations(HeapSamplingReport, nullptr,
                                  /*force_gc=*/true);
  EXPECT(heap_samples > 0);
  EXPECT(heap_samples < kNumAllocations);

  Dart_EnterIsolate(isolate);
  Dart_DisableHeapSampling();
}

// Check that we set correct sampling interval for old space allocations
// during initial isolate startup (before the first TLAB is created).
// This is a regression test for a bug that was causing each old space
// allocation to be sampled.
VM_UNIT_TEST_CASE(
    DartAPI_HeapSampling_CorrectSamplingIntervalForOldSpaceAllocations) {
  Dart_RegisterHeapSamplingCallback(
      [](Dart_Isolate isolate, Dart_IsolateGroup isolate_group,
         const char* cls_name, intptr_t allocation_size) -> void* {
        // Should not be called because sampling interval is very large.
        UNREACHABLE();
        return nullptr;
      },
      [](void* data) {
        // Nothing to do.
      });
  Dart_SetHeapSamplingPeriod(1 * GB);
  Dart_EnableHeapSampling();
  TestCase::CreateTestIsolate();
  Dart_DisableHeapSampling();
  Dart_ShutdownIsolate();
}
#endif  // !defined(PRODUCT) || defined(FORCE_INCLUDE_SAMPLING_HEAP_PROFILER)

#if defined(DART_ENABLE_HEAP_SNAPSHOT_WRITER)
TEST_CASE(DartAPI_WriteHeapSnapshot) {
  struct WriterContext {
    intptr_t bytes_written;
    bool saw_last_chunk;
  };

  WriterContext context = {0, false};
  char* error = Dart_WriteHeapSnapshot(
      [](void* context, uint8_t* buffer, intptr_t size, bool is_last) {
        auto ctx = static_cast<WriterContext*>(context);
        ctx->bytes_written += size;
        EXPECT(!ctx->saw_last_chunk);
        ctx->saw_last_chunk = is_last;

        free(buffer);
      },
      &context);
  EXPECT(error == nullptr);
  EXPECT_GT(context.bytes_written, 0);
  EXPECT(context.saw_last_chunk);
}
#endif  // defined(DART_ENABLE_HEAP_SNAPSHOT_WRITER)

}  // namespace dart
