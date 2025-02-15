// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/compiler/jit/compiler.h"
#include "platform/assert.h"
#include "vm/class_finalizer.h"
#include "vm/code_patcher.h"
#include "vm/dart_api_impl.h"
#include "vm/heap/safepoint.h"
#include "vm/kernel_isolate.h"
#include "vm/object.h"
#include "vm/symbols.h"
#include "vm/thread_pool.h"
#include "vm/unit_test.h"

namespace dart {

ISOLATE_UNIT_TEST_CASE(CompileFunction) {
  const char* kScriptChars =
      "class A {\n"
      "  static foo() { return 42; }\n"
      "  static moo() {\n"
      "    // A.foo();\n"
      "  }\n"
      "}\n";
  Dart_Handle library;
  {
    TransitionVMToNative transition(thread);
    library = TestCase::LoadTestScript(kScriptChars, nullptr);
  }
  const Library& lib =
      Library::Handle(Library::RawCast(Api::UnwrapHandle(library)));
  EXPECT(ClassFinalizer::ProcessPendingClasses());
  Class& cls =
      Class::Handle(lib.LookupClass(String::Handle(Symbols::New(thread, "A"))));
  EXPECT(!cls.IsNull());
  const auto& error = cls.EnsureIsFinalized(thread);
  EXPECT(error == Error::null());
  String& function_foo_name = String::Handle(String::New("foo"));
  Function& function_foo =
      Function::Handle(cls.LookupStaticFunction(function_foo_name));
  EXPECT(!function_foo.IsNull());
  String& function_source = String::Handle(function_foo.GetSource());
  EXPECT_STREQ("static foo() { return 42; }", function_source.ToCString());
  EXPECT(CompilerTest::TestCompileFunction(function_foo));
  EXPECT(function_foo.HasCode());

  String& function_moo_name = String::Handle(String::New("moo"));
  Function& function_moo =
      Function::Handle(cls.LookupStaticFunction(function_moo_name));
  EXPECT(!function_moo.IsNull());

  EXPECT(CompilerTest::TestCompileFunction(function_moo));
  EXPECT(function_moo.HasCode());
  function_source = function_moo.GetSource();
  EXPECT_STREQ("static moo() {\n    // A.foo();\n  }",
               function_source.ToCString());
}

ISOLATE_UNIT_TEST_CASE(OptimizeCompileFunctionOnHelperThread) {
  // Create a simple function and compile it without optimization.
  const char* kScriptChars =
      "class A {\n"
      "  static foo() { return 42; }\n"
      "}\n";
  Dart_Handle library;
  {
    TransitionVMToNative transition(thread);
    library = TestCase::LoadTestScript(kScriptChars, nullptr);
  }
  const Library& lib =
      Library::Handle(Library::RawCast(Api::UnwrapHandle(library)));
  EXPECT(ClassFinalizer::ProcessPendingClasses());
  Class& cls =
      Class::Handle(lib.LookupClass(String::Handle(Symbols::New(thread, "A"))));
  EXPECT(!cls.IsNull());
  String& function_foo_name = String::Handle(String::New("foo"));
  const auto& error = cls.EnsureIsFinalized(thread);
  EXPECT(error == Error::null());
  Function& func =
      Function::Handle(cls.LookupStaticFunction(function_foo_name));
  EXPECT(!func.HasCode());
  CompilerTest::TestCompileFunction(func);
  EXPECT(func.HasCode());
  EXPECT(!func.HasOptimizedCode());
#if !defined(PRODUCT)
  // Constant in product mode.
  FLAG_background_compilation = true;
#endif
  auto isolate_group = thread->isolate_group();
  isolate_group->background_compiler()->EnqueueCompilation(func);
  Monitor* m = new Monitor();
  {
    SafepointMonitorLocker ml(m);
    while (!func.HasOptimizedCode()) {
      ml.Wait(1);
    }
  }
  delete m;
}

ISOLATE_UNIT_TEST_CASE(CompileFunctionOnHelperThread) {
  // Create a simple function and compile it without optimization.
  const char* kScriptChars =
      "class A {\n"
      "  static foo() { return 42; }\n"
      "}\n";
  Dart_Handle library;
  {
    TransitionVMToNative transition(thread);
    library = TestCase::LoadTestScript(kScriptChars, nullptr);
  }
  const Library& lib =
      Library::Handle(Library::RawCast(Api::UnwrapHandle(library)));
  EXPECT(ClassFinalizer::ProcessPendingClasses());
  Class& cls =
      Class::Handle(lib.LookupClass(String::Handle(Symbols::New(thread, "A"))));
  EXPECT(!cls.IsNull());
  const auto& error = cls.EnsureIsFinalized(thread);
  EXPECT(error == Error::null());
  String& function_foo_name = String::Handle(String::New("foo"));
  Function& func =
      Function::Handle(cls.LookupStaticFunction(function_foo_name));
  EXPECT(!func.HasCode());
  CompilerTest::TestCompileFunction(func);
  EXPECT(func.HasCode());
}

ISOLATE_UNIT_TEST_CASE(RegenerateAllocStubs) {
  const char* kScriptChars =
      "class A {\n"
      "}\n"
      "unOpt() => new A(); \n"
      "optIt() => new A(); \n"
      "A main() {\n"
      "  return unOpt();\n"
      "}\n";

  Class& cls = Class::Handle();
  TransitionVMToNative transition(thread);

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);

  {
    TransitionNativeToVM transition(thread);
    Library& lib_handle =
        Library::Handle(Library::RawCast(Api::UnwrapHandle(lib)));
    cls = lib_handle.LookupClass(String::Handle(Symbols::New(thread, "A")));
    EXPECT(!cls.IsNull());
  }

  {
    TransitionNativeToVM transition(thread);
    cls.DisableAllocationStub();
  }
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);

  {
    TransitionNativeToVM transition(thread);
    cls.DisableAllocationStub();
  }
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);

  {
    TransitionNativeToVM transition(thread);
    cls.DisableAllocationStub();
  }
  result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
}

TEST_CASE(EvalExpression) {
  const char* kScriptChars =
      R"(
       int ten = 2 * 5;
       get dot => '.';
       class A {
         var apa = 'Herr Nilsson';
         calc(x) => '${x*ten}';
       }
       @pragma('vm:entry-point', 'call')
       makeObj() => new A();
      )";

  Dart_Handle lib = TestCase::LoadTestScript(kScriptChars, nullptr);
  Dart_Handle obj_handle =
      Dart_Invoke(lib, Dart_NewStringFromCString("makeObj"), 0, nullptr);
  EXPECT_VALID(obj_handle);
  TransitionNativeToVM transition(thread);
  const Object& obj = Object::Handle(Api::UnwrapHandle(obj_handle));
  EXPECT(!obj.IsNull());
  EXPECT(obj.IsInstance());

  String& expr_text = String::Handle();
  expr_text = String::New("apa + ' ${calc(10)}' + dot");
  Object& val = Object::Handle();
  const Class& receiver_cls = Class::Handle(obj.clazz());

  if (!KernelIsolate::IsRunning()) {
    UNREACHABLE();
  } else {
    LibraryPtr raw_library = Library::RawCast(Api::UnwrapHandle(lib));
    Library& lib_handle = Library::ZoneHandle(raw_library);

    Dart_KernelCompilationResult compilation_result =
        KernelIsolate::CompileExpressionToKernel(
            /*platform_kernel=*/nullptr, /*platform_kernel_size=*/0,
            expr_text.ToCString(), Array::empty_array(), Array::empty_array(),
            Array::empty_array(), Array::empty_array(), Array::empty_array(),
            String::Handle(lib_handle.url()).ToCString(), "A",
            /* method= */ nullptr,
            /* token_pos= */ TokenPosition::kNoSource,
            /* script_uri= */ String::Handle(lib_handle.url()).ToCString(),
            /* is_static= */ false);
    EXPECT_EQ(Dart_KernelCompilationStatus_Ok, compilation_result.status);

    const ExternalTypedData& kernel_buffer =
        ExternalTypedData::Handle(ExternalTypedData::NewFinalizeWithFree(
            const_cast<uint8_t*>(compilation_result.kernel),
            compilation_result.kernel_size));

    val = Instance::Cast(obj).EvaluateCompiledExpression(
        receiver_cls, kernel_buffer, Array::empty_array(), Array::empty_array(),
        TypeArguments::null_type_arguments());
  }
  EXPECT(!val.IsNull());
  EXPECT(!val.IsError());
  EXPECT(val.IsString());
  EXPECT_STREQ("Herr Nilsson 100.", val.ToCString());
}

ISOLATE_UNIT_TEST_CASE(EvalExpressionWithLazyCompile) {
  {  // Initialize an incremental compiler in DFE mode.
    TransitionVMToNative transition(thread);
    TestCase::LoadTestScript("", nullptr);
  }
  Library& lib = Library::Handle(Library::CoreLibrary());
  const String& expression = String::Handle(
      String::New("(){ return (){ return (){ return 3 + 4; }(); }(); }()"));
  Object& val = Object::Handle();
  val = Api::UnwrapHandle(
      TestCase::EvaluateExpression(lib, expression,
                                   /* param_names= */ Array::empty_array(),
                                   /* param_values= */ Array::empty_array()));

  EXPECT(!val.IsNull());
  EXPECT(!val.IsError());
  EXPECT(val.IsInteger());
  EXPECT_EQ(7, Integer::Cast(val).Value());
}

ISOLATE_UNIT_TEST_CASE(EvalExpressionExhaustCIDs) {
  {  // Initialize an incremental compiler in DFE mode.
    TransitionVMToNative transition(thread);
    TestCase::LoadTestScript("", nullptr);
  }
  Library& lib = Library::Handle(Library::CoreLibrary());
  const String& expression = String::Handle(String::New("3 + 4"));
  Object& val = Object::Handle();
  val = Api::UnwrapHandle(
      TestCase::EvaluateExpression(lib, expression,
                                   /* param_names= */ Array::empty_array(),
                                   /* param_values= */ Array::empty_array()));

  EXPECT(!val.IsNull());
  EXPECT(!val.IsError());
  EXPECT(val.IsInteger());
  EXPECT_EQ(7, Integer::Cast(val).Value());

  auto class_table = IsolateGroup::Current()->class_table();

  intptr_t initial_class_table_size = class_table->NumCids();

  val = Api::UnwrapHandle(
      TestCase::EvaluateExpression(lib, expression,
                                   /* param_names= */ Array::empty_array(),
                                   /* param_values= */ Array::empty_array()));
  EXPECT(!val.IsNull());
  EXPECT(!val.IsError());
  EXPECT(val.IsInteger());
  EXPECT_EQ(7, Integer::Cast(val).Value());

  intptr_t final_class_table_size = class_table->NumCids();
  // Eval should not eat into this non-renewable resource.
  EXPECT_EQ(initial_class_table_size, final_class_table_size);
}

// Too slow in debug mode.
#if !defined(DEBUG) && !defined(USING_THREAD_SANITIZER)
TEST_CASE(ManyClasses) {
  // Limit is 20 bits. Check only more than 16 bits so test completes in
  // reasonable time.
  const intptr_t kNumClasses = (1 << 16) + 1;

  TextBuffer buffer(MB);
  for (intptr_t i = 0; i < kNumClasses; i++) {
    buffer.Printf("class C%" Pd " { String toString() => 'C%" Pd "'; }\n", i,
                  i);
  }
  buffer.Printf("main() {\n");
  for (intptr_t i = 0; i < kNumClasses; i++) {
    buffer.Printf("  new C%" Pd "().toString();\n", i);
  }
  buffer.Printf("}\n");

  Dart_Handle lib = TestCase::LoadTestScript(buffer.buffer(), nullptr);
  EXPECT_VALID(lib);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);

  EXPECT(IsolateGroup::Current()->class_table()->NumCids() >= kNumClasses);
}
#endif  // !defined(DEBUG) && !defined(USING_THREAD_SANITIZER)

}  // namespace dart
