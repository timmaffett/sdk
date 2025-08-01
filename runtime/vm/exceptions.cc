// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include <setjmp.h>

#include "vm/exceptions.h"

#include "platform/address_sanitizer.h"
#include "platform/thread_sanitizer.h"

#include "lib/stacktrace.h"

#include "vm/dart_api_impl.h"
#include "vm/dart_api_state.h"
#include "vm/dart_entry.h"
#include "vm/datastream.h"
#include "vm/debugger.h"
#include "vm/deopt_instructions.h"
#include "vm/flags.h"
#include "vm/interpreter.h"
#include "vm/log.h"
#include "vm/longjump.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/stack_frame.h"
#include "vm/stub_code.h"
#include "vm/symbols.h"

namespace dart {

DECLARE_FLAG(bool, trace_deoptimization);
DEFINE_FLAG(bool,
            print_stacktrace_at_throw,
            false,
            "Prints a stack trace everytime a throw occurs.");

class StackTraceBuilder : public ValueObject {
 public:
  explicit StackTraceBuilder(const Instance& stacktrace)
      : stacktrace_(StackTrace::Cast(stacktrace)),
        cur_index_(0),
        dropped_frames_(0) {}
  ~StackTraceBuilder() {}

  void AddFrame(const Object& code, uword pc_offset);

 private:
  static constexpr int kNumTopframes = StackTrace::kFixedOOMStackdepth / 2;

  const StackTrace& stacktrace_;
  intptr_t cur_index_;
  intptr_t dropped_frames_;

  DISALLOW_COPY_AND_ASSIGN(StackTraceBuilder);
};

void StackTraceBuilder::AddFrame(const Object& code, uword pc_offset) {
  if (cur_index_ >= StackTrace::kFixedOOMStackdepth) {
    // The number of frames is overflowing the preallocated stack trace object.
    Object& frame_code = Object::Handle();
    intptr_t start = StackTrace::kFixedOOMStackdepth - (kNumTopframes - 1);
    intptr_t null_slot = start - 2;
    // We are going to drop one frame.
    dropped_frames_++;
    // Add an empty slot to indicate the overflow so that the toString
    // method can account for the overflow.
    if (stacktrace_.CodeAtFrame(null_slot) != Code::null()) {
      stacktrace_.SetCodeAtFrame(null_slot, frame_code);
      // We drop an extra frame here too.
      dropped_frames_++;
    }
    // Encode the number of dropped frames into the pc offset.
    stacktrace_.SetPcOffsetAtFrame(null_slot, dropped_frames_);
    // Move frames one slot down so that we can accommodate the new frame.
    for (intptr_t i = start; i < StackTrace::kFixedOOMStackdepth; i++) {
      intptr_t prev = (i - 1);
      frame_code = stacktrace_.CodeAtFrame(i);
      const uword frame_offset = stacktrace_.PcOffsetAtFrame(i);
      stacktrace_.SetCodeAtFrame(prev, frame_code);
      stacktrace_.SetPcOffsetAtFrame(prev, frame_offset);
    }
    cur_index_ = (StackTrace::kFixedOOMStackdepth - 1);
  }
  stacktrace_.SetCodeAtFrame(cur_index_, code);
  stacktrace_.SetPcOffsetAtFrame(cur_index_, pc_offset);
  cur_index_ += 1;
}

static void BuildStackTrace(StackTraceBuilder* builder) {
  StackFrameIterator frames(ValidationPolicy::kDontValidateFrames,
                            Thread::Current(),
                            StackFrameIterator::kNoCrossThreadIteration);
  StackFrame* frame = frames.NextFrame();
  ASSERT(frame != nullptr);  // We expect to find a dart invocation frame.
  Code& code = Code::Handle();
  Bytecode& bytecode = Bytecode::Handle();
  for (; frame != nullptr; frame = frames.NextFrame()) {
    if (!frame->IsDartFrame()) {
      continue;
    }
    if (frame->is_interpreted()) {
      bytecode = frame->LookupDartBytecode();
      ASSERT(bytecode.ContainsInstructionAt(frame->pc()));
      if (bytecode.function() == Function::null()) {
        continue;
      }
      const uword pc_offset = frame->pc() - bytecode.PayloadStart();
      builder->AddFrame(bytecode, pc_offset);
    } else {
      code = frame->LookupDartCode();
      ASSERT(code.ContainsInstructionAt(frame->pc()));
      const uword pc_offset = frame->pc() - code.PayloadStart();
      builder->AddFrame(code, pc_offset);
    }
  }
}

class ExceptionHandlerFinder : public StackResource {
 public:
  explicit ExceptionHandlerFinder(Thread* thread)
      : StackResource(thread), thread_(thread) {}

  // Iterate through the stack frames and try to find a frame with an
  // exception handler. Once found, set the pc, sp and fp so that execution
  // can continue in that frame. Sets 'needs_stacktrace' if there is no
  // catch-all handler or if a stack-trace is specified in the catch.
  bool Find() {
    StackFrameIterator frames(ValidationPolicy::kDontValidateFrames,
                              Thread::Current(),
                              StackFrameIterator::kNoCrossThreadIteration);
    StackFrame* frame = frames.NextFrame();
    if (frame == nullptr) return false;  // No Dart frame.
    handler_pc_set_ = false;
    needs_stacktrace = false;
    bool is_catch_all = false;
    uword temp_handler_pc = kUwordMax;
    bool is_optimized = false;
    code_ = nullptr;

    while (!frame->IsEntryFrame()) {
      if (frame->IsDartFrame()) {
        if (frame->FindExceptionHandler(thread_, &temp_handler_pc,
                                        &needs_stacktrace, &is_catch_all,
                                        &is_optimized)) {
          if (!handler_pc_set_) {
            handler_pc_set_ = true;
            handler_pc = temp_handler_pc;
            handler_sp = frame->sp();
            handler_fp = frame->fp();
            if (is_optimized &&
                (handler_pc !=
                 StubCode::AsyncExceptionHandler().EntryPoint())) {
              pc_ = frame->pc();
              code_ = &Code::Handle(frame->LookupDartCode());
            }
          }
          if (needs_stacktrace || is_catch_all) {
            return true;
          }
        }
      }  // if frame->IsDartFrame
      frame = frames.NextFrame();
      ASSERT(frame != nullptr);
    }  // while !frame->IsEntryFrame
    ASSERT(frame->IsEntryFrame());
    if (!handler_pc_set_) {
      handler_pc = frame->pc();
      handler_sp = frame->sp();
      handler_fp = frame->fp();
    }
    // No catch-all encountered, needs stacktrace.
    needs_stacktrace = true;
    return handler_pc_set_;
  }

  // When entering catch block in the optimized code we need to execute
  // catch entry moves that would morph the state of the frame into
  // what catch entry expects.
  void PrepareFrameForCatchEntry() {
    if (code_ == nullptr || !code_->is_optimized()) {
      return;
    }
    thread_->isolate_group()->RunWithCachedCatchEntryMoves(
        *code_, pc_,
        [&](const CatchEntryMoves& moves) { ExecuteCatchEntryMoves(moves); });
  }

  void ExecuteCatchEntryMoves(const CatchEntryMoves& moves) {
    Zone* zone = Thread::Current()->zone();
    auto& value = Object::Handle(zone);
    GrowableArray<Object*> dst_values;

    uword fp = handler_fp;
    ObjectPool* pool = nullptr;
    for (int j = 0; j < moves.count(); j++) {
      const CatchEntryMove& move = moves.At(j);

      switch (move.source_kind()) {
        case CatchEntryMove::SourceKind::kConstant:
          if (pool == nullptr) {
            pool = &ObjectPool::Handle(code_->GetObjectPool());
          }
          value = pool->ObjectAt(move.src_slot());
          break;

        case CatchEntryMove::SourceKind::kTaggedSlot:
          value = *TaggedSlotAt(fp, move.src_slot());
          break;

        case CatchEntryMove::SourceKind::kFloatSlot:
          value = Double::New(*SlotAt<float>(fp, move.src_slot()));
          break;

        case CatchEntryMove::SourceKind::kDoubleSlot:
          value = Double::New(*SlotAt<double>(fp, move.src_slot()));
          break;

        case CatchEntryMove::SourceKind::kFloat32x4Slot:
          value = Float32x4::New(*SlotAt<simd128_value_t>(fp, move.src_slot()));
          break;

        case CatchEntryMove::SourceKind::kFloat64x2Slot:
          value = Float64x2::New(*SlotAt<simd128_value_t>(fp, move.src_slot()));
          break;

        case CatchEntryMove::SourceKind::kInt32x4Slot:
          value = Int32x4::New(*SlotAt<simd128_value_t>(fp, move.src_slot()));
          break;

        case CatchEntryMove::SourceKind::kInt64PairSlot:
          value = Integer::New(
              Utils::LowHighTo64Bits(*SlotAt<uint32_t>(fp, move.src_lo_slot()),
                                     *SlotAt<int32_t>(fp, move.src_hi_slot())));
          break;

        case CatchEntryMove::SourceKind::kInt64Slot:
          value = Integer::New(*SlotAt<int64_t>(fp, move.src_slot()));
          break;

        case CatchEntryMove::SourceKind::kInt32Slot:
          value = Integer::New(*SlotAt<int32_t>(fp, move.src_slot()));
          break;

        case CatchEntryMove::SourceKind::kUint32Slot:
          value = Integer::New(*SlotAt<uint32_t>(fp, move.src_slot()));
          break;

        default:
          UNREACHABLE();
      }

      dst_values.Add(&Object::Handle(zone, value.ptr()));
    }

    {
      Thread* thread = Thread::Current();
      NoSafepointScope no_safepoint_scope(thread);

      for (int j = 0; j < moves.count(); j++) {
        const CatchEntryMove& move = moves.At(j);
        *TaggedSlotAt(fp, move.dest_slot()) = dst_values[j]->ptr();
      }

      // Update the return address in the stack so the correct stack map is used
      // for any stack walks that happen before we jump to the handler.
      StackFrameIterator frames(ValidationPolicy::kDontValidateFrames, thread,
                                StackFrameIterator::kNoCrossThreadIteration);
      bool found = false;
      for (StackFrame* frame = frames.NextFrame(); frame != nullptr;
           frame = frames.NextFrame()) {
        if (frame->fp() == handler_fp) {
          ASSERT_EQUAL(frame->pc(), static_cast<uword>(pc_));
          frame->set_pc(handler_pc);
          found = true;
          break;
        }
      }
      ASSERT(found);
    }
  }

  bool needs_stacktrace;
  uword handler_pc;
  uword handler_sp;
  uword handler_fp;

 private:
  template <typename T>
  static T* SlotAt(uword fp, int stack_slot) {
    const intptr_t frame_slot =
        runtime_frame_layout.FrameSlotForVariableIndex(-stack_slot);
    return reinterpret_cast<T*>(fp + frame_slot * kWordSize);
  }

  static ObjectPtr* TaggedSlotAt(uword fp, int stack_slot) {
    return SlotAt<ObjectPtr>(fp, stack_slot);
  }

  typedef ReadStream::Raw<sizeof(intptr_t), intptr_t> Reader;
  Thread* thread_;
  Code* code_;
  bool handler_pc_set_;
  intptr_t pc_;  // Current pc in the handler frame.
};

CatchEntryMove CatchEntryMove::ReadFrom(ReadStream* stream) {
  using Reader = ReadStream::Raw<sizeof(int32_t), int32_t>;
  const int32_t src = Reader::Read(stream);
  const int32_t dest_and_kind = Reader::Read(stream);
  return CatchEntryMove(src, dest_and_kind);
}

void CatchEntryMove::WriteTo(BaseWriteStream* stream) {
  using Writer = BaseWriteStream::Raw<sizeof(int32_t), int32_t>;
  Writer::Write(stream, src_);
  Writer::Write(stream, dest_and_kind_);
}

#if !defined(PRODUCT) || defined(FORCE_INCLUDE_DISASSEMBLER)
static intptr_t SlotIndexToFrameIndex(intptr_t slot) {
  return runtime_frame_layout.FrameSlotForVariableIndex(-slot);
}

static intptr_t SlotIndexToFpRelativeOffset(intptr_t slot) {
  return SlotIndexToFrameIndex(slot) * compiler::target::kWordSize;
}

const char* CatchEntryMove::ToCString() const {
  char from[256];

  switch (source_kind()) {
    case SourceKind::kConstant:
      Utils::SNPrint(from, ARRAY_SIZE(from), "pp[%" Pd "]",
                     SlotIndexToFrameIndex(src_slot()));
      break;

    case SourceKind::kTaggedSlot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "fp[%" Pd "]",
                     SlotIndexToFrameIndex(src_slot()));
      break;

    case SourceKind::kFloatSlot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "f32 [fp%+" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    case SourceKind::kDoubleSlot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "f64 [fp%+" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    case SourceKind::kFloat32x4Slot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "f32x4 [fp%+" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    case SourceKind::kFloat64x2Slot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "f64x2 [fp%+" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    case SourceKind::kInt32x4Slot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "i32x4 [fp%+" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    case SourceKind::kInt64PairSlot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "i64 ([fp%+" Pd "], [fp%+" Pd "])",
                     SlotIndexToFpRelativeOffset(src_lo_slot()),
                     SlotIndexToFpRelativeOffset(src_hi_slot()));
      break;

    case SourceKind::kInt64Slot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "i64 [fp%+" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    case SourceKind::kInt32Slot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "i32 [fp%+" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    case SourceKind::kUint32Slot:
      Utils::SNPrint(from, ARRAY_SIZE(from), "u32 [fp + %" Pd "]",
                     SlotIndexToFpRelativeOffset(src_slot()));
      break;

    default:
      UNREACHABLE();
  }

  return Thread::Current()->zone()->PrintToString(
      "fp[%+" Pd "] <- %s", SlotIndexToFrameIndex(dest_slot()), from);
}

void CatchEntryMovesMapReader::PrintEntries() {
  NoSafepointScope no_safepoint;

  using Reader = ReadStream::Raw<sizeof(intptr_t), intptr_t>;

  ReadStream stream(static_cast<uint8_t*>(bytes_.DataAddr(0)), bytes_.Length());

  while (stream.PendingBytes() > 0) {
    const intptr_t stream_position = stream.Position();
    const intptr_t target_pc_offset = Reader::Read(&stream);
    const intptr_t prefix_length = Reader::Read(&stream);
    const intptr_t suffix_length = Reader::Read(&stream);
    const intptr_t length = prefix_length + suffix_length;
    Reader::Read(&stream);  // Skip suffix_offset
    for (intptr_t j = 0; j < prefix_length; j++) {
      CatchEntryMove::ReadFrom(&stream);
    }

    ReadStream inner_stream(static_cast<uint8_t*>(bytes_.DataAddr(0)),
                            bytes_.Length());
    CatchEntryMoves* moves = ReadCompressedCatchEntryMovesSuffix(
        &inner_stream, stream_position, length);
    THR_Print("  [code+0x%08" Px "]: (% " Pd " moves)\n", target_pc_offset,
              moves->count());
    for (intptr_t i = 0; i < moves->count(); i++) {
      THR_Print("    %s\n", moves->At(i).ToCString());
    }
    CatchEntryMoves::Free(moves);
  }
}
#endif  // !defined(PRODUCT) || defined(FORCE_INCLUDE_DISASSEMBLER)

CatchEntryMoves* CatchEntryMovesMapReader::ReadMovesForPcOffset(
    intptr_t pc_offset) {
  NoSafepointScope no_safepoint;

  ReadStream stream(static_cast<uint8_t*>(bytes_.DataAddr(0)), bytes_.Length());

  intptr_t position = 0;
  intptr_t length = 0;
  FindEntryForPc(&stream, pc_offset, &position, &length);

  return ReadCompressedCatchEntryMovesSuffix(&stream, position, length);
}

void CatchEntryMovesMapReader::FindEntryForPc(ReadStream* stream,
                                              intptr_t pc_offset,
                                              intptr_t* position,
                                              intptr_t* length) {
  using Reader = ReadStream::Raw<sizeof(intptr_t), intptr_t>;

  while (stream->PendingBytes() > 0) {
    const intptr_t stream_position = stream->Position();
    const intptr_t target_pc_offset = Reader::Read(stream);
    const intptr_t prefix_length = Reader::Read(stream);
    const intptr_t suffix_length = Reader::Read(stream);
    Reader::Read(stream);  // Skip suffix_offset
    if (pc_offset == target_pc_offset) {
      *position = stream_position;
      *length = prefix_length + suffix_length;
      return;
    }

    // Skip the prefix moves.
    for (intptr_t j = 0; j < prefix_length; j++) {
      CatchEntryMove::ReadFrom(stream);
    }
  }

  UNREACHABLE();
}

CatchEntryMoves* CatchEntryMovesMapReader::ReadCompressedCatchEntryMovesSuffix(
    ReadStream* stream,
    intptr_t offset,
    intptr_t length) {
  using Reader = ReadStream::Raw<sizeof(intptr_t), intptr_t>;

  CatchEntryMoves* moves = CatchEntryMoves::Allocate(length);

  intptr_t remaining_length = length;

  intptr_t moves_offset = 0;
  while (remaining_length > 0) {
    stream->SetPosition(offset);
    Reader::Read(stream);  // skip pc_offset
    Reader::Read(stream);  // skip prefix length
    const intptr_t suffix_length = Reader::Read(stream);
    const intptr_t suffix_offset = Reader::Read(stream);
    const intptr_t to_read = remaining_length - suffix_length;
    if (to_read > 0) {
      for (int j = 0; j < to_read; j++) {
        // The prefix is written from the back.
        moves->At(moves_offset + to_read - j - 1) =
            CatchEntryMove::ReadFrom(stream);
      }
      remaining_length -= to_read;
      moves_offset += to_read;
    }
    offset = suffix_offset;
  }

  return moves;
}

static void ClearLazyDeopts(Thread* thread, uword frame_pointer) {
  if (thread->pending_deopts().HasPendingDeopts()) {
    // We may be jumping over frames scheduled for lazy deopt. Remove these
    // frames from the pending deopt table, but only after unmarking them so
    // any stack walk that happens before the stack is unwound will still work.
    {
      DartFrameIterator frames(thread,
                               StackFrameIterator::kNoCrossThreadIteration);
      for (StackFrame* frame = frames.NextFrame(); frame != nullptr;
           frame = frames.NextFrame()) {
        if (frame->is_interpreted()) {
          continue;
        } else if (frame->fp() >= frame_pointer) {
          break;
        }
        if (frame->IsMarkedForLazyDeopt()) {
          frame->UnmarkForLazyDeopt();
        }
      }
    }

#if defined(DEBUG)
    ValidateFrames();
#endif

    thread->pending_deopts().ClearPendingDeoptsBelow(
        frame_pointer, PendingDeopts::kClearDueToThrow);

#if defined(DEBUG)
    ValidateFrames();
#endif
  }
}

enum ExceptionType { kPassObject, kPassHandle, kPassUnboxed };

static void JumpToExceptionHandler(Thread* thread,
                                   uword program_counter,
                                   uword stack_pointer,
                                   uword frame_pointer,
                                   const Object& exception_object,
                                   const Object& stacktrace_object,
                                   ExceptionType type = kPassObject) {
  bool clear_deopt = false;
  uword remapped_pc = thread->pending_deopts().RemapExceptionPCForDeopt(
      program_counter, frame_pointer, &clear_deopt);
  uword run_exception_pc = StubCode::RunExceptionHandler().EntryPoint();
  switch (type) {
    case kPassObject:
      thread->set_active_exception(exception_object);
      break;
    case kPassHandle: {
      LocalHandle* handle =
          thread->api_top_scope()->local_handles()->AllocateHandle();
      handle->set_ptr(exception_object.ptr());
      thread->set_active_exception(handle);
      break;
    }
    case kPassUnboxed: {
      thread->set_active_exception(exception_object);
      run_exception_pc = StubCode::RunExceptionHandlerUnbox().EntryPoint();
      break;
    }
    default:
      UNREACHABLE();
  }
  thread->set_active_stacktrace(stacktrace_object);
  thread->set_resume_pc(remapped_pc);
  Exceptions::JumpToFrame(thread, run_exception_pc, stack_pointer,
                          frame_pointer, clear_deopt);
}

NO_SANITIZE_SAFE_STACK  // This function manipulates the safestack pointer.
    void Exceptions::JumpToFrame(Thread* thread,
                                 uword program_counter,
                                 uword stack_pointer,
                                 uword frame_pointer,
                                 bool clear_deopt_at_target) {
  ASSERT(thread->execution_state() == Thread::kThreadInVM);

  const uword fp_for_clearing =
      (clear_deopt_at_target ? frame_pointer + 1 : frame_pointer);
  ClearLazyDeopts(thread, fp_for_clearing);

  // Prepare for unwinding frames by destroying all the stack resources
  // in the previous frames.
  StackResource::Unwind(thread);

#if defined(DART_DYNAMIC_MODULES)
  Interpreter* interpreter = thread->interpreter();
  if ((interpreter != nullptr) && interpreter->HasFrame(frame_pointer)) {
    interpreter->JumpToFrame(program_counter, stack_pointer, frame_pointer,
                             thread);
  }
#endif  // defined(DART_DYNAMIC_MODULES)

  // If execution exited generated code through FFI then exit the safepoint
  // and transition back to kThreadInGenerated execution state. JumpToFrame
  // stub will transfer control directly to the exception handler and bypass
  // inlined transition code which follows the FFI callsite.
  //
  // For contrast, runtime calls perform transition by entering
  // the |TransitionGeneratedToVM| scope in the runtime entry itself
  // (see DEFINE_RUNTIME_ENTRY_IMPL boilerplate in runtime_entry.h). This scope
  // will be destroyed by |StackResource::Unwind| above and execution state
  // will transition to kThreadInGenerated as a side-effect of that.
  //
  // Important: thread must exit safepoint before |JumpToFrame| is called
  // because the stub will unwind the stack and thus destroy the exit frame,
  // which can only happen outside of safepoint - as GC otherwise might try
  // to use it to traverse the stack.
  if (thread->exit_through_ffi() == Thread::kExitThroughFfi) {
    // StackResource::Unwind above should have left us in the Native state by
    // destroying appropriate TransitionNativeToVM.
    ASSERT(thread->execution_state() == Thread::kThreadInNative);
    thread->ExitSafepointFromNative();
    thread->set_execution_state(Thread::kThreadInGenerated);
  }

#if defined(DART_INCLUDE_SIMULATOR)
  // Unwinding of the C++ frames and destroying of their stack resources is done
  // by the simulator, because the target stack_pointer is a simulated stack
  // pointer and not the C++ stack pointer.

  // Continue simulating at the given pc in the given frame after setting up the
  // exception object in the kExceptionObjectReg register and the stacktrace
  // object (may be raw null) in the kStackTraceObjectReg register.

  if (FLAG_use_simulator) {
    Simulator::Current()->JumpToFrame(program_counter, stack_pointer,
                                      frame_pointer, thread);
    UNREACHABLE();
  }
#endif

  // Zero out HWASAN tags from the current stack pointer to the destination.
  //
  // Stack region is by default tagged with 0 (including SP and all pointers
  // derived from it via arithmetic), however HWASAN also selectively tags
  // some stack allocations - which means these tags need to be zeroed out
  // when the stack is unwound so that it could be safely reused later.
  HWASAN_HANDLE_LONGJMP(reinterpret_cast<void*>(stack_pointer));

  // Unpoison the stack before we tear it down in the generated stub code.
  uword current_sp = OSThread::GetCurrentStackPointer() - 1024;
  ASAN_UNPOISON(reinterpret_cast<void*>(current_sp),
                stack_pointer - current_sp);

  // We are jumping over C++ frames, so we have to set the safestack pointer
  // back to what it was when we entered the runtime from Dart code.
#if defined(USING_SAFE_STACK)
  const uword saved_ssp = thread->saved_safestack_limit();
  OSThread::SetCurrentSafestackPointer(saved_ssp);
#endif

#if defined(USING_SHADOW_CALL_STACK)
  // The shadow call stack register will be restored by the JumpToFrame stub.
#endif

#if defined(USING_THREAD_SANITIZER)
  if (thread->exit_through_ffi() == Thread::kExitThroughRuntimeCall) {
    auto tsan_utils = thread->tsan_utils();
    tsan_utils->exception_pc = program_counter;
    tsan_utils->exception_sp = stack_pointer;
    tsan_utils->exception_fp = frame_pointer;
    DART_LONGJMP(*(tsan_utils->setjmp_buffer), 1);
  }
#endif  // defined(USING_THREAD_SANITIZER)

  // Call a stub to set up the exception object in kExceptionObjectReg,
  // to set up the stacktrace object in kStackTraceObjectReg, and to
  // continue execution at the given pc in the given frame.
  typedef void (*ExcpHandler)(uword, uword, uword, Thread*);
  ExcpHandler func =
      reinterpret_cast<ExcpHandler>(StubCode::JumpToFrame().EntryPoint());

  if (thread->is_unwind_in_progress()) {
    thread->SetUnwindErrorInProgress(true);
  }
  func(program_counter, stack_pointer, frame_pointer, thread);

  UNREACHABLE();
}

static FieldPtr LookupStackTraceField(const Instance& instance) {
  if (instance.GetClassId() < kNumPredefinedCids) {
    // 'class Error' is not a predefined class.
    return Field::null();
  }
  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();
  auto isolate_group = thread->isolate_group();
  const auto& error_class =
      Class::Handle(zone, isolate_group->object_store()->error_class());
  // If instance class extends 'class Error' return '_stackTrace' field.
  Class& test_class = Class::Handle(zone, instance.clazz());
  AbstractType& type = AbstractType::Handle(zone, AbstractType::null());
  while (true) {
    if (test_class.ptr() == error_class.ptr()) {
      return error_class.LookupInstanceFieldAllowPrivate(
          Symbols::_stackTrace());
    }
    type = test_class.super_type();
    if (type.IsNull()) return Field::null();
    test_class = type.type_class();
  }
  UNREACHABLE();
  return Field::null();
}

StackTracePtr Exceptions::CurrentStackTrace() {
  return GetStackTraceForException();
}

static StackTracePtr TryCreateStackTrace(Thread* thread, Zone* zone) {
  LongJumpScope jump(thread);
  if (DART_SETJMP(*jump.Set()) == 0) {
    const Array& code_array = Array::Handle(
        zone, Array::New(StackTrace::kFixedOOMStackdepth, Heap::kOld));
    const TypedData& pc_offset_array = TypedData::Handle(
        zone, TypedData::New(kUintPtrCid, StackTrace::kFixedOOMStackdepth,
                             Heap::kOld));
    const StackTrace& stack_trace =
        StackTrace::Handle(zone, StackTrace::New(code_array, pc_offset_array));
    // Expansion of inlined functions requires additional memory at run time,
    // avoid it.
    stack_trace.set_expand_inlined(false);
    return stack_trace.ptr();
  } else {
    RELEASE_ASSERT(thread->StealStickyError() ==
                   Object::out_of_memory_error().ptr());
    return StackTrace::null();
  }
}

static UnhandledExceptionPtr CreateUnhandledExceptionOrUsePrecanned(
    Thread* thread,
    const Instance& exception,
    const Instance& stacktrace) {
  LongJumpScope jump(thread);
  if (DART_SETJMP(*jump.Set()) == 0) {
    UnhandledException& unhandled =
        UnhandledException::Handle(UnhandledException::New(Heap::kOld));
    unhandled.set_exception(exception);
    unhandled.set_stacktrace(stacktrace);
    return unhandled.ptr();
  } else {
    RELEASE_ASSERT(thread->StealStickyError() ==
                   Object::out_of_memory_error().ptr());
    // If we failed to create new instance, use pre-canned one.
    return Object::unhandled_oom_exception().ptr();
  }
}

DART_NORETURN
static void ThrowExceptionHelper(Thread* thread,
                                 const Instance& incoming_exception,
                                 const Instance& existing_stacktrace,
                                 const bool is_rethrow,
                                 const bool bypass_debugger) {
  // SuspendLongJumpScope during Dart entry ensures that if a longjmp base is
  // available, it is the innermost error handler. If one is available, so
  // should jump there instead.
  RELEASE_ASSERT(thread->long_jump_base() == nullptr);
  Zone* zone = thread->zone();
  auto object_store = thread->isolate_group()->object_store();
#if !defined(PRODUCT)
  Isolate* isolate = thread->isolate();
  // TODO(dartbug.com/60507): Support debugging of isolate group dart mutator.
  if (!bypass_debugger && isolate != nullptr) {
    // Do not notify debugger on stack overflow and out of memory exceptions.
    // The VM would crash when the debugger calls back into the VM to
    // get values of variables.
    if (incoming_exception.ptr() != object_store->out_of_memory() &&
        incoming_exception.ptr() != object_store->stack_overflow()) {
      thread->isolate()->debugger()->PauseException(incoming_exception);
    }
  }
#endif
  bool create_stacktrace = false;
  Instance& exception = Instance::Handle(zone, incoming_exception.ptr());
  if (exception.IsNull()) {
    const Array& args = Array::Handle(zone, Array::New(4));
    const Smi& line_col = Smi::Handle(zone, Smi::New(-1));
    args.SetAt(0, Symbols::OptimizedOut());
    args.SetAt(1, line_col);
    args.SetAt(2, line_col);
    args.SetAt(3, String::Handle(String::New("Throw of null.")));
    exception ^= Exceptions::Create(Exceptions::kType, args);
  } else if (existing_stacktrace.IsNull() &&
             (exception.ptr() == object_store->out_of_memory() ||
              exception.ptr() == object_store->stack_overflow())) {
    create_stacktrace = true;
  }
  // Find the exception handler and determine if the handler needs a
  // stacktrace.
  ExceptionHandlerFinder finder(thread);
  bool handler_exists = finder.Find();
  uword handler_pc = finder.handler_pc;
  uword handler_sp = finder.handler_sp;
  uword handler_fp = finder.handler_fp;
  bool handler_needs_stacktrace = finder.needs_stacktrace;
  Instance& stacktrace = Instance::Handle(zone);
  if (create_stacktrace) {
    // Ensure we have enough memory to create stacktrace,
    // otherwise fallback to reporting OOM without stacktrace.
    stacktrace = TryCreateStackTrace(thread, zone);
    if (!stacktrace.IsNull()) {
      if (handler_pc == 0) {
        // No Dart frame.
        ASSERT(incoming_exception.ptr() == object_store->out_of_memory());
        UnhandledException& error = UnhandledException::Handle(
            zone,
            CreateUnhandledExceptionOrUsePrecanned(
                thread, Instance::Handle(zone, object_store->out_of_memory()),
                stacktrace));
        thread->long_jump_base()->Jump(1, error);
        UNREACHABLE();
      }
      StackTraceBuilder frame_builder(stacktrace);
      ASSERT(existing_stacktrace.IsNull() ||
             (existing_stacktrace.ptr() == stacktrace.ptr()));
      ASSERT(existing_stacktrace.IsNull() || is_rethrow);
      if (handler_needs_stacktrace && existing_stacktrace.IsNull()) {
        BuildStackTrace(&frame_builder);
      }
    }
  } else {
    if (!existing_stacktrace.IsNull()) {
      stacktrace = existing_stacktrace.ptr();
      // If this is not a rethrow, it's a "throw with stacktrace".
      // Set an Error object's stackTrace field if needed.
      if (!is_rethrow) {
        Exceptions::TrySetStackTrace(zone, exception, stacktrace);
      }
    } else {
      // Get stacktrace field of class Error to determine whether we have a
      // subclass of Error which carries around its stack trace.
      const Field& stacktrace_field =
          Field::Handle(zone, LookupStackTraceField(exception));
      if (!stacktrace_field.IsNull() || handler_needs_stacktrace) {
        // Collect the stacktrace if needed.
        ASSERT(existing_stacktrace.IsNull());
        stacktrace = Exceptions::CurrentStackTrace();
        // If we have an Error object, then set its stackTrace field only if it
        // not yet initialized.
        if (!stacktrace_field.IsNull() &&
            (exception.GetField(stacktrace_field) == Object::null())) {
          exception.SetField(stacktrace_field, stacktrace);
        }
      }
    }
  }
  // We expect to find a handler_pc, if the exception is unhandled
  // then we expect to at least have the dart entry frame on the
  // stack as Exceptions::Throw should happen only after a dart
  // invocation has been done.
  ASSERT(handler_pc != 0);

  if (FLAG_print_stacktrace_at_throw) {
    THR_Print("Exception '%s' thrown:\n", exception.ToCString());
    THR_Print("%s\n", stacktrace.ToCString());
  }
  if (handler_exists) {
    finder.PrepareFrameForCatchEntry();
    // Found a dart handler for the exception, jump to it.
    JumpToExceptionHandler(thread, handler_pc, handler_sp, handler_fp,
                           exception, stacktrace);
  } else {
    // No dart exception handler found in this invocation sequence,
    // so we create an unhandled exception object and return to the
    // invocation stub so that it returns this unhandled exception
    // object. The C++ code which invoked this dart sequence can check
    // and do the appropriate thing (rethrow the exception to the
    // dart invocation sequence above it, print diagnostics and terminate
    // the isolate etc.). This can happen in the compiler, which is not
    // allowed to allocate in new space, so we pass the kOld argument.
    const UnhandledException& unhandled_exception = UnhandledException::Handle(
        zone,
        CreateUnhandledExceptionOrUsePrecanned(thread, exception, stacktrace));
    stacktrace = StackTrace::null();
    JumpToExceptionHandler(thread, handler_pc, handler_sp, handler_fp,
                           unhandled_exception, stacktrace);
  }
  UNREACHABLE();
}

// Static helpers for allocating, initializing, and throwing an error instance.

// Return the script of the Dart function that called the native entry or the
// runtime entry. The frame iterator points to the callee.
ScriptPtr Exceptions::GetCallerScript(DartFrameIterator* iterator) {
  StackFrame* caller_frame = iterator->NextFrame();
  ASSERT(caller_frame != nullptr && caller_frame->IsDartFrame());
  const Function& caller = Function::Handle(caller_frame->LookupDartFunction());
#if defined(DART_PRECOMPILED_RUNTIME)
  if (caller.IsNull()) return Script::null();
#else
  ASSERT(!caller.IsNull());
#endif
  return caller.script();
}

// Allocate a new instance of the given class name.
// TODO(hausner): Rename this NewCoreInstance to call out the fact that
// the class name is resolved in the core library implicitly?
InstancePtr Exceptions::NewInstance(const char* class_name) {
  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();
  const String& cls_name =
      String::Handle(zone, Symbols::New(thread, class_name));
  const Library& core_lib = Library::Handle(Library::CoreLibrary());
  // No ambiguity error expected: passing nullptr.
  Class& cls = Class::Handle(core_lib.LookupClass(cls_name));
  ASSERT(!cls.IsNull());
  // There are no parameterized error types, so no need to set type arguments.
  return Instance::New(cls);
}

// Allocate, initialize, and throw a TypeError.
void Exceptions::CreateAndThrowTypeError(TokenPosition location,
                                         const AbstractType& src_type,
                                         const AbstractType& dst_type,
                                         const String& dst_name) {
  ASSERT(!dst_name.IsNull());  // Pass Symbols::Empty() instead.
  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();
  const Array& args = Array::Handle(zone, Array::New(4));

  ExceptionType exception_type = kType;

  DartFrameIterator iterator(thread,
                             StackFrameIterator::kNoCrossThreadIteration);
  const Script& script = Script::Handle(zone, GetCallerScript(&iterator));
  const String& url = String::Handle(
      zone, script.IsNull() ? Symbols::OptimizedOut().ptr() : script.url());
  intptr_t line = -1;
  intptr_t column = -1;
  if (!script.IsNull()) {
    script.GetTokenLocation(location, &line, &column);
  }
  // Initialize '_url', '_line', and '_column' arguments.
  args.SetAt(0, url);
  args.SetAt(1, Smi::Handle(zone, Smi::New(line)));
  args.SetAt(2, Smi::Handle(zone, Smi::New(column)));

  // Construct '_errorMsg'.
  const GrowableObjectArray& pieces =
      GrowableObjectArray::Handle(zone, GrowableObjectArray::New(20));

  if (!dst_type.IsNull()) {
    // Describe the type error.
    if (!src_type.IsNull()) {
      pieces.Add(Symbols::TypeQuote());
      pieces.Add(String::Handle(zone, src_type.UserVisibleName()));
      pieces.Add(Symbols::QuoteIsNotASubtypeOf());
    }
    pieces.Add(Symbols::TypeQuote());
    pieces.Add(String::Handle(zone, dst_type.UserVisibleName()));
    pieces.Add(Symbols::SingleQuote());
    if (dst_name.Length() > 0) {
      if (dst_name.ptr() == Symbols::InTypeCast().ptr()) {
        pieces.Add(dst_name);
      } else {
        pieces.Add(Symbols::SpaceOfSpace());
        pieces.Add(Symbols::SingleQuote());
        pieces.Add(dst_name);
        pieces.Add(Symbols::SingleQuote());
      }
    }
    // Print ambiguous URIs of src and dst types.
    URIs uris(zone, 12);
    if (!src_type.IsNull()) {
      src_type.EnumerateURIs(&uris);
    }
    if (!dst_type.IsDynamicType() && !dst_type.IsVoidType() &&
        !dst_type.IsNeverType()) {
      dst_type.EnumerateURIs(&uris);
    }
    const String& formatted_uris =
        String::Handle(zone, AbstractType::PrintURIs(&uris));
    if (formatted_uris.Length() > 0) {
      pieces.Add(Symbols::SpaceWhereNewLine());
      pieces.Add(formatted_uris);
    }
  }
  const Array& arr = Array::Handle(zone, Array::MakeFixedLength(pieces));
  const String& error_msg = String::Handle(zone, String::ConcatAll(arr));
  args.SetAt(3, error_msg);

  // Type errors in the core library may be difficult to diagnose.
  // Print type error information before throwing the error when debugging.
  if (FLAG_print_stacktrace_at_throw) {
    THR_Print("'%s': Failed type check: line %" Pd " pos %" Pd ": ",
              String::Handle(zone, script.url()).ToCString(), line, column);
    THR_Print("%s\n", error_msg.ToCString());
  }

  // Throw TypeError instance.
  Exceptions::ThrowByType(exception_type, args);
  UNREACHABLE();
}

void Exceptions::Throw(Thread* thread, const Instance& exception) {
  // Null object is a valid exception object.
  ThrowExceptionHelper(thread, exception, StackTrace::Handle(thread->zone()),
                       /*is_rethrow=*/false,
                       /*bypass_debugger=*/false);
}

void Exceptions::ReThrow(Thread* thread,
                         const Instance& exception,
                         const Instance& stacktrace,
                         bool bypass_debugger /* = false */) {
  // Null object is a valid exception object.
  ThrowExceptionHelper(thread, exception, stacktrace, /*is_rethrow=*/true,
                       bypass_debugger);
}

void Exceptions::ThrowWithStackTrace(Thread* thread,
                                     const Instance& exception,
                                     const Instance& stacktrace) {
  // Null object is a valid exception object.
  ThrowExceptionHelper(thread, exception, stacktrace, /*is_rethrow=*/false,
                       /*bypass_debugger=*/false);
}

void Exceptions::TrySetStackTrace(Zone* zone,
                                  const Instance& error,
                                  const Instance& stacktrace) {
  const Field& stacktrace_field =
      Field::Handle(zone, dart::LookupStackTraceField(error));
  if (!stacktrace_field.IsNull() &&
      (error.GetField(stacktrace_field) == Object::null())) {
    error.SetField(stacktrace_field, stacktrace);
  }
}

void Exceptions::PropagateError(const Error& error) {
  ASSERT(!error.IsNull());
  Thread* thread = Thread::Current();
  // SuspendLongJumpScope during Dart entry ensures that if a longjmp base is
  // available, it is the innermost error handler. If one is available, so
  // should jump there instead.
  RELEASE_ASSERT(thread->long_jump_base() == nullptr);
  Zone* zone = thread->zone();
  if (error.IsUnhandledException()) {
    // If the error object represents an unhandled exception, then
    // rethrow the exception in the normal fashion.
    const UnhandledException& uhe = UnhandledException::Cast(error);
    const Instance& exc = Instance::Handle(zone, uhe.exception());
    const Instance& stk = Instance::Handle(zone, uhe.stacktrace());
    Exceptions::ReThrow(thread, exc, stk);
  } else {
    const Instance& stk = StackTrace::Handle(zone);  // Null stacktrace.
    // Return to the invocation stub and return this error object.  The
    // C++ code which invoked this dart sequence can check and do the
    // appropriate thing.
    StackFrameIterator frames(ValidationPolicy::kDontValidateFrames, thread,
                              StackFrameIterator::kNoCrossThreadIteration);
    StackFrame* frame = frames.NextFrame();
    StackFrame* prev = frame;
    ASSERT(frame != nullptr);
    while (!frame->IsEntryFrame()) {
      prev = frame;
      frame = frames.NextFrame();
      ASSERT(frame != nullptr);
    }
    if (frame->pc() == StubCode::InvokeDartCode().EntryPoint()) {
      // This is an FFI callback using the invocation stub as a marker. Real use
      // of invocation stub would be in the middle, not the entry point. Use the
      // callback's exceptional return value instead of the error unless the
      // return type is Dart_Handle.
      ASSERT(prev->IsDartFrame());
      frame = prev;
      const Function& func =
          Function::Handle(zone, frame->LookupDartFunction());
      ASSERT(func.IsFfiCallbackTrampoline());
      if (func.FfiCSignatureReturnsHandle()) {
        JumpToExceptionHandler(thread, frame->pc(), frame->sp(), frame->fp(),
                               error, stk, kPassHandle);
      } else {
        const Instance& val =
            Instance::Handle(zone, func.FfiCallbackExceptionalReturn());
        JumpToExceptionHandler(thread, frame->pc(), frame->sp(), frame->fp(),
                               val, stk, kPassUnboxed);
      }
    }
    JumpToExceptionHandler(thread, frame->pc(), frame->sp(), frame->fp(), error,
                           stk);
  }
  UNREACHABLE();
}

void Exceptions::ThrowByType(ExceptionType type, const Array& arguments) {
  Thread* thread = Thread::Current();
  const Object& result =
      Object::Handle(thread->zone(), Create(type, arguments));
  if (result.IsError()) {
    // We got an error while constructing the exception object.
    // Propagate the error instead of throwing the exception.
    PropagateError(Error::Cast(result));
  } else {
    ASSERT(result.IsInstance());
    Throw(thread, Instance::Cast(result));
  }
}

void Exceptions::ThrowOOM() {
  auto thread = Thread::Current();
  auto isolate_group = thread->isolate_group();
  const Instance& oom = Instance::Handle(
      thread->zone(), isolate_group->object_store()->out_of_memory());
  Throw(thread, oom);
}

void Exceptions::ThrowStackOverflow() {
  auto thread = Thread::Current();
  auto isolate_group = thread->isolate_group();
  const Instance& stack_overflow = Instance::Handle(
      thread->zone(), isolate_group->object_store()->stack_overflow());
  Throw(thread, stack_overflow);
}

void Exceptions::ThrowArgumentError(const Instance& arg) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, arg);
  Exceptions::ThrowByType(Exceptions::kArgument, args);
}

void Exceptions::ThrowStateError(const Instance& arg) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, arg);
  Exceptions::ThrowByType(Exceptions::kState, args);
}

void Exceptions::ThrowRangeError(const char* argument_name,
                                 const Integer& argument_value,
                                 intptr_t expected_from,
                                 intptr_t expected_to) {
  const Array& args = Array::Handle(Array::New(4));
  args.SetAt(0, argument_value);
  args.SetAt(1, Integer::Handle(Integer::New(expected_from)));
  args.SetAt(2, Integer::Handle(Integer::New(expected_to)));
  args.SetAt(3, String::Handle(String::New(argument_name)));
  Exceptions::ThrowByType(Exceptions::kRange, args);
}

void Exceptions::ThrowUnsupportedError(const char* msg) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, String::Handle(String::New(msg)));
  Exceptions::ThrowByType(Exceptions::kUnsupported, args);
}

void Exceptions::ThrowCompileTimeError(const LanguageError& error) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, String::Handle(error.FormatMessage()));
  Exceptions::ThrowByType(Exceptions::kCompileTimeError, args);
}

void Exceptions::ThrowStaticFieldAccessedWithoutIsolate(const String& name) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, name);
  Exceptions::ThrowByType(Exceptions::kStaticFieldAccessedWithoutIsolate, args);
}

void Exceptions::ThrowLateFieldAlreadyInitialized(const String& name) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, name);
  Exceptions::ThrowByType(Exceptions::kLateFieldAlreadyInitialized, args);
}

void Exceptions::ThrowLateFieldNotInitialized(const String& name) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, name);
  Exceptions::ThrowByType(Exceptions::kLateFieldNotInitialized, args);
}

void Exceptions::ThrowLateFieldAssignedDuringInitialization(
    const String& name) {
  const Array& args = Array::Handle(Array::New(1));
  args.SetAt(0, name);
  Exceptions::ThrowByType(Exceptions::kLateFieldAssignedDuringInitialization,
                          args);
}

ObjectPtr Exceptions::Create(ExceptionType type, const Array& arguments) {
  Library& library = Library::Handle();
  const String* class_name = nullptr;
  const String* constructor_name = &Symbols::Dot();
  switch (type) {
    case kNone:
    case kStackOverflow:
    case kOutOfMemory:
      UNREACHABLE();
      break;
    case kRange:
      library = Library::CoreLibrary();
      class_name = &Symbols::RangeError();
      constructor_name = &Symbols::DotRange();
      break;
    case kRangeMsg:
      library = Library::CoreLibrary();
      class_name = &Symbols::RangeError();
      constructor_name = &Symbols::Dot();
      break;
    case kArgument:
      library = Library::CoreLibrary();
      class_name = &Symbols::ArgumentError();
      break;
    case kArgumentValue:
      library = Library::CoreLibrary();
      class_name = &Symbols::ArgumentError();
      constructor_name = &Symbols::DotValue();
      break;
    case kState:
      library = Library::CoreLibrary();
      class_name = &Symbols::StateError();
      break;
    case kIntegerDivisionByZeroException:
      library = Library::CoreLibrary();
      class_name = &Symbols::IntegerDivisionByZeroException();
      break;
    case kNoSuchMethod:
      library = Library::CoreLibrary();
      class_name = &Symbols::NoSuchMethodError();
      constructor_name = &Symbols::DotWithType();
      break;
    case kFormat:
      library = Library::CoreLibrary();
      class_name = &Symbols::FormatException();
      break;
    case kUnsupported:
      library = Library::CoreLibrary();
      class_name = &Symbols::UnsupportedError();
      break;
    case kIsolateSpawn:
      library = Library::IsolateLibrary();
      class_name = &Symbols::IsolateSpawnException();
      break;
    case kAssertion:
      library = Library::CoreLibrary();
      class_name = &Symbols::AssertionError();
      constructor_name = &Symbols::DotCreate();
      break;
    case kType:
      library = Library::CoreLibrary();
      class_name = &Symbols::TypeError();
      constructor_name = &Symbols::DotCreate();
      break;
    case kAbstractClassInstantiation:
#if defined(DART_PRECOMPILED_RUNTIME)
      UNREACHABLE();
#else
      library = Library::MirrorsLibrary();
      class_name = &Symbols::AbstractClassInstantiationError();
      constructor_name = &Symbols::DotCreate();
      break;
#endif
    case kCompileTimeError:
      library = Library::CoreLibrary();
      class_name = &Symbols::_CompileTimeError();
      break;
    case kStaticFieldAccessedWithoutIsolate:
      library = Library::InternalLibrary();
      class_name = &Symbols::FieldAccessError();
      constructor_name = &Symbols::DotStaticFieldAccessedWithoutIsolate();
      break;
    case kLateFieldAlreadyInitialized:
      library = Library::InternalLibrary();
      class_name = &Symbols::LateError();
      constructor_name = &Symbols::DotFieldAI();
      break;
    case kLateFieldAssignedDuringInitialization:
      library = Library::InternalLibrary();
      class_name = &Symbols::LateError();
      constructor_name = &Symbols::DotFieldADI();
      break;
    case kLateFieldNotInitialized:
      library = Library::InternalLibrary();
      class_name = &Symbols::LateError();
      constructor_name = &Symbols::DotFieldNI();
      break;
  }

  return DartLibraryCalls::InstanceCreate(library, *class_name,
                                          *constructor_name, arguments);
}

UnhandledExceptionPtr Exceptions::CreateUnhandledException(Zone* zone,
                                                           ExceptionType type,
                                                           const char* msg) {
  const String& error_str = String::Handle(zone, String::New(msg));
  const Array& args = Array::Handle(zone, Array::New(1));
  args.SetAt(0, error_str);

  Object& result = Object::Handle(zone, Exceptions::Create(type, args));
  const StackTrace& stacktrace = StackTrace::Handle(zone);
  return UnhandledException::New(Instance::Cast(result), stacktrace);
}

}  // namespace dart
