// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/stack_frame.h"
#include "include/dart_api.h"
#include "platform/assert.h"
#include "vm/class_finalizer.h"
#include "vm/compiler/jit/compiler.h"
#include "vm/dart_api_impl.h"
#include "vm/dart_entry.h"
#include "vm/heap/verifier.h"
#include "vm/resolver.h"
#include "vm/unit_test.h"
#include "vm/zone.h"

namespace dart {

// Unit test for empty stack frame iteration.
ISOLATE_UNIT_TEST_CASE(EmptyStackFrameIteration) {
  StackFrameIterator iterator(ValidationPolicy::kValidateFrames,
                              Thread::Current(),
                              StackFrameIterator::kNoCrossThreadIteration);
  EXPECT(!iterator.HasNextFrame());
  EXPECT(iterator.NextFrame() == nullptr);
  VerifyPointersVisitor::VerifyPointers("EmptyStackFrameIterationTest");
}

// Unit test for empty dart stack frame iteration.
ISOLATE_UNIT_TEST_CASE(EmptyDartStackFrameIteration) {
  DartFrameIterator iterator(Thread::Current(),
                             StackFrameIterator::kNoCrossThreadIteration);
  EXPECT(iterator.NextFrame() == nullptr);
  VerifyPointersVisitor::VerifyPointers("EmptyDartStackFrameIterationTest");
}

#define FUNCTION_NAME(name) StackFrame_##name
#define REGISTER_FUNCTION(name, count) {"" #name, FUNCTION_NAME(name), count},

void FUNCTION_NAME(StackFrame_equals)(Dart_NativeArguments args) {
  NativeArguments* arguments = reinterpret_cast<NativeArguments*>(args);
  TransitionNativeToVM transition(arguments->thread());
  Zone* zone = arguments->thread()->zone();
  const Instance& expected =
      Instance::CheckedHandle(zone, arguments->NativeArgAt(0));
  const Instance& actual =
      Instance::CheckedHandle(zone, arguments->NativeArgAt(1));
  if (!expected.OperatorEquals(actual)) {
    OS::PrintErr("expected: '%s' actual: '%s'\n", expected.ToCString(),
                 actual.ToCString());
    EXPECT(false);
  }
}

void FUNCTION_NAME(StackFrame_frameCount)(Dart_NativeArguments args) {
  NativeArguments* arguments = reinterpret_cast<NativeArguments*>(args);
  TransitionNativeToVM transition(arguments->thread());
  int count = 0;
  StackFrameIterator frames(ValidationPolicy::kValidateFrames,
                            arguments->thread(),
                            StackFrameIterator::kNoCrossThreadIteration);
  while (frames.NextFrame() != nullptr) {
    count += 1;  // Count the frame.
  }
  VerifyPointersVisitor::VerifyPointers("StackFrame_frameCount_Test");
  arguments->SetReturn(Object::Handle(Smi::New(count)));
}

void FUNCTION_NAME(StackFrame_dartFrameCount)(Dart_NativeArguments args) {
  TransitionNativeToVM transition(Thread::Current());
  int count = 0;
  DartFrameIterator frames(Thread::Current(),
                           StackFrameIterator::kNoCrossThreadIteration);
  while (frames.NextFrame() != nullptr) {
    count += 1;  // Count the dart frame.
  }
  VerifyPointersVisitor::VerifyPointers("StackFrame_dartFrameCount_Test");
  NativeArguments* arguments = reinterpret_cast<NativeArguments*>(args);
  arguments->SetReturn(Object::Handle(Smi::New(count)));
}

void FUNCTION_NAME(StackFrame_validateFrame)(Dart_NativeArguments args) {
  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();

  Dart_Handle index = Dart_GetNativeArgument(args, 0);
  Dart_Handle name = Dart_GetNativeArgument(args, 1);

  TransitionNativeToVM transition(thread);
  const Smi& frame_index_smi =
      Smi::CheckedHandle(zone, Api::UnwrapHandle(index));
  const char* expected_name =
      String::CheckedHandle(zone, Api::UnwrapHandle(name)).ToCString();
  int frame_index = frame_index_smi.Value();
  int count = 0;
  DartFrameIterator frames(thread, StackFrameIterator::kNoCrossThreadIteration);
  StackFrame* frame = frames.NextFrame();
  while (frame != nullptr) {
    if (count == frame_index) {
      // Find the function corresponding to this frame and check if it
      // matches the function name passed in.
      const Function& function =
          Function::Handle(zone, frame->LookupDartFunction());
      if (function.IsNull()) {
        FATAL("StackFrame_validateFrame fails, invalid dart frame.\n");
      }
      const char* name = function.ToFullyQualifiedCString();
      // Currently all unit tests are loaded as being part of dart:core-lib.
      String& url = String::Handle(zone, String::New(TestCase::url()));
      const Library& lib =
          Library::Handle(zone, Library::LookupLibrary(thread, url));
      ASSERT(!lib.IsNull());
      const char* lib_name = String::Handle(zone, lib.url()).ToCString();
      char* full_name = OS::SCreate(zone, "%s_%s", lib_name, expected_name);
      EXPECT_STREQ(full_name, name);
      return;
    }
    count += 1;  // Count the dart frames.
    frame = frames.NextFrame();
  }
  FATAL("StackFrame_validateFrame fails, frame count < index passed in.\n");
}

// List all native functions implemented in the vm or core boot strap dart
// libraries so that we can resolve the native function to it's entry
// point.
#define STACKFRAME_NATIVE_LIST(V)                                              \
  V(StackFrame_equals, 2)                                                      \
  V(StackFrame_frameCount, 0)                                                  \
  V(StackFrame_dartFrameCount, 0)                                              \
  V(StackFrame_validateFrame, 2)

static struct NativeEntries {
  const char* name_;
  Dart_NativeFunction function_;
  int argument_count_;
} BuiltinEntries[] = {STACKFRAME_NATIVE_LIST(REGISTER_FUNCTION)};

static Dart_NativeFunction native_lookup(Dart_Handle name,
                                         int argument_count,
                                         bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = false;
  TransitionNativeToVM transition(Thread::Current());
  const Object& obj = Object::Handle(Api::UnwrapHandle(name));
  ASSERT(obj.IsString());
  const char* function_name = obj.ToCString();
  ASSERT(function_name != nullptr);
  int num_entries = sizeof(BuiltinEntries) / sizeof(struct NativeEntries);
  for (int i = 0; i < num_entries; i++) {
    struct NativeEntries* entry = &(BuiltinEntries[i]);
    if ((strcmp(function_name, entry->name_) == 0) &&
        (entry->argument_count_ == argument_count)) {
      return reinterpret_cast<Dart_NativeFunction>(entry->function_);
    }
  }
  return nullptr;
}

// Unit test case to verify stack frame iteration.
TEST_CASE(ValidateStackFrameIteration) {
  // clang-format off
  const char* kScriptChars =
          "class StackFrame {"
          "  @pragma('vm:external-name', 'StackFrame_equals')\n"
          "  external static equals(var obj1, var obj2);\n"
          "  @pragma('vm:external-name', 'StackFrame_frameCount')\n"
          "  external static int frameCount();\n"
          "  @pragma('vm:external-name', 'StackFrame_dartFrameCount')\n"
          "  external static int dartFrameCount();\n"
          "  @pragma('vm:external-name', 'StackFrame_validateFrame')\n"
          "  external static validateFrame(int index, String name);"
          "} "
          "class First {"
          "  First() { }"
          "  int? method1(int? param) {"
          "    if (param == 1) {"
          "      param = method2(200);"
          "    } else {"
          "      param = method2(100);"
          "    }"
          "  }"
          "  int? method2(int param) {"
          "    if (param == 200) {"
          "      First.staticmethod(this, param);"
          "    } else {"
          "      First.staticmethod(this, 10);"
          "    }"
          "  }"
          "  static int? staticmethod(First obj, int param) {"
          "    if (param == 10) {"
          "      obj.method3(10);"
          "    } else {"
          "      obj.method3(200);"
          "    }"
          "  }"
          "  method3(int param) {"
          "    StackFrame.equals(9, StackFrame.frameCount());"
          "    StackFrame.equals(7, StackFrame.dartFrameCount());"
          "    StackFrame.validateFrame(0, \"StackFrame_validateFrame\");"
          "    StackFrame.validateFrame(1, \"First_method3\");"
          "    StackFrame.validateFrame(2, \"First_staticmethod\");"
          "    StackFrame.validateFrame(3, \"First_method2\");"
          "    StackFrame.validateFrame(4, \"First_method1\");"
          "    StackFrame.validateFrame(5, \"Second_method1\");"
          "    StackFrame.validateFrame(6, \"StackFrameTest_testMain\");"
          "  }"
          "}"
          "class Second {"
          "  Second() { }"
          "  int? method1(int? param) {"
          "    if (param == 1) {"
          "      param = method2(200);"
          "    } else {"
          "      First obj = new First();"
          "      param = obj.method1(1);"
          "      param = obj.method1(2);"
          "    }"
          "  }"
          "  int? method2(int param) {"
          "    Second.staticmethod(this, param);"
          "  }"
          "  static int? staticmethod(Second obj, int param) {"
          "    obj.method3(10);"
          "  }"
          "  method3(int param) {"
          "    StackFrame.equals(8, StackFrame.frameCount());"
          "    StackFrame.equals(6, StackFrame.dartFrameCount());"
          "    StackFrame.validateFrame(0, \"StackFrame_validateFrame\");"
          "    StackFrame.validateFrame(1, \"Second_method3\");"
          "    StackFrame.validateFrame(2, \"Second_staticmethod\");"
          "    StackFrame.validateFrame(3, \"Second_method2\");"
          "    StackFrame.validateFrame(4, \"Second_method1\");"
          "    StackFrame.validateFrame(5, \"StackFrameTest_testMain\");"
          "  }"
          "}"
          "@pragma('vm:entry-point')\n"
          "class StackFrameTest {"
          "  @pragma('vm:entry-point', 'call')\n"
          "  static testMain() {"
          "    Second obj = new Second();"
          "    obj.method1(1);"
          "    obj.method1(2);"
          "  }"
          "}";
  // clang-format on
  Dart_Handle lib = TestCase::LoadTestScript(
      kScriptChars, reinterpret_cast<Dart_NativeEntryResolver>(native_lookup));
  Dart_Handle cls = Dart_GetClass(lib, NewString("StackFrameTest"));
  EXPECT_VALID(Dart_Invoke(cls, NewString("testMain"), 0, nullptr));
}

// Unit test case to verify stack frame iteration.
TEST_CASE(ValidateNoSuchMethodStackFrameIteration) {
  const char* const kScriptChars =
      "class StackFrame {"
      "  @pragma('vm:external-name', 'StackFrame_equals')\n"
      "  external static equals(var obj1, var obj2);\n"
      "  @pragma('vm:external-name', 'StackFrame_frameCount')\n"
      "  external static int frameCount();\n"
      "  @pragma('vm:external-name', 'StackFrame_dartFrameCount')\n"
      "  external static int dartFrameCount();\n"
      "  @pragma('vm:external-name', 'StackFrame_validateFrame')\n"
      "  external static validateFrame(int index, String name);"
      "} "
      "@pragma('vm:entry-point')\n"
      "class StackFrame2Test {"
      "  StackFrame2Test() {}"
      "  noSuchMethod(Invocation im) {"
      "    /* We should have 6 general frames and 4 dart frames as follows:"
      "     * exit frame"
      "     * dart frame corresponding to StackFrame.frameCount"
      "     * dart frame corresponding to StackFrame2Test.noSuchMethod"
      "     * frame for instance function invocation stub calling "
      "noSuchMethod"
      "     * dart frame corresponding to StackFrame2Test.testMain"
      "     * entry frame"
      "     */"
      "    StackFrame.equals(6, StackFrame.frameCount());"
      "    StackFrame.equals(4, StackFrame.dartFrameCount());"
      "    StackFrame.validateFrame(0, \"StackFrame_validateFrame\");"
      "    StackFrame.validateFrame(1, \"StackFrame2Test_noSuchMethod\");"
      "    StackFrame.validateFrame(2, \"StackFrame2Test_foo\");"
      "    StackFrame.validateFrame(3, \"StackFrame2Test_testMain\");"
      "    return 5;"
      "  }"
      "  @pragma('vm:entry-point', 'call')\n"
      "  static testMain() {"
      "    /* Declare |obj| dynamic so that noSuchMethod can be"
      "     * called in strong mode. */"
      "    dynamic obj = new StackFrame2Test();"
      "    StackFrame.equals(5, obj.foo(101, 202));"
      "  }"
      "}";
  Dart_Handle lib = TestCase::LoadTestScript(
      kScriptChars, reinterpret_cast<Dart_NativeEntryResolver>(native_lookup));
  Dart_Handle cls = Dart_GetClass(lib, NewString("StackFrame2Test"));
  EXPECT_VALID(Dart_Invoke(cls, NewString("testMain"), 0, nullptr));
}

}  // namespace dart
