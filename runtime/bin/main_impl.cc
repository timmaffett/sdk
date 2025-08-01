// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "bin/main_impl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cerrno>
#include <memory>
#include <utility>

#include "bin/builtin.h"
#include "bin/console.h"
#include "bin/crashpad.h"
#include "bin/dartutils.h"
#include "bin/dfe.h"
#include "bin/error_exit.h"
#include "bin/exe_utils.h"
#include "bin/file.h"
#include "bin/gzip.h"
#include "bin/icu.h"
#include "bin/isolate_data.h"
#include "bin/loader.h"
#include "bin/main_options.h"
#include "bin/platform.h"
#include "bin/process.h"
#include "bin/snapshot_utils.h"
#include "bin/utils.h"
#include "bin/vmservice_impl.h"
#include "include/bin/dart_io_api.h"
#include "include/bin/native_assets_api.h"
#include "include/dart_api.h"
#include "include/dart_embedder_api.h"
#include "include/dart_tools_api.h"
#include "platform/assert.h"
#include "platform/globals.h"
#include "platform/syslog.h"
#include "platform/utils.h"

extern "C" {
extern const uint8_t kDartVmSnapshotData[];
extern const uint8_t kDartVmSnapshotInstructions[];
extern const uint8_t kDartCoreIsolateSnapshotData[];
extern const uint8_t kDartCoreIsolateSnapshotInstructions[];
}

namespace dart {
namespace bin {

// Snapshot pieces we link in a snapshot.
const uint8_t* vm_snapshot_data = kDartVmSnapshotData;
const uint8_t* vm_snapshot_instructions = kDartVmSnapshotInstructions;
const uint8_t* core_isolate_snapshot_data = kDartCoreIsolateSnapshotData;
const uint8_t* core_isolate_snapshot_instructions =
    kDartCoreIsolateSnapshotInstructions;

/**
 * Global state used to control and store generation of application snapshots.
 * An application snapshot can be generated and run using the following
 * command
 *   dart --snapshot-kind=app-jit --snapshot=<app_snapshot_filename>
 *       <script_uri> [<script_options>]
 * To Run the application snapshot generated above, use :
 *   dart <app_snapshot_filename> [<script_options>]
 */
static bool vm_run_app_snapshot = false;
static char* app_script_uri = nullptr;
static const uint8_t* app_isolate_snapshot_data = nullptr;
static const uint8_t* app_isolate_snapshot_instructions = nullptr;
static bool kernel_isolate_is_running = false;

static Dart_Isolate main_isolate = nullptr;

#define SAVE_ERROR_AND_EXIT(result)                                            \
  *error = Utils::StrDup(Dart_GetError(result));                               \
  if (Dart_IsCompilationError(result)) {                                       \
    *exit_code = kCompilationErrorExitCode;                                    \
  } else if (Dart_IsApiError(result)) {                                        \
    *exit_code = kApiErrorExitCode;                                            \
  } else {                                                                     \
    *exit_code = kErrorExitCode;                                               \
  }                                                                            \
  Dart_ExitScope();                                                            \
  Dart_ShutdownIsolate();                                                      \
  return nullptr;

#define CHECK_RESULT(result)                                                   \
  if (Dart_IsError(result)) {                                                  \
    SAVE_ERROR_AND_EXIT(result);                                               \
  }

#define CHECK_RESULT_CLEANUP(result, cleanup)                                  \
  if (Dart_IsError(result)) {                                                  \
    delete (cleanup);                                                          \
    SAVE_ERROR_AND_EXIT(result);                                               \
  }

static void WriteDepsFile() {
  if (Options::depfile() == nullptr) {
    return;
  }
  File* file = File::Open(nullptr, Options::depfile(), File::kWriteTruncate);
  if (file == nullptr) {
    ErrorExit(kErrorExitCode, "Error: Unable to open snapshot depfile: %s\n\n",
              Options::depfile());
  }
  bool success = true;
  if (Options::depfile_output_filename() != nullptr) {
    success &= file->Print("%s: ", Options::depfile_output_filename());
  } else {
    success &= file->Print("%s: ", Options::snapshot_filename());
  }
  if (kernel_isolate_is_running) {
    Dart_KernelCompilationResult result = Dart_KernelListDependencies();
    if (result.status != Dart_KernelCompilationStatus_Ok) {
      ErrorExit(
          kErrorExitCode,
          "Error: Failed to fetch dependencies from kernel service: %s\n\n",
          result.error);
    }
    success &= file->WriteFully(result.kernel, result.kernel_size);
    free(result.kernel);
  }
  success &= file->Print("\n");
  if (!success) {
    ErrorExit(kErrorExitCode, "Error: Unable to write snapshot depfile: %s\n\n",
              Options::depfile());
  }
  file->Release();
}

static void OnExitHook(int64_t exit_code) {
  if (Dart_CurrentIsolate() != main_isolate) {
    Syslog::PrintErr(
        "A snapshot was requested, but a secondary isolate "
        "performed a hard exit (%" Pd64 ").\n",
        exit_code);
    Platform::Exit(kErrorExitCode);
  }
  if (exit_code == 0) {
    if (Options::gen_snapshot_kind() == kAppJIT) {
      Snapshot::GenerateAppJIT(Options::snapshot_filename());
    }
    WriteDepsFile();
  }
}

static Dart_Handle SetupCoreLibraries(Dart_Isolate isolate,
                                      IsolateData* isolate_data,
                                      bool is_isolate_group_start,
                                      bool is_kernel_isolate,
                                      const char** resolved_packages_config) {
  auto isolate_group_data = isolate_data->isolate_group_data();
  const auto packages_file = isolate_data->packages_file();
  const auto script_uri = isolate_group_data->script_url;

  Dart_Handle result;

  // Prepare builtin and other core libraries for use to resolve URIs.
  // Set up various closures, e.g: printing, timers etc.
  // Set up package configuration for URI resolution.
#if defined(PRODUCT)
  bool flag_profile_microtasks = false;
#else
  bool flag_profile_microtasks = Options::profile_microtasks();
#endif  // defined(PRODUCT)
  result = DartUtils::PrepareForScriptLoading(false, Options::trace_loading(),
                                              flag_profile_microtasks);
  if (Dart_IsError(result)) return result;

  // Setup packages config if specified.
  result = DartUtils::SetupPackageConfig(packages_file);
  if (Dart_IsError(result)) return result;
  if (!Dart_IsNull(result) && resolved_packages_config != nullptr) {
    result = Dart_StringToCString(result, resolved_packages_config);
    if (Dart_IsError(result)) return result;
    ASSERT(*resolved_packages_config != nullptr);
#if !defined(DART_PRECOMPILED_RUNTIME)
    if (is_isolate_group_start) {
      isolate_group_data->set_resolved_packages_config(
          *resolved_packages_config);
    } else {
      ASSERT(strcmp(isolate_group_data->resolved_packages_config(),
                    *resolved_packages_config) == 0);
    }
#endif
  }

  result = Dart_SetEnvironmentCallback(DartUtils::EnvironmentCallback);
  if (Dart_IsError(result)) return result;

  // Setup the native resolver as the snapshot does not carry it.
  Builtin::SetNativeResolver(Builtin::kBuiltinLibrary);
  Builtin::SetNativeResolver(Builtin::kIOLibrary);
  Builtin::SetNativeResolver(Builtin::kCLILibrary);
  VmService::SetNativeResolver();

  const char* namespc = is_kernel_isolate ? nullptr : Options::namespc();
  result =
      DartUtils::SetupIOLibrary(namespc, script_uri, Options::exit_disabled());
  if (Dart_IsError(result)) return result;

  return Dart_Null();
}

static bool OnIsolateInitialize(void** child_callback_data, char** error) {
  Dart_Isolate isolate = Dart_CurrentIsolate();
  ASSERT(isolate != nullptr);

  auto isolate_group_data =
      reinterpret_cast<IsolateGroupData*>(Dart_CurrentIsolateGroupData());

  auto isolate_data = new IsolateData(isolate_group_data);
  *child_callback_data = isolate_data;

  Dart_EnterScope();
  const auto script_uri = isolate_group_data->script_url;
  const bool isolate_run_app_snapshot =
      isolate_group_data->RunFromAppSnapshot();
  Dart_Handle result = SetupCoreLibraries(isolate, isolate_data,
                                          /*is_isolate_group_start=*/false,
                                          /*is_kernel_isolate=*/false,
                                          /*resolved_packages_config=*/nullptr);
  if (Dart_IsError(result)) goto failed;

  if (isolate_run_app_snapshot) {
    result = Loader::InitForSnapshot(script_uri, isolate_data);
    if (Dart_IsError(result)) goto failed;
  } else {
    result = DartUtils::ResolveScript(Dart_NewStringFromCString(script_uri));
    if (Dart_IsError(result)) goto failed;

    if (isolate_group_data->kernel_buffer() != nullptr) {
      // Various core-library parts will send requests to the Loader to resolve
      // relative URIs and perform other related tasks. We need Loader to be
      // initialized for this to work because loading from Kernel binary
      // bypasses normal source code loading paths that initialize it.
      const char* resolved_script_uri = nullptr;
      result = Dart_StringToCString(result, &resolved_script_uri);
      if (Dart_IsError(result)) goto failed;
      result = Loader::InitForSnapshot(resolved_script_uri, isolate_data);
      if (Dart_IsError(result)) goto failed;
    }
  }

  Dart_ExitScope();
  return true;

failed:
  *error = Utils::StrDup(Dart_GetError(result));
  Dart_ExitScope();
  return false;
}

static void* NativeAssetsDlopenRelative(const char* path, char** error) {
  auto isolate_group_data =
      reinterpret_cast<IsolateGroupData*>(Dart_CurrentIsolateGroupData());
  return NativeAssets::DlopenRelative(
      path, isolate_group_data->asset_resolution_base, error);
}

static Dart_Isolate IsolateSetupHelper(Dart_Isolate isolate,
                                       bool is_main_isolate,
                                       const char* script_uri,
                                       const char* packages_config,
                                       bool isolate_run_app_snapshot,
                                       Dart_IsolateFlags* flags,
                                       char** error,
                                       int* exit_code) {
  Dart_EnterScope();

  // Set up the library tag handler for the isolate group shared by all
  // isolates in the group.
  Dart_Handle result = Dart_SetLibraryTagHandler(Loader::LibraryTagHandler);
  CHECK_RESULT(result);
  result = Dart_SetDeferredLoadHandler(Loader::DeferredLoadHandler);
  CHECK_RESULT(result);

  auto isolate_data = reinterpret_cast<IsolateData*>(Dart_IsolateData(isolate));

  const char* resolved_packages_config = nullptr;
  result =
      SetupCoreLibraries(isolate, isolate_data,
                         /*is_isolate_group_start=*/true,
                         flags->is_kernel_isolate, &resolved_packages_config);
  CHECK_RESULT(result);

#if !defined(DART_PRECOMPILED_RUNTIME)
  auto isolate_group_data = isolate_data->isolate_group_data();
  const uint8_t* kernel_buffer = isolate_group_data->kernel_buffer().get();
  intptr_t kernel_buffer_size = isolate_group_data->kernel_buffer_size();
  if (!isolate_run_app_snapshot && kernel_buffer == nullptr &&
      !Dart_IsKernelIsolate(isolate)) {
    if (!dfe.CanUseDartFrontend()) {
      const char* format = "Dart frontend unavailable to compile script %s.";
      intptr_t len = snprintf(nullptr, 0, format, script_uri) + 1;
      *error = reinterpret_cast<char*>(malloc(len));
      ASSERT(error != nullptr);
      snprintf(*error, len, format, script_uri);
      *exit_code = kErrorExitCode;
      Dart_ExitScope();
      Dart_ShutdownIsolate();
      return nullptr;
    }
    uint8_t* application_kernel_buffer = nullptr;
    intptr_t application_kernel_buffer_size = 0;
    // Only pass snapshot = true when generating an AppJIT snapshot to avoid
    // duplicate null-safety info messages from the frontend when generating
    // a kernel snapshot (this flag is instead set in
    // Snapshot::GenerateKernel()).
    const bool for_snapshot = Options::gen_snapshot_kind() == kAppJIT;
    // If we compile for AppJIT the sources will not be included across app-jit
    // snapshotting, so there's no reason CFE should embed them in the kernel.
    const bool embed_sources = Options::gen_snapshot_kind() != kAppJIT;
    dfe.CompileAndReadScript(script_uri, &application_kernel_buffer,
                             &application_kernel_buffer_size, error, exit_code,
                             resolved_packages_config, for_snapshot,
                             embed_sources);
    if (application_kernel_buffer == nullptr) {
      Dart_ExitScope();
      Dart_ShutdownIsolate();
      return nullptr;
    }
    isolate_group_data->SetKernelBufferNewlyOwned(
        application_kernel_buffer, application_kernel_buffer_size);
    kernel_buffer = application_kernel_buffer;
    kernel_buffer_size = application_kernel_buffer_size;
  }
  if (kernel_buffer != nullptr) {
    Dart_Handle uri = Dart_NewStringFromCString(script_uri);
    CHECK_RESULT(uri);
    Dart_Handle resolved_script_uri = DartUtils::ResolveScript(uri);
    CHECK_RESULT(resolved_script_uri);
    if (Dart_IsBytecode(kernel_buffer, kernel_buffer_size)) {
      result = Dart_LoadScriptFromBytecode(kernel_buffer, kernel_buffer_size);
      CHECK_RESULT(result);
    } else {
      result = Dart_LoadScriptFromKernel(kernel_buffer, kernel_buffer_size);
      CHECK_RESULT(result);
    }
  }
#endif  // !defined(DART_PRECOMPILED_RUNTIME)

  if (isolate_run_app_snapshot) {
    Dart_Handle result = Loader::InitForSnapshot(script_uri, isolate_data);
    CHECK_RESULT(result);
#if !defined(DART_PRECOMPILED_RUNTIME)
    if (is_main_isolate) {
      // Find the canonical uri of the app snapshot. We'll use this to decide if
      // other isolates should use the app snapshot or the core snapshot.
      const char* resolved_script_uri = nullptr;
      result = Dart_StringToCString(
          DartUtils::ResolveScript(Dart_NewStringFromCString(script_uri)),
          &resolved_script_uri);
      CHECK_RESULT(result);
      ASSERT(app_script_uri == nullptr);
      app_script_uri = Utils::StrDup(resolved_script_uri);
    }
#endif  // !defined(DART_PRECOMPILED_RUNTIME)
  } else {
#if !defined(DART_PRECOMPILED_RUNTIME)
    // Load the specified application script into the newly created isolate.
    Dart_Handle uri =
        DartUtils::ResolveScript(Dart_NewStringFromCString(script_uri));
    CHECK_RESULT(uri);
    if (kernel_buffer != nullptr) {
      // relative URIs and perform other related tasks. We need Loader to be
      // initialized for this to work because loading from Kernel binary
      // bypasses normal source code loading paths that initialize it.
      const char* resolved_script_uri = nullptr;
      result = Dart_StringToCString(uri, &resolved_script_uri);
      CHECK_RESULT(result);
      result = Loader::InitForSnapshot(resolved_script_uri, isolate_data);
      CHECK_RESULT(result);
    }
    Dart_RecordTimelineEvent("LoadScript", Dart_TimelineGetMicros(),
                             Dart_GetMainPortId(), /*flow_id_count=*/0, nullptr,
                             Dart_Timeline_Event_Async_End,
                             /*argument_count=*/0, nullptr, nullptr);
#else
    UNREACHABLE();
#endif  // !defined(DART_PRECOMPILED_RUNTIME)
  }

  if ((Options::gen_snapshot_kind() == kAppJIT) && is_main_isolate) {
    result = Dart_SortClasses();
    CHECK_RESULT(result);
  }

#if !defined(DART_PRECOMPILER)
  NativeAssetsApi native_assets;
  memset(&native_assets, 0, sizeof(native_assets));
  native_assets.dlopen_absolute = &NativeAssets::DlopenAbsolute;
  native_assets.dlopen_relative = &NativeAssetsDlopenRelative;
  native_assets.dlopen_system = &NativeAssets::DlopenSystem;
  native_assets.dlopen_executable = &NativeAssets::DlopenExecutable;
  native_assets.dlopen_process = &NativeAssets::DlopenProcess;
  native_assets.dlsym = &NativeAssets::Dlsym;
  Dart_InitializeNativeAssetsResolver(&native_assets);
#endif  // !defined(DART_PRECOMPILER)

  // Make the isolate runnable so that it is ready to handle messages.
  Dart_ExitScope();
  Dart_ExitIsolate();
  *error = Dart_IsolateMakeRunnable(isolate);
  if (*error != nullptr) {
    Dart_EnterIsolate(isolate);
    Dart_ShutdownIsolate();
    return nullptr;
  }

  return isolate;
}

#if !defined(EXCLUDE_CFE_AND_KERNEL_PLATFORM)
// Returns newly created Kernel Isolate on success, nullptr on failure.
// For now we only support the kernel isolate coming up from an
// application snapshot or from a .dill file.
static Dart_Isolate CreateAndSetupKernelIsolate(const char* script_uri,
                                                const char* packages_config,
                                                Dart_IsolateFlags* flags,
                                                char** error,
                                                int* exit_code) {
  // Do not start a kernel isolate if we are doing a training run
  // to create an app JIT snapshot and a kernel file is specified
  // as the application to run.
  if (Options::gen_snapshot_kind() == kAppJIT) {
    const uint8_t* kernel_buffer = nullptr;
    intptr_t kernel_buffer_size = 0;
    dfe.application_kernel_buffer(&kernel_buffer, &kernel_buffer_size);
    if (kernel_buffer_size != 0) {
      return nullptr;
    }
  }
  // Create and Start the kernel isolate.
  const char* kernel_snapshot_uri = dfe.frontend_filename();
  const char* uri =
      kernel_snapshot_uri != nullptr ? kernel_snapshot_uri : script_uri;

  if (packages_config == nullptr) {
    packages_config = Options::packages_file();
  }

  Dart_Isolate isolate = nullptr;
  IsolateGroupData* isolate_group_data = nullptr;
  IsolateData* isolate_data = nullptr;
  bool isolate_run_app_snapshot = false;
  AppSnapshot* app_snapshot = nullptr;
  // Kernel isolate uses an app JIT snapshot or uses the dill file.
  if ((kernel_snapshot_uri != nullptr) &&
      ((app_snapshot = Snapshot::TryReadAppSnapshot(
            kernel_snapshot_uri, /*force_load_from_memory=*/false,
            /*decode_uri=*/false)) != nullptr) &&
      app_snapshot->IsJIT()) {
    const uint8_t* isolate_snapshot_data = nullptr;
    const uint8_t* isolate_snapshot_instructions = nullptr;
    const uint8_t* ignore_vm_snapshot_data;
    const uint8_t* ignore_vm_snapshot_instructions;
    isolate_run_app_snapshot = true;
    app_snapshot->SetBuffers(
        &ignore_vm_snapshot_data, &ignore_vm_snapshot_instructions,
        &isolate_snapshot_data, &isolate_snapshot_instructions);
    isolate_group_data = new IsolateGroupData(
        uri, /*asset_resolution_base=*/nullptr, packages_config, app_snapshot,
        isolate_run_app_snapshot);
    isolate_data = new IsolateData(isolate_group_data);
    isolate = Dart_CreateIsolateGroup(
        DART_KERNEL_ISOLATE_NAME, DART_KERNEL_ISOLATE_NAME,
        isolate_snapshot_data, isolate_snapshot_instructions, flags,
        isolate_group_data, isolate_data, error);
  }
  if (isolate == nullptr) {
    // Clear error from app snapshot and re-trying from kernel file.
    free(*error);
    *error = nullptr;
    delete isolate_data;
    delete isolate_group_data;

    const uint8_t* kernel_service_buffer = nullptr;
    intptr_t kernel_service_buffer_size = 0;
    dfe.LoadKernelService(&kernel_service_buffer, &kernel_service_buffer_size);
    ASSERT(kernel_service_buffer != nullptr);
    isolate_group_data = new IsolateGroupData(
        uri, /*asset_resolution_base=*/nullptr, packages_config, nullptr,
        isolate_run_app_snapshot);
    isolate_group_data->SetKernelBufferUnowned(
        const_cast<uint8_t*>(kernel_service_buffer),
        kernel_service_buffer_size);
    isolate_data = new IsolateData(isolate_group_data);
    isolate = Dart_CreateIsolateGroupFromKernel(
        DART_KERNEL_ISOLATE_NAME, DART_KERNEL_ISOLATE_NAME,
        kernel_service_buffer, kernel_service_buffer_size, flags,
        isolate_group_data, isolate_data, error);
  }

  if (isolate == nullptr) {
    Syslog::PrintErr("%s\n", *error);
    delete isolate_data;
    delete isolate_group_data;
    return nullptr;
  }
  kernel_isolate_is_running = true;

  return IsolateSetupHelper(isolate, false, uri, packages_config,
                            isolate_run_app_snapshot, flags, error, exit_code);
}
#endif  // !defined(EXCLUDE_CFE_AND_KERNEL_PLATFORM)

// Returns newly created Service Isolate on success, nullptr on failure.
// For now we only support the service isolate coming up from sources
// which are compiled by the VM parser.
static Dart_Isolate CreateAndSetupServiceIsolate(const char* script_uri,
                                                 const char* packages_config,
                                                 Dart_IsolateFlags* flags,
                                                 char** error,
                                                 int* exit_code) {
#if !defined(PRODUCT)
  ASSERT(script_uri != nullptr);
  Dart_Isolate isolate = nullptr;
  auto isolate_group_data =
      new IsolateGroupData(script_uri, /*asset_resolution_base=*/nullptr,
                           packages_config, nullptr, false);
  ASSERT(flags != nullptr);

#if defined(DART_PRECOMPILED_RUNTIME)
  // AOT: The service isolate is included in any AOT snapshot in non-PRODUCT
  // mode - so we launch the vm-service from the main app AOT snapshot.
  const uint8_t* isolate_snapshot_data = app_isolate_snapshot_data;
  const uint8_t* isolate_snapshot_instructions =
      app_isolate_snapshot_instructions;
  isolate = Dart_CreateIsolateGroup(
      script_uri, DART_VM_SERVICE_ISOLATE_NAME, isolate_snapshot_data,
      isolate_snapshot_instructions, flags, isolate_group_data,
      /*isolate_data=*/nullptr, error);
#else
  // JIT: Service isolate uses the core libraries snapshot.

  // Set flag to load and retain the vmservice library.
  flags->load_vmservice_library = true;
  flags->null_safety = true;  // Service isolate runs in sound null safe mode.
  const uint8_t* isolate_snapshot_data = core_isolate_snapshot_data;
  const uint8_t* isolate_snapshot_instructions =
      core_isolate_snapshot_instructions;
  isolate = Dart_CreateIsolateGroup(
      script_uri, DART_VM_SERVICE_ISOLATE_NAME, isolate_snapshot_data,
      isolate_snapshot_instructions, flags, isolate_group_data,
      /*isolate_data=*/nullptr, error);
#endif  // !defined(DART_PRECOMPILED_RUNTIME)
  if (isolate == nullptr) {
    delete isolate_group_data;
    return nullptr;
  }

  Dart_EnterScope();

  Dart_Handle result = Dart_SetLibraryTagHandler(Loader::LibraryTagHandler);
  CHECK_RESULT(result);
  result = Dart_SetDeferredLoadHandler(Loader::DeferredLoadHandler);
  CHECK_RESULT(result);

  // We do not spawn the external dds process if DDS is explicitly disabled.
  bool wait_for_dds_to_advertise_service = Options::enable_dds();
  bool serve_devtools =
      Options::enable_devtools() || !Options::disable_devtools();
  // Load embedder specific bits and return.
  if (!VmService::Setup(
          Options::vm_service_server_ip(), Options::vm_service_server_port(),
          Options::vm_service_dev_mode(), Options::vm_service_auth_disabled(),
          Options::vm_write_service_info_filename(), Options::trace_loading(),
          Options::deterministic(), Options::enable_service_port_fallback(),
          wait_for_dds_to_advertise_service, serve_devtools,
          Options::enable_observatory(), Options::print_dtd(),
          Options::resident(),
          Options::resident_compiler_info_file_path() != nullptr
              ? Options::resident_compiler_info_file_path()
              : Options::resident_server_info_file_path())) {
    *error = Utils::StrDup(VmService::GetErrorMessage());
    return nullptr;
  }
  if (Options::compile_all()) {
    result = Dart_CompileAll();
    CHECK_RESULT(result);
  }
  result = Dart_SetEnvironmentCallback(DartUtils::EnvironmentCallback);
  CHECK_RESULT(result);
  Dart_ExitScope();
  Dart_ExitIsolate();
  return isolate;
#else   // !defined(PRODUCT)
  return nullptr;
#endif  // !defined(PRODUCT)
}

// Returns newly created Isolate on success, nullptr on failure.
static Dart_Isolate CreateIsolateGroupAndSetupHelper(
    bool is_main_isolate,
    const char* script_uri,
    const char* asset_resolution_base,
    const char* name,
    const char* packages_config,
    Dart_IsolateFlags* flags,
    void* callback_data,
    char** error,
    int* exit_code) {
  int64_t start = Dart_TimelineGetMicros();
  ASSERT(script_uri != nullptr);
  uint8_t* kernel_buffer = nullptr;
  intptr_t kernel_buffer_size = 0;
  AppSnapshot* app_snapshot = nullptr;

#if defined(DART_PRECOMPILED_RUNTIME)
  const uint8_t* isolate_snapshot_data = nullptr;
  const uint8_t* isolate_snapshot_instructions = nullptr;
  if (is_main_isolate) {
    isolate_snapshot_data = app_isolate_snapshot_data;
    isolate_snapshot_instructions = app_isolate_snapshot_instructions;
  } else {
    // AOT: All isolates need to be run from AOT compiled snapshots.
    const bool kForceLoadFromMemory = false;
    app_snapshot =
        Snapshot::TryReadAppSnapshot(script_uri, kForceLoadFromMemory);
    if (app_snapshot == nullptr || !app_snapshot->IsAOT()) {
      *error = Utils::SCreate(
          "The uri(%s) provided to `Isolate.spawnUri()` does not "
          "contain a valid AOT snapshot.",
          script_uri);
      return nullptr;
    }

    const uint8_t* ignore_vm_snapshot_data;
    const uint8_t* ignore_vm_snapshot_instructions;
    app_snapshot->SetBuffers(
        &ignore_vm_snapshot_data, &ignore_vm_snapshot_instructions,
        &isolate_snapshot_data, &isolate_snapshot_instructions);
  }

  bool isolate_run_app_snapshot = true;
#else
  // JIT: Main isolate starts from the app snapshot, if any. Other isolates
  // use the core libraries snapshot.
  bool isolate_run_app_snapshot = false;
  const uint8_t* isolate_snapshot_data = core_isolate_snapshot_data;
  const uint8_t* isolate_snapshot_instructions =
      core_isolate_snapshot_instructions;
  if ((app_isolate_snapshot_data != nullptr) &&
      (is_main_isolate || ((app_script_uri != nullptr) &&
                           (strcmp(script_uri, app_script_uri) == 0)))) {
    isolate_run_app_snapshot = true;
    isolate_snapshot_data = app_isolate_snapshot_data;
    isolate_snapshot_instructions = app_isolate_snapshot_instructions;
  } else if (!is_main_isolate) {
    app_snapshot = Snapshot::TryReadAppSnapshot(script_uri);
    if (app_snapshot != nullptr && app_snapshot->IsJITorAOT()) {
      if (app_snapshot->IsAOT()) {
        *error = Utils::SCreate(
            "The uri(%s) provided to `Isolate.spawnUri()` is an "
            "AOT snapshot and the JIT VM cannot spawn an isolate using it.",
            script_uri);
        delete app_snapshot;
        return nullptr;
      }
      isolate_run_app_snapshot = true;
      const uint8_t* ignore_vm_snapshot_data;
      const uint8_t* ignore_vm_snapshot_instructions;
      app_snapshot->SetBuffers(
          &ignore_vm_snapshot_data, &ignore_vm_snapshot_instructions,
          &isolate_snapshot_data, &isolate_snapshot_instructions);
    }
  }

  if (kernel_buffer == nullptr && !isolate_run_app_snapshot) {
    dfe.ReadScript(script_uri, app_snapshot, &kernel_buffer,
                   &kernel_buffer_size, /*decode_uri=*/true);
  }
  PathSanitizer script_uri_sanitizer(script_uri);
  PathSanitizer packages_config_sanitizer(packages_config);
#endif  // !defined(DART_PRECOMPILED_RUNTIME)

  auto isolate_group_data =
      new IsolateGroupData(script_uri, asset_resolution_base, packages_config,
                           app_snapshot, isolate_run_app_snapshot);
  if (kernel_buffer != nullptr) {
    isolate_group_data->SetKernelBufferNewlyOwned(kernel_buffer,
                                                  kernel_buffer_size);
  }

  Dart_Isolate isolate = nullptr;

  IsolateData* isolate_data = nullptr;
#if !defined(DART_PRECOMPILED_RUNTIME)
  if (!isolate_run_app_snapshot && (isolate_snapshot_data == nullptr)) {
    const uint8_t* platform_kernel_buffer = nullptr;
    intptr_t platform_kernel_buffer_size = 0;
    dfe.LoadPlatform(&platform_kernel_buffer, &platform_kernel_buffer_size);
    if (platform_kernel_buffer == nullptr) {
      platform_kernel_buffer = kernel_buffer;
      platform_kernel_buffer_size = kernel_buffer_size;
    }
    if (platform_kernel_buffer == nullptr) {
#if defined(EXCLUDE_CFE_AND_KERNEL_PLATFORM)
      FATAL(
          "Binary built with --exclude-kernel-service. Cannot run"
          " from source.");
#else
      FATAL("platform_program cannot be nullptr.");
#endif  // defined(EXCLUDE_CFE_AND_KERNEL_PLATFORM)
    }
    // TODO(sivachandra): When the platform program is unavailable, check if
    // application kernel binary is self contained or an incremental binary.
    // Isolate should be created only if it is a self contained kernel binary.
    isolate_data = new IsolateData(isolate_group_data);
    isolate = Dart_CreateIsolateGroupFromKernel(
        script_uri, name, platform_kernel_buffer, platform_kernel_buffer_size,
        flags, isolate_group_data, isolate_data, error);
  } else {
    isolate_data = new IsolateData(isolate_group_data);
    isolate = Dart_CreateIsolateGroup(script_uri, name, isolate_snapshot_data,
                                      isolate_snapshot_instructions, flags,
                                      isolate_group_data, isolate_data, error);
  }
#else
  isolate_data = new IsolateData(isolate_group_data);
  isolate = Dart_CreateIsolateGroup(script_uri, name, isolate_snapshot_data,
                                    isolate_snapshot_instructions, flags,
                                    isolate_group_data, isolate_data, error);
#endif  // !defined(DART_PRECOMPILED_RUNTIME)

  Dart_Isolate created_isolate = nullptr;
  if (isolate == nullptr) {
    delete isolate_data;
    delete isolate_group_data;
  } else {
    created_isolate = IsolateSetupHelper(
        isolate, is_main_isolate, script_uri, packages_config,
        isolate_run_app_snapshot, flags, error, exit_code);
  }
  int64_t end = Dart_TimelineGetMicros();
  Dart_RecordTimelineEvent("CreateIsolateGroupAndSetupHelper", start, end,
                           /*flow_id_count=*/0, nullptr,
                           Dart_Timeline_Event_Duration,
                           /*argument_count=*/0, nullptr, nullptr);
  return created_isolate;
}

#undef CHECK_RESULT

static CStringUniquePtr ResolveSymlinks(const char* path, char** error) {
  auto file_type = File::GetType(nullptr, path, /*follow_links=*/true);
  switch (file_type) {
    case File::kIsLink:
      UNREACHABLE();
    case File::kIsSock:
    case File::kIsPipe:
      // Don't use pipes or sockets as base paths for assets resolution.
      return CStringUniquePtr();
    case File::kDoesNotExist:
      // Don't try to resolve symlinks if the file doesn't exist.
      // `dartdev` and `Isolate.spawnUri` will already issue an error.
      return CStringUniquePtr();
    case File::kIsFile:
    case File::kIsDirectory:
      break;
  }

  const size_t kPathBufSize = PATH_MAX + 1;
  char canon_path[kPathBufSize];
  auto result = File::GetCanonicalPath(nullptr, path, canon_path, kPathBufSize);
  if (result == nullptr) {
    OSError os_error;
    *error = Utils::SCreate(
        "Failed to canonicalize path '%s'. OS error: '%s' (%i).\n", path,
        os_error.message(), os_error.code());
    return CStringUniquePtr();
  }
  return CStringUniquePtr(Utils::StrDup(canon_path));
}

// Get a file path from the script uri if it is a file uri and resolve symlinks.
static CStringUniquePtr FindAssetResolutionBase(const char* script_uri,
                                                char** error) {
  static const char* data_schema = "data:";
  static const int data_schema_length = 5;
  static const char* package_scheme = "package:";
  static const int package_scheme_length = 8;
  static const char* https_scheme = "https://";
  static const int https_scheme_length = 8;
  static const char* http_scheme = "http://";
  static const int http_scheme_length = 7;
  static const char* file_schema = "file://";
  static const int file_schema_length = 7;

  if ((strlen(script_uri) > data_schema_length &&
       strncmp(script_uri, data_schema, data_schema_length) == 0) ||
      (strlen(script_uri) > data_schema_length &&
       strncmp(script_uri, package_scheme, package_scheme_length) == 0) ||
      (strlen(script_uri) > package_scheme_length &&
       strncmp(script_uri, https_scheme, https_scheme_length) == 0) ||
      (strlen(script_uri) > http_scheme_length &&
       strncmp(script_uri, http_scheme, http_scheme_length) == 0)) {
    // No base path for assets.
    return CStringUniquePtr();
  }

  if (strlen(script_uri) > file_schema_length &&
      strncmp(script_uri, file_schema, file_schema_length) == 0) {
    // Isolate.spawnUri sets a `source` including the file schema,
    // e.g. Isolate.spawnUri may make the embedder pass a file:// uri.
    return ResolveSymlinks(File::UriToPath(script_uri).get(), error);
  }

  // It's possible to spawn uri without a scheme, assume file path.
  return ResolveSymlinks(script_uri, error);
}

static Dart_Isolate CreateIsolateGroupAndSetup(const char* script_uri,
                                               const char* main,
                                               const char* package_root,
                                               const char* package_config,
                                               Dart_IsolateFlags* flags,
                                               void* callback_data,
                                               char** error) {
  // The VM should never call the isolate helper with a nullptr flags.
  ASSERT(flags != nullptr);
  ASSERT(flags->version == DART_FLAGS_CURRENT_VERSION);
  ASSERT(package_root == nullptr);

  if (error != nullptr) {
    *error = nullptr;
  }

  bool dontneed_safe = true;
#if defined(DART_HOST_OS_LINUX)
  // This would also be true in Linux, except that Google3 overrides the default
  // ELF interpreter to one that apparently doesn't create proper mappings.
  dontneed_safe = false;
#elif defined(DEBUG)
  // If the snapshot isn't file-backed, madvise(DONT_NEED) is destructive.
  if (Options::force_load_from_memory()) {
    dontneed_safe = false;
  }
#endif
  flags->snapshot_is_dontneed_safe = dontneed_safe;

  int exit_code = 0;
#if !defined(EXCLUDE_CFE_AND_KERNEL_PLATFORM)
  if (strcmp(script_uri, DART_KERNEL_ISOLATE_NAME) == 0) {
    return CreateAndSetupKernelIsolate(script_uri, package_config, flags, error,
                                       &exit_code);
  }
#endif  // !defined(EXCLUDE_CFE_AND_KERNEL_PLATFORM)

  if (strcmp(script_uri, DART_VM_SERVICE_ISOLATE_NAME) == 0) {
    return CreateAndSetupServiceIsolate(script_uri, package_config, flags,
                                        error, &exit_code);
  }

  bool is_main_isolate = false;
  auto asset_resolution_base = FindAssetResolutionBase(script_uri, error);
  if (*error != nullptr) {
    return nullptr;
  }
  return CreateIsolateGroupAndSetupHelper(
      is_main_isolate, script_uri, asset_resolution_base.get(), main,
      package_config, flags, callback_data, error, &exit_code);
}

static void OnIsolateShutdown(void* isolate_group_data, void* isolate_data) {
  Dart_EnterScope();
  Dart_Handle sticky_error = Dart_GetStickyError();
  if (!Dart_IsNull(sticky_error) && !Dart_IsFatalError(sticky_error)) {
    Syslog::PrintErr("%s\n", Dart_GetError(sticky_error));
  }
  Dart_ExitScope();
}

static void DeleteIsolateData(void* isolate_group_data, void* callback_data) {
  auto isolate_data = reinterpret_cast<IsolateData*>(callback_data);
  delete isolate_data;
}

static void DeleteIsolateGroupData(void* callback_data) {
  auto isolate_group_data = reinterpret_cast<IsolateGroupData*>(callback_data);
  delete isolate_group_data;
}

static constexpr const char* kStdoutStreamId = "Stdout";
static constexpr const char* kStderrStreamId = "Stderr";

static bool ServiceStreamListenCallback(const char* stream_id) {
  if (strcmp(stream_id, kStdoutStreamId) == 0) {
    SetCaptureStdout(true);
    return true;
  } else if (strcmp(stream_id, kStderrStreamId) == 0) {
    SetCaptureStderr(true);
    return true;
  }
  return false;
}

static void ServiceStreamCancelCallback(const char* stream_id) {
  if (strcmp(stream_id, kStdoutStreamId) == 0) {
    SetCaptureStdout(false);
  } else if (strcmp(stream_id, kStderrStreamId) == 0) {
    SetCaptureStderr(false);
  }
}

static bool FileModifiedCallback(const char* url, int64_t since) {
  auto path = File::UriToPath(url);
  if (path == nullptr) {
    // If it isn't a file on local disk, we don't know if it has been
    // modified.
    return true;
  }
  int64_t data[File::kStatSize];
  File::Stat(nullptr, path.get(), data);
  if (data[File::kType] == File::kDoesNotExist) {
    return true;
  }
  return data[File::kModifiedTime] > since;
}

static void EmbedderInformationCallback(Dart_EmbedderInformation* info) {
  info->version = DART_EMBEDDER_INFORMATION_CURRENT_VERSION;
  info->name = "Dart VM";
  Process::GetRSSInformation(&(info->max_rss), &(info->current_rss));
}

#define CHECK_RESULT(result)                                                   \
  if (Dart_IsError(result)) {                                                  \
    const int exit_code = Dart_IsCompilationError(result)                      \
                              ? kCompilationErrorExitCode                      \
                              : kErrorExitCode;                                \
    ErrorExit(exit_code, "%s\n", Dart_GetError(result));                       \
  }

static void CompileAndSaveKernel(const char* script_name,
                                 const char* package_config_override,
                                 CommandLineOptions* dart_options) {
  if (vm_run_app_snapshot) {
    Syslog::PrintErr("Cannot create a script snapshot from an app snapshot.\n");
    // The snapshot would contain references to the app snapshot instead of
    // the core snapshot.
    Platform::Exit(kErrorExitCode);
  }
  Snapshot::GenerateKernel(Options::snapshot_filename(), script_name,
                           package_config_override);
  WriteDepsFile();
}

void RunMainIsolate(const char* script_name,
                    const char* asset_resolution_base,
                    const char* package_config_override,
                    CommandLineOptions* dart_options) {
  if (script_name != nullptr) {
    const char* base_name = strrchr(script_name, '/');
    if (base_name == nullptr) {
      base_name = script_name;
    } else {
      base_name++;  // Skip '/'.
    }
    const intptr_t kMaxNameLength = 64;
    char name[kMaxNameLength];
    Utils::SNPrint(name, kMaxNameLength, "dart:%s", base_name);
    Platform::SetProcessName(name);
  }

  // Call CreateIsolateGroupAndSetup which creates an isolate and loads up
  // the specified application script.
  char* error = nullptr;
  int exit_code = 0;
  Dart_IsolateFlags flags;
  Dart_IsolateFlagsInitialize(&flags);
  flags.is_system_isolate = Options::mark_main_isolate_as_system_isolate();
  bool dontneed_safe = true;
#if defined(DART_HOST_OS_LINUX)
  // This would also be true in Linux, except that Google3 overrides the default
  // ELF interpreter to one that apparently doesn't create proper mappings.
  dontneed_safe = false;
#elif defined(DEBUG)
  // If the snapshot isn't file-backed, madvise(DONT_NEED) is destructive.
  if (Options::force_load_from_memory()) {
    dontneed_safe = false;
  }
#endif
  flags.snapshot_is_dontneed_safe = dontneed_safe;

  Dart_Isolate isolate = CreateIsolateGroupAndSetupHelper(
      /* is_main_isolate */ true, script_name, asset_resolution_base, "main",
      Options::packages_file() == nullptr ? package_config_override
                                          : Options::packages_file(),
      &flags, nullptr /* callback_data */, &error, &exit_code);

  if (isolate == nullptr) {
    Syslog::PrintErr("%s\n", error);
    free(error);
    error = nullptr;
    Process::TerminateExitCodeHandler();
    error = Dart_Cleanup();
    if (error != nullptr) {
      Syslog::PrintErr("VM cleanup failed: %s\n", error);
      free(error);
    }
    dart::embedder::Cleanup();
    Platform::Exit((exit_code != 0) ? exit_code : kErrorExitCode);
  }
  main_isolate = isolate;

  Dart_EnterIsolate(isolate);
  ASSERT(isolate == Dart_CurrentIsolate());
  ASSERT(isolate != nullptr);
  Dart_Handle result;

  Dart_EnterScope();

  // Kernel snapshots should have been handled before reaching this point.
  ASSERT(Options::gen_snapshot_kind() != kKernel);
  // Lookup the library of the root script.
  Dart_Handle root_lib = Dart_RootLibrary();

#if !defined(DART_PRECOMPILED_RUNTIME)
  if (Options::compile_all()) {
    result = Dart_CompileAll();
    CHECK_RESULT(result);
  }
#endif  // !defined(DART_PRECOMPILED_RUNTIME)

  if (Dart_IsNull(root_lib)) {
    ErrorExit(kErrorExitCode, "Unable to find root library for '%s'\n",
              script_name);
  }

  // Create a closure for the main entry point which is in the exported
  // namespace of the root library or invoke a getter of the same name
  // in the exported namespace and return the resulting closure.
  Dart_Handle main_closure =
      Dart_GetField(root_lib, Dart_NewStringFromCString("main"));
  CHECK_RESULT(main_closure);
  if (!Dart_IsClosure(main_closure)) {
    ErrorExit(kErrorExitCode, "Unable to find 'main' in root library '%s'\n",
              script_name);
  }

  // Call _startIsolate in the isolate library to enable dispatching the
  // initial startup message.
  const intptr_t kNumIsolateArgs = 2;
  Dart_Handle isolate_args[kNumIsolateArgs];
  isolate_args[0] = main_closure;                          // entryPoint
  isolate_args[1] = dart_options->CreateRuntimeOptions();  // args

  Dart_Handle isolate_lib =
      Dart_LookupLibrary(Dart_NewStringFromCString("dart:isolate"));
  result =
      Dart_Invoke(isolate_lib, Dart_NewStringFromCString("_startMainIsolate"),
                  kNumIsolateArgs, isolate_args);
  CHECK_RESULT(result);

  // Keep handling messages until the last active receive port is closed.
  result = Dart_RunLoop();
  // Generate an app snapshot after execution if specified.
  if (Options::gen_snapshot_kind() == kAppJIT) {
    if (!Dart_IsCompilationError(result)) {
      Snapshot::GenerateAppJIT(Options::snapshot_filename());
    }
  }
  CHECK_RESULT(result);

  WriteDepsFile();

  Dart_ExitScope();

  // Shutdown the isolate.
  Dart_ShutdownIsolate();
}

#undef CHECK_RESULT

static bool CheckForInvalidPath(const char* path) {
  // TODO(zichangguo): "\\?\" is a prefix for paths on Windows.
  // Arguments passed are parsed as an URI. "\\?\" causes problems as a part
  // of URIs. This is a temporary workaround to prevent VM from crashing.
  // Issue: https://github.com/dart-lang/sdk/issues/42779
  if (strncmp(path, "\\\\?\\", 4) == 0) {
    Syslog::PrintErr("\\\\?\\ prefix is not supported");
    return false;
  }
  return true;
}

void main(int argc, char** argv) {
#if !defined(DART_HOST_OS_WINDOWS)
  // Very early so any crashes during startup can also be symbolized.
  EXEUtils::LoadDartProfilerSymbols(argv[0]);
#endif

  char* script_name = nullptr;
  CStringUniquePtr asset_resolution_base = CStringUniquePtr();
  char* package_config_override = nullptr;
  const int EXTRA_VM_ARGUMENTS = 10;
  CommandLineOptions vm_options(argc + EXTRA_VM_ARGUMENTS);
  CommandLineOptions dart_options(argc + EXTRA_VM_ARGUMENTS);
  bool print_flags_seen = false;

  // Perform platform specific initialization.
  if (!Platform::Initialize()) {
    Syslog::PrintErr("Initialization failed\n");
    Platform::Exit(kErrorExitCode);
  }

  // Save the console state so we can restore it at shutdown.
  Console::SaveConfig();

  SetupICU();

  // On Windows, the argv strings are code page encoded and not
  // utf8. We need to convert them to utf8.
  bool argv_converted = ShellUtils::GetUtf8Argv(argc, argv);

#if !defined(DART_PRECOMPILED_RUNTIME)
  // Processing of some command line flags directly manipulates dfe.
  Options::set_dfe(&dfe);
#endif  // !defined(DART_PRECOMPILED_RUNTIME)

  // When running from the command line we assume that we are optimizing for
  // throughput, and therefore use a larger new gen semi space size and a faster
  // new gen growth factor unless others have been specified.
  if (kWordSize <= 4) {
    vm_options.AddArgument("--new_gen_semi_max_size=16");
  } else {
    vm_options.AddArgument("--new_gen_semi_max_size=32");
  }
  vm_options.AddArgument("--new_gen_growth_factor=4");

  auto parse_arguments =
      [&](int argc, char** argv, CommandLineOptions* vm_options,
          CommandLineOptions* dart_options, bool parsing_dart_vm_options) {
        bool success = Options::ParseArguments(
            argc, argv, vm_run_app_snapshot, parsing_dart_vm_options,
            vm_options, &script_name, dart_options, &print_flags_seen);
        if (!success) {
          if (Options::help_option()) {
            Options::PrintUsage();
            Platform::Exit(0);
          } else if (Options::version_option()) {
            Options::PrintVersion();
            Platform::Exit(0);
          } else if (print_flags_seen) {
            // Will set the VM flags, print them out and then we exit as no
            // script was specified on the command line.
            char* error =
                Dart_SetVMFlags(vm_options->count(), vm_options->arguments());
            if (error != nullptr) {
              Syslog::PrintErr("Setting VM flags failed: %s\n", error);
              free(error);
              Platform::Exit(kErrorExitCode);
            }
            Platform::Exit(0);
          } else {
            Options::PrintUsage();
            Platform::Exit(kErrorExitCode);
          }
        }
      };

  AppSnapshot* app_snapshot = nullptr;
#if defined(DART_PRECOMPILED_RUNTIME)
  // If the executable binary contains the runtime together with an appended
  // snapshot, load and run that.
  // Any arguments passed to such an executable are meant for the actual
  // application so skip all Dart VM flag parsing.

  const size_t kPathBufSize = PATH_MAX + 1;
  char executable_path[kPathBufSize];
  if (Platform::ResolveExecutablePathInto(executable_path, kPathBufSize) > 0) {
    app_snapshot = Snapshot::TryReadAppendedAppSnapshot(executable_path);
    if (app_snapshot != nullptr) {
      script_name = argv[0];

      char* error = nullptr;
      asset_resolution_base = ResolveSymlinks(executable_path, &error);
      if (error != nullptr) {
        Syslog::PrintErr("%s", error);
        free(error);
        delete app_snapshot;
        Platform::Exit(kErrorExitCode);
      }

      // Store the executable name.
      Platform::SetExecutableName(argv[0]);

      // Parse out options to be passed to dart main.
      for (int i = 1; i < argc; i++) {
        dart_options.AddArgument(argv[i]);
      }

      // Parse DART_VM_OPTIONS options.
      int env_argc = 0;
      char** env_argv = Options::GetEnvArguments(&env_argc);
      if (env_argv != nullptr) {
        // Any Dart options that are generated based on parsing DART_VM_OPTIONS
        // are useless, so we'll throw them away rather than passing them along.
        CommandLineOptions tmp_options(env_argc + EXTRA_VM_ARGUMENTS);
        parse_arguments(env_argc, env_argv, &vm_options, &tmp_options,
                        /*parsing_dart_vm_options=*/true);
      }
    }
  }
#endif

  // Parse command line arguments.
  if (app_snapshot == nullptr) {
    parse_arguments(argc, argv, &vm_options, &dart_options,
                    /*parsing_dart_vm_options=*/false);
  }

  DartUtils::SetEnvironment(Options::environment());

  if (Options::suppress_core_dump()) {
    Platform::SetCoreDumpResourceLimit(0);
  } else {
    InitializeCrashpadClient();
  }

  Loader::InitOnce();

  auto try_load_snapshots_lambda = [&](void) -> void {
    if (app_snapshot == nullptr) {
      // For testing purposes we add a flag to debug-mode to use the
      // in-memory ELF loader.
      const bool force_load_from_memory =
          false DEBUG_ONLY(|| Options::force_load_from_memory());
      app_snapshot =
          Snapshot::TryReadAppSnapshot(script_name, force_load_from_memory);
    }
    if (app_snapshot != nullptr && app_snapshot->IsJITorAOT()) {
      if (app_snapshot->IsAOT() && !Dart_IsPrecompiledRuntime()) {
        Syslog::PrintErr(
            "%s is an AOT snapshot and should be run with 'dartaotruntime'\n",
            script_name);
        Platform::Exit(kErrorExitCode);
      }
      if (app_snapshot->IsJIT() && Dart_IsPrecompiledRuntime()) {
        Syslog::PrintErr(
            "%s is a JIT snapshot, it cannot be run with 'dartaotruntime'\n",
            script_name);
        Platform::Exit(kErrorExitCode);
      }
      vm_run_app_snapshot = true;
      app_snapshot->SetBuffers(&vm_snapshot_data, &vm_snapshot_instructions,
                               &app_isolate_snapshot_data,
                               &app_isolate_snapshot_instructions);
    } else if (app_snapshot == nullptr && Dart_IsPrecompiledRuntime()) {
      Syslog::PrintErr(
          "%s is not an AOT snapshot,"
          " it cannot be run with 'dartaotruntime'\n",
          script_name);
      Platform::Exit(kErrorExitCode);
    }
  };

  // At this point, script_name now points to a script or a valid file path
  // was provided as the first non-flag argument.
  if (script_name != nullptr) {
    if (!CheckForInvalidPath(script_name)) {
      Platform::Exit(0);
    }
    try_load_snapshots_lambda();
  }

#if defined(DART_PRECOMPILED_RUNTIME)
  vm_options.AddArgument("--precompilation");
#endif
  if (Options::gen_snapshot_kind() == kAppJIT) {
    // App-jit snapshot can be deployed to another machine,
    // so generated code should not depend on the CPU features
    // of the system where snapshot was generated.
    vm_options.AddArgument("--target-unknown-cpu");
#if !defined(TARGET_ARCH_IA32)
    vm_options.AddArgument("--link_natives_lazily");
#endif
  }

  // If we need to write an app-jit snapshot or a depfile, then add an exit
  // hook that writes the snapshot and/or depfile as appropriate.
  if ((Options::gen_snapshot_kind() == kAppJIT) ||
      (Options::depfile() != nullptr)) {
    Process::SetExitHook(OnExitHook);
  }

  char* error = nullptr;
  if (!dart::embedder::InitOnce(&error)) {
    Syslog::PrintErr("Standalone embedder initialization failed: %s\n", error);
    free(error);
    Platform::Exit(kErrorExitCode);
  }

  error = Dart_SetVMFlags(vm_options.count(), vm_options.arguments());
  if (error != nullptr) {
    Syslog::PrintErr("Setting VM flags failed: %s\n", error);
    free(error);
    Platform::Exit(kErrorExitCode);
  }

// Note: must read platform only *after* VM flags are parsed because
// they might affect how the platform is loaded.
#if !defined(DART_PRECOMPILED_RUNTIME)
  // Load vm_platform.dill for dart:* source support.
  dfe.Init();
  dfe.set_verbosity(Options::verbosity_level());
  if (script_name != nullptr) {
    uint8_t* application_kernel_buffer = nullptr;
    intptr_t application_kernel_buffer_size = 0;
    dfe.ReadScript(script_name, app_snapshot, &application_kernel_buffer,
                   &application_kernel_buffer_size);
    if (application_kernel_buffer != nullptr) {
      // Since we loaded the script anyway, save it.
      dfe.set_application_kernel_buffer(application_kernel_buffer,
                                        application_kernel_buffer_size);
      Options::dfe()->set_use_dfe();
    }
  }
#endif

  // Initialize the Dart VM.
  Dart_InitializeParams init_params;
  memset(&init_params, 0, sizeof(init_params));
  init_params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  init_params.vm_snapshot_data = vm_snapshot_data;
  init_params.vm_snapshot_instructions = vm_snapshot_instructions;
  init_params.create_group = CreateIsolateGroupAndSetup;
  init_params.initialize_isolate = OnIsolateInitialize;
  init_params.shutdown_isolate = OnIsolateShutdown;
  init_params.cleanup_isolate = DeleteIsolateData;
  init_params.cleanup_group = DeleteIsolateGroupData;
  init_params.file_open = DartUtils::OpenFile;
  init_params.file_read = DartUtils::ReadFile;
  init_params.file_write = DartUtils::WriteFile;
  init_params.file_close = DartUtils::CloseFile;
  init_params.entropy_source = DartUtils::EntropySource;
#if !defined(DART_PRECOMPILED_RUNTIME)
  init_params.start_kernel_isolate =
      dfe.UseDartFrontend() && dfe.CanUseDartFrontend();
#else
  init_params.start_kernel_isolate = false;
#endif
#if defined(DART_HOST_OS_FUCHSIA)
#if defined(DART_PRECOMPILED_RUNTIME)
  init_params.vmex_resource = ZX_HANDLE_INVALID;
#else
  init_params.vmex_resource = Platform::GetVMEXResource();
#endif
#endif

  error = Dart_Initialize(&init_params);
  if (error != nullptr) {
    dart::embedder::Cleanup();
    Syslog::PrintErr("VM initialization failed: %s\n", error);
    free(error);
    Platform::Exit(kErrorExitCode);
  }

  Dart_SetServiceStreamCallbacks(&ServiceStreamListenCallback,
                                 &ServiceStreamCancelCallback);
  Dart_SetFileModifiedCallback(&FileModifiedCallback);
  Dart_SetEmbedderInformationCallback(&EmbedderInformationCallback);
  bool should_run_user_program = true;
#if !defined(DART_PRECOMPILED_RUNTIME)
  if (script_name == nullptr &&
      Options::gen_snapshot_kind() != SnapshotKind::kNone) {
    Syslog::PrintErr(
        "Snapshot generation should be done using the 'dart compile' "
        "command.\n");
    Platform::Exit(kErrorExitCode);
  }
  if (!Options::resident() &&
      (Options::resident_compiler_info_file_path() != nullptr ||
       Options::resident_server_info_file_path() != nullptr)) {
    Syslog::PrintErr(
        "Error: the --resident flag must be passed whenever the "
        "--resident-compiler-info-file option is passed.\n");
    Platform::Exit(kErrorExitCode);
  }
#endif  // !defined(DART_PRECOMPILED_RUNTIME)

  if (should_run_user_program) {
    if (asset_resolution_base.get() == nullptr) {
      asset_resolution_base = ResolveSymlinks(script_name, &error);
      if (error != nullptr) {
        Syslog::PrintErr("%s", error);
        free(error);
        delete app_snapshot;
        Platform::Exit(kErrorExitCode);
      }
    }
    if (Options::gen_snapshot_kind() == kKernel) {
      CompileAndSaveKernel(script_name, package_config_override, &dart_options);
    } else {
      // Run the main isolate until we aren't told to restart.
      RunMainIsolate(script_name, asset_resolution_base.get(),
                     package_config_override, &dart_options);
    }
  }

  // Terminate process exit-code handler.
  Process::TerminateExitCodeHandler();

  error = Dart_Cleanup();
  if (error != nullptr) {
    Syslog::PrintErr("VM cleanup failed: %s\n", error);
    free(error);
  }
  const intptr_t global_exit_code = Process::GlobalExitCode();
  dart::embedder::Cleanup();

  delete app_snapshot;
  free(app_script_uri);
  asset_resolution_base.reset();

  // Free copied argument strings if converted.
  if (argv_converted) {
    for (int i = 0; i < argc; i++) {
      free(argv[i]);
    }
  }

  // Free environment if any.
  Options::Cleanup();

  Platform::Exit(global_exit_code);
}

}  // namespace bin
}  // namespace dart
