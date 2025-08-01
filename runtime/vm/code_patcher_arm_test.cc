// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/globals.h"
#if defined(TARGET_ARCH_ARM)

#include "vm/code_patcher.h"
#include "vm/compiler/assembler/assembler.h"
#include "vm/dart_entry.h"
#include "vm/instructions.h"
#include "vm/native_entry.h"
#include "vm/native_entry_test.h"
#include "vm/runtime_entry.h"
#include "vm/stub_code.h"
#include "vm/symbols.h"
#include "vm/unit_test.h"

namespace dart {

#define __ assembler->

ASSEMBLER_TEST_GENERATE(IcDataAccess, assembler) {
  Thread* thread = Thread::Current();
  const String& class_name = String::Handle(Symbols::New(thread, "ownerClass"));
  const Script& script = Script::Handle();
  const Class& owner_class = Class::Handle(Class::New(
      Library::Handle(), class_name, script, TokenPosition::kNoSource));
  const String& function_name =
      String::Handle(Symbols::New(thread, "callerFunction"));
  const FunctionType& signature = FunctionType::ZoneHandle(FunctionType::New());
  const Function& function = Function::Handle(Function::New(
      signature, function_name, UntaggedFunction::kRegularFunction, true, false,
      false, false, false, owner_class, TokenPosition::kNoSource));

  const String& target_name =
      String::Handle(Symbols::New(thread, "targetFunction"));
  const intptr_t kTypeArgsLen = 0;
  const intptr_t kNumArgs = 1;
  const Array& args_descriptor = Array::Handle(ArgumentsDescriptor::NewBoxed(
      kTypeArgsLen, kNumArgs, Object::null_array()));
  const ICData& ic_data = ICData::ZoneHandle(ICData::New(
      function, target_name, args_descriptor, 15, 1, ICData::kInstance));

  // Code is generated, but not executed. Just parsed with CodePatcher.
  __ set_constant_pool_allowed(true);  // Uninitialized pp is OK.
  SPILLS_LR_TO_FRAME({});              // Clobbered LR is OK.

  __ LoadObject(CODE_REG, StubCode::OneArgCheckInlineCache());
  __ LoadObject(R9, ic_data);
  __ Call(compiler::FieldAddress(
      CODE_REG, Code::entry_point_offset(Code::EntryKind::kMonomorphic)));
  RESTORES_LR_FROM_FRAME({});  // Clobbered LR is OK.
  __ Ret();
}

ASSEMBLER_TEST_RUN(IcDataAccess, test) {
  uword end = test->payload_start() + test->code().Size();
  uword return_address = end - Instr::kInstrSize;
  ICData& ic_data = ICData::Handle();
  CodePatcher::GetInstanceCallAt(return_address, test->code(), &ic_data);
  EXPECT_STREQ("targetFunction",
               String::Handle(ic_data.target_name()).ToCString());
  EXPECT_EQ(1, ic_data.NumArgsTested());
  EXPECT_EQ(0, ic_data.NumberOfChecks());
}

}  // namespace dart

#endif  // TARGET_ARCH_ARM
