// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "platform/assert.h"
#include "vm/heap/safepoint.h"
#include "vm/isolate.h"
#include "vm/lockers.h"
#include "vm/profiler.h"
#include "vm/stack_frame.h"
#include "vm/symbols.h"
#include "vm/thread_pool.h"
#include "vm/unit_test.h"

namespace dart {

VM_UNIT_TEST_CASE(Mutex) {
  // This unit test case needs a running isolate.
  TestCase::CreateTestIsolate();
  Mutex* mutex = new Mutex();
  mutex->Lock();
  EXPECT_EQ(false, mutex->TryLock());
  mutex->Unlock();
  EXPECT_EQ(true, mutex->TryLock());
  mutex->Unlock();
  {
    MutexLocker ml(mutex);
    EXPECT_EQ(false, mutex->TryLock());
  }
  // The isolate shutdown and the destruction of the mutex are out-of-order on
  // purpose.
  Dart_ShutdownIsolate();
  delete mutex;
}

#if !defined(PRODUCT)
VM_UNIT_TEST_CASE(Monitor) {
  // This unit test case needs a running isolate.
  TestCase::CreateTestIsolate();
  OSThread* thread = OSThread::Current();
  // Thread interrupter interferes with this test, disable interrupts.
  thread->DisableThreadInterrupts();
  Monitor* monitor = new Monitor();
  monitor->Enter();
  monitor->Exit();
  EXPECT_EQ(true, monitor->TryEnter());
  monitor->Exit();

  const int kNumAttempts = 5;
  int attempts = 0;
  while (attempts < kNumAttempts) {
    MonitorLocker ml(monitor);
    int64_t start = OS::GetCurrentMonotonicMicros();
    int64_t wait_time = 2017;
    Monitor::WaitResult wait_result = ml.Wait(wait_time);
    int64_t stop = OS::GetCurrentMonotonicMicros();

    // We expect to be timing out here.
    EXPECT_EQ(Monitor::kTimedOut, wait_result);

    // Check whether this attempt falls within the expected time limits.
    int64_t wakeup_time = (stop - start) / kMicrosecondsPerMillisecond;
    OS::PrintErr("wakeup_time: %" Pd64 "\n", wakeup_time);
    const int kAcceptableTimeJitter = 20;    // Measured in milliseconds.
    const int kAcceptableWakeupDelay = 150;  // Measured in milliseconds.
    if (((wait_time - kAcceptableTimeJitter) <= wakeup_time) &&
        (wakeup_time <= (wait_time + kAcceptableWakeupDelay))) {
      break;
    }

    // Record the attempt.
    attempts++;
  }
  EXPECT_LT(attempts, kNumAttempts);

  // The isolate shutdown and the destruction of the mutex are out-of-order on
  // purpose.
  Dart_ShutdownIsolate();
  delete monitor;
}
#endif

class ObjectCounter : public ObjectPointerVisitor {
 public:
  explicit ObjectCounter(IsolateGroup* isolate_group, const Object* obj)
      : ObjectPointerVisitor(isolate_group), obj_(obj), count_(0) {}

  void VisitPointers(ObjectPtr* first, ObjectPtr* last) override {
    for (ObjectPtr* current = first; current <= last; ++current) {
      if (*current == obj_->ptr()) {
        ++count_;
      }
    }
  }

#if defined(DART_COMPRESSED_POINTERS)
  void VisitCompressedPointers(uword heap_base,
                               CompressedObjectPtr* first,
                               CompressedObjectPtr* last) override {
    for (CompressedObjectPtr* current = first; current <= last; ++current) {
      if (current->Decompress(heap_base) == obj_->ptr()) {
        ++count_;
      }
    }
  }
#endif

  intptr_t count() const { return count_; }

 private:
  const Object* obj_;
  intptr_t count_;
};

class TaskWithZoneAllocation : public ThreadPool::Task {
 public:
  TaskWithZoneAllocation(IsolateGroup* isolate_group,
                         Monitor* monitor,
                         bool* done,
                         intptr_t id)
      : isolate_group_(isolate_group),
        monitor_(monitor),
        done_(done),
        id_(id) {}
  virtual void Run() {
    const bool kBypassSafepoint = false;
    Thread::EnterIsolateGroupAsHelper(isolate_group_, Thread::kUnknownTask,
                                      kBypassSafepoint);
    {
      Thread* thread = Thread::Current();
      // Create a zone (which is also a stack resource) and exercise it a bit.
      StackZone stack_zone(thread);
      Zone* zone = thread->zone();
      EXPECT_EQ(zone, stack_zone.GetZone());
      ZoneGrowableArray<bool>* a0 = new (zone) ZoneGrowableArray<bool>(zone, 1);
      GrowableArray<bool> a1(zone, 1);
      for (intptr_t i = 0; i < 100000; ++i) {
        a0->Add(true);
        a1.Add(true);
      }
      // Check that we can create handles and allocate in old space.
      String& str = String::Handle(zone, String::New("old", Heap::kOld));
      EXPECT(str.Equals("old"));

      const intptr_t unique_smi = id_ + 928327281;
      Smi& smi = Smi::Handle(zone, Smi::New(unique_smi));
      EXPECT(smi.Value() == unique_smi);
      {
        HeapIterationScope iteration(thread);
        ObjectCounter counter(isolate_group_, &smi);
        // Ensure that our particular zone is visited.
        iteration.IterateStackPointers(&counter,
                                       ValidationPolicy::kValidateFrames);
        EXPECT_EQ(1, counter.count());
      }
      char* unique_chars = zone->PrintToString("unique_str_%" Pd, id_);
      String& unique_str = String::Handle(zone);
      {
        // String::New may create additional handles in the topmost scope that
        // we don't want to count, so wrap this in its own scope.
        HANDLESCOPE(thread);
        unique_str = String::New(unique_chars, Heap::kOld);
      }
      EXPECT(unique_str.Equals(unique_chars));
      {
        HeapIterationScope iteration(thread);
        ObjectCounter str_counter(isolate_group_, &unique_str);
        // Ensure that our particular zone is visited.
        iteration.IterateStackPointers(&str_counter,
                                       ValidationPolicy::kValidateFrames);
        // We should visit the string object exactly once.
        EXPECT_EQ(1, str_counter.count());
      }
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
  intptr_t id_;
};

ISOLATE_UNIT_TEST_CASE(ManyTasksWithZones) {
  const int kTaskCount = 100;
  Monitor sync[kTaskCount];
  bool done[kTaskCount];
  auto isolate = thread->isolate();
  auto isolate_group = thread->isolate_group();
  for (int i = 0; i < kTaskCount; i++) {
    done[i] = false;
    Dart::thread_pool()->Run<TaskWithZoneAllocation>(isolate_group, &sync[i],
                                                     &done[i], i);
  }
  bool in_isolate = true;
  for (int i = 0; i < kTaskCount; i++) {
    // Check that main mutator thread can still freely use its own zone.
    String& bar = String::Handle(String::New("bar"));
    if (i % 10 == 0) {
      // Mutator thread is free to independently move in/out/between isolates.
      Thread::ExitIsolate();
      in_isolate = false;
    }
    MonitorLocker ml(&sync[i]);
    while (!done[i]) {
      if (in_isolate) {
        ml.WaitWithSafepointCheck(thread);
      } else {
        ml.Wait();
      }
    }
    EXPECT(done[i]);
    if (i % 10 == 0) {
      Thread::EnterIsolate(isolate);
      in_isolate = true;
    }
    EXPECT(bar.Equals("bar"));
  }
}

#ifndef PRODUCT
class SimpleTaskWithZoneAllocation : public ThreadPool::Task {
 public:
  SimpleTaskWithZoneAllocation(intptr_t id,
                               IsolateGroup* isolate_group,
                               Thread** thread_ptr,
                               Monitor* sync,
                               Monitor* monitor,
                               intptr_t* done_count,
                               bool* wait)
      : id_(id),
        isolate_group_(isolate_group),
        thread_ptr_(thread_ptr),
        sync_(sync),
        monitor_(monitor),
        done_count_(done_count),
        wait_(wait) {}

  virtual void Run() {
    const bool kBypassSafepoint = false;
    Thread::EnterIsolateGroupAsHelper(isolate_group_, Thread::kUnknownTask,
                                      kBypassSafepoint);
    {
      Thread* thread = Thread::Current();
      *thread_ptr_ = thread;
      CreateStackZones(id_);
    }
    Thread::ExitIsolateGroupAsHelper(kBypassSafepoint);
    // Notify the main thread that this thread has exited.
    {
      MonitorLocker ml(monitor_);
      *done_count_ += 1;
      ml.Notify();
    }
  }

 private:
  void CreateStackZones(intptr_t num) {
    Thread* thread = Thread::Current();
    *thread_ptr_ = thread;

    StackZone stack_zone(thread);
    Zone* zone = thread->zone();
    EXPECT_EQ(zone, stack_zone.GetZone());

    // Create a zone (which is also a stack resource) and exercise it a bit.
    ZoneGrowableArray<bool>* a0 = new (zone) ZoneGrowableArray<bool>(zone, 1);
    GrowableArray<bool> a1(zone, 1);
    for (intptr_t i = 0; i < 1000 * num + id_; ++i) {
      a0->Add(true);
      a1.Add(true);
    }

    num -= 1;
    if (num != 0) {
      CreateStackZones(num);
      return;
    }
    {
      // Let the main thread know we're done with memory ops on this thread.
      MonitorLocker ml(monitor_);
      *done_count_ += 1;
      ml.Notify();
    }
    // Wait for the go-ahead from the main thread to exit.
    {
      MonitorLocker sync_ml(sync_);
      while (*wait_) {
        sync_ml.Wait();
      }
    }
  }

  intptr_t id_;
  IsolateGroup* isolate_group_;
  Thread** thread_ptr_;
  Monitor* sync_;
  Monitor* monitor_;
  intptr_t* done_count_;
  bool* wait_;
};

ISOLATE_UNIT_TEST_CASE(ManySimpleTasksWithZones) {
  const int kTaskCount = 10;
  Monitor monitor;
  Monitor sync;
  Thread* threads[kTaskCount];
  auto isolate_group = thread->isolate_group();
  intptr_t done_count = 0;
  bool wait = true;

  EXPECT(!thread->force_growth());

  ForceGrowthScope no_heap_growth_scope(thread);

  for (intptr_t i = 0; i < kTaskCount; i++) {
    Dart::thread_pool()->Run<SimpleTaskWithZoneAllocation>(
        (i + 1), isolate_group, &threads[i], &sync, &monitor, &done_count,
        &wait);
  }
  // Wait until all spawned tasks finish their memory operations.
  {
    MonitorLocker ml(&monitor);
    while (done_count < kTaskCount) {
      ml.Wait();
    }
    // Reset the done counter for use later.
    done_count = 0;
  }

  // Unblock the tasks so they can finish.
  {
    MonitorLocker sync_ml(&sync);
    wait = false;
    sync_ml.NotifyAll();
  }
  // Now wait for them all to exit before destroying the isolate.
  {
    MonitorLocker ml(&monitor);
    while (done_count < kTaskCount) {
      ml.Wait();
    }
  }
}
#endif

TEST_CASE(ThreadRegistry) {
  Isolate* orig = Thread::Current()->isolate();
  Zone* orig_zone = Thread::Current()->zone();
  char* orig_str = orig_zone->PrintToString("foo");
  Dart_ExitIsolate();
  // Create and enter a new isolate.
  TestCase::CreateTestIsolate();
  Zone* zone0 = Thread::Current()->zone();
  EXPECT(zone0 != orig_zone);
  Dart_ShutdownIsolate();
  // Create and enter yet another isolate.
  TestCase::CreateTestIsolate();
  {
    // Create a stack resource this time, and exercise it.
    TransitionNativeToVM transition(Thread::Current());
    StackZone stack_zone(Thread::Current());
    Zone* zone1 = Thread::Current()->zone();
    EXPECT(zone1 != zone0);
    EXPECT(zone1 != orig_zone);
  }
  Dart_ShutdownIsolate();
  Dart_EnterIsolate(reinterpret_cast<Dart_Isolate>(orig));
  // Original zone should be preserved.
  EXPECT_EQ(orig_zone, Thread::Current()->zone());
  EXPECT_STREQ("foo", orig_str);
}

// A helper thread that repeatedly reads ICData
class ICDataTestTask : public ThreadPool::Task {
 public:
  static constexpr intptr_t kTaskCount = 1;

  ICDataTestTask(IsolateGroup* isolate_group,
                 const Array& ic_datas,
                 Monitor* monitor,
                 intptr_t* exited,
                 std::atomic<bool>* done)
      : isolate_group_(isolate_group),
        ic_datas_(ic_datas),
        len_(ic_datas.Length()),
        monitor_(monitor),
        exited_(exited),
        done_(done) {}

  virtual void Run() {
    const bool kBypassSafepoint = false;
    Thread::EnterIsolateGroupAsHelper(isolate_group_, Thread::kUnknownTask,
                                      kBypassSafepoint);

    Thread* thread = Thread::Current();

    {
      StackZone stack_zone(thread);

      ICData& ic_data = ICData::Handle();
      Array& arr = Array::Handle();
      while (true) {
        for (intptr_t cnt = 0; cnt < 0x1000; cnt++) {
          for (intptr_t i = 0; i < len_; i++) {
            ic_data ^= ic_datas_.AtAcquire(i);
            arr = ic_data.entries();
            intptr_t num_checks = arr.Length() / 3;
            if (num_checks < 0 || num_checks > 5) {
              OS::PrintErr("Failure: %" Pd " checks!\n", num_checks);
              abort();
            }
          }
        }

        if (done_->load(std::memory_order_acquire)) {
          break;
        }

        TransitionVMToBlocked blocked(thread);
      }
    }

    Thread::ExitIsolateGroupAsHelper(kBypassSafepoint);
    {
      MonitorLocker ml(monitor_);
      ++*exited_;
      ml.Notify();
    }
  }

 private:
  IsolateGroup* isolate_group_;
  const Array& ic_datas_;
  const intptr_t len_;
  Monitor* monitor_;
  intptr_t* exited_;         // # tasks that are no longer running.
  std::atomic<bool>* done_;  // Signal that helper threads can stop working.
};

static Function* CreateFunction(const char* name) {
  const String& class_name =
      String::Handle(Symbols::New(Thread::Current(), "ownerClass"));
  const Script& script = Script::Handle();
  const Library& lib = Library::Handle(Library::New(class_name));
  const Class& owner_class = Class::Handle(
      Class::New(lib, class_name, script, TokenPosition::kNoSource));
  const String& function_name =
      String::ZoneHandle(Symbols::New(Thread::Current(), name));
  const FunctionType& signature = FunctionType::ZoneHandle(FunctionType::New());
  Function& function = Function::ZoneHandle(Function::New(
      signature, function_name, UntaggedFunction::kRegularFunction, true, false,
      false, false, false, owner_class, TokenPosition::kNoSource));
  return &function;
}

// Test that checks that other threads only see a fully initialized ICData
// whenever ICData is updated.
ISOLATE_UNIT_TEST_CASE(ICDataTest) {
  auto isolate_group = thread->isolate_group();
  USE(isolate_group);
  Monitor monitor;
  intptr_t exited = 0;
  std::atomic<bool> done = {false};

  const intptr_t kNumICData = 0x10;

  const Array& ic_datas = Array::Handle(Array::New(kNumICData));
  ICData& ic_data = ICData::Handle();
  Function& owner = *CreateFunction("DummyFunction");
  String& name = String::Handle(Symbols::New(thread, "foo"));
  const Array& args_desc =
      Array::Handle(ArgumentsDescriptor::NewBoxed(0, 0, Object::empty_array()));
  for (intptr_t i = 0; i < kNumICData; i++) {
    ic_data = ICData::New(owner, name, args_desc, /*deopt_id=*/0,
                          /*num_args_tested=*/1, ICData::kInstance,
                          Object::null_abstract_type());
    ic_datas.SetAtRelease(i, ic_data);
  }

  for (int i = 0; i < ICDataTestTask::kTaskCount; i++) {
    Dart::thread_pool()->Run<ICDataTestTask>(isolate_group, ic_datas, &monitor,
                                             &exited, &done);
  }

  for (int i = 0; i < 0x10000; i++) {
    for (intptr_t i = 0; i < kNumICData; i++) {
      ic_data ^= ic_datas.At(i);
      if (ic_data.NumberOfChecks() < 4) {
        ic_data.AddReceiverCheck(kInstanceCid + ic_data.NumberOfChecks(), owner,
                                 1);
      } else {
        ic_data = ICData::New(owner, name, args_desc, /*deopt_id=*/0,
                              /*num_args_tested=*/1, ICData::kInstance,
                              Object::null_abstract_type());
        ic_datas.SetAtRelease(i, ic_data);
      }
    }
  }
  // Ensure we looped long enough to allow all helpers to succeed and exit.
  {
    done.store(true, std::memory_order_release);
    MonitorLocker ml(&monitor);
    while (exited != ICDataTestTask::kTaskCount) {
      ml.Wait();
    }
    EXPECT_EQ(ICDataTestTask::kTaskCount, exited);
  }
}

// A helper thread that alternatingly cooperates and organizes
// safepoint rendezvous. At rendezvous, it explicitly visits the
// stacks looking for a specific marker (Smi) to verify that the expected
// number threads are actually visited. The task is "done" when it has
// successfully made all other tasks and the main thread rendezvous (may
// not happen in the first rendezvous, since tasks are still starting up).
class SafepointTestTask : public ThreadPool::Task {
 public:
  static constexpr intptr_t kTaskCount = 5;

  SafepointTestTask(Isolate* isolate,
                    Monitor* monitor,
                    intptr_t* expected_count,
                    intptr_t* total_done,
                    intptr_t* exited)
      : isolate_(isolate),
        monitor_(monitor),
        expected_count_(expected_count),
        total_done_(total_done),
        exited_(exited),
        local_done_(false) {}

  virtual void Run() {
    const bool kBypassSafepoint = false;
    Thread::EnterIsolateGroupAsHelper(isolate_->group(), Thread::kUnknownTask,
                                      kBypassSafepoint);
    {
      MonitorLocker ml(monitor_);
      ++*expected_count_;
    }
    Thread* thread = Thread::Current();
    for (int i = reinterpret_cast<intptr_t>(thread);; ++i) {
      StackZone stack_zone(thread);
      Zone* zone = thread->zone();
      const intptr_t kUniqueSmi = 928327281;
      Smi& smi = Smi::Handle(zone, Smi::New(kUniqueSmi));
      if ((i % 100) != 0) {
        // Usually, we just cooperate.
        TransitionVMToBlocked transition(thread);
      } else {
        // But occasionally, organize a rendezvous.
        HeapIterationScope iteration(thread);  // Establishes a safepoint.
        ASSERT(thread->OwnsSafepoint());
        ObjectCounter counter(isolate_->group(), &smi);
        iteration.IterateStackPointers(&counter,
                                       ValidationPolicy::kValidateFrames);
        {
          MonitorLocker ml(monitor_);
          EXPECT_EQ(*expected_count_, counter.count());
        }
        UserTag& tag = UserTag::Handle(zone, isolate_->current_tag());
        if (tag.ptr() != isolate_->default_tag()) {
          String& label = String::Handle(zone, tag.label());
          EXPECT(label.Equals("foo"));
          MonitorLocker ml(monitor_);
          if (*expected_count_ == kTaskCount && !local_done_) {
            // Success for the first time! Remember that we are done, and
            // update the total count.
            local_done_ = true;
            ++*total_done_;
          }
        }
      }
      // Check whether everyone is done.
      {
        MonitorLocker ml(monitor_);
        if (*total_done_ == kTaskCount) {
          // Another task might be at SafepointThreads when resuming. Ensure its
          // expectation reflects reality, since we pop our handles here.
          --*expected_count_;
          break;
        }
      }
    }
    Thread::ExitIsolateGroupAsHelper(kBypassSafepoint);
    {
      MonitorLocker ml(monitor_);
      ++*exited_;
      ml.Notify();
    }
  }

 private:
  Isolate* isolate_;
  Monitor* monitor_;
  intptr_t* expected_count_;  // # copies of kUniqueSmi we expect to visit.
  intptr_t* total_done_;      // # tasks that successfully safepointed once.
  intptr_t* exited_;          // # tasks that are no longer running.
  bool local_done_;           // this task has successfully safepointed >= once.
};

// Test rendezvous of:
// - helpers in VM code,
// - main thread in pure Dart,
// organized by
// - helpers.
TEST_CASE(SafepointTestDart) {
  Isolate* isolate = Thread::Current()->isolate();
  Monitor monitor;
  intptr_t expected_count = 0;
  intptr_t total_done = 0;
  intptr_t exited = 0;
  for (int i = 0; i < SafepointTestTask::kTaskCount; i++) {
    Dart::thread_pool()->Run<SafepointTestTask>(
        isolate, &monitor, &expected_count, &total_done, &exited);
  }
// Run Dart code on the main thread long enough to allow all helpers
// to get their verification done and exit. Use a specific UserTag
// to enable the helpers to verify that the main thread is
// successfully interrupted in the pure Dart loop.
#if defined(DART_INCLUDE_SIMULATOR)
  const intptr_t kLoopCount = 12345678;
#else
  const intptr_t kLoopCount = 1234567890;
#endif  // defined(DART_INCLUDE_SIMULATOR)
  char buffer[1024];
  Utils::SNPrint(buffer, sizeof(buffer),
                 "import 'dart:developer';\n"
                 "int dummy = 0;\n"
                 "main() {\n"
                 "  new UserTag('foo').makeCurrent();\n"
                 "  for (dummy = 0; dummy < %" Pd
                 "; ++dummy) {\n"
                 "    dummy += (dummy & 1);\n"
                 "  }\n"
                 "}\n",
                 kLoopCount);
  Dart_Handle lib = TestCase::LoadTestScript(buffer, nullptr);
  EXPECT_VALID(lib);
  Dart_Handle result = Dart_Invoke(lib, NewString("main"), 0, nullptr);
  EXPECT_VALID(result);
  // Ensure we looped long enough to allow all helpers to succeed and exit.
  {
    MonitorLocker ml(&monitor);
    while (exited != SafepointTestTask::kTaskCount) {
      ml.Wait();
    }
    EXPECT_EQ(SafepointTestTask::kTaskCount, total_done);
    EXPECT_EQ(SafepointTestTask::kTaskCount, exited);
  }
}

// Test rendezvous of:
// - helpers in VM code, and
// - main thread in VM code,
// organized by
// - helpers.
ISOLATE_UNIT_TEST_CASE(SafepointTestVM) {
  Isolate* isolate = thread->isolate();
  Monitor monitor;
  intptr_t expected_count = 0;
  intptr_t total_done = 0;
  intptr_t exited = 0;
  for (int i = 0; i < SafepointTestTask::kTaskCount; i++) {
    Dart::thread_pool()->Run<SafepointTestTask>(
        isolate, &monitor, &expected_count, &total_done, &exited);
  }
  String& label = String::Handle(String::New("foo"));
  UserTag& tag = UserTag::Handle(UserTag::New(label));
  isolate->set_current_tag(tag);
  MonitorLocker ml(&monitor);
  while (exited != SafepointTestTask::kTaskCount) {
    ml.WaitWithSafepointCheck(thread);
  }
}

// Test case for recursive safepoint operations.
ISOLATE_UNIT_TEST_CASE(RecursiveSafepointTest1) {
  intptr_t count = 0;
  {
    GcSafepointOperationScope safepoint_scope(thread);
    count += 1;
    {
      GcSafepointOperationScope safepoint_scope(thread);
      count += 1;
      {
        GcSafepointOperationScope safepoint_scope(thread);
        count += 1;
      }
    }
  }
  EXPECT(count == 3);
}

ISOLATE_UNIT_TEST_CASE(ThreadIterator_Count) {
  intptr_t thread_count_0 = 0;
  intptr_t thread_count_1 = 0;

  {
    OSThreadIterator ti;
    while (ti.HasNext()) {
      OSThread* thread = ti.Next();
      EXPECT(thread != nullptr);
      thread_count_0++;
    }
  }

  {
    OSThreadIterator ti;
    while (ti.HasNext()) {
      OSThread* thread = ti.Next();
      EXPECT(thread != nullptr);
      thread_count_1++;
    }
  }

  EXPECT(thread_count_0 > 0);
  EXPECT(thread_count_1 > 0);
  EXPECT(thread_count_0 >= thread_count_1);
}

ISOLATE_UNIT_TEST_CASE(ThreadIterator_FindSelf) {
  OSThread* current = OSThread::Current();
  EXPECT(OSThread::IsThreadInList(current->id()));
}

struct ThreadIteratorTestParams {
  ThreadId spawned_thread_id;
  ThreadJoinId spawned_thread_join_id;
  Monitor* monitor;
};

void ThreadIteratorTestMain(uword parameter) {
  ThreadIteratorTestParams* params =
      reinterpret_cast<ThreadIteratorTestParams*>(parameter);
  OSThread* thread = OSThread::Current();
  EXPECT(thread != nullptr);

  MonitorLocker ml(params->monitor);
  params->spawned_thread_id = thread->id();
  params->spawned_thread_join_id = OSThread::GetCurrentThreadJoinId(thread);
  EXPECT(params->spawned_thread_id != OSThread::kInvalidThreadId);
  EXPECT(OSThread::IsThreadInList(thread->id()));
  ml.Notify();
}

// NOTE: This test case also verifies that known TLS destructors are called
// on Windows. See |OnDartThreadExit| in os_thread_win.cc for more details.
TEST_CASE(ThreadIterator_AddFindRemove) {
  ThreadIteratorTestParams params;
  params.spawned_thread_id = OSThread::kInvalidThreadId;
  params.monitor = new Monitor();

  {
    MonitorLocker ml(params.monitor);
    EXPECT(params.spawned_thread_id == OSThread::kInvalidThreadId);
    // Spawn thread and wait to receive the thread id.
    OSThread::Start("ThreadIteratorTest", ThreadIteratorTestMain,
                    reinterpret_cast<uword>(&params));
    while (params.spawned_thread_id == OSThread::kInvalidThreadId) {
      ml.Wait();
    }
    EXPECT(params.spawned_thread_id != OSThread::kInvalidThreadId);
    EXPECT(params.spawned_thread_join_id != OSThread::kInvalidThreadJoinId);
    OSThread::Join(params.spawned_thread_join_id);
  }

  EXPECT(!OSThread::IsThreadInList(params.spawned_thread_id))

  delete params.monitor;
}

// Test rendezvous of:
// - helpers in VM code, and
// - main thread in VM code,
// organized by
// - main thread, and
// - helpers.
ISOLATE_UNIT_TEST_CASE(SafepointTestVM2) {
  Isolate* isolate = thread->isolate();
  Monitor monitor;
  intptr_t expected_count = 0;
  intptr_t total_done = 0;
  intptr_t exited = 0;
  for (int i = 0; i < SafepointTestTask::kTaskCount; i++) {
    Dart::thread_pool()->Run<SafepointTestTask>(
        isolate, &monitor, &expected_count, &total_done, &exited);
  }
  bool all_helpers = false;
  do {
    GcSafepointOperationScope safepoint_scope(thread);
    {
      MonitorLocker ml(&monitor);
      if (expected_count == SafepointTestTask::kTaskCount) {
        all_helpers = true;
      }
    }
  } while (!all_helpers);
  String& label = String::Handle(String::New("foo"));
  UserTag& tag = UserTag::Handle(UserTag::New(label));
  isolate->set_current_tag(tag);
  MonitorLocker ml(&monitor);
  while (exited != SafepointTestTask::kTaskCount) {
    ml.WaitWithSafepointCheck(thread);
  }
}

// Test recursive safepoint operation scopes with other threads trying
// to also start a safepoint operation scope.
ISOLATE_UNIT_TEST_CASE(RecursiveSafepointTest2) {
  Isolate* isolate = thread->isolate();
  Monitor monitor;
  intptr_t expected_count = 0;
  intptr_t total_done = 0;
  intptr_t exited = 0;
  for (int i = 0; i < SafepointTestTask::kTaskCount; i++) {
    Dart::thread_pool()->Run<SafepointTestTask>(
        isolate, &monitor, &expected_count, &total_done, &exited);
  }
  bool all_helpers = false;
  do {
    GcSafepointOperationScope safepoint_scope(thread);
    {
      GcSafepointOperationScope safepoint_scope(thread);
      MonitorLocker ml(&monitor);
      if (expected_count == SafepointTestTask::kTaskCount) {
        all_helpers = true;
      }
    }
  } while (!all_helpers);
  String& label = String::Handle(String::New("foo"));
  UserTag& tag = UserTag::Handle(UserTag::New(label));
  isolate->set_current_tag(tag);
  bool all_exited = false;
  do {
    GcSafepointOperationScope safepoint_scope(thread);
    {
      GcSafepointOperationScope safepoint_scope(thread);
      MonitorLocker ml(&monitor);
      if (exited == SafepointTestTask::kTaskCount) {
        all_exited = true;
      }
    }
  } while (!all_exited);
}

class AllocAndGCTask : public ThreadPool::Task {
 public:
  AllocAndGCTask(IsolateGroup* isolate_group, Monitor* done_monitor, bool* done)
      : isolate_group_(isolate_group),
        done_monitor_(done_monitor),
        done_(done) {}

  virtual void Run() {
    const bool kBypassSafepoint = false;
    Thread::EnterIsolateGroupAsHelper(isolate_group_, Thread::kUnknownTask,
                                      kBypassSafepoint);
    {
      Thread* thread = Thread::Current();
      StackZone stack_zone(thread);
      Zone* zone = stack_zone.GetZone();
      String& old_str = String::Handle(zone, String::New("old", Heap::kOld));
      isolate_group_->heap()->CollectAllGarbage();
      EXPECT(old_str.Equals("old"));
    }
    Thread::ExitIsolateGroupAsHelper(kBypassSafepoint);
    // Tell main thread that we are ready.
    {
      MonitorLocker ml(done_monitor_);
      ASSERT(!*done_);
      *done_ = true;
      ml.Notify();
    }
  }

 private:
  IsolateGroup* isolate_group_;
  Monitor* done_monitor_;
  bool* done_;
};

ISOLATE_UNIT_TEST_CASE(HelperAllocAndGC) {
  Monitor done_monitor;
  bool done = false;
  auto isolate_group = thread->isolate_group();
  Dart::thread_pool()->Run<AllocAndGCTask>(isolate_group, &done_monitor, &done);
  {
    while (true) {
      TransitionVMToBlocked transition(thread);
      MonitorLocker ml(&done_monitor);
      if (done) {
        break;
      }
    }
  }
}

class AllocateGlobsOfMemoryTask : public ThreadPool::Task {
 public:
  AllocateGlobsOfMemoryTask(IsolateGroup* isolate_group,
                            Monitor* done_monitor,
                            bool* done)
      : isolate_group_(isolate_group),
        done_monitor_(done_monitor),
        done_(done) {}

  virtual void Run() {
    const bool kBypassSafepoint = false;
    Thread::EnterIsolateGroupAsHelper(isolate_group_, Thread::kUnknownTask,
                                      kBypassSafepoint);
    {
      Thread* thread = Thread::Current();
      StackZone stack_zone(thread);
      Zone* zone = stack_zone.GetZone();
      int count = 100 * 1000;
      while (count-- > 0) {
        String::Handle(zone, String::New("abc"));
      }
    }
    Thread::ExitIsolateGroupAsHelper(kBypassSafepoint);
    // Tell main thread that we are ready.
    {
      MonitorLocker ml(done_monitor_);
      ASSERT(!*done_);
      *done_ = true;
      ml.Notify();
    }
  }

 private:
  IsolateGroup* isolate_group_;
  Monitor* done_monitor_;
  bool* done_;
};

ISOLATE_UNIT_TEST_CASE(ExerciseTLABs) {
  const int NUMBER_TEST_THREADS = 10;
  Monitor done_monitor[NUMBER_TEST_THREADS];
  bool done[NUMBER_TEST_THREADS];
  auto isolate_group = thread->isolate_group();
  for (int i = 0; i < NUMBER_TEST_THREADS; i++) {
    done[i] = false;
    Dart::thread_pool()->Run<AllocateGlobsOfMemoryTask>(
        isolate_group, &done_monitor[i], &done[i]);
  }

  for (int i = 0; i < NUMBER_TEST_THREADS; i++) {
    MonitorLocker ml(&done_monitor[i]);
    while (!done[i]) {
      ml.WaitWithSafepointCheck(thread);
    }
  }
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockWithReadLock) {
  SafepointRwLock lock;
  SafepointReadRwLocker locker(Thread::Current(), &lock);
  DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
  EXPECT(!lock.IsCurrentThreadWriter());
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockWithWriteLock) {
  SafepointRwLock lock;
  SafepointWriteRwLocker locker(Thread::Current(), &lock);
  DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
  EXPECT(lock.IsCurrentThreadWriter());
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockWithoutAnyLocks) {
  SafepointRwLock lock;
  DEBUG_ONLY(EXPECT(!lock.IsCurrentThreadReader()));
  EXPECT(!lock.IsCurrentThreadWriter());
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockReentrantReadLock) {
  SafepointRwLock lock;
  {
    SafepointReadRwLocker locker(Thread::Current(), &lock);
    {
      SafepointReadRwLocker locker1(Thread::Current(), &lock);
      DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
      EXPECT(!lock.IsCurrentThreadWriter());
    }
    DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
    EXPECT(!lock.IsCurrentThreadWriter());
  }
  DEBUG_ONLY(EXPECT(!lock.IsCurrentThreadReader()));
  EXPECT(!lock.IsCurrentThreadWriter());
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockReentrantWriteLock) {
  SafepointRwLock lock;
  {
    SafepointWriteRwLocker locker(Thread::Current(), &lock);
    {
      SafepointWriteRwLocker locker1(Thread::Current(), &lock);
      DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
      EXPECT(lock.IsCurrentThreadWriter());
    }
    DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
    EXPECT(lock.IsCurrentThreadWriter());
  }
  DEBUG_ONLY(EXPECT(!lock.IsCurrentThreadReader()));
  EXPECT(!lock.IsCurrentThreadWriter());
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockWriteToReadLock) {
  SafepointRwLock lock;
  {
    SafepointWriteRwLocker locker(Thread::Current(), &lock);
    {
      SafepointReadRwLocker locker1(Thread::Current(), &lock);
      DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
      EXPECT(lock.IsCurrentThreadWriter());
    }
    DEBUG_ONLY(EXPECT(lock.IsCurrentThreadReader()));
    EXPECT(lock.IsCurrentThreadWriter());
  }
  DEBUG_ONLY(EXPECT(!lock.IsCurrentThreadReader()));
  EXPECT(!lock.IsCurrentThreadWriter());
}

template <typename LockType, typename LockerType>
static void RunLockerWithLongJumpTest() {
  const intptr_t kNumIterations = 5;
  volatile intptr_t execution_count = 0;
  volatile intptr_t thrown_count = 0;
  LockType lock;
  for (intptr_t i = 0; i < kNumIterations; ++i) {
    LongJumpScope jump;
    if (DART_SETJMP(*jump.Set()) == 0) {
      LockerType locker(Thread::Current(), &lock);
      execution_count = execution_count + 1;
      Thread::Current()->long_jump_base()->Jump(
          1, Object::background_compilation_error());
    } else {
      ASSERT(Thread::Current()->StealStickyError() ==
             Object::background_compilation_error().ptr());
      thrown_count = thrown_count + 1;
    }
  }
  EXPECT_EQ(kNumIterations, execution_count);
  EXPECT_EQ(kNumIterations, thrown_count);
}
ISOLATE_UNIT_TEST_CASE(SafepointRwLockWriteWithLongJmp) {
  RunLockerWithLongJumpTest<SafepointRwLock, SafepointWriteRwLocker>();
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockReadWithLongJmp) {
  RunLockerWithLongJumpTest<SafepointRwLock, SafepointReadRwLocker>();
}

ISOLATE_UNIT_TEST_CASE(SafepointMutexLockerWithLongJmp) {
  RunLockerWithLongJumpTest<Mutex, SafepointMutexLocker>();
}

struct ReaderThreadState {
  ThreadJoinId reader_id = OSThread::kInvalidThreadJoinId;
  SafepointRwLock* rw_lock = nullptr;
  IsolateGroup* isolate_group = nullptr;
  Monitor* monitor = nullptr;
  bool child_started = false;
  intptr_t value = -1;
  intptr_t observed_value = -1;
};

void Helper(uword arg) {
  auto state = reinterpret_cast<ReaderThreadState*>(arg);
  state->reader_id = OSThread::GetCurrentThreadJoinId(OSThread::Current());
  // Notify other thread.
  {
    MonitorLocker ml(state->monitor);
    state->child_started = true;
    ml.Notify();
  }
  const bool kBypassSafepoint = false;
  Thread::EnterIsolateGroupAsHelper(state->isolate_group, Thread::kUnknownTask,
                                    kBypassSafepoint);
  {
    auto thread = Thread::Current();
    intptr_t observed_value = -1;
    {
      SafepointReadRwLocker reader(thread, state->rw_lock);
      observed_value = state->value;
    }
    state->observed_value = observed_value;
  }
  Thread::ExitIsolateGroupAsHelper(kBypassSafepoint);
}

ISOLATE_UNIT_TEST_CASE(SafepointRwLockExclusiveNestedWriter_Regress44000) {
  auto isolate_group = IsolateGroup::Current();

  SafepointRwLock lock;
  ReaderThreadState state;
  state.rw_lock = &lock;
  state.isolate_group = isolate_group;
  state.value = 0;
  state.child_started = false;
  state.monitor = new Monitor();
  {
    // Hold one writer lock.
    SafepointWriteRwLocker locker(Thread::Current(), &lock);
    {
      // Hold another, nested, writer lock.
      SafepointWriteRwLocker locker2(Thread::Current(), &lock);

      // Start a thread, it will try to acquire read lock but it will have to
      // wait until we have exited both writer scopes.
      OSThread::Start("DartWorker", &Helper, reinterpret_cast<uword>(&state));
      // Wait for the thread to start.
      {
        MonitorLocker ml(state.monitor);
        while (!state.child_started) {
          ml.Wait();
        }
      }
      state.value = 1;
    }
    state.value = 2;
  }
  // Join the other thread.
  OSThread::Join(state.reader_id);

  // Ensure the reader thread had to wait before it entered the
  // SafepointWriteRwLocker scope.
  EXPECT(state.observed_value == 2);

  delete state.monitor;
}

ISOLATE_UNIT_TEST_CASE(SafepointMonitorUnlockScope) {
  // This test uses ASSERT instead of EXPECT because IsOwnedByCurrentThread is
  // only available in debug mode. Since our vm/cc tests run in DEBUG mode that
  // is sufficient for this test.
  Monitor monitor;
  {
    SafepointMonitorLocker ml(&monitor);
    ASSERT(monitor.IsOwnedByCurrentThread());
    {
      SafepointMonitorUnlockScope ml_unlocker(&ml);
      ASSERT(!monitor.IsOwnedByCurrentThread());
      {
        SafepointMonitorLocker inner_ml(&monitor);
        ASSERT(monitor.IsOwnedByCurrentThread());
      }
    }
  }
}

ISOLATE_UNIT_TEST_CASE(ReentrantMonitorAllowsReentrance) {
  ReentrantMonitor monitor;
  {
    SafepointLocker<ReentrantMonitor> ml1(&monitor);
    ASSERT(monitor.IsOwnedByCurrentThread());
    {
      SafepointLocker<ReentrantMonitor> ml2(&monitor);
      ASSERT(monitor.IsOwnedByCurrentThread());
    }
    ASSERT(monitor.IsOwnedByCurrentThread());
  }
}

}  // namespace dart
