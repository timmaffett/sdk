// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/globals.h"  // Needed here to get TARGET_ARCH_X64.
#if defined(TARGET_ARCH_X64)

#include "vm/code_patcher.h"
#include "vm/cpu.h"
#include "vm/dart_entry.h"
#include "vm/instructions.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/raw_object.h"
#include "vm/reverse_pc_lookup_cache.h"

namespace dart {

// callq [CODE_REG + entry_point_offset (disp8)]
static const int16_t kCallPatternJIT[] = {
    0x41, 0xff, 0x54, 0x24, -1,
};

// callq [TMP + entry_point_offset (disp8)]
static const int16_t kCallPatternAOT[] = {
    0x41,
    0xff,
    0x53,
    -1,
};

static const intptr_t kLoadCodeFromPoolInstructionLength = 3;
static const intptr_t kLoadCodeFromPoolDisp8PatternLength =
    kLoadCodeFromPoolInstructionLength + 1;
static const intptr_t kLoadCodeFromPoolDisp32PatternLength =
    kLoadCodeFromPoolInstructionLength + 4;

// movq CODE_REG, [PP + disp8]
static const int16_t
    kLoadCodeFromPoolDisp8JIT[kLoadCodeFromPoolDisp8PatternLength] = {
        0x4d,
        0x8b,
        0x67,
        -1,
};

// movq CODE_REG, [PP + disp32]
static const int16_t
    kLoadCodeFromPoolDisp32JIT[kLoadCodeFromPoolDisp32PatternLength] = {
        0x4d, 0x8b, 0xa7, -1, -1, -1, -1,
};

// movq TMP, [PP + disp8]
static const int16_t
    kLoadCodeFromPoolDisp8AOT[kLoadCodeFromPoolDisp8PatternLength] = {
        0x4d,
        0x8b,
        0x5f,
        -1,
};

// movq TMP, [PP + disp32]
static const int16_t
    kLoadCodeFromPoolDisp32AOT[kLoadCodeFromPoolDisp32PatternLength] = {
        0x4d, 0x8b, 0x9f, -1, -1, -1, -1,
};

static void MatchCallPattern(uword* pc) {
  const int16_t* call_pattern =
      FLAG_precompiled_mode ? kCallPatternAOT : kCallPatternJIT;
  const intptr_t call_pattern_length = FLAG_precompiled_mode
                                           ? ARRAY_SIZE(kCallPatternAOT)
                                           : ARRAY_SIZE(kCallPatternJIT);

  // callq [reg + entry_point_offset]
  if (MatchesPattern(*pc, call_pattern, call_pattern_length)) {
    *pc -= call_pattern_length;
  } else {
    FATAL("Expected `call [%s + offs]` at %" Px,
          FLAG_precompiled_mode ? "TMP" : "CODE_REG", *pc);
  }
}

static void MatchDataLoadFromPool(uword* pc, intptr_t* data_index) {
  // movq RBX, [PP + offset]
  static int16_t load_data_disp8[] = {
      0x49, 0x8b, 0x5f, -1,  //
  };
  static int16_t load_data_disp32[] = {
      0x49, 0x8b, 0x9f, -1, -1, -1, -1,
  };
  if (MatchesPattern(*pc, load_data_disp8, ARRAY_SIZE(load_data_disp8))) {
    *pc -= ARRAY_SIZE(load_data_disp8);
    *data_index = IndexFromPPLoadDisp8(*pc + 3);
  } else if (MatchesPattern(*pc, load_data_disp32,
                            ARRAY_SIZE(load_data_disp32))) {
    *pc -= ARRAY_SIZE(load_data_disp32);
    *data_index = IndexFromPPLoadDisp32(*pc + 3);
  } else {
    FATAL("Expected `movq RBX, [PP + imm8|imm32]` at %" Px, *pc);
  }
}

static void MatchCodeLoadFromPool(uword* pc, intptr_t* code_index) {
  const int16_t* load_code_disp8_pattern = FLAG_precompiled_mode
                                               ? kLoadCodeFromPoolDisp8AOT
                                               : kLoadCodeFromPoolDisp8JIT;
  const int16_t* load_code_disp32_pattern = FLAG_precompiled_mode
                                                ? kLoadCodeFromPoolDisp32AOT
                                                : kLoadCodeFromPoolDisp32JIT;

  if (MatchesPattern(*pc, load_code_disp8_pattern,
                     kLoadCodeFromPoolDisp8PatternLength)) {
    *pc -= kLoadCodeFromPoolDisp8PatternLength;
    *code_index =
        IndexFromPPLoadDisp8(*pc + kLoadCodeFromPoolInstructionLength);
  } else if (MatchesPattern(*pc, load_code_disp32_pattern,
                            kLoadCodeFromPoolDisp32PatternLength)) {
    *pc -= kLoadCodeFromPoolDisp32PatternLength;
    *code_index =
        IndexFromPPLoadDisp32(*pc + kLoadCodeFromPoolInstructionLength);
  } else {
    FATAL("Expected `movq %s, [PP + imm8|imm32]` at %" Px,
          FLAG_precompiled_mode ? "TMP" : "CODE_REG", *pc);
  }
}

class UnoptimizedCall : public ValueObject {
 public:
  UnoptimizedCall(uword return_address, const Code& code)
      : object_pool_(ObjectPool::Handle(code.GetObjectPool())),
        code_index_(-1),
        argument_index_(-1) {
    uword pc = return_address;
    MatchCallPattern(&pc);
    MatchDataLoadFromPool(&pc, &argument_index_);
    MatchCodeLoadFromPool(&pc, &code_index_);
    ASSERT(Object::Handle(object_pool_.ObjectAt(code_index_)).IsCode());
  }

  intptr_t argument_index() const { return argument_index_; }

  CodePtr target() const {
    Code& code = Code::Handle();
    code ^= object_pool_.ObjectAt(code_index_);
    return code.ptr();
  }

  void set_target(const Code& target) const {
    object_pool_.SetObjectAt(code_index_, target);
    // No need to flush the instruction cache, since the code is not modified.
  }

 protected:
  const ObjectPool& object_pool_;
  intptr_t code_index_;
  intptr_t argument_index_;

 private:
  DISALLOW_IMPLICIT_CONSTRUCTORS(UnoptimizedCall);
};

class NativeCall : public ValueObject {
 public:
  NativeCall(uword return_address, const Code& code)
      : object_pool_(ObjectPool::Handle(code.GetObjectPool())),
        code_index_(-1),
        argument_index_(-1) {
    uword pc = return_address;
    MatchCallPattern(&pc);
    MatchCodeLoadFromPool(&pc, &code_index_);
    MatchDataLoadFromPool(&pc, &argument_index_);
    ASSERT(Object::Handle(object_pool_.ObjectAt(code_index_)).IsCode());
  }

  intptr_t argument_index() const { return argument_index_; }

  NativeFunction native_function() const {
    return reinterpret_cast<NativeFunction>(
        object_pool_.RawValueAt(argument_index()));
  }

  void set_native_function(NativeFunction func) const {
    object_pool_.SetRawValueAt(argument_index(), reinterpret_cast<uword>(func));
  }

  CodePtr target() const {
    Code& code = Code::Handle();
    code ^= object_pool_.ObjectAt(code_index_);
    return code.ptr();
  }

  void set_target(const Code& target) const {
    object_pool_.SetObjectAt(code_index_, target);
    // No need to flush the instruction cache, since the code is not modified.
  }

 private:
  const ObjectPool& object_pool_;
  intptr_t code_index_;
  intptr_t argument_index_;

  DISALLOW_IMPLICIT_CONSTRUCTORS(NativeCall);
};

class InstanceCall : public UnoptimizedCall {
 public:
  InstanceCall(uword return_address, const Code& code)
      : UnoptimizedCall(return_address, code) {
#if defined(DEBUG)
    Object& test_data = Object::Handle(data());
    ASSERT(test_data.IsArray() || test_data.IsICData() ||
           test_data.IsMegamorphicCache());
    if (test_data.IsICData()) {
      ASSERT(ICData::Cast(test_data).NumArgsTested() > 0);
    }
#endif  // DEBUG
  }

  ObjectPtr data() const { return object_pool_.ObjectAt(argument_index()); }
  void set_data(const Object& data) const {
    ASSERT(data.IsArray() || data.IsICData() || data.IsMegamorphicCache());
    object_pool_.SetObjectAt(argument_index(), data);
  }

 private:
  DISALLOW_IMPLICIT_CONSTRUCTORS(InstanceCall);
};

class UnoptimizedStaticCall : public UnoptimizedCall {
 public:
  UnoptimizedStaticCall(uword return_address, const Code& caller_code)
      : UnoptimizedCall(return_address, caller_code) {
#if defined(DEBUG)
    ICData& test_ic_data = ICData::Handle();
    test_ic_data ^= ic_data();
    ASSERT(test_ic_data.NumArgsTested() >= 0);
#endif  // DEBUG
  }

  ObjectPtr ic_data() const { return object_pool_.ObjectAt(argument_index()); }

 private:
  DISALLOW_IMPLICIT_CONSTRUCTORS(UnoptimizedStaticCall);
};

// The expected pattern of a call where the target is loaded from
// the object pool.
class PoolPointerCall : public ValueObject {
 public:
  explicit PoolPointerCall(uword return_address, const Code& caller_code)
      : object_pool_(ObjectPool::Handle(caller_code.GetObjectPool())),
        code_index_(-1) {
    uword pc = return_address;

    MatchCallPattern(&pc);
    MatchCodeLoadFromPool(&pc, &code_index_);
    ASSERT(Object::Handle(object_pool_.ObjectAt(code_index_)).IsCode());
  }

  CodePtr Target() const {
    Code& code = Code::Handle();
    code ^= object_pool_.ObjectAt(code_index_);
    return code.ptr();
  }

  void SetTarget(const Code& target) const {
    object_pool_.SetObjectAt(code_index_, target);
    // No need to flush the instruction cache, since the code is not modified.
  }

 protected:
  const ObjectPool& object_pool_;
  intptr_t code_index_;

 private:
  DISALLOW_IMPLICIT_CONSTRUCTORS(PoolPointerCall);
};

// Instance call that can switch between a direct monomorphic call, an IC call,
// and a megamorphic call.
//   load guarded cid            load ICData             load MegamorphicCache
//   load monomorphic target <-> load ICLookup stub  ->  load MMLookup stub
//   call target.entry           call stub.entry         call stub.entry
class SwitchableCallBase : public ValueObject {
 public:
  explicit SwitchableCallBase(const ObjectPool& object_pool)
      : object_pool_(object_pool), target_index_(-1), data_index_(-1) {}

  intptr_t data_index() const { return data_index_; }
  intptr_t target_index() const { return target_index_; }

  ObjectPtr data() const { return object_pool_.ObjectAt(data_index()); }

  void SetData(const Object& data) const {
    ASSERT(!Object::Handle(object_pool_.ObjectAt(data_index())).IsCode());
    object_pool_.SetObjectAt(data_index(), data);
    // No need to flush the instruction cache, since the code is not modified.
  }

 protected:
  const ObjectPool& object_pool_;
  intptr_t target_index_;
  intptr_t data_index_;

 private:
  DISALLOW_IMPLICIT_CONSTRUCTORS(SwitchableCallBase);
};

// See [SwitchableCallBase] for a switchable calls in general.
//
// The target slot is always a [Code] object: Either the code of the
// monomorphic function or a stub code.
class SwitchableCall : public SwitchableCallBase {
 public:
  SwitchableCall(uword return_address, const Code& caller_code)
      : SwitchableCallBase(ObjectPool::Handle(caller_code.GetObjectPool())) {
    ASSERT(caller_code.ContainsInstructionAt(return_address));
    uword pc = return_address;

    // callq [CODE_REG + entrypoint_offset]
    static int16_t call_pattern[] = {
        0x41, 0xff, 0x54, 0x24, -1,  //
    };
    if (MatchesPattern(pc, call_pattern, ARRAY_SIZE(call_pattern))) {
      pc -= ARRAY_SIZE(call_pattern);
    } else {
      FATAL("Failed to decode at %" Px, pc);
    }

    // movq RBX, [PP + offset]
    MatchDataLoadFromPool(&pc, &data_index_);

    // movq CODE_REG, [PP + offset]
    static int16_t load_code_disp8[] = {
        0x4d, 0x8b, 0x67, -1,  //
    };
    static int16_t load_code_disp32[] = {
        0x4d, 0x8b, 0xa7, -1, -1, -1, -1,
    };
    if (MatchesPattern(pc, load_code_disp8, ARRAY_SIZE(load_code_disp8))) {
      pc -= ARRAY_SIZE(load_code_disp8);
      target_index_ = IndexFromPPLoadDisp8(pc + 3);
    } else if (MatchesPattern(pc, load_code_disp32,
                              ARRAY_SIZE(load_code_disp32))) {
      pc -= ARRAY_SIZE(load_code_disp32);
      target_index_ = IndexFromPPLoadDisp32(pc + 3);
    } else {
      FATAL("Failed to decode at %" Px, pc);
    }
    ASSERT(Object::Handle(object_pool_.ObjectAt(target_index_)).IsCode());
  }

  void SetTarget(const Code& target) const {
    ASSERT(Object::Handle(object_pool_.ObjectAt(target_index())).IsCode());
    object_pool_.SetObjectAt(target_index(), target);
    // No need to flush the instruction cache, since the code is not modified.
  }

  ObjectPtr target() const { return object_pool_.ObjectAt(target_index()); }
};

// See [SwitchableCallBase] for a switchable calls in general.
//
// The target slot is always a direct entrypoint address: Either the entry point
// of the monomorphic function or a stub entry point.
class BareSwitchableCall : public SwitchableCallBase {
 public:
  explicit BareSwitchableCall(uword return_address)
      : SwitchableCallBase(ObjectPool::Handle(
            IsolateGroup::Current()->object_store()->global_object_pool())) {
    uword pc = return_address;

    // callq RCX
    static int16_t call_pattern[] = {
        0xff, 0xd1,  //
    };
    if (MatchesPattern(pc, call_pattern, ARRAY_SIZE(call_pattern))) {
      pc -= ARRAY_SIZE(call_pattern);
    } else {
      FATAL("Failed to decode at %" Px, pc);
    }

    // movq RBX, [PP + offset]
    static int16_t load_data_disp8[] = {
        0x49, 0x8b, 0x5f, -1,  //
    };
    static int16_t load_data_disp32[] = {
        0x49, 0x8b, 0x9f, -1, -1, -1, -1,
    };
    if (MatchesPattern(pc, load_data_disp8, ARRAY_SIZE(load_data_disp8))) {
      pc -= ARRAY_SIZE(load_data_disp8);
      data_index_ = IndexFromPPLoadDisp8(pc + 3);
    } else if (MatchesPattern(pc, load_data_disp32,
                              ARRAY_SIZE(load_data_disp32))) {
      pc -= ARRAY_SIZE(load_data_disp32);
      data_index_ = IndexFromPPLoadDisp32(pc + 3);
    } else {
      FATAL("Failed to decode at %" Px, pc);
    }
    ASSERT(!Object::Handle(object_pool_.ObjectAt(data_index_)).IsCode());

    // movq RCX, [PP + offset]
    static int16_t load_code_disp8[] = {
        0x49, 0x8b, 0x4f, -1,  //
    };
    static int16_t load_code_disp32[] = {
        0x49, 0x8b, 0x8f, -1, -1, -1, -1,
    };
    if (MatchesPattern(pc, load_code_disp8, ARRAY_SIZE(load_code_disp8))) {
      pc -= ARRAY_SIZE(load_code_disp8);
      target_index_ = IndexFromPPLoadDisp8(pc + 3);
    } else if (MatchesPattern(pc, load_code_disp32,
                              ARRAY_SIZE(load_code_disp32))) {
      pc -= ARRAY_SIZE(load_code_disp32);
      target_index_ = IndexFromPPLoadDisp32(pc + 3);
    } else {
      FATAL("Failed to decode at %" Px, pc);
    }
    ASSERT(object_pool_.TypeAt(target_index_) ==
           ObjectPool::EntryType::kImmediate);
  }

  void SetTarget(const Code& target) const {
    ASSERT(object_pool_.TypeAt(target_index()) ==
           ObjectPool::EntryType::kImmediate);
    object_pool_.SetRawValueAt(target_index(), target.MonomorphicEntryPoint());
  }

  uword target_entry() const { return object_pool_.RawValueAt(target_index()); }
};

CodePtr CodePatcher::GetStaticCallTargetAt(uword return_address,
                                           const Code& code) {
  ASSERT(code.ContainsInstructionAt(return_address));
  PoolPointerCall call(return_address, code);
  return call.Target();
}

void CodePatcher::PatchStaticCallAt(uword return_address,
                                    const Code& code,
                                    const Code& new_target) {
  PoolPointerCall call(return_address, code);
  call.SetTarget(new_target);
}

void CodePatcher::PatchPoolPointerCallAt(uword return_address,
                                         const Code& code,
                                         const Code& new_target) {
  ASSERT(code.ContainsInstructionAt(return_address));
  PoolPointerCall call(return_address, code);
  call.SetTarget(new_target);
}

CodePtr CodePatcher::GetInstanceCallAt(uword return_address,
                                       const Code& caller_code,
                                       Object* data) {
  ASSERT(caller_code.ContainsInstructionAt(return_address));
  InstanceCall call(return_address, caller_code);
  if (data != nullptr) {
    *data = call.data();
  }
  return call.target();
}

void CodePatcher::PatchInstanceCallAt(uword return_address,
                                      const Code& caller_code,
                                      const Object& data,
                                      const Code& target) {
  auto thread = Thread::Current();
  thread->isolate_group()->RunWithStoppedMutators([&]() {
    PatchInstanceCallAtWithMutatorsStopped(thread, return_address, caller_code,
                                           data, target);
  });
}

void CodePatcher::PatchInstanceCallAtWithMutatorsStopped(
    Thread* thread,
    uword return_address,
    const Code& caller_code,
    const Object& data,
    const Code& target) {
  ASSERT(caller_code.ContainsInstructionAt(return_address));
  InstanceCall call(return_address, caller_code);
  call.set_data(data);
  call.set_target(target);
}

FunctionPtr CodePatcher::GetUnoptimizedStaticCallAt(uword return_address,
                                                    const Code& caller_code,
                                                    ICData* ic_data_result) {
  ASSERT(caller_code.ContainsInstructionAt(return_address));
  UnoptimizedStaticCall static_call(return_address, caller_code);
  ICData& ic_data = ICData::Handle();
  ic_data ^= static_call.ic_data();
  if (ic_data_result != nullptr) {
    *ic_data_result = ic_data.ptr();
  }
  return ic_data.GetTargetAt(0);
}

void CodePatcher::PatchSwitchableCallAt(uword return_address,
                                        const Code& caller_code,
                                        const Object& data,
                                        const Code& target) {
  auto thread = Thread::Current();
  // Ensure all threads are suspended as we update data and target pair.
  thread->isolate_group()->RunWithStoppedMutators([&]() {
    PatchSwitchableCallAtWithMutatorsStopped(thread, return_address,
                                             caller_code, data, target);
  });
}

void CodePatcher::PatchSwitchableCallAtWithMutatorsStopped(
    Thread* thread,
    uword return_address,
    const Code& caller_code,
    const Object& data,
    const Code& target) {
  if (FLAG_precompiled_mode) {
    BareSwitchableCall call(return_address);
    call.SetData(data);
    call.SetTarget(target);
  } else {
    SwitchableCall call(return_address, caller_code);
    call.SetData(data);
    call.SetTarget(target);
  }
}

ObjectPtr CodePatcher::GetSwitchableCallTargetAt(uword return_address,
                                                 const Code& caller_code) {
  if (FLAG_precompiled_mode) {
    UNREACHABLE();
  } else {
    SwitchableCall call(return_address, caller_code);
    return call.target();
  }
}

uword CodePatcher::GetSwitchableCallTargetEntryAt(uword return_address,
                                                  const Code& caller_code) {
  if (FLAG_precompiled_mode) {
    BareSwitchableCall call(return_address);
    return call.target_entry();
  } else {
    UNREACHABLE();
  }
}

ObjectPtr CodePatcher::GetSwitchableCallDataAt(uword return_address,
                                               const Code& caller_code) {
  if (FLAG_precompiled_mode) {
    BareSwitchableCall call(return_address);
    return call.data();
  } else {
    SwitchableCall call(return_address, caller_code);
    return call.data();
  }
}

void CodePatcher::PatchNativeCallAt(uword return_address,
                                    const Code& caller_code,
                                    NativeFunction target,
                                    const Code& trampoline) {
  Thread::Current()->isolate_group()->RunWithStoppedMutators([&]() {
    ASSERT(caller_code.ContainsInstructionAt(return_address));
    NativeCall call(return_address, caller_code);
    call.set_target(trampoline);
    call.set_native_function(target);
  });
}

CodePtr CodePatcher::GetNativeCallAt(uword return_address,
                                     const Code& caller_code,
                                     NativeFunction* target) {
  ASSERT(caller_code.ContainsInstructionAt(return_address));
  NativeCall call(return_address, caller_code);
  *target = call.native_function();
  return call.target();
}

}  // namespace dart

#endif  // defined TARGET_ARCH_X64
