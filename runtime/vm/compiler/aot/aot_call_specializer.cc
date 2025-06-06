// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/compiler/aot/aot_call_specializer.h"

#include <utility>

#include "vm/bit_vector.h"
#include "vm/compiler/aot/precompiler.h"
#include "vm/compiler/backend/branch_optimizer.h"
#include "vm/compiler/backend/flow_graph_compiler.h"
#include "vm/compiler/backend/il.h"
#include "vm/compiler/backend/il_printer.h"
#include "vm/compiler/backend/inliner.h"
#include "vm/compiler/backend/range_analysis.h"
#include "vm/compiler/cha.h"
#include "vm/compiler/compiler_state.h"
#include "vm/compiler/frontend/flow_graph_builder.h"
#include "vm/compiler/jit/compiler.h"
#include "vm/compiler/jit/jit_call_specializer.h"
#include "vm/cpu.h"
#include "vm/dart_entry.h"
#include "vm/exceptions.h"
#include "vm/hash_map.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/parser.h"
#include "vm/resolver.h"
#include "vm/scopes.h"
#include "vm/stack_frame.h"
#include "vm/symbols.h"

namespace dart {

DEFINE_FLAG(int,
            max_exhaustive_polymorphic_checks,
            5,
            "If a call receiver is known to be of at most this many classes, "
            "generate exhaustive class tests instead of a megamorphic call");

// Quick access to the current isolate and zone.
#define IG (isolate_group())
#define Z (zone())

#ifdef DART_PRECOMPILER

// Returns named function that is a unique dynamic target, i.e.,
// - the target is identified by its name alone, since it occurs only once.
// - target's class has no subclasses, and neither is subclassed, i.e.,
//   the receiver type can be only the function's class.
// Returns Function::null() if there is no unique dynamic target for
// given 'fname'. 'fname' must be a symbol.
static void GetUniqueDynamicTarget(IsolateGroup* isolate_group,
                                   const String& fname,
                                   Object* function) {
  UniqueFunctionsMap functions_map(
      isolate_group->object_store()->unique_dynamic_targets());
  ASSERT(fname.IsSymbol());
  *function = functions_map.GetOrNull(fname);
  ASSERT(functions_map.Release().ptr() ==
         isolate_group->object_store()->unique_dynamic_targets());
}

AotCallSpecializer::AotCallSpecializer(Precompiler* precompiler,
                                       FlowGraph* flow_graph)
    : CallSpecializer(flow_graph,
                      /* should_clone_fields=*/false),
      precompiler_(precompiler),
      has_unique_no_such_method_(false) {
  Function& target_function = Function::Handle();
  if (isolate_group()->object_store()->unique_dynamic_targets() !=
      Array::null()) {
    GetUniqueDynamicTarget(isolate_group(), Symbols::NoSuchMethod(),
                           &target_function);
    has_unique_no_such_method_ = !target_function.IsNull();
  }
}

bool AotCallSpecializer::TryCreateICDataForUniqueTarget(
    InstanceCallInstr* call) {
  if (isolate_group()->object_store()->unique_dynamic_targets() ==
      Array::null()) {
    return false;
  }

  // Check if the target is unique.
  Function& target_function = Function::Handle(Z);
  GetUniqueDynamicTarget(isolate_group(), call->function_name(),
                         &target_function);

  if (target_function.IsNull()) {
    return false;
  }

  // Calls passing named arguments and calls to a function taking named
  // arguments must be resolved/checked at runtime.
  // Calls passing a type argument vector and calls to a generic function must
  // be resolved/checked at runtime.
  if (target_function.HasOptionalNamedParameters() ||
      target_function.IsGeneric() ||
      !target_function.AreValidArgumentCounts(
          call->type_args_len(), call->ArgumentCountWithoutTypeArgs(),
          call->argument_names().IsNull() ? 0 : call->argument_names().Length(),
          /* error_message = */ nullptr)) {
    return false;
  }

  const Class& cls = Class::Handle(Z, target_function.Owner());
  intptr_t implementor_cid = kIllegalCid;
  if (!CHA::HasSingleConcreteImplementation(cls, &implementor_cid)) {
    return false;
  }

  call->SetTargets(
      CallTargets::CreateMonomorphic(Z, implementor_cid, target_function));
  ASSERT(call->Targets().IsMonomorphic());

  // If we know that the only noSuchMethod is Object.noSuchMethod then
  // this call is guaranteed to either succeed or throw.
  if (has_unique_no_such_method_) {
    call->set_has_unique_selector(true);

    // Add redefinition of the receiver to prevent code motion across
    // this call.
    const intptr_t receiver_index = call->FirstArgIndex();
    RedefinitionInstr* redefinition = new (Z)
        RedefinitionInstr(new (Z) Value(call->ArgumentAt(receiver_index)));
    flow_graph()->AllocateSSAIndex(redefinition);
    redefinition->InsertAfter(call);
    // Replace all uses of the receiver dominated by this call.
    FlowGraph::RenameDominatedUses(call->ArgumentAt(receiver_index),
                                   redefinition, redefinition);
    if (!redefinition->HasUses()) {
      redefinition->RemoveFromGraph();
    }
  }

  return true;
}

bool AotCallSpecializer::TryCreateICData(InstanceCallInstr* call) {
  if (TryCreateICDataForUniqueTarget(call)) {
    return true;
  }

  return CallSpecializer::TryCreateICData(call);
}

bool AotCallSpecializer::RecognizeRuntimeTypeGetter(InstanceCallInstr* call) {
  if ((precompiler_ == nullptr) ||
      !precompiler_->get_runtime_type_is_unique()) {
    return false;
  }

  if (call->function_name().ptr() != Symbols::GetRuntimeType().ptr()) {
    return false;
  }

  // There is only a single function Object.get:runtimeType that can be invoked
  // by this call. Convert dynamic invocation to a static one.
  const Class& cls = Class::Handle(Z, IG->object_store()->object_class());
  const Function& function =
      Function::Handle(Z, call->ResolveForReceiverClass(cls));
  ASSERT(!function.IsNull());
  const Function& target = Function::ZoneHandle(Z, function.ptr());
  StaticCallInstr* static_call =
      StaticCallInstr::FromCall(Z, call, target, call->CallCount());
  // Since the result is either a Type or a FunctionType, we cannot pin it.
  call->ReplaceWith(static_call, current_iterator());
  return true;
}

static bool IsGetRuntimeType(Definition* defn) {
  StaticCallInstr* call = defn->AsStaticCall();
  return (call != nullptr) && (call->function().recognized_kind() ==
                               MethodRecognizer::kObjectRuntimeType);
}

// Recognize a.runtimeType == b.runtimeType and fold it into
// Object._haveSameRuntimeType(a, b).
// Note: this optimization is not speculative.
bool AotCallSpecializer::TryReplaceWithHaveSameRuntimeType(
    TemplateDartCall<0>* call) {
  ASSERT((call->IsInstanceCall() &&
          (call->AsInstanceCall()->ic_data()->NumArgsTested() == 2)) ||
         call->IsStaticCall());
  ASSERT(call->type_args_len() == 0);
  ASSERT(call->ArgumentCount() == 2);

  Definition* left = call->ArgumentAt(0);
  Definition* right = call->ArgumentAt(1);

  if (IsGetRuntimeType(left) && left->input_use_list()->IsSingleUse() &&
      IsGetRuntimeType(right) && right->input_use_list()->IsSingleUse()) {
    const Class& cls = Class::Handle(Z, IG->object_store()->object_class());
    const Function& have_same_runtime_type = Function::ZoneHandle(
        Z,
        cls.LookupStaticFunctionAllowPrivate(Symbols::HaveSameRuntimeType()));
    ASSERT(!have_same_runtime_type.IsNull());

    InputsArray args(Z, 2);
    args.Add(left->ArgumentValueAt(0)->CopyWithType(Z));
    args.Add(right->ArgumentValueAt(0)->CopyWithType(Z));
    const intptr_t kTypeArgsLen = 0;
    StaticCallInstr* static_call = new (Z)
        StaticCallInstr(call->source(), have_same_runtime_type, kTypeArgsLen,
                        Object::null_array(),  // argument_names
                        std::move(args), call->deopt_id(), call->CallCount(),
                        ICData::kOptimized);
    static_call->SetResultType(Z, CompileType::FromCid(kBoolCid));
    ReplaceCall(call, static_call);
    // ReplaceCall moved environment from 'call' to 'static_call'.
    // Update arguments of 'static_call' in the environment.
    Environment* env = static_call->env();
    env->ValueAt(env->Length() - 2)
        ->BindToEnvironment(static_call->ArgumentAt(0));
    env->ValueAt(env->Length() - 1)
        ->BindToEnvironment(static_call->ArgumentAt(1));
    return true;
  }

  return false;
}

bool AotCallSpecializer::TryInlineFieldAccess(InstanceCallInstr* call) {
  const Token::Kind op_kind = call->token_kind();
  if ((op_kind == Token::kGET) && TryInlineInstanceGetter(call)) {
    return true;
  }
  if ((op_kind == Token::kSET) && TryInlineInstanceSetter(call)) {
    return true;
  }
  return false;
}

bool AotCallSpecializer::TryInlineFieldAccess(StaticCallInstr* call) {
  if (call->function().IsImplicitGetterFunction()) {
    Field& field = Field::ZoneHandle(call->function().accessor_field());
    if (field.is_late()) {
      // TODO(dartbug.com/40447): Inline implicit getters for late fields.
      return false;
    }
    if (should_clone_fields_) {
      field = field.CloneFromOriginal();
    }
    InlineImplicitInstanceGetter(call, field);
    return true;
  }

  return false;
}

bool AotCallSpecializer::IsSupportedIntOperandForStaticDoubleOp(
    CompileType* operand_type) {
  if (operand_type->IsNullableInt()) {
    if (operand_type->ToNullableCid() == kSmiCid) {
      return true;
    }

    if (FlowGraphCompiler::CanConvertInt64ToDouble()) {
      return true;
    }
  }

  return false;
}

Value* AotCallSpecializer::PrepareStaticOpInput(Value* input,
                                                intptr_t cid,
                                                Instruction* call) {
  ASSERT((cid == kDoubleCid) || (cid == kMintCid));

  if (input->Type()->is_nullable()) {
    const String& function_name =
        (call->IsInstanceCall()
             ? call->AsInstanceCall()->function_name()
             : String::ZoneHandle(Z, call->AsStaticCall()->function().name()));
    AddCheckNull(input, function_name, call->deopt_id(), call->env(), call);
  }

  input = input->CopyWithType(Z);

  if (cid == kDoubleCid && input->Type()->IsNullableInt()) {
    Definition* conversion = nullptr;

    if (input->Type()->ToNullableCid() == kSmiCid) {
      conversion = new (Z) SmiToDoubleInstr(input, call->source());
    } else if (FlowGraphCompiler::CanConvertInt64ToDouble()) {
      conversion = new (Z) Int64ToDoubleInstr(input, DeoptId::kNone);
    } else {
      UNREACHABLE();
    }

    if (FLAG_trace_strong_mode_types) {
      THR_Print("[Strong mode] Inserted %s\n", conversion->ToCString());
    }
    InsertBefore(call, conversion, /* env = */ nullptr, FlowGraph::kValue);
    return new (Z) Value(conversion);
  }

  return input;
}

CompileType AotCallSpecializer::BuildStrengthenedReceiverType(Value* input,
                                                              intptr_t cid) {
  CompileType* old_type = input->Type();
  CompileType* refined_type = old_type;

  CompileType type = CompileType::None();
  if (cid == kSmiCid) {
    type = CompileType::NullableSmi();
    refined_type = CompileType::ComputeRefinedType(old_type, &type);
  } else if (cid == kMintCid) {
    type = CompileType::NullableMint();
    refined_type = CompileType::ComputeRefinedType(old_type, &type);
  } else if (cid == kIntegerCid && !input->Type()->IsNullableInt()) {
    type = CompileType::NullableInt();
    refined_type = CompileType::ComputeRefinedType(old_type, &type);
  } else if (cid == kDoubleCid && !input->Type()->IsNullableDouble()) {
    type = CompileType::NullableDouble();
    refined_type = CompileType::ComputeRefinedType(old_type, &type);
  }

  if (refined_type != old_type) {
    return *refined_type;
  }
  return CompileType::None();
}

// After replacing a call with a specialized instruction, make sure to
// update types at all uses, as specialized instruction can provide a more
// specific type.
static void RefineUseTypes(Definition* instr) {
  CompileType* new_type = instr->Type();
  for (Value::Iterator it(instr->input_use_list()); !it.Done(); it.Advance()) {
    it.Current()->RefineReachingType(new_type);
  }
}

bool AotCallSpecializer::TryOptimizeInstanceCallUsingStaticTypes(
    InstanceCallInstr* instr) {
  const Token::Kind op_kind = instr->token_kind();
  return TryOptimizeIntegerOperation(instr, op_kind) ||
         TryOptimizeDoubleOperation(instr, op_kind);
}

bool AotCallSpecializer::TryOptimizeStaticCallUsingStaticTypes(
    StaticCallInstr* instr) {
  const String& name = String::Handle(Z, instr->function().name());
  const Token::Kind op_kind = MethodTokenRecognizer::RecognizeTokenKind(name);

  if (op_kind == Token::kEQ && TryReplaceWithHaveSameRuntimeType(instr)) {
    return true;
  }

  // We only specialize instance methods for int/double operations.
  const auto& target = instr->function();
  if (!target.IsDynamicFunction()) {
    return false;
  }

  // For de-virtualized instance calls, we strengthen the type here manually
  // because it might not be attached to the receiver.
  // See http://dartbug.com/35179 for preserving the receiver type information.
  const Class& owner = Class::Handle(Z, target.Owner());
  const intptr_t cid = owner.id();
  if (cid == kSmiCid || cid == kMintCid || cid == kIntegerCid ||
      cid == kDoubleCid) {
    // Sometimes TFA de-virtualizes instance calls to static calls.  In such
    // cases the VM might have a looser type on the receiver, so we explicitly
    // tighten it (this is safe since it was proven that the receiver is either
    // null or will end up with that target).
    const intptr_t receiver_index = instr->FirstArgIndex();
    const intptr_t argument_count = instr->ArgumentCountWithoutTypeArgs();
    if (argument_count >= 1) {
      auto receiver_value = instr->ArgumentValueAt(receiver_index);
      auto receiver = receiver_value->definition();
      auto type = BuildStrengthenedReceiverType(receiver_value, cid);
      if (!type.IsNone()) {
        auto redefinition =
            flow_graph()->EnsureRedefinition(instr->previous(), receiver, type);
        if (redefinition != nullptr) {
          RefineUseTypes(redefinition);
        }
      }
    }
  }

  return TryOptimizeIntegerOperation(instr, op_kind) ||
         TryOptimizeDoubleOperation(instr, op_kind);
}

Definition* AotCallSpecializer::TryOptimizeDivisionOperation(
    TemplateDartCall<0>* instr,
    Token::Kind op_kind,
    Value* left_value,
    Value* right_value) {
  auto unboxed_constant = [&](int64_t value) -> Definition* {
    ASSERT(compiler::target::IsSmi(value));
#if defined(TARGET_ARCH_IS_32_BIT)
    Definition* const const_def = new (Z) UnboxedConstantInstr(
        Smi::ZoneHandle(Z, Smi::New(value)), kUnboxedInt32);
    InsertBefore(instr, const_def, /*env=*/nullptr, FlowGraph::kValue);
    return new (Z) IntConverterInstr(kUnboxedInt32, kUnboxedInt64,
                                     new (Z) Value(const_def));
#else
    return new (Z) UnboxedConstantInstr(Smi::ZoneHandle(Z, Smi::New(value)),
                                        kUnboxedInt64);
#endif
  };

  if (!right_value->BindsToConstant()) {
    return nullptr;
  }

  const Object& rhs = right_value->BoundConstant();
  const int64_t value = Integer::Cast(rhs).Value();  // smi and mint

  if (value == kMinInt64) {
    return nullptr;  // The absolute value can't be held in an int64_t.
  }

  const int64_t magnitude = Utils::Abs(value);
  // The replacements for both operations assume that the magnitude of the
  // value is a power of two and that the mask derived from the magnitude
  // can fit in a Smi.
  if (!Utils::IsPowerOfTwo(magnitude) ||
      !compiler::target::IsSmi(magnitude - 1)) {
    return nullptr;
  }

  if (op_kind == Token::kMOD) {
    // Modulo against a constant power-of-two can be optimized into a mask.
    // x % y -> x & (|y| - 1)  for smi masks only
    left_value = PrepareStaticOpInput(left_value, kMintCid, instr);

    Definition* right_definition = unboxed_constant(magnitude - 1);
    if (magnitude == 1) return right_definition;
    InsertBefore(instr, right_definition, /*env=*/nullptr, FlowGraph::kValue);
    right_value = new (Z) Value(right_definition);
    return new (Z) BinaryInt64OpInstr(Token::kBIT_AND, left_value, right_value,
                                      DeoptId::kNone);
  } else {
    ASSERT_EQUAL(op_kind, Token::kTRUNCDIV);
#if !defined(TARGET_ARCH_IS_32_BIT)
    // If BinaryInt64Op(kTRUNCDIV, ...) is supported, then only perform the
    // simplest replacements and use the instruction otherwise.
    if (magnitude != 1) return nullptr;
#endif

    // If the divisor is negative, then we need to negate the final result.
    const bool negate = value < 0;
    Definition* result = nullptr;

    left_value = PrepareStaticOpInput(left_value, kMintCid, instr);
    if (magnitude > 1) {
      // For two's complement signed arithmetic where the bit width is k
      // and the divisor is 2^n for some n in [0, k), we can perform a simple
      // shift if m is non-negative:
      //   m ~/ 2^n => m >> n
      // For negative m, however, this won't work since just shifting m rounds
      // towards negative infinity. Instead, we add (2^n - 1) first before
      // shifting, which rounds the result towards positive infinity
      // (and thus rounding towards zero, since m is negative):
      //   m ~/ 2^n => (m + (2^n - 1)) >> n
      // By sign extending the sign bit (the (k-1)-bit) and using that as a
      // mask, we get a non-branching computation that only adds (2^n - 1)
      // when m is negative, rounding towards zero in both cases:
      //   m ~/ 2^n => (m + ((m >> (k - 1)) & (2^n - 1))) >> n
      auto* const sign_bit_position = unboxed_constant(63);
      InsertBefore(instr, sign_bit_position, /*env=*/nullptr,
                   FlowGraph::kValue);
      auto* const sign_bit_extended = new (Z)
          BinaryInt64OpInstr(Token::kSHR, left_value,
                             new (Z) Value(sign_bit_position), DeoptId::kNone);
      InsertBefore(instr, sign_bit_extended, /*env=*/nullptr,
                   FlowGraph::kValue);
      auto* rounding_adjustment = unboxed_constant(magnitude - 1);
      InsertBefore(instr, rounding_adjustment, /*env=*/nullptr,
                   FlowGraph::kValue);
      rounding_adjustment = new (Z) BinaryInt64OpInstr(
          Token::kBIT_AND, new (Z) Value(sign_bit_extended),
          new (Z) Value(rounding_adjustment), DeoptId::kNone);
      InsertBefore(instr, rounding_adjustment, /*env=*/nullptr,
                   FlowGraph::kValue);
      auto* const left_definition = new (Z) BinaryInt64OpInstr(
          Token::kADD, left_value->CopyWithType(Z),
          new (Z) Value(rounding_adjustment), DeoptId::kNone);
      InsertBefore(instr, left_definition, /*env=*/nullptr, FlowGraph::kValue);
      left_value = new (Z) Value(left_definition);
      auto* const right_definition =
          unboxed_constant(Utils::ShiftForPowerOfTwo(magnitude));
      InsertBefore(instr, right_definition, /*env=*/nullptr, FlowGraph::kValue);
      right_value = new (Z) Value(right_definition);
      result = new (Z) BinaryInt64OpInstr(Token::kSHR, left_value, right_value,
                                          DeoptId::kNone);
    } else {
      ASSERT_EQUAL(magnitude, 1);
      // No division needed, just redefine the value.
      result = new (Z) RedefinitionInstr(left_value);
    }
    if (negate) {
      InsertBefore(instr, result, /*env=*/nullptr, FlowGraph::kValue);
      result = new (Z) UnaryInt64OpInstr(Token::kNEGATE, new (Z) Value(result),
                                         DeoptId::kNone);
    }
    return result;
  }
}

bool AotCallSpecializer::TryOptimizeIntegerOperation(TemplateDartCall<0>* instr,
                                                     Token::Kind op_kind) {
  if (instr->type_args_len() != 0) {
    // Arithmetic operations don't have type arguments.
    return false;
  }

  Definition* replacement = nullptr;
  if (instr->ArgumentCount() == 2) {
    Value* left_value = instr->ArgumentValueAt(0);
    Value* right_value = instr->ArgumentValueAt(1);
    CompileType* left_type = left_value->Type();
    CompileType* right_type = right_value->Type();

    bool has_nullable_int_args =
        left_type->IsNullableInt() && right_type->IsNullableInt();

    if (auto* call = instr->AsInstanceCall()) {
      if (!call->CanReceiverBeSmiBasedOnInterfaceTarget(Z)) {
        has_nullable_int_args = false;
      }
    }

    // We only support binary operations if both operands are nullable integers
    // or when we can use a cheap strict comparison operation.
    if (!has_nullable_int_args) {
      return false;
    }

    switch (op_kind) {
      case Token::kEQ:
      case Token::kNE: {
        const bool either_can_be_null =
            left_type->is_nullable() || right_type->is_nullable();
        replacement = new (Z) EqualityCompareInstr(
            instr->source(), op_kind, left_value->CopyWithType(Z),
            right_value->CopyWithType(Z),
            either_can_be_null ? kTagged : kUnboxedInt64, DeoptId::kNone,
            /*null_aware=*/either_can_be_null);
        break;
      }
      case Token::kLT:
      case Token::kLTE:
      case Token::kGT:
      case Token::kGTE:
        left_value = PrepareStaticOpInput(left_value, kMintCid, instr);
        right_value = PrepareStaticOpInput(right_value, kMintCid, instr);
        replacement = new (Z)
            RelationalOpInstr(instr->source(), op_kind, left_value, right_value,
                              kUnboxedInt64, DeoptId::kNone);
        break;
      case Token::kMOD:
      case Token::kTRUNCDIV:
        replacement = TryOptimizeDivisionOperation(instr, op_kind, left_value,
                                                   right_value);
        if (replacement != nullptr) break;
#if defined(TARGET_ARCH_IS_32_BIT)
        // Truncating 64-bit division and modulus via BinaryInt64OpInstr are
        // not implemented on 32-bit architectures, so we can only optimize
        // certain cases and otherwise must leave the call in.
        break;
#else
        FALL_THROUGH;
#endif
      case Token::kSHL:
        FALL_THROUGH;
      case Token::kSHR:
        FALL_THROUGH;
      case Token::kUSHR:
        FALL_THROUGH;
      case Token::kBIT_OR:
        FALL_THROUGH;
      case Token::kBIT_XOR:
        FALL_THROUGH;
      case Token::kBIT_AND:
        FALL_THROUGH;
      case Token::kADD:
        FALL_THROUGH;
      case Token::kSUB:
        FALL_THROUGH;
      case Token::kMUL: {
        left_value = PrepareStaticOpInput(left_value, kMintCid, instr);
        right_value = PrepareStaticOpInput(right_value, kMintCid, instr);
        replacement = new (Z) BinaryInt64OpInstr(op_kind, left_value,
                                                 right_value, DeoptId::kNone);
        break;
      }

      default:
        break;
    }
  } else if (instr->ArgumentCount() == 1) {
    Value* left_value = instr->ArgumentValueAt(0);
    CompileType* left_type = left_value->Type();

    // We only support unary operations on nullable integers.
    if (!left_type->IsNullableInt()) {
      return false;
    }

    if (op_kind == Token::kNEGATE || op_kind == Token::kBIT_NOT) {
      left_value = PrepareStaticOpInput(left_value, kMintCid, instr);
      replacement =
          new (Z) UnaryInt64OpInstr(op_kind, left_value, DeoptId::kNone);
    }
  }

  if (replacement != nullptr && !replacement->ComputeCanDeoptimize()) {
    if (FLAG_trace_strong_mode_types) {
      THR_Print("[Strong mode] Optimization: replacing %s with %s\n",
                instr->ToCString(), replacement->ToCString());
    }
    ReplaceCall(instr, replacement);
    RefineUseTypes(replacement);
    return true;
  }

  return false;
}

bool AotCallSpecializer::TryOptimizeDoubleOperation(TemplateDartCall<0>* instr,
                                                    Token::Kind op_kind) {
  if (instr->type_args_len() != 0) {
    // Arithmetic operations don't have type arguments.
    return false;
  }

  Definition* replacement = nullptr;

  if (instr->ArgumentCount() == 2) {
    Value* left_value = instr->ArgumentValueAt(0);
    Value* right_value = instr->ArgumentValueAt(1);
    CompileType* left_type = left_value->Type();
    CompileType* right_type = right_value->Type();

    if (!left_type->IsNullableDouble() &&
        !IsSupportedIntOperandForStaticDoubleOp(left_type)) {
      return false;
    }
    if (!right_type->IsNullableDouble() &&
        !IsSupportedIntOperandForStaticDoubleOp(right_type)) {
      return false;
    }

    switch (op_kind) {
      case Token::kEQ:
        FALL_THROUGH;
      case Token::kNE: {
        // TODO(dartbug.com/32166): Support EQ, NE for nullable doubles.
        // (requires null-aware comparison instruction).
        if (!left_type->is_nullable() && !right_type->is_nullable()) {
          left_value = PrepareStaticOpInput(left_value, kDoubleCid, instr);
          right_value = PrepareStaticOpInput(right_value, kDoubleCid, instr);
          replacement = new (Z) EqualityCompareInstr(
              instr->source(), op_kind, left_value, right_value, kUnboxedDouble,
              DeoptId::kNone, /*null_aware=*/false);
          break;
        }
        break;
      }
      case Token::kLT:
        FALL_THROUGH;
      case Token::kLTE:
        FALL_THROUGH;
      case Token::kGT:
        FALL_THROUGH;
      case Token::kGTE: {
        left_value = PrepareStaticOpInput(left_value, kDoubleCid, instr);
        right_value = PrepareStaticOpInput(right_value, kDoubleCid, instr);
        replacement = new (Z)
            RelationalOpInstr(instr->source(), op_kind, left_value, right_value,
                              kUnboxedDouble, DeoptId::kNone);
        break;
      }
      case Token::kADD:
        FALL_THROUGH;
      case Token::kSUB:
        FALL_THROUGH;
      case Token::kMUL:
        FALL_THROUGH;
      case Token::kDIV: {
        left_value = PrepareStaticOpInput(left_value, kDoubleCid, instr);
        right_value = PrepareStaticOpInput(right_value, kDoubleCid, instr);
        replacement = new (Z) BinaryDoubleOpInstr(
            op_kind, left_value, right_value, DeoptId::kNone, instr->source());
        break;
      }

      case Token::kBIT_OR:
        FALL_THROUGH;
      case Token::kBIT_XOR:
        FALL_THROUGH;
      case Token::kBIT_AND:
        FALL_THROUGH;
      case Token::kMOD:
        FALL_THROUGH;
      case Token::kTRUNCDIV:
        FALL_THROUGH;
      default:
        break;
    }
  } else if (instr->ArgumentCount() == 1) {
    Value* left_value = instr->ArgumentValueAt(0);
    CompileType* left_type = left_value->Type();

    // We only support unary operations on nullable doubles.
    if (!left_type->IsNullableDouble()) {
      return false;
    }

    if (op_kind == Token::kNEGATE) {
      left_value = PrepareStaticOpInput(left_value, kDoubleCid, instr);
      replacement = new (Z)
          UnaryDoubleOpInstr(Token::kNEGATE, left_value, instr->deopt_id());
    }
  }

  if (replacement != nullptr && !replacement->ComputeCanDeoptimize()) {
    if (FLAG_trace_strong_mode_types) {
      THR_Print("[Strong mode] Optimization: replacing %s with %s\n",
                instr->ToCString(), replacement->ToCString());
    }
    ReplaceCall(instr, replacement);
    RefineUseTypes(replacement);
    return true;
  }

  return false;
}

// Tries to optimize instance call by replacing it with a faster instruction
// (e.g, binary op, field load, ..).
// TODO(dartbug.com/30635) Evaluate how much this can be shared with
// JitCallSpecializer.
void AotCallSpecializer::VisitInstanceCall(InstanceCallInstr* instr) {
  // Type test is special as it always gets converted into inlined code.
  const Token::Kind op_kind = instr->token_kind();
  if (Token::IsTypeTestOperator(op_kind)) {
    ReplaceWithInstanceOf(instr);
    return;
  }

  if (TryInlineFieldAccess(instr)) {
    return;
  }

  if (RecognizeRuntimeTypeGetter(instr)) {
    return;
  }

  if ((op_kind == Token::kEQ) && TryReplaceWithHaveSameRuntimeType(instr)) {
    return;
  }

  const CallTargets& targets = instr->Targets();
  const intptr_t receiver_idx = instr->FirstArgIndex();

  if (TryOptimizeInstanceCallUsingStaticTypes(instr)) {
    return;
  }

  bool has_one_target = targets.HasSingleTarget();
  if (has_one_target) {
    // Check if the single target is a polymorphic target, if it is,
    // we don't have one target.
    const Function& target = targets.FirstTarget();
    has_one_target =
        !target.is_polymorphic_target() && !target.IsDynamicallyOverridden();
  }

  if (has_one_target) {
    const Function& target = targets.FirstTarget();
    UntaggedFunction::Kind function_kind = target.kind();
    if (flow_graph()->CheckForInstanceCall(instr, function_kind) ==
        FlowGraph::ToCheck::kNoCheck) {
      StaticCallInstr* call = StaticCallInstr::FromCall(
          Z, instr, target, targets.AggregateCallCount());
      instr->ReplaceWith(call, current_iterator());
      return;
    }
  }

  // No IC data checks. Try resolve target using the propagated cid.
  const intptr_t receiver_cid =
      instr->ArgumentValueAt(receiver_idx)->Type()->ToCid();
  if (receiver_cid != kDynamicCid && receiver_cid != kSentinelCid) {
    const Class& receiver_class =
        Class::Handle(Z, isolate_group()->class_table()->At(receiver_cid));
    const Function& function =
        Function::Handle(Z, instr->ResolveForReceiverClass(receiver_class));
    if (!function.IsNull()) {
      const Function& target = Function::ZoneHandle(Z, function.ptr());
      StaticCallInstr* call =
          StaticCallInstr::FromCall(Z, instr, target, instr->CallCount());
      instr->ReplaceWith(call, current_iterator());
      return;
    }
  }

  // Check for x == y, where x has type T?, there are no subtypes of T, and
  // T does not override ==. Replace with StrictCompare.
  if (instr->token_kind() == Token::kEQ || instr->token_kind() == Token::kNE) {
    GrowableArray<intptr_t> class_ids(6);
    if (instr->ArgumentValueAt(receiver_idx)->Type()->Specialize(&class_ids)) {
      bool is_object_eq = true;
      for (intptr_t i = 0; i < class_ids.length(); i++) {
        const intptr_t cid = class_ids[i];
        // Skip sentinel cid. It may appear in the unreachable code after
        // inlining a method which doesn't return.
        if (cid == kSentinelCid) continue;
        const Class& cls =
            Class::Handle(Z, isolate_group()->class_table()->At(cid));
        const Function& target =
            Function::Handle(Z, instr->ResolveForReceiverClass(cls));
        if (target.recognized_kind() != MethodRecognizer::kObjectEquals) {
          is_object_eq = false;
          break;
        }
      }
      if (is_object_eq) {
        auto* replacement = new (Z) StrictCompareInstr(
            instr->source(),
            (instr->token_kind() == Token::kEQ) ? Token::kEQ_STRICT
                                                : Token::kNE_STRICT,
            instr->ArgumentValueAt(0)->CopyWithType(Z),
            instr->ArgumentValueAt(1)->CopyWithType(Z),
            /*needs_number_check=*/false, DeoptId::kNone);
        ReplaceCall(instr, replacement);
        RefineUseTypes(replacement);
        return;
      }
    }
  }

  Definition* callee_receiver = instr->ArgumentAt(receiver_idx);
  const Function& function = flow_graph()->function();
  Class& receiver_class = Class::Handle(Z);

  if (function.IsDynamicFunction() &&
      flow_graph()->IsReceiver(callee_receiver)) {
    // Call receiver is method receiver.
    receiver_class = function.Owner();
  } else {
    // Check if we have an non-nullable compile type for the receiver.
    CompileType* type = instr->ArgumentAt(receiver_idx)->Type();
    if (type->ToAbstractType()->IsType() &&
        !type->ToAbstractType()->IsDynamicType() && !type->is_nullable()) {
      receiver_class = type->ToAbstractType()->type_class();
      if (receiver_class.is_implemented()) {
        receiver_class = Class::null();
      }
    }
  }
  if (!receiver_class.IsNull()) {
    GrowableArray<intptr_t> class_ids(6);
    if (thread()->compiler_state().cha().ConcreteSubclasses(receiver_class,
                                                            &class_ids)) {
      // First check if all subclasses end up calling the same method.
      // If this is the case we will replace instance call with a direct
      // static call.
      // Otherwise we will try to create ICData that contains all possible
      // targets with appropriate checks.
      Function& single_target = Function::Handle(Z);
      ICData& ic_data = ICData::Handle(Z);
      const Array& args_desc_array =
          Array::Handle(Z, instr->GetArgumentsDescriptor());
      Function& target = Function::Handle(Z);
      Class& cls = Class::Handle(Z);
      for (intptr_t i = 0; i < class_ids.length(); i++) {
        const intptr_t cid = class_ids[i];
        cls = isolate_group()->class_table()->At(cid);
        target = instr->ResolveForReceiverClass(cls);
        ASSERT(target.IsNull() || !target.IsInvokeFieldDispatcher());
        if (target.IsNull()) {
          single_target = Function::null();
          ic_data = ICData::null();
          break;
        } else if (ic_data.IsNull()) {
          // First we are trying to compute a single target for all subclasses.
          if (single_target.IsNull()) {
            ASSERT(i == 0);
            single_target = target.ptr();
            continue;
          } else if (single_target.ptr() == target.ptr()) {
            continue;
          }

          // The call does not resolve to a single target within the hierarchy.
          // If we have too many subclasses abort the optimization.
          if (class_ids.length() > FLAG_max_exhaustive_polymorphic_checks) {
            single_target = Function::null();
            break;
          }

          // Create an ICData and map all previously seen classes (< i) to
          // the computed single_target.
          ic_data = ICData::New(function, instr->function_name(),
                                args_desc_array, DeoptId::kNone,
                                /*num_args_tested=*/1, ICData::kOptimized);
          for (intptr_t j = 0; j < i; j++) {
            ic_data.AddReceiverCheck(class_ids[j], single_target);
          }

          single_target = Function::null();
        }

        ASSERT(ic_data.ptr() != ICData::null());
        ASSERT(single_target.ptr() == Function::null());
        ic_data.AddReceiverCheck(cid, target);
      }

      if (single_target.ptr() != Function::null()) {
        // If this is a getter or setter invocation try inlining it right away
        // instead of replacing it with a static call.
        if ((op_kind == Token::kGET) || (op_kind == Token::kSET)) {
          // Create fake IC data with the resolved target.
          const ICData& ic_data = ICData::Handle(
              ICData::New(flow_graph()->function(), instr->function_name(),
                          args_desc_array, DeoptId::kNone,
                          /*num_args_tested=*/1, ICData::kOptimized));
          cls = single_target.Owner();
          ic_data.AddReceiverCheck(cls.id(), single_target);
          instr->set_ic_data(&ic_data);

          if (TryInlineFieldAccess(instr)) {
            return;
          }
        }

        // We have computed that there is only a single target for this call
        // within the whole hierarchy. Replace InstanceCall with StaticCall.
        const Function& target = Function::ZoneHandle(Z, single_target.ptr());
        StaticCallInstr* call =
            StaticCallInstr::FromCall(Z, instr, target, instr->CallCount());
        instr->ReplaceWith(call, current_iterator());
        return;
      } else if ((ic_data.ptr() != ICData::null()) &&
                 !ic_data.NumberOfChecksIs(0)) {
        const CallTargets* targets = CallTargets::Create(Z, ic_data);
        ASSERT(!targets->is_empty());
        PolymorphicInstanceCallInstr* call =
            PolymorphicInstanceCallInstr::FromCall(Z, instr, *targets,
                                                   /* complete = */ true);
        instr->ReplaceWith(call, current_iterator());
        return;
      }
    }

    // Detect if o.m(...) is a call through a getter and expand it
    // into o.get:m().call(...).
    if (TryExpandCallThroughGetter(receiver_class, instr)) {
      return;
    }
  }

  // More than one target. Generate generic polymorphic call without
  // deoptimization.
  if (targets.length() > 0) {
    ASSERT(!FLAG_polymorphic_with_deopt);
    // OK to use checks with PolymorphicInstanceCallInstr since no
    // deoptimization is allowed.
    PolymorphicInstanceCallInstr* call =
        PolymorphicInstanceCallInstr::FromCall(Z, instr, targets,
                                               /* complete = */ false);
    instr->ReplaceWith(call, current_iterator());
    return;
  }
}

void AotCallSpecializer::VisitStaticCall(StaticCallInstr* instr) {
  if (TryInlineFieldAccess(instr)) {
    return;
  }
  CallSpecializer::VisitStaticCall(instr);
}

bool AotCallSpecializer::TryExpandCallThroughGetter(const Class& receiver_class,
                                                    InstanceCallInstr* call) {
  // If it's an accessor call it can't be a call through getter.
  if (call->token_kind() == Token::kGET || call->token_kind() == Token::kSET) {
    return false;
  }

  // Ignore callsites like f.call() for now. Those need to be handled
  // specially if f is a closure.
  if (call->function_name().ptr() == Symbols::call().ptr()) {
    return false;
  }

  Function& target = Function::Handle(Z);

  const String& getter_name =
      String::ZoneHandle(Z, Symbols::FromGet(thread(), call->function_name()));

  const Array& args_desc_array = Array::Handle(
      Z,
      ArgumentsDescriptor::NewBoxed(/*type_args_len=*/0, /*num_arguments=*/1));
  ArgumentsDescriptor args_desc(args_desc_array);
  target = Resolver::ResolveDynamicForReceiverClass(
      receiver_class, getter_name, args_desc, /*allow_add=*/false);
  if (target.ptr() == Function::null() || target.IsMethodExtractor()) {
    return false;
  }

  // We found a getter with the same name as the method this
  // call tries to invoke. This implies call through getter
  // because methods can't override getters. Build
  // o.get:m().call(...) sequence and replace o.m(...) invocation.

  const intptr_t receiver_idx = call->type_args_len() > 0 ? 1 : 0;

  InputsArray get_arguments(Z, 1);
  get_arguments.Add(call->ArgumentValueAt(receiver_idx)->CopyWithType(Z));
  InstanceCallInstr* invoke_get = new (Z) InstanceCallInstr(
      call->source(), getter_name, Token::kGET, std::move(get_arguments),
      /*type_args_len=*/0,
      /*argument_names=*/Object::empty_array(),
      /*checked_argument_count=*/1,
      thread()->compiler_state().GetNextDeoptId());

  // Arguments to the .call() are the same as arguments to the
  // original call (including type arguments), but receiver
  // is replaced with the result of the get.
  InputsArray call_arguments(Z, call->ArgumentCount());
  if (call->type_args_len() > 0) {
    call_arguments.Add(call->ArgumentValueAt(0)->CopyWithType(Z));
  }
  call_arguments.Add(new (Z) Value(invoke_get));
  for (intptr_t i = receiver_idx + 1; i < call->ArgumentCount(); i++) {
    call_arguments.Add(call->ArgumentValueAt(i)->CopyWithType(Z));
  }

  InstanceCallInstr* invoke_call = new (Z) InstanceCallInstr(
      call->source(), Symbols::call(), Token::kILLEGAL,
      std::move(call_arguments), call->type_args_len(), call->argument_names(),
      /*checked_argument_count=*/1,
      thread()->compiler_state().GetNextDeoptId());

  // Create environment and insert 'invoke_get'.
  Environment* get_env =
      call->env()->DeepCopy(Z, call->env()->Length() - call->ArgumentCount());
  for (intptr_t i = 0, n = invoke_get->ArgumentCount(); i < n; i++) {
    get_env->PushValue(new (Z) Value(invoke_get->ArgumentAt(i)));
  }
  InsertBefore(call, invoke_get, get_env, FlowGraph::kValue);

  // Replace original call with .call(...) invocation.
  call->ReplaceWith(invoke_call, current_iterator());

  // ReplaceWith moved environment from 'call' to 'invoke_call'.
  // Update receiver argument in the environment.
  Environment* invoke_env = invoke_call->env();
  invoke_env
      ->ValueAt(invoke_env->Length() - invoke_call->ArgumentCount() +
                receiver_idx)
      ->BindToEnvironment(invoke_get);

  // AOT compiler expects all calls to have an ICData.
  invoke_get->EnsureICData(flow_graph());
  invoke_call->EnsureICData(flow_graph());

  // Specialize newly inserted calls.
  TryCreateICData(invoke_get);
  VisitInstanceCall(invoke_get);
  TryCreateICData(invoke_call);
  VisitInstanceCall(invoke_call);

  // Success.
  return true;
}

void AotCallSpecializer::VisitPolymorphicInstanceCall(
    PolymorphicInstanceCallInstr* call) {
  const intptr_t receiver_idx = call->type_args_len() > 0 ? 1 : 0;
  const intptr_t receiver_cid =
      call->ArgumentValueAt(receiver_idx)->Type()->ToCid();
  if (receiver_cid != kDynamicCid && receiver_cid != kSentinelCid) {
    const Class& receiver_class =
        Class::Handle(Z, isolate_group()->class_table()->At(receiver_cid));
    const Function& function =
        Function::ZoneHandle(Z, call->ResolveForReceiverClass(receiver_class));
    if (!function.IsNull()) {
      // Only one target. Replace by static call.
      StaticCallInstr* new_call =
          StaticCallInstr::FromCall(Z, call, function, call->CallCount());
      call->ReplaceWith(new_call, current_iterator());
    }
  }
}

bool AotCallSpecializer::TryReplaceInstanceOfWithRangeCheck(
    InstanceCallInstr* call,
    const AbstractType& type) {
  HierarchyInfo* hi = thread()->hierarchy_info();
  if (hi == nullptr) {
    return false;
  }

  intptr_t lower_limit, upper_limit;
  if (!hi->InstanceOfHasClassRange(type, &lower_limit, &upper_limit)) {
    return false;
  }

  Definition* left = call->ArgumentAt(0);
  LoadClassIdInstr* load_cid =
      new (Z) LoadClassIdInstr(new (Z) Value(left), kUnboxedUword);
  InsertBefore(call, load_cid, nullptr, FlowGraph::kValue);

  ConditionInstr* check_range;
  if (lower_limit == upper_limit) {
    ConstantInstr* cid_constant = flow_graph()->GetConstant(
        Smi::Handle(Z, Smi::New(lower_limit)), kUnboxedUword);
    check_range = new (Z)
        EqualityCompareInstr(call->source(), Token::kEQ, new Value(load_cid),
                             new Value(cid_constant), kUnboxedUword,
                             DeoptId::kNone, /*null_aware=*/false);
  } else {
    check_range =
        new (Z) TestRangeInstr(call->source(), new (Z) Value(load_cid),
                               lower_limit, upper_limit, kUnboxedUword);
  }
  ReplaceCall(call, check_range);

  return true;
}

void AotCallSpecializer::ReplaceInstanceCallsWithDispatchTableCalls() {
  ASSERT(current_iterator_ == nullptr);
  const intptr_t max_block_id = flow_graph()->max_block_id();
  for (BlockIterator block_it = flow_graph()->reverse_postorder_iterator();
       !block_it.Done(); block_it.Advance()) {
    ForwardInstructionIterator it(block_it.Current());
    current_iterator_ = &it;
    while (!it.Done()) {
      Instruction* instr = it.Current();
      // Advance to the next instruction before replacing a call,
      // as call can be replaced with a diamond and the rest of
      // the instructions can be moved to a new basic block.
      if (!it.Done()) it.Advance();

      if (auto call = instr->AsInstanceCall()) {
        TryReplaceWithDispatchTableCall(call);
      } else if (auto call = instr->AsPolymorphicInstanceCall()) {
        TryReplaceWithDispatchTableCall(call);
      }
    }
    current_iterator_ = nullptr;
  }
  if (flow_graph()->max_block_id() != max_block_id) {
    flow_graph()->DiscoverBlocks();
  }
}

const Function& AotCallSpecializer::InterfaceTargetForTableDispatch(
    InstanceCallBaseInstr* call) {
  const Function& interface_target = call->interface_target();
  if (!interface_target.IsNull()) {
    return interface_target;
  }

  // Dynamic call or tearoff.
  const Function& tearoff_interface_target = call->tearoff_interface_target();
  if (!tearoff_interface_target.IsNull()) {
    // Tearoff.
    return Function::ZoneHandle(
        Z, tearoff_interface_target.GetMethodExtractor(call->function_name()));
  }

  // Dynamic call.
  return Function::null_function();
}

void AotCallSpecializer::TryReplaceWithDispatchTableCall(
    InstanceCallBaseInstr* call) {
  const Function& interface_target = InterfaceTargetForTableDispatch(call);
  if (interface_target.IsNull()) {
    // Dynamic call.
    return;
  }

  Value* receiver = call->ArgumentValueAt(call->FirstArgIndex());
  const compiler::TableSelector* selector =
      precompiler_->selector_map()->GetSelector(interface_target);

  if (selector == nullptr) {
#if defined(DEBUG)
    if (!interface_target.IsDynamicallyOverridden()) {
      // Target functions were removed by tree shaking. This call is dead code,
      // or the receiver is always null.
      AddCheckNull(receiver->CopyWithType(Z), call->function_name(),
                   DeoptId::kNone, call->env(), call);
      StopInstr* stop = new (Z) StopInstr("Dead instance call executed.");
      InsertBefore(call, stop, call->env(), FlowGraph::kEffect);
    }
#endif
    return;
  }

  const bool receiver_can_be_smi =
      call->CanReceiverBeSmiBasedOnInterfaceTarget(Z);
  auto load_cid = new (Z) LoadClassIdInstr(receiver->CopyWithType(Z),
                                           kUnboxedUword, receiver_can_be_smi);
  InsertBefore(call, load_cid, call->env(), FlowGraph::kValue);

  const auto& cls = Class::Handle(Z, interface_target.Owner());
  if (cls.has_dynamically_extendable_subtypes()) {
    ReplaceWithConditionalDispatchTableCall(call, load_cid, interface_target,
                                            selector);
    return;
  }

  auto dispatch_table_call = DispatchTableCallInstr::FromCall(
      Z, call, new (Z) Value(load_cid), interface_target, selector);
  call->ReplaceWith(dispatch_table_call, current_iterator());
}

void AotCallSpecializer::ReplaceWithConditionalDispatchTableCall(
    InstanceCallBaseInstr* call,
    LoadClassIdInstr* load_cid,
    const Function& interface_target,
    const compiler::TableSelector* selector) {
  BlockEntryInstr* current_block = call->GetBlock();
  const bool has_uses = call->HasUses();
  const auto deopt_id = call->deopt_id();

  const intptr_t num_cids = isolate_group()->class_table()->NumCids();
  auto* compare = new (Z) TestRangeInstr(
      call->source(), new (Z) Value(load_cid), 0, num_cids - 1, kUnboxedUword);

  BranchInstr* branch = new (Z) BranchInstr(compare, deopt_id);

  TargetEntryInstr* true_target = new (Z) TargetEntryInstr(
      flow_graph()->allocate_block_id(), current_block->try_index(), deopt_id);
  *branch->true_successor_address() = true_target;

  TargetEntryInstr* false_target = new (Z) TargetEntryInstr(
      flow_graph()->allocate_block_id(), current_block->try_index(), deopt_id);
  *branch->false_successor_address() = false_target;

  JoinEntryInstr* join = new (Z) JoinEntryInstr(
      flow_graph()->allocate_block_id(), current_block->try_index(), deopt_id);

  current_block->ReplaceAsPredecessorWith(join);

  for (intptr_t i = 0, n = current_block->dominated_blocks().length(); i < n;
       ++i) {
    BlockEntryInstr* block = current_block->dominated_blocks()[i];
    join->AddDominatedBlock(block);
  }
  current_block->ClearDominatedBlocks();
  current_block->AddDominatedBlock(join);
  current_block->AddDominatedBlock(true_target);
  current_block->AddDominatedBlock(false_target);

  PhiInstr* phi = nullptr;
  if (has_uses) {
    phi = new (Z) PhiInstr(join, 2);
    phi->mark_alive();
    flow_graph()->AllocateSSAIndex(phi);
    join->InsertPhi(phi);
    phi->UpdateType(*call->Type());
    phi->set_representation(call->representation());
    call->ReplaceUsesWith(phi);
  }

  GotoInstr* true_goto = new (Z) GotoInstr(join, deopt_id);
  true_target->LinkTo(true_goto);
  true_target->set_last_instruction(true_goto);

  GotoInstr* false_goto = new (Z) GotoInstr(join, deopt_id);
  false_target->LinkTo(false_goto);
  false_target->set_last_instruction(false_goto);

  auto dispatch_table_call = DispatchTableCallInstr::FromCall(
      Z, call, new (Z) Value(load_cid), interface_target, selector);
  ASSERT(dispatch_table_call->representation() == call->representation());
  InsertBefore(true_goto, dispatch_table_call, call->env(),
               has_uses ? FlowGraph::kValue : FlowGraph::kEffect);

  call->previous()->AppendInstruction(branch);
  call->set_previous(nullptr);
  join->LinkTo(call->next());
  call->set_next(nullptr);
  call->UnuseAllInputs();  // So it can be re-added to the graph.
  call->InsertBefore(false_goto);
  if (call->env() != nullptr) {
    call->env()->DeepCopyTo(Z, call);  // Restore env use list.
  }

  if (has_uses) {
    phi->SetInputAt(0, new (Z) Value(dispatch_table_call));
    dispatch_table_call->AddInputUse(phi->InputAt(0));
    phi->SetInputAt(1, new (Z) Value(call));
    call->AddInputUse(phi->InputAt(1));
  }
}

#endif  // DART_PRECOMPILER

}  // namespace dart
