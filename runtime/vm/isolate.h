// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_ISOLATE_H_
#define RUNTIME_VM_ISOLATE_H_

#if defined(SHOULD_NOT_INCLUDE_RUNTIME)
#error "Should not include runtime"
#endif

#include <functional>
#include <memory>
#include <utility>

#include "include/dart_api.h"
#include "platform/assert.h"
#include "platform/atomic.h"
#include "platform/growable_array.h"
#include "vm/class_table.h"
#include "vm/dispatch_table.h"
#include "vm/exceptions.h"
#include "vm/ffi_callback_metadata.h"
#include "vm/field_table.h"
#include "vm/fixed_cache.h"
#include "vm/handles.h"
#include "vm/heap/verifier.h"
#include "vm/intrusive_dlist.h"
#include "vm/megamorphic_cache_table.h"
#include "vm/metrics.h"
#include "vm/os_thread.h"
#include "vm/port.h"
#include "vm/random.h"
#include "vm/service.h"
#include "vm/tags.h"
#include "vm/thread.h"
#include "vm/thread_pool.h"
#include "vm/thread_stack_resource.h"
#include "vm/token_position.h"
#include "vm/virtual_memory.h"

namespace dart {

// Forward declarations.
class ApiState;
class BackgroundCompiler;
class Become;
class Capability;
class CodeIndexTable;
class Debugger;
class ExternalTypedData;
class GroupDebugger;
class HandleScope;
class HandleVisitor;
class Heap;
class ICData;
class IsolateGroupReloadContext;
class IsolateMessageHandler;
class IsolateObjectStore;
class IsolateProfilerData;
class Log;
class Message;
class MessageHandler;
class Mutex;
class Object;
class ObjectIdRing;
class ObjectPointerVisitor;
class ObjectStore;
class PersistentHandle;
class ProgramReloadContext;
class RwLock;
class SafepointHandler;
class SafepointRwLock;
class SampleBlock;
class SampleBlockBuffer;
class SampleBuffer;
class SendPort;
class SerializedObjectBuffer;
class ServiceIdZone;
class Simulator;
class StackResource;
class StackZone;
class StoreBuffer;
class StubCode;
class ThreadRegistry;
class UserTag;

class IsolateVisitor {
 public:
  IsolateVisitor() {}
  virtual ~IsolateVisitor() {}

  virtual void VisitIsolate(Isolate* isolate) = 0;

 protected:
  // Returns true if |isolate| is the VM or service isolate.
  bool IsSystemIsolate(Isolate* isolate) const;

 private:
  DISALLOW_COPY_AND_ASSIGN(IsolateVisitor);
};

class Callable : public ValueObject {
 public:
  Callable() {}
  virtual ~Callable() {}

  virtual void Call() = 0;

 private:
  DISALLOW_COPY_AND_ASSIGN(Callable);
};

template <typename T>
class LambdaCallable : public Callable {
 public:
  explicit LambdaCallable(T& lambda) : lambda_(lambda) {}
  void Call() { lambda_(); }

 private:
  T& lambda_;
  DISALLOW_COPY_AND_ASSIGN(LambdaCallable);
};

// Fixed cache for exception handler lookup.
typedef FixedCache<intptr_t, ExceptionHandlerInfo, 16> HandlerInfoCache;
// Fixed cache for catch entry state lookup.
typedef FixedCache<intptr_t, CatchEntryMovesRefPtr, 16> CatchEntryMovesCache;

// List of Isolate group flags.
//
//     V(when, name, bit-name, Dart_IsolateFlags-name, command-line-flag-name)
//
#define BOOL_ISOLATE_GROUP_FLAG_LIST(V)                                        \
  V(PRECOMPILER, obfuscate, Obfuscate, obfuscate, false)                       \
  V(NONPRODUCT, asserts, EnableAsserts, enable_asserts, FLAG_enable_asserts)   \
  V(NONPRODUCT, use_field_guards, UseFieldGuards, use_field_guards,            \
    FLAG_use_field_guards)                                                     \
  V(PRODUCT, should_load_vmservice_library, ShouldLoadVmService,               \
    load_vmservice_library, false)                                             \
  V(NONPRODUCT, use_osr, UseOsr, use_osr, FLAG_use_osr)                        \
  V(NONPRODUCT, snapshot_is_dontneed_safe, SnapshotIsDontNeedSafe,             \
    snapshot_is_dontneed_safe, false)                                          \
  V(NONPRODUCT, branch_coverage, BranchCoverage, branch_coverage,              \
    FLAG_branch_coverage)                                                      \
  V(NONPRODUCT, coverage, Coverage, coverage, FLAG_coverage)

// List of Isolate flags with corresponding members of Dart_IsolateFlags and
// corresponding global command line flags.
#define BOOL_ISOLATE_FLAG_LIST(V)                                              \
  V(NONPRODUCT, is_system_isolate, IsSystemIsolate, is_system_isolate, false)  \
  V(NONPRODUCT, is_service_isolate, IsServiceIsolate, is_service_isolate,      \
    false)                                                                     \
  V(NONPRODUCT, is_kernel_isolate, IsKernelIsolate, is_kernel_isolate, false)

// Represents the information used for spawning the first isolate within an
// isolate group. All isolates within a group will refer to this
// [IsolateGroupSource].
class IsolateGroupSource {
 public:
  IsolateGroupSource(const char* script_uri,
                     const char* name,
                     const uint8_t* snapshot_data,
                     const uint8_t* snapshot_instructions,
                     const uint8_t* kernel_buffer,
                     intptr_t kernel_buffer_size,
                     Dart_IsolateFlags flags)
      : script_uri(script_uri == nullptr ? nullptr : Utils::StrDup(script_uri)),
        name(Utils::StrDup(name)),
        snapshot_data(snapshot_data),
        snapshot_instructions(snapshot_instructions),
        kernel_buffer(kernel_buffer),
        kernel_buffer_size(kernel_buffer_size),
        flags(flags),
        script_kernel_buffer(nullptr),
        script_kernel_size(-1),
        loaded_blobs_(nullptr),
        num_blob_loads_(0) {}
  ~IsolateGroupSource() {
    free(script_uri);
    free(name);
  }

  void add_loaded_blob(Zone* zone_,
                       const ExternalTypedData& external_typed_data);

  // The arguments used for spawning in
  // `Dart_CreateIsolateGroupFromKernel` / `Dart_CreateIsolate`.
  char* script_uri;
  char* name;
  const uint8_t* snapshot_data;
  const uint8_t* snapshot_instructions;
  const uint8_t* kernel_buffer;
  const intptr_t kernel_buffer_size;
  Dart_IsolateFlags flags;

  // The kernel buffer used in `Dart_LoadScriptFromKernel`.
  const uint8_t* script_kernel_buffer;
  intptr_t script_kernel_size;

  // List of weak pointers to external typed data for loaded blobs.
  ArrayPtr loaded_blobs_;
  intptr_t num_blob_loads_;
};

// Tracks idle time and notifies heap when idle time expired.
class IdleTimeHandler : public ValueObject {
 public:
  IdleTimeHandler() {}

  // Initializes the idle time handler with the given [heap], to which
  // idle notifications will be sent.
  void InitializeWithHeap(Heap* heap);

  // Returns whether the caller should check for idle timeouts.
  bool ShouldCheckForIdle();

  // Declares that the idle time should be reset to now.
  void UpdateStartIdleTime();

  // Returns whether idle time expired and [NotifyIdle] should be called.
  bool ShouldNotifyIdle(int64_t* expiry);

  // Notifies the heap that now is a good time to do compactions and indicates
  // we have time for the GC until [deadline].
  void NotifyIdle(int64_t deadline);

  // Calls [NotifyIdle] with the default deadline.
  void NotifyIdleUsingDefaultDeadline();

 private:
  friend class DisableIdleTimerScope;

  Mutex mutex_;
  Heap* heap_ = nullptr;
  intptr_t disabled_counter_ = 0;
  int64_t idle_start_time_ = 0;
};

// Disables firing of the idle timer while this object is alive.
class DisableIdleTimerScope : public ValueObject {
 public:
  explicit DisableIdleTimerScope(IdleTimeHandler* handler);
  ~DisableIdleTimerScope();

 private:
  IdleTimeHandler* handler_;
};

class MutatorThreadPool : public ThreadPool {
 public:
  MutatorThreadPool(IsolateGroup* isolate_group, intptr_t max_pool_size)
      : ThreadPool(max_pool_size), isolate_group_(isolate_group) {}
  virtual ~MutatorThreadPool() {}

 protected:
  virtual void OnEnterIdleLocked(MutexLocker* ml, ThreadPool::Worker* worker);

 private:
  void NotifyIdle();

  IsolateGroup* isolate_group_ = nullptr;
};

enum RootSlice : intptr_t {
  kClassTable,
  kApiState,
  kObjectStore,
  kSavedUnlinkedCalls,
  kInitialFieldTable,
  kSentinelFieldTable,
  kSharedInitialFieldTable,
  kSharedFieldTable,
  kBackgroundCompiler,
  kDebugger,
  kReloadContext,
  kLoadedBlobs,
  kBecome,
  kObjectIdZones,

  kNumRootSlices,
};

inline const char* RootSliceToCString(intptr_t slice) {
  switch (slice) {
    case kClassTable:
      return "class table";
    case kApiState:
      return "api state";
    case kObjectStore:
      return "group object store";
    case kSavedUnlinkedCalls:
      return "saved unlinked calls";
    case kInitialFieldTable:
      return "initial field table";
    case kSentinelFieldTable:
      return "sentinel field table";
    case kSharedInitialFieldTable:
      return "shared initial field table";
    case kSharedFieldTable:
      return "shared field table";
    case kBackgroundCompiler:
      return "background compiler";
    case kDebugger:
      return "debugger";
    case kReloadContext:
      return "reload context";
    case kLoadedBlobs:
      return "loaded blobs";
    case kBecome:
      return "become";
    case kObjectIdZones:
      return "object id zones";
    default:
      return "?";
  }
}

// Represents an isolate group and is shared among all isolates within a group.
class IsolateGroup : public IntrusiveDListEntry<IsolateGroup> {
 public:
  IsolateGroup(std::shared_ptr<IsolateGroupSource> source,
               void* embedder_data,
               ObjectStore* object_store,
               Dart_IsolateFlags api_flags,
               bool is_vm_isolate);
  IsolateGroup(std::shared_ptr<IsolateGroupSource> source,
               void* embedder_data,
               Dart_IsolateFlags api_flags,
               bool is_vm_isolate);
  ~IsolateGroup();

  void RehashConstants(Become* become);
#if defined(DEBUG)
  void ValidateClassTable();
#endif

  IsolateGroupSource* source() const { return source_.get(); }
  std::shared_ptr<IsolateGroupSource> shareable_source() const {
    return source_;
  }
  bool is_vm_isolate() const { return is_vm_isolate_; }
  void* embedder_data() const { return embedder_data_; }

  bool initial_spawn_successful() { return initial_spawn_successful_; }
  void set_initial_spawn_successful() { initial_spawn_successful_ = true; }

  Heap* heap() const { return heap_.get(); }

  BackgroundCompiler* background_compiler() const {
#if defined(DART_PRECOMPILED_RUNTIME)
    return nullptr;
#else
    return background_compiler_.get();
#endif
  }
#if !defined(DART_PRECOMPILED_RUNTIME)
  intptr_t optimization_counter_threshold() const {
    if (IsSystemIsolateGroup(this)) {
      return kDefaultOptimizationCounterThreshold;
    }
    return FLAG_optimization_counter_threshold;
  }
#endif

#if !defined(PRODUCT)
  GroupDebugger* debugger() const { return debugger_; }
#endif

  IdleTimeHandler* idle_time_handler() { return &idle_time_handler_; }

  void RegisterIsolate(Isolate* isolate);
  void UnregisterIsolate(Isolate* isolate);
  // Returns `true` if this was the last isolate and the caller is responsible
  // for deleting the isolate group.
  bool UnregisterIsolateDecrementCount();
  void RegisterIsolateGroupMutator();
  void UnregisterIsolateGroupMutator();

  bool ContainsOnlyOneIsolate();

  Dart_Port interrupt_port() { return interrupt_port_; }

  ThreadRegistry* thread_registry() const { return thread_registry_.get(); }
  SafepointHandler* safepoint_handler() { return safepoint_handler_.get(); }

  void CreateHeap(bool is_vm_isolate, bool is_service_or_kernel_isolate);
  void SetupImagePage(const uint8_t* snapshot_buffer, bool is_executable);
  void Shutdown();

#define ISOLATE_METRIC_ACCESSOR(type, variable, name, unit)                    \
  type* Get##variable##Metric() { return &metric_##variable##_; }
  ISOLATE_GROUP_METRIC_LIST(ISOLATE_METRIC_ACCESSOR);
#undef ISOLATE_METRIC_ACCESSOR

#if !defined(PRODUCT)
  void UpdateLastAllocationProfileAccumulatorResetTimestamp() {
    last_allocationprofile_accumulator_reset_timestamp_ =
        OS::GetCurrentTimeMillis();
  }

  int64_t last_allocationprofile_accumulator_reset_timestamp() const {
    return last_allocationprofile_accumulator_reset_timestamp_;
  }

  void UpdateLastAllocationProfileGCTimestamp() {
    last_allocationprofile_gc_timestamp_ = OS::GetCurrentTimeMillis();
  }

  int64_t last_allocationprofile_gc_timestamp() const {
    return last_allocationprofile_gc_timestamp_;
  }
#endif  // !defined(PRODUCT)

  DispatchTable* dispatch_table() const { return dispatch_table_.get(); }
  void set_dispatch_table(DispatchTable* table) {
    dispatch_table_.reset(table);
  }
  const uint8_t* dispatch_table_snapshot() const {
    return dispatch_table_snapshot_;
  }
  void set_dispatch_table_snapshot(const uint8_t* snapshot) {
    dispatch_table_snapshot_ = snapshot;
  }
  intptr_t dispatch_table_snapshot_size() const {
    return dispatch_table_snapshot_size_;
  }
  void set_dispatch_table_snapshot_size(intptr_t size) {
    dispatch_table_snapshot_size_ = size;
  }

  ClassTableAllocator* class_table_allocator() {
    return &class_table_allocator_;
  }

  static intptr_t class_table_offset() {
    COMPILE_ASSERT(sizeof(IsolateGroup::class_table_) == kWordSize);
    return OFFSET_OF(IsolateGroup, class_table_);
  }

  ClassPtr* cached_class_table_table() {
    return cached_class_table_table_.load();
  }
  void set_cached_class_table_table(ClassPtr* cached_class_table_table) {
    cached_class_table_table_.store(cached_class_table_table);
  }
  static intptr_t cached_class_table_table_offset() {
    COMPILE_ASSERT(sizeof(IsolateGroup::cached_class_table_table_) ==
                   kWordSize);
    return OFFSET_OF(IsolateGroup, cached_class_table_table_);
  }

  void set_object_store(ObjectStore* object_store);
  static intptr_t object_store_offset() {
    COMPILE_ASSERT(sizeof(IsolateGroup::object_store_) == kWordSize);
    return OFFSET_OF(IsolateGroup, object_store_);
  }

  void set_obfuscation_map(const char** map) { obfuscation_map_ = map; }
  const char** obfuscation_map() const { return obfuscation_map_; }

  Random* random() { return &random_; }

  bool is_system_isolate_group() const { return is_system_isolate_group_; }

  // IsolateGroup-specific flag handling.
  static void FlagsInitialize(Dart_IsolateFlags* api_flags);
  void FlagsCopyTo(Dart_IsolateFlags* api_flags);
  void FlagsCopyFrom(const Dart_IsolateFlags& api_flags);

#if defined(DART_PRECOMPILER)
#define FLAG_FOR_PRECOMPILER(from_field, from_flag) (from_field)
#else
#define FLAG_FOR_PRECOMPILER(from_field, from_flag) (from_flag)
#endif

#if !defined(PRODUCT)
#define FLAG_FOR_NONPRODUCT(from_field, from_flag) (from_field)
#else
#define FLAG_FOR_NONPRODUCT(from_field, from_flag) (from_flag)
#endif

#define FLAG_FOR_PRODUCT(from_field, from_flag) (from_field)

#define DECLARE_GETTER(when, name, bitname, isolate_flag_name, flag_name)      \
  bool name() const {                                                          \
    return FLAG_FOR_##when(bitname##Bit::decode(isolate_group_flags_),         \
                           flag_name);                                         \
  }
  BOOL_ISOLATE_GROUP_FLAG_LIST(DECLARE_GETTER)
#undef FLAG_FOR_NONPRODUCT
#undef FLAG_FOR_PRECOMPILER
#undef FLAG_FOR_PRODUCT
#undef DECLARE_GETTER

  bool should_load_vmservice() const {
    return isolate_group_flags_.Read<ShouldLoadVmServiceBit>();
  }
  void set_should_load_vmservice(bool value) {
    isolate_group_flags_.UpdateBool<ShouldLoadVmServiceBit>(value);
  }

  void set_asserts(bool value) {
    isolate_group_flags_.UpdateBool<EnableAssertsBit>(value);
  }

  void set_branch_coverage(bool value) {
    isolate_group_flags_.UpdateBool<BranchCoverageBit>(value);
  }

  void set_coverage(bool value) {
    isolate_group_flags_.UpdateBool<CoverageBit>(value);
  }

#if !defined(PRODUCT)
#if !defined(DART_PRECOMPILED_RUNTIME)
  bool HasAttemptedReload() const {
    return isolate_group_flags_.Read<HasAttemptedReloadBit>();
  }
  void SetHasAttemptedReload(bool value) {
    isolate_group_flags_.UpdateBool<HasAttemptedReloadBit>(value);
  }
  void MaybeIncreaseReloadEveryNStackOverflowChecks();
  intptr_t reload_every_n_stack_overflow_checks() const {
    return reload_every_n_stack_overflow_checks_;
  }
#else
  bool HasAttemptedReload() const { return false; }
#endif  // !defined(DART_PRECOMPILED_RUNTIME)
#endif  // !defined(PRODUCT)

  bool has_seen_oom() const {
    return isolate_group_flags_.Read<HasSeenOOMBit>();
  }
  void set_has_seen_oom(bool value) {
    isolate_group_flags_.UpdateBool<HasSeenOOMBit>(value);
  }

#if defined(PRODUCT)
  void set_use_osr(bool use_osr) { ASSERT(!use_osr); }
#else   // defined(PRODUCT)
  void set_use_osr(bool use_osr) {
    isolate_group_flags_.UpdateBool<UseOsrBit>(use_osr);
  }
#endif  // defined(PRODUCT)

  // Class table for the program loaded into this isolate group.
  //
  // This table is modified by kernel loading.
  ClassTable* class_table() const { return class_table_; }

  // Class table used for heap walks by GC visitors. Usually it
  // is the same table as one in |class_table_|, except when in the
  // middle of the reload.
  //
  // See comment for |ClassTable| class for more details.
  ClassTable* heap_walk_class_table() const { return heap_walk_class_table_; }

  void CloneClassTableForReload();
  void RestoreOriginalClassTable();
  void DropOriginalClassTable();

  StoreBuffer* store_buffer() const { return store_buffer_.get(); }
  ObjectStore* object_store() const { return object_store_.get(); }
  Mutex* symbols_mutex() { return &symbols_mutex_; }
  Mutex* type_canonicalization_mutex() { return &type_canonicalization_mutex_; }
  Mutex* type_arguments_canonicalization_mutex() {
    return &type_arguments_canonicalization_mutex_;
  }
  Mutex* subtype_test_cache_mutex() { return &subtype_test_cache_mutex_; }
  Mutex* megamorphic_table_mutex() { return &megamorphic_table_mutex_; }
  Mutex* type_feedback_mutex() { return &type_feedback_mutex_; }
  Mutex* patchable_call_mutex() { return &patchable_call_mutex_; }
  Mutex* constant_canonicalization_mutex() {
    return &constant_canonicalization_mutex_;
  }
  Mutex* kernel_data_lib_cache_mutex() { return &kernel_data_lib_cache_mutex_; }
  Mutex* kernel_data_class_cache_mutex() {
    return &kernel_data_class_cache_mutex_;
  }
  Mutex* kernel_constants_mutex() { return &kernel_constants_mutex_; }

#if defined(DART_PRECOMPILED_RUNTIME)
  Mutex* unlinked_call_map_mutex() { return &unlinked_call_map_mutex_; }
#endif

#if !defined(DART_PRECOMPILED_RUNTIME) || defined(DART_DYNAMIC_MODULES)
  Mutex* initializer_functions_mutex() { return &initializer_functions_mutex_; }
#endif  // !defined(DART_PRECOMPILED_RUNTIME) || defined(DART_DYNAMIC_MODULES)

  SafepointRwLock* shared_field_initializer_rwlock() {
    return &shared_field_initializer_rwlock_;
  }

  SafepointRwLock* program_lock() { return program_lock_.get(); }

  static inline IsolateGroup* Current() {
    Thread* thread = Thread::Current();
    return thread == nullptr ? nullptr : thread->isolate_group();
  }

  void IncreaseMutatorCount(Thread* thread,
                            bool is_nested_reenter,
                            bool was_stolen);
  void DecreaseMutatorCount(bool is_nested_exit);
  NO_SANITIZE_THREAD
  intptr_t MutatorCount() const { return active_mutators_; }

  bool HasTagHandler() const { return library_tag_handler() != nullptr; }
  ObjectPtr CallTagHandler(Dart_LibraryTag tag,
                           const Object& arg1,
                           const Object& arg2);
  Dart_LibraryTagHandler library_tag_handler() const {
    return library_tag_handler_;
  }
  void set_library_tag_handler(Dart_LibraryTagHandler handler) {
    library_tag_handler_ = handler;
  }
  Dart_DeferredLoadHandler deferred_load_handler() const {
    return deferred_load_handler_;
  }
  void set_deferred_load_handler(Dart_DeferredLoadHandler handler) {
    deferred_load_handler_ = handler;
  }

  // Prepares all threads in an isolate for Garbage Collection.
  void ReleaseStoreBuffers();
  void FlushMarkingStacks();
  void EnableIncrementalBarrier(MarkingStack* old_marking_stack,
                                MarkingStack* new_marking_stack,
                                MarkingStack* deferred_marking_stack);
  void DisableIncrementalBarrier();

  MarkingStack* old_marking_stack() const { return old_marking_stack_; }
  MarkingStack* new_marking_stack() const { return new_marking_stack_; }
  MarkingStack* deferred_marking_stack() const {
    return deferred_marking_stack_;
  }

  // Runs the given [function] on every isolate in the isolate group.
  //
  // During the duration of this function, no new isolates can be added or
  // removed.
  //
  // If [at_safepoint] is `true`, then the entire isolate group must be in a
  // safepoint. There is therefore no reason to guard against other threads
  // adding/removing isolates, so no locks will be held.
  void ForEachIsolate(std::function<void(Isolate* isolate)> function,
                      bool at_safepoint = false);
  Isolate* FirstIsolate() const;
  Isolate* FirstIsolateLocked() const;

  // Ensures mutators are stopped during execution of the provided function.
  //
  // If the current thread is the only mutator in the isolate group,
  // [callable] will be called directly. Otherwise [callable] will be
  // called inside a [SafepointOperationsScope].
  //
  // During the duration of this function, no new isolates can be added to the
  // isolate group.
  void RunWithStoppedMutatorsCallable(Callable* callable);

  template <typename T>
  void RunWithStoppedMutators(T function) {
    LambdaCallable<T> callable(function);
    RunWithStoppedMutatorsCallable(&callable);
  }

#ifndef PRODUCT
  void PrintJSON(JSONStream* stream, bool ref = true);
  void PrintToJSONObject(JSONObject* jsobj, bool ref);

  // Creates an object with the total heap memory usage statistics for this
  // isolate group.
  void PrintMemoryUsageJSON(JSONStream* stream);
#endif

#if !defined(PRODUCT) && !defined(DART_PRECOMPILED_RUNTIME)
  // By default the reload context is deleted. This parameter allows
  // the caller to delete is separately if it is still needed.
  bool ReloadSources(JSONStream* js,
                     bool force_reload,
                     const char* root_script_url = nullptr,
                     const char* packages_url = nullptr,
                     bool dont_delete_reload_context = false);

  // If provided, the VM takes ownership of kernel_buffer.
  bool ReloadKernel(JSONStream* js,
                    bool force_reload,
                    const uint8_t* kernel_buffer = nullptr,
                    intptr_t kernel_buffer_size = 0,
                    bool dont_delete_reload_context = false);

  void set_last_reload_timestamp(int64_t value) {
    last_reload_timestamp_ = value;
  }
  int64_t last_reload_timestamp() const { return last_reload_timestamp_; }

  IsolateGroupReloadContext* reload_context() {
    return group_reload_context_.get();
  }
  ProgramReloadContext* program_reload_context() {
    return program_reload_context_;
  }

  void DeleteReloadContext();
  bool CanReload();
#else
  bool CanReload() { return false; }
#endif  // !defined(PRODUCT) && !defined(DART_PRECOMPILED_RUNTIME)

  bool IsReloading() const {
#if !defined(PRODUCT) && !defined(DART_PRECOMPILED_RUNTIME)
    return group_reload_context_ != nullptr;
#else
    return false;
#endif
  }

  Become* become() const { return become_; }
  void set_become(Become* become) { become_ = become; }

  Dart_Port id() const { return id_; }

  static void Init();
  static void Cleanup();

  static void ForEach(std::function<void(IsolateGroup*)> action);
  static void RunWithIsolateGroup(Dart_Port id,
                                  std::function<void(IsolateGroup*)> action,
                                  std::function<void()> not_found);

  // Manage list of existing isolate groups.
  static void RegisterIsolateGroup(IsolateGroup* isolate_group);
  static void UnregisterIsolateGroup(IsolateGroup* isolate_group);

  static bool HasApplicationIsolateGroups();
  static bool HasOnlyVMIsolateGroup();
  static bool IsSystemIsolateGroup(const IsolateGroup* group);

  int64_t UptimeMicros() const;

  ApiState* api_state() const { return api_state_.get(); }

  // Visit all object pointers. Caller must ensure concurrent sweeper is not
  // running, and the visitor must not allocate.
  void VisitObjectPointers(ObjectPointerVisitor* visitor,
                           ValidationPolicy validate_frames);
  void VisitSharedPointers(ObjectPointerVisitor* visitor);
  void VisitSharedPointers(ObjectPointerVisitor* visitor, intptr_t slice);
  void VisitStackPointers(ObjectPointerVisitor* visitor,
                          ValidationPolicy validate_frames);
  void VisitWeakPersistentHandles(HandleVisitor* visitor);

  // In precompilation we finalize all regular classes before compiling.
  bool all_classes_finalized() const {
    return isolate_group_flags_.Read<AllClassesFinalizedBit>();
  }
  void set_all_classes_finalized(bool value) {
    isolate_group_flags_.UpdateBool<AllClassesFinalizedBit>(value);
  }
  bool has_dynamically_extendable_classes() const {
    return isolate_group_flags_.Read<HasDynamicallyExtendableClassesBit>();
  }
  void set_has_dynamically_extendable_classes(bool value) {
    isolate_group_flags_.UpdateBool<HasDynamicallyExtendableClassesBit>(value);
  }

  bool remapping_cids() const {
    return isolate_group_flags_.Read<RemappingCidsBit>();
  }
  void set_remapping_cids(bool value) {
    isolate_group_flags_.UpdateBool<RemappingCidsBit>(value);
  }

  void RememberLiveTemporaries();
  void DeferredMarkLiveTemporaries();

  ArrayPtr saved_unlinked_calls() const { return saved_unlinked_calls_; }
  void set_saved_unlinked_calls(const Array& saved_unlinked_calls);

  FieldTable* initial_field_table() const { return initial_field_table_.get(); }
  std::shared_ptr<FieldTable> initial_field_table_shareable() {
    return initial_field_table_;
  }
  void set_initial_field_table(std::shared_ptr<FieldTable> field_table) {
    initial_field_table_ = field_table;
  }

  FieldTable* sentinel_field_table() const {
    return sentinel_field_table_.get();
  }
  std::shared_ptr<FieldTable> sentinel_field_table_shareable() {
    return sentinel_field_table_;
  }
  void set_sentinel_field_table(std::shared_ptr<FieldTable> field_table) {
    sentinel_field_table_ = field_table;
  }

  FieldTable* shared_initial_field_table() const {
    return shared_initial_field_table_.get();
  }
  std::shared_ptr<FieldTable> shared_initial_field_table_shareable() {
    return shared_initial_field_table_;
  }
  void set_shared_initial_field_table(std::shared_ptr<FieldTable> field_table) {
    shared_initial_field_table_ = field_table;
  }

  FieldTable* shared_field_table() const { return shared_field_table_.get(); }
  std::shared_ptr<FieldTable> shared_field_table_shareable() {
    return shared_field_table_;
  }
  void set_shared_field_table(Thread* T, FieldTable* shared_field_table) {
    shared_field_table_.reset(shared_field_table);
    T->shared_field_table_values_ = shared_field_table->table();
  }

  MutatorThreadPool* thread_pool() { return thread_pool_.get(); }

  void RegisterClass(const Class& cls);
  void RegisterSharedStaticField(const Field& field,
                                 const Object& initial_value);
  void RegisterStaticField(const Field& field, const Object& initial_value);
  void FreeStaticField(const Field& field);

  Isolate* EnterTemporaryIsolate();
  static void ExitTemporaryIsolate();

  Mutex* cache_mutex() { return &cache_mutex_; }
  void RunWithCachedCatchEntryMoves(
      const Code& code,
      intptr_t pc,
      std::function<void(const CatchEntryMoves&)> action);
  void ClearCatchEntryMovesCacheLocked();
  HandlerInfoCache* handler_info_cache() { return &handler_info_cache_; }

  void SetNativeAssetsCallbacks(NativeAssetsApi* native_assets_api) {
    native_assets_api_ = *native_assets_api;
  }
  NativeAssetsApi* native_assets_api() { return &native_assets_api_; }

  bool has_attempted_stepping() const {
    return has_attempted_stepping_.load(std::memory_order_relaxed);
  }
  void set_has_attempted_stepping(bool value) {
    has_attempted_stepping_.store(value, std::memory_order_relaxed);
  }

 private:
  friend class Dart;  // For `object_store_ = ` in Dart::Init
  friend class Heap;
  friend class StackFrame;  // For `[isolates_].First()`.
  // For `object_store_shared_untag()`, `class_table_shared_untag()`
  friend class Isolate;

#define ISOLATE_GROUP_FLAG_BITS(V)                                             \
  V(AllClassesFinalized)                                                       \
  V(EnableAsserts)                                                             \
  V(HasAttemptedReload)                                                        \
  V(HasSeenOOM)                                                                \
  V(RemappingCids)                                                             \
  V(ShouldLoadVmService)                                                       \
  V(Obfuscate)                                                                 \
  V(UseFieldGuards)                                                            \
  V(UseOsr)                                                                    \
  V(SnapshotIsDontNeedSafe)                                                    \
  V(BranchCoverage)                                                            \
  V(Coverage)                                                                  \
  V(HasDynamicallyExtendableClasses)

  // Isolate group specific flags.
  enum FlagBits {
#define DECLARE_BIT(Name) k##Name##Bit,
    ISOLATE_GROUP_FLAG_BITS(DECLARE_BIT)
#undef DECLARE_BIT
  };

#define DECLARE_BITFIELD(Name)                                                 \
  using Name##Bit = BitField<uint32_t, bool, k##Name##Bit>;
  ISOLATE_GROUP_FLAG_BITS(DECLARE_BITFIELD)
#undef DECLARE_BITFIELD

  void set_heap(std::unique_ptr<Heap> value);

  // Accessed from generated code.
  ClassTable* class_table_;
  AcqRelAtomic<ClassPtr*> cached_class_table_table_;
  std::unique_ptr<ObjectStore> object_store_;
  // End accessed from generated code.

  ClassTableAllocator class_table_allocator_;
  ClassTable* heap_walk_class_table_;

  const char** obfuscation_map_ = nullptr;

  bool is_vm_isolate_ = false;
  void* embedder_data_ = nullptr;

  IdleTimeHandler idle_time_handler_;
  std::unique_ptr<MutatorThreadPool> thread_pool_;
  std::unique_ptr<SafepointRwLock> isolates_lock_;
  IntrusiveDList<Isolate> isolates_;
  RelaxedAtomic<Dart_Port> interrupt_port_ = ILLEGAL_PORT;
  intptr_t isolate_count_ = 0;
  intptr_t group_mutator_count_ = 0;
  bool initial_spawn_successful_ = false;
  Dart_LibraryTagHandler library_tag_handler_ = nullptr;
  Dart_DeferredLoadHandler deferred_load_handler_ = nullptr;
  int64_t start_time_micros_;
  bool is_system_isolate_group_;
  Random random_;

#if !defined(PRODUCT) && !defined(DART_PRECOMPILED_RUNTIME)
  int64_t last_reload_timestamp_;
  std::shared_ptr<IsolateGroupReloadContext> group_reload_context_;
  // Per-isolate-group copy of FLAG_reload_every.
  RelaxedAtomic<intptr_t> reload_every_n_stack_overflow_checks_;
  ProgramReloadContext* program_reload_context_ = nullptr;
#endif
  Become* become_ = nullptr;

#define ISOLATE_METRIC_VARIABLE(type, variable, name, unit)                    \
  type metric_##variable##_;
  ISOLATE_GROUP_METRIC_LIST(ISOLATE_METRIC_VARIABLE);
#undef ISOLATE_METRIC_VARIABLE

#if !defined(PRODUCT)
  // Timestamps of last operation via service.
  int64_t last_allocationprofile_accumulator_reset_timestamp_ = 0;
  int64_t last_allocationprofile_gc_timestamp_ = 0;

#endif  // !defined(PRODUCT)

  MarkingStack* old_marking_stack_ = nullptr;
  MarkingStack* new_marking_stack_ = nullptr;
  MarkingStack* deferred_marking_stack_ = nullptr;
  std::shared_ptr<IsolateGroupSource> source_;
  std::unique_ptr<ApiState> api_state_;
  std::unique_ptr<ThreadRegistry> thread_registry_;
  std::unique_ptr<SafepointHandler> safepoint_handler_;

  static RwLock* isolate_groups_rwlock_;
  static IntrusiveDList<IsolateGroup>* isolate_groups_;
  static Random* isolate_group_random_;

  Dart_Port id_ = 0;

  std::unique_ptr<StoreBuffer> store_buffer_;
  std::unique_ptr<Heap> heap_;
  std::unique_ptr<DispatchTable> dispatch_table_;
  const uint8_t* dispatch_table_snapshot_ = nullptr;
  intptr_t dispatch_table_snapshot_size_ = 0;
  ArrayPtr saved_unlinked_calls_;
  std::shared_ptr<FieldTable> initial_field_table_;
  std::shared_ptr<FieldTable> sentinel_field_table_;
  std::shared_ptr<FieldTable> shared_initial_field_table_;
  std::shared_ptr<FieldTable> shared_field_table_;
  AtomicBitFieldContainer<uint32_t> isolate_group_flags_;

  NOT_IN_PRECOMPILED(std::unique_ptr<BackgroundCompiler> background_compiler_);

  Mutex symbols_mutex_;
  Mutex type_canonicalization_mutex_;
  Mutex type_arguments_canonicalization_mutex_;
  Mutex subtype_test_cache_mutex_;
  Mutex megamorphic_table_mutex_;
  Mutex type_feedback_mutex_;
  Mutex patchable_call_mutex_;
  Mutex constant_canonicalization_mutex_;
  Mutex kernel_data_lib_cache_mutex_;
  Mutex kernel_data_class_cache_mutex_;
  Mutex kernel_constants_mutex_;

#if defined(DART_PRECOMPILED_RUNTIME)
  Mutex unlinked_call_map_mutex_;
#endif

#if !defined(DART_PRECOMPILED_RUNTIME) || defined(DART_DYNAMIC_MODULES)
  Mutex initializer_functions_mutex_;
#endif  // !defined(DART_PRECOMPILED_RUNTIME) || defined(DART_DYNAMIC_MODULES)

  // Ensure exclusive execution of shared field initializers.
  SafepointRwLock shared_field_initializer_rwlock_;

  // Ensures synchronized access to classes functions, fields and other
  // program structure elements to accommodate concurrent modification done
  // by multiple isolates and background compiler.
  std::unique_ptr<SafepointRwLock> program_lock_;

  // Allow us to ensure the number of active mutators is limited by a maximum.
  std::unique_ptr<Monitor> active_mutators_monitor_;
  intptr_t active_mutators_ = 0;
  intptr_t waiting_mutators_ = 0;
  intptr_t max_active_mutators_ = 0;
  bool has_timeout_waiter_ = false;

  NOT_IN_PRODUCT(GroupDebugger* debugger_ = nullptr);

  NativeAssetsApi native_assets_api_;

  Mutex cache_mutex_;
  HandlerInfoCache handler_info_cache_;
  CatchEntryMovesCache catch_entry_moves_cache_;

  std::atomic<bool> has_attempted_stepping_;
};

// When an isolate sends-and-exits this class represent things that it passed
// to the beneficiary.
class Bequest {
 public:
  Bequest(PersistentHandle* handle, Dart_Port beneficiary)
      : handle_(handle), beneficiary_(beneficiary) {}
  ~Bequest();

  PersistentHandle* handle() { return handle_; }
  PersistentHandle* TakeHandle() {
    auto handle = handle_;
    handle_ = nullptr;
    return handle;
  }
  Dart_Port beneficiary() { return beneficiary_; }

 private:
  PersistentHandle* handle_;
  Dart_Port beneficiary_;
};

class Isolate : public IntrusiveDListEntry<Isolate> {
 public:
  // Keep both these enums in sync with isolate_patch.dart.
  // The different Isolate API message types.
  enum LibMsgId {
    kPauseMsg = 1,
    kResumeMsg = 2,
    kPingMsg = 3,
    kKillMsg = 4,
    kAddExitMsg = 5,
    kDelExitMsg = 6,
    kAddErrorMsg = 7,
    kDelErrorMsg = 8,
    kErrorFatalMsg = 9,

    // Internal message ids.
    kInterruptMsg = 10,     // Break in the debugger.
    kInternalKillMsg = 11,  // Like kill, but does not run exit listeners, etc.
    kDrainServiceExtensionsMsg = 12,  // Invoke pending service extensions
    kCheckForReload = 13,  // Participate in other isolate group reload.
  };
  // The different Isolate API message priorities for ping and kill messages.
  enum LibMsgPriority {
    kImmediateAction = 0,
    kBeforeNextEventAction = 1,
    kAsEventAction = 2
  };

  ~Isolate();

  static inline Isolate* Current() {
    Thread* thread = Thread::Current();
    return thread == nullptr ? nullptr : thread->isolate();
  }

  bool IsScheduled() { return scheduled_mutator_thread() != nullptr; }
  Thread* scheduled_mutator_thread() const { return scheduled_mutator_thread_; }

  ThreadRegistry* thread_registry() const { return group()->thread_registry(); }

  SafepointHandler* safepoint_handler() const {
    return group()->safepoint_handler();
  }

  FieldTable* field_table() const { return field_table_; }
  void set_field_table(Thread* T, FieldTable* field_table) {
    delete field_table_;
    field_table_ = field_table;
    T->field_table_values_ = field_table->table();
  }

  IsolateObjectStore* isolate_object_store() const {
    return isolate_object_store_.get();
  }

  Dart_MessageNotifyCallback message_notify_callback() const {
    return message_notify_callback_.load(std::memory_order_relaxed);
  }

  void set_message_notify_callback(Dart_MessageNotifyCallback value) {
    message_notify_callback_.store(value, std::memory_order_release);
  }

  void set_on_shutdown_callback(Dart_IsolateShutdownCallback value) {
    on_shutdown_callback_ = value;
  }
  Dart_IsolateShutdownCallback on_shutdown_callback() {
    return on_shutdown_callback_;
  }
  void set_on_cleanup_callback(Dart_IsolateCleanupCallback value) {
    on_cleanup_callback_ = value;
  }
  Dart_IsolateCleanupCallback on_cleanup_callback() {
    return on_cleanup_callback_;
  }

  void bequeath(std::unique_ptr<Bequest> bequest) {
    bequest_ = std::move(bequest);
  }

  IsolateGroupSource* source() const { return isolate_group_->source(); }
  IsolateGroup* group() const { return isolate_group_; }

  bool HasPendingMessages();

  Thread* mutator_thread() const;

  const char* name() const { return name_; }
  void set_name(const char* name);

  int64_t UptimeMicros() const;

  Dart_Port main_port() const { return main_port_; }
  void set_main_port(Dart_Port port) {
    ASSERT(main_port_ == 0);  // Only set main port once.
    main_port_ = port;
  }
  void set_pause_capability(uint64_t value) { pause_capability_ = value; }
  uint64_t pause_capability() const { return pause_capability_; }
  void set_terminate_capability(uint64_t value) {
    terminate_capability_ = value;
  }
  uint64_t terminate_capability() const { return terminate_capability_; }

  void SendInternalLibMessage(LibMsgId msg_id, uint64_t capability);
  static bool SendInternalLibMessage(Dart_Port main_port,
                                     LibMsgId msg_id,
                                     uint64_t capability);

  void set_init_callback_data(void* value) { init_callback_data_ = value; }
  void* init_callback_data() const { return init_callback_data_; }

  void set_finalizers(const GrowableObjectArray& value);
  static intptr_t finalizers_offset() {
    return OFFSET_OF(Isolate, finalizers_);
  }

  Dart_EnvironmentCallback environment_callback() const {
    return environment_callback_;
  }
  void set_environment_callback(Dart_EnvironmentCallback value) {
    environment_callback_ = value;
  }

  bool HasDeferredLoadHandler() const {
    return group()->deferred_load_handler() != nullptr;
  }
  ObjectPtr CallDeferredLoadHandler(intptr_t id);

  void ScheduleInterrupts(uword interrupt_bits);

  const char* MakeRunnable();
  void MakeRunnableLocked();
  void Run();

  MessageHandler* message_handler() const;

  bool is_runnable() const { return isolate_flags_.Read<IsRunnableBit>(); }
  void set_is_runnable(bool value) {
    isolate_flags_.UpdateBool<IsRunnableBit>(value);
#if !defined(PRODUCT)
    if (is_runnable()) {
      set_last_resume_timestamp();
    }
#endif
  }

#if !defined(PRODUCT)
  Debugger* debugger() const { return debugger_; }

  // Returns the current SampleBlock used to track CPU profiling samples.
  SampleBlock* current_sample_block() const { return current_sample_block_; }
  void set_current_sample_block(SampleBlock* block) {
    current_sample_block_ = block;
  }
  void ProcessFreeSampleBlocks(Thread* thread);

  // Returns the current SampleBlock used to track Dart allocation samples.
  SampleBlock* current_allocation_sample_block() const {
    return current_allocation_sample_block_;
  }
  void set_current_allocation_sample_block(SampleBlock* block) {
    current_allocation_sample_block_ = block;
  }

  bool TakeHasCompletedBlocks() {
    return has_completed_blocks_.exchange(0) != 0;
  }
  bool TrySetHasCompletedBlocks() {
    return has_completed_blocks_.exchange(1) == 0;
  }

  void set_has_resumption_breakpoints(bool value) {
    has_resumption_breakpoints_ = value;
  }
  bool has_resumption_breakpoints() const {
    return has_resumption_breakpoints_;
  }
  static intptr_t has_resumption_breakpoints_offset() {
    return OFFSET_OF(Isolate, has_resumption_breakpoints_);
  }

  bool ResumeRequest() const { return isolate_flags_.Read<ResumeRequestBit>(); }
  // Lets the embedder know that a service message resulted in a resume request.
  void SetResumeRequest() {
    isolate_flags_.UpdateBool<ResumeRequestBit>(true);
    set_last_resume_timestamp();
  }

  void set_last_resume_timestamp() {
    last_resume_timestamp_ = OS::GetCurrentTimeMillis();
  }

  int64_t last_resume_timestamp() const { return last_resume_timestamp_; }

  // Returns whether the vm service has requested that the debugger
  // resume execution.
  bool GetAndClearResumeRequest() {
    return isolate_flags_.TryClear<ResumeRequestBit>();
  }
#endif

  // Verify that the sender has the capability to pause or terminate the
  // isolate.
  bool VerifyPauseCapability(const Object& capability) const;
  bool VerifyTerminateCapability(const Object& capability) const;

  // Returns true if the capability was added or removed from this isolate's
  // list of pause events.
  bool AddResumeCapability(const Capability& capability);
  bool RemoveResumeCapability(const Capability& capability);

  void AddExitListener(const SendPort& listener, const Instance& response);
  void RemoveExitListener(const SendPort& listener);
  void NotifyExitListeners();

  void AddErrorListener(const SendPort& listener);
  void RemoveErrorListener(const SendPort& listener);
  bool NotifyErrorListeners(const char* msg, const char* stacktrace);

  bool ErrorsFatal() const { return isolate_flags_.Read<ErrorsFatalBit>(); }
  void SetErrorsFatal(bool value) {
    isolate_flags_.UpdateBool<ErrorsFatalBit>(value);
  }

  Random* random() { return &random_; }

  Simulator* simulator() const { return simulator_; }
  void set_simulator(Simulator* value) { simulator_ = value; }

  void IncrementSpawnCount();
  void DecrementSpawnCount();
  void WaitForOutstandingSpawns();

  static void SetCreateGroupCallback(Dart_IsolateGroupCreateCallback cb) {
    create_group_callback_ = cb;
  }
  static Dart_IsolateGroupCreateCallback CreateGroupCallback() {
    return create_group_callback_;
  }

  static void SetInitializeCallback_(Dart_InitializeIsolateCallback cb) {
    initialize_callback_ = cb;
  }
  static Dart_InitializeIsolateCallback InitializeCallback() {
    return initialize_callback_;
  }

  static void SetShutdownCallback(Dart_IsolateShutdownCallback cb) {
    shutdown_callback_ = cb;
  }
  static Dart_IsolateShutdownCallback ShutdownCallback() {
    return shutdown_callback_;
  }

  static void SetCleanupCallback(Dart_IsolateCleanupCallback cb) {
    cleanup_callback_ = cb;
  }
  static Dart_IsolateCleanupCallback CleanupCallback() {
    return cleanup_callback_;
  }

  static void SetGroupCleanupCallback(Dart_IsolateGroupCleanupCallback cb) {
    cleanup_group_callback_ = cb;
  }
  static Dart_IsolateGroupCleanupCallback GroupCleanupCallback() {
    return cleanup_group_callback_;
  }

#if !defined(PRODUCT)
  // This method first ensures that the default Service ID zone for this isolate
  // exists, by creating it if necessary, and then adds a new Service ID zone to
  // `serivce_id_zones_` and returns a reference to that new zone.
  RingServiceIdZone& AddServiceIdZone(
      ObjectIdRing::BackingBufferKind backing_buffer_kind,
      ObjectIdRing::IdPolicy id_assignment_policy,
      int32_t capacity);

  void DeleteServiceIdZone(int32_t id);

  // The default Service ID zone is created lazily; this method returns the
  // default Service ID zone, creating it if necessary.
  RingServiceIdZone& EnsureDefaultServiceIdZone();

  RingServiceIdZone* GetServiceIdZone(intptr_t zone_id) const;

  intptr_t NumServiceIdZones() const;
#endif  // !defined(PRODUCT)

  FfiCallbackMetadata::Trampoline CreateAsyncFfiCallback(
      Zone* zone,
      const Function& send_function,
      Dart_Port send_port);
  FfiCallbackMetadata::Trampoline CreateIsolateLocalFfiCallback(
      Zone* zone,
      const Function& trampoline,
      const Closure& target,
      bool keep_isolate_alive);
  FfiCallbackMetadata::Trampoline CreateIsolateGroupBoundFfiCallback(
      Zone* zone,
      const Function& trampoline,
      const Closure& target);
  void DeleteFfiCallback(FfiCallbackMetadata::Trampoline callback);
  void UpdateNativeCallableKeepIsolateAliveCounter(intptr_t delta);
  bool HasOpenNativeCallables();

  bool HasLivePorts();
  ReceivePortPtr CreateReceivePort(const String& debug_name);
  void SetReceivePortKeepAliveState(const ReceivePort& receive_port,
                                    bool keep_isolate_alive);
  void CloseReceivePort(const ReceivePort& receive_port);

  // Visible for testing.
  FfiCallbackMetadata::MetadataEntry* ffi_callback_list_head() {
    return ffi_callback_list_head_;
  }

  intptr_t BlockClassFinalization() {
    ASSERT(defer_finalization_count_ >= 0);
    return defer_finalization_count_++;
  }

  intptr_t UnblockClassFinalization() {
    ASSERT(defer_finalization_count_ > 0);
    return defer_finalization_count_--;
  }

  bool AllowClassFinalization() {
    ASSERT(defer_finalization_count_ >= 0);
    return defer_finalization_count_ == 0;
  }

#ifndef PRODUCT
  void PrintJSON(JSONStream* stream, bool ref = true);

  // Creates an object with the total heap memory usage statistics for this
  // isolate.
  void PrintMemoryUsageJSON(JSONStream* stream);

  void PrintPauseEventJSON(JSONStream* stream);
#endif

#if !defined(PRODUCT)
  VMTagCounters* vm_tag_counters() { return &vm_tag_counters_; }
#endif  // !defined(PRODUCT)

  bool IsPaused() const;

#if !defined(PRODUCT)
  bool should_pause_post_service_request() const {
    return isolate_flags_.Read<ShouldPausePostServiceRequestBit>();
  }
  void set_should_pause_post_service_request(bool value) {
    isolate_flags_.UpdateBool<ShouldPausePostServiceRequestBit>(value);
  }
#endif  // !defined(PRODUCT)

  ErrorPtr PausePostRequest();

  uword user_tag() const { return user_tag_; }
  static intptr_t user_tag_offset() { return OFFSET_OF(Isolate, user_tag_); }
  static intptr_t current_tag_offset() {
    return OFFSET_OF(Isolate, current_tag_);
  }
  static intptr_t default_tag_offset() {
    return OFFSET_OF(Isolate, default_tag_);
  }

#if !defined(PRODUCT)
#define ISOLATE_METRIC_ACCESSOR(type, variable, name, unit)                    \
  type* Get##variable##Metric() { return &metric_##variable##_; }
  ISOLATE_METRIC_LIST(ISOLATE_METRIC_ACCESSOR);
#undef ISOLATE_METRIC_ACCESSOR
#endif  // !defined(PRODUCT)

  static intptr_t IsolateListLength();

  GrowableObjectArrayPtr tag_table() const { return tag_table_; }
  void set_tag_table(const GrowableObjectArray& value);

  UserTagPtr current_tag() const { return current_tag_; }
  void set_current_tag(const UserTag& tag);

  UserTagPtr default_tag() const { return default_tag_; }
  void set_default_tag(const UserTag& tag);

  // Also sends a paused at exit event over the service protocol.
  void SetStickyError(ErrorPtr sticky_error);

  ErrorPtr sticky_error() const { return sticky_error_; }
  DART_WARN_UNUSED_RESULT ErrorPtr StealStickyError();

#ifndef PRODUCT
  ErrorPtr InvokePendingServiceExtensionCalls();
  void AppendServiceExtensionCall(const Instance& closure,
                                  const String& method_name,
                                  const Array& parameter_keys,
                                  const Array& parameter_values,
                                  const Instance& reply_port,
                                  const Instance& id);
  void RegisterServiceExtensionHandler(const String& name,
                                       const Instance& closure);
  InstancePtr LookupServiceExtensionHandler(const String& name);
#endif

  static void VisitIsolates(IsolateVisitor* visitor);

#if !defined(PRODUCT)
  // Handle service messages until we are told to resume execution.
  void PauseEventHandler();
#endif

  bool is_vm_isolate() const { return isolate_flags_.Read<IsVMIsolateBit>(); }
  void set_is_vm_isolate(bool value) {
    isolate_flags_.UpdateBool<IsVMIsolateBit>(value);
  }

  bool is_service_registered() const {
    return isolate_flags_.Read<IsServiceRegisteredBit>();
  }
  void set_is_service_registered(bool value) {
    isolate_flags_.UpdateBool<IsServiceRegisteredBit>(value);
  }

  // Isolate-specific flag handling.
  static void FlagsInitialize(Dart_IsolateFlags* api_flags);
  void FlagsCopyTo(Dart_IsolateFlags* api_flags) const;
  void FlagsCopyFrom(const Dart_IsolateFlags& api_flags);

#if defined(DART_PRECOMPILER)
#define FLAG_FOR_PRECOMPILER(from_field, from_flag) (from_field)
#else
#define FLAG_FOR_PRECOMPILER(from_field, from_flag) (from_flag)
#endif

#if !defined(PRODUCT)
#define FLAG_FOR_NONPRODUCT(from_field, from_flag) (from_field)
#else
#define FLAG_FOR_NONPRODUCT(from_field, from_flag) (from_flag)
#endif

#define FLAG_FOR_PRODUCT(from_field, from_flag) (from_field)

#define DECLARE_GETTER(when, name, bitname, isolate_flag_name, flag_name)      \
  bool name() const {                                                          \
    return FLAG_FOR_##when(isolate_flags_.Read<bitname##Bit>(), flag_name);    \
  }
  BOOL_ISOLATE_FLAG_LIST(DECLARE_GETTER)
#undef FLAG_FOR_NONPRODUCT
#undef FLAG_FOR_PRECOMPILER
#undef FLAG_FOR_PRODUCT
#undef DECLARE_GETTER

  // Kills all non-system isolates.
  static void KillAllIsolates(LibMsgId msg_id);
  // Kills all system isolates, excluding the kernel service and VM service.
  static void KillAllSystemIsolates(LibMsgId msg_id);
  static void KillIfExists(Isolate* isolate, LibMsgId msg_id);

  // Lookup an isolate by its main port. Returns nullptr if no matching isolate
  // is found.
  static Isolate* LookupIsolateByPort(Dart_Port port);

  // Lookup an isolate by its main port and return a copy of its name. Returns
  // nullptr if not matching isolate is found.
  static std::unique_ptr<char[]> LookupIsolateNameByPort(Dart_Port port);

  static void DisableIsolateCreation();
  static void EnableIsolateCreation();
  static bool IsolateCreationEnabled();
  static bool IsSystemIsolate(const Isolate* isolate) {
    return IsolateGroup::IsSystemIsolateGroup(isolate->group());
  }
  static bool IsVMInternalIsolate(const Isolate* isolate);

  void RememberLiveTemporaries();
  void DeferredMarkLiveTemporaries();

  std::unique_ptr<VirtualMemory> TakeRegexpBacktrackStack() {
    return std::move(regexp_backtracking_stack_cache_);
  }

  void CacheRegexpBacktrackStack(std::unique_ptr<VirtualMemory> stack) {
    regexp_backtracking_stack_cache_ = std::move(stack);
  }

  void init_loaded_prefixes_set_storage();
  bool IsPrefixLoaded(const LibraryPrefix& prefix) const;
  void SetPrefixIsLoaded(const LibraryPrefix& prefix);

  bool SetOwnerThread(ThreadId expected_old_owner, ThreadId new_owner);

  // Must be invoked with a valid PortMap::Locker, or while this isolate is the
  // current isolate (in which case the locker may be null).
  ThreadId GetOwnerThread(PortMap::Locker* locker);

 private:
  friend class Dart;                  // Init, InitOnce, Shutdown.
  friend class IsolateKillerVisitor;  // Kill().
  friend Isolate* CreateWithinExistingIsolateGroup(IsolateGroup* g,
                                                   const char* n,
                                                   char** e);

  Isolate(IsolateGroup* group, const Dart_IsolateFlags& api_flags);

  static void InitVM();
  static Isolate* InitIsolate(const char* name_prefix,
                              IsolateGroup* isolate_group,
                              const Dart_IsolateFlags& api_flags,
                              bool is_vm_isolate = false);

  // The isolate_creation_monitor_ should be held when calling Kill().
  void KillLocked(LibMsgId msg_id);

  void Shutdown();
  void RunAndCleanupFinalizersOnShutdown();
  void LowLevelShutdown();

  // Unregister the [isolate] from the thread, remove it from the isolate group,
  // invoke the cleanup function (if any), delete the isolate and possibly
  // delete the isolate group (if it's the last isolate in the group).
  static void LowLevelCleanup(Isolate* isolate);

  void BuildName(const char* name_prefix);

  void ProfileIdle();

  // Visit all object pointers. Caller must ensure concurrent sweeper is not
  // running, and the visitor must not allocate.
  void VisitObjectPointers(ObjectPointerVisitor* visitor,
                           ValidationPolicy validate_frames);
  void VisitStackPointers(ObjectPointerVisitor* visitor,
                          ValidationPolicy validate_frames);

  void set_user_tag(uword tag) { user_tag_ = tag; }

  void set_is_system_isolate(bool is_system_isolate) {
    is_system_isolate_ = is_system_isolate;
  }

#if !defined(PRODUCT)
  GrowableObjectArrayPtr GetAndClearPendingServiceExtensionCalls();
  GrowableObjectArrayPtr pending_service_extension_calls() const {
    return pending_service_extension_calls_;
  }
  void set_pending_service_extension_calls(const GrowableObjectArray& value);
  GrowableObjectArrayPtr registered_service_extension_handlers() const {
    return registered_service_extension_handlers_;
  }
  void set_registered_service_extension_handlers(
      const GrowableObjectArray& value);
#endif  // !defined(PRODUCT)

  // DEPRECATED: Use Thread's methods instead. During migration, these default
  // to using the mutator thread (which must also be the current thread).
  Zone* current_zone() const {
    ASSERT(Thread::Current() == mutator_thread());
    return mutator_thread()->zone();
  }

  // Accessed from generated code.
  // ** This block of fields must come first! **
  // For AOT cross-compilation, we rely on these members having the same offsets
  // in SIMARM(IA32) and ARM, and the same offsets in SIMARM64(X64) and ARM64.
  // We use only word-sized fields to avoid differences in struct packing on the
  // different architectures. See also CheckOffsets in dart.cc.
  uword user_tag_ = 0;
  UserTagPtr current_tag_;
  UserTagPtr default_tag_;
  FieldTable* field_table_ = nullptr;
  // Used to clear out `UntaggedFinalizerBase::isolate_` pointers on isolate
  // shutdown to prevent usage of dangling pointers.
  GrowableObjectArrayPtr finalizers_;
  bool has_resumption_breakpoints_ = false;
  // End accessed from generated code.

  Thread* scheduled_mutator_thread_ = nullptr;
  // Stores the saved [Thread] object of a mutator. Mutators may retain their
  // thread even when being descheduled (e.g. due to having an active stack).
  Thread* mutator_thread_ = nullptr;

  IsolateGroup* const isolate_group_;
  std::unique_ptr<IsolateObjectStore> isolate_object_store_;

#define ISOLATE_FLAG_BITS(V)                                                   \
  V(ErrorsFatal)                                                               \
  V(IsRunnable)                                                                \
  V(IsVMIsolate)                                                               \
  V(IsServiceIsolate)                                                          \
  V(IsKernelIsolate)                                                           \
  V(ResumeRequest)                                                             \
  V(HasAttemptedStepping)                                                      \
  V(ShouldPausePostServiceRequest)                                             \
  V(IsSystemIsolate)                                                           \
  V(IsServiceRegistered)

  // Isolate specific flags.
  enum FlagBits {
#define DECLARE_BIT(Name) k##Name##Bit,
    ISOLATE_FLAG_BITS(DECLARE_BIT)
#undef DECLARE_BIT
  };

#define DECLARE_BITFIELD(Name)                                                 \
  using Name##Bit = BitField<uint32_t, bool, k##Name##Bit>;
  ISOLATE_FLAG_BITS(DECLARE_BITFIELD)
#undef DECLARE_BITFIELD

  AtomicBitFieldContainer<uint32_t> isolate_flags_;

// Fields that aren't needed in a product build go here with boolean flags at
// the top.
#if !defined(PRODUCT)
  Debugger* debugger_ = nullptr;

  // SampleBlock containing CPU profiling samples.
  RelaxedAtomic<SampleBlock*> current_sample_block_ = nullptr;

  // SampleBlock containing Dart allocation profiling samples.
  RelaxedAtomic<SampleBlock*> current_allocation_sample_block_ = nullptr;

  RelaxedAtomic<uword> has_completed_blocks_ = {0};

  int64_t last_resume_timestamp_;

  VMTagCounters vm_tag_counters_;

  // We use 6 list entries for each pending service extension calls.
  enum {
    kPendingHandlerIndex = 0,
    kPendingMethodNameIndex,
    kPendingKeysIndex,
    kPendingValuesIndex,
    kPendingReplyPortIndex,
    kPendingIdIndex,
    kPendingEntrySize
  };
  GrowableObjectArrayPtr pending_service_extension_calls_;

  // We use 2 list entries for each registered extension handler.
  enum {
    kRegisteredNameIndex = 0,
    kRegisteredHandlerIndex,
    kRegisteredEntrySize
  };
  GrowableObjectArrayPtr registered_service_extension_handlers_;

  // Used to wake the isolate when it is in the pause event loop.
  Monitor* pause_loop_monitor_ = nullptr;

  // The array of Service ID zones is created lazily.
  MallocGrowableArray<RingServiceIdZone*>* service_id_zones_;

#define ISOLATE_METRIC_VARIABLE(type, variable, name, unit)                    \
  type metric_##variable##_;
  ISOLATE_METRIC_LIST(ISOLATE_METRIC_VARIABLE);
#undef ISOLATE_METRIC_VARIABLE
#endif  // !defined(PRODUCT)

  // All other fields go here.
  int64_t start_time_micros_;
  std::atomic<Dart_MessageNotifyCallback> message_notify_callback_;
  Dart_IsolateShutdownCallback on_shutdown_callback_ = nullptr;
  Dart_IsolateCleanupCallback on_cleanup_callback_ = nullptr;
  char* name_ = nullptr;
  Dart_Port main_port_ = 0;
  uint64_t pause_capability_ = 0;
  uint64_t terminate_capability_ = 0;
  void* init_callback_data_ = nullptr;
  Dart_EnvironmentCallback environment_callback_ = nullptr;
  Random random_;
  Simulator* simulator_ = nullptr;
  Mutex mutex_;  // Protects compiler stats.
  IsolateMessageHandler* message_handler_ = nullptr;
  intptr_t defer_finalization_count_ = 0;
  FfiCallbackMetadata::MetadataEntry* ffi_callback_list_head_ = nullptr;
  intptr_t ffi_callback_keep_alive_counter_ = 0;
  RelaxedAtomic<ThreadId> owner_thread_ = OSThread::kInvalidThreadId;

  GrowableObjectArrayPtr tag_table_;

  ErrorPtr sticky_error_;

  std::unique_ptr<Bequest> bequest_;
  Dart_Port beneficiary_ = 0;

  // This guards spawn_count_. An isolate cannot complete shutdown and be
  // destroyed while there are child isolates in the midst of a spawn.
  Monitor spawn_count_monitor_;
  intptr_t spawn_count_ = 0;

  // Signals whether the isolate can receive messages (e.g. KillAllIsolates can
  // send a kill message).
  // This is protected by [isolate_creation_monitor_].
  bool accepts_messages_ = false;

  std::unique_ptr<VirtualMemory> regexp_backtracking_stack_cache_ = nullptr;

  intptr_t wake_pause_event_handler_count_;

  // The number of open [ReceivePort]s the isolate owns.
  intptr_t open_ports_ = 0;

  // The number of open [ReceivePort]s that keep the isolate alive.
  intptr_t open_ports_keepalive_ = 0;

  static Dart_IsolateGroupCreateCallback create_group_callback_;
  static Dart_InitializeIsolateCallback initialize_callback_;
  static Dart_IsolateShutdownCallback shutdown_callback_;
  static Dart_IsolateCleanupCallback cleanup_callback_;
  static Dart_IsolateGroupCleanupCallback cleanup_group_callback_;

#if !defined(PRODUCT)
  static void WakePauseEventHandler(Dart_Isolate isolate);
#endif

  // Manage list of existing isolates.
  static bool TryMarkIsolateReady(Isolate* isolate);
  static void UnMarkIsolateReady(Isolate* isolate);
  static void MaybeNotifyVMShutdown();
  bool AcceptsMessagesLocked() {
    ASSERT(isolate_creation_monitor_->IsOwnedByCurrentThread());
    return accepts_messages_;
  }

  // This monitor protects [creation_enabled_] and [pending_shutdowns_].
  static Monitor* isolate_creation_monitor_;
  static bool creation_enabled_;
  static intptr_t pending_shutdowns_;

  ArrayPtr loaded_prefixes_set_storage_;

  bool is_system_isolate_ = false;

#define REUSABLE_FRIEND_DECLARATION(name)                                      \
  friend class Reusable##name##HandleScope;
  REUSABLE_HANDLE_LIST(REUSABLE_FRIEND_DECLARATION)
#undef REUSABLE_FRIEND_DECLARATION

  friend class Become;       // VisitObjectPointers
  friend class GCCompactor;  // VisitObjectPointers
  friend class GCMarker;     // VisitObjectPointers
  friend class SafepointHandler;
  friend class ObjectGraph;         // VisitObjectPointers
  friend class HeapSnapshotWriter;  // VisitObjectPointers
  friend class Scavenger;           // VisitObjectPointers
  friend class HeapIterationScope;  // VisitObjectPointers
  friend class ServiceIsolate;
  friend class Thread;
  friend class Timeline;
  friend class IsolateGroup;  // reload_context_

  DISALLOW_COPY_AND_ASSIGN(Isolate);
};

// When we need to execute code in an isolate, we use the
// StartIsolateScope.
class StartIsolateScope {
 public:
  explicit StartIsolateScope(Isolate* new_isolate)
      : new_isolate_(new_isolate), saved_isolate_(Isolate::Current()) {
    if (new_isolate_ == nullptr) {
      ASSERT(Isolate::Current() == nullptr);
      // Do nothing.
      return;
    }
    if (saved_isolate_ != new_isolate_) {
      ASSERT(Isolate::Current() == nullptr);
      Thread::EnterIsolate(new_isolate_);
      // Ensure this is not a nested 'isolate enter' with prior state.
      ASSERT(Thread::Current()->top_exit_frame_info() == 0);
    }
  }

  ~StartIsolateScope() {
    if (new_isolate_ == nullptr) {
      ASSERT(Isolate::Current() == nullptr);
      // Do nothing.
      return;
    }
    if (saved_isolate_ != new_isolate_) {
      ASSERT(saved_isolate_ == nullptr);
      // ASSERT that we have bottomed out of all Dart invocations.
      ASSERT(Thread::Current()->top_exit_frame_info() == 0);
      Thread::ExitIsolate();
    }
  }

 private:
  Isolate* new_isolate_;
  Isolate* saved_isolate_;

  DISALLOW_COPY_AND_ASSIGN(StartIsolateScope);
};

class EnterIsolateGroupScope {
 public:
  explicit EnterIsolateGroupScope(IsolateGroup* isolate_group)
      : isolate_group_(isolate_group) {
    ASSERT(IsolateGroup::Current() == nullptr);
    Thread::EnterIsolateGroupAsHelper(isolate_group_, Thread::kUnknownTask,
                                      /*bypass_safepoint=*/false);
  }

  ~EnterIsolateGroupScope() {
    Thread::ExitIsolateGroupAsHelper(/*bypass_safepoint=*/false);
  }

 private:
  IsolateGroup* isolate_group_;

  DISALLOW_COPY_AND_ASSIGN(EnterIsolateGroupScope);
};

// Ensure that isolate is not available for the duration of this scope.
//
// This can be used in code (e.g. GC, Kernel Loader, Compiler) that should not
// operate on an individual isolate.
class NoActiveIsolateScope : public StackResource {
 public:
  NoActiveIsolateScope() : NoActiveIsolateScope(Thread::Current()) {}
  explicit NoActiveIsolateScope(Thread* thread)
      : StackResource(thread), thread_(thread) {
    outer_ = thread_->no_active_isolate_scope_;
    saved_isolate_ = thread_->isolate_;

    thread_->no_active_isolate_scope_ = this;
    thread_->isolate_ = nullptr;
  }
  ~NoActiveIsolateScope() {
    ASSERT(thread_->isolate_ == nullptr);
    thread_->isolate_ = saved_isolate_;
    thread_->no_active_isolate_scope_ = outer_;
  }

 private:
  friend class ActiveIsolateScope;

  Thread* thread_;
  Isolate* saved_isolate_;
  NoActiveIsolateScope* outer_;
};

class ActiveIsolateScope : public StackResource {
 public:
  explicit ActiveIsolateScope(Thread* thread)
      : ActiveIsolateScope(thread,
                           thread->no_active_isolate_scope_->saved_isolate_) {}

  ActiveIsolateScope(Thread* thread, Isolate* isolate)
      : StackResource(thread), thread_(thread) {
    RELEASE_ASSERT(thread->isolate() == nullptr);
    thread_->isolate_ = isolate;
  }
  ~ActiveIsolateScope() {
    ASSERT(thread_->isolate_ != nullptr);
    thread_->isolate_ = nullptr;
  }

 private:
  Thread* thread_;
};

}  // namespace dart

#endif  // RUNTIME_VM_ISOLATE_H_
