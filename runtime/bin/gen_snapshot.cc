// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Generate a snapshot file after loading all the scripts specified on the
// command line.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cstdarg>
#include <memory>

#include "bin/builtin.h"
#include "bin/console.h"
#include "bin/dartutils.h"
#include "bin/error_exit.h"
#include "bin/eventhandler.h"
#include "bin/exe_utils.h"
#include "bin/file.h"
#include "bin/loader.h"
#include "bin/options.h"
#include "bin/platform.h"
#include "bin/snapshot_utils.h"
#include "bin/thread.h"
#include "bin/utils.h"
#include "bin/vmservice_impl.h"

#include "include/dart_api.h"
#include "include/dart_tools_api.h"

#include "platform/globals.h"
#include "platform/growable_array.h"
#include "platform/hashmap.h"
#include "platform/syslog.h"
#include "platform/text_buffer.h"

namespace dart {
namespace bin {

#define CHECK_RESULT(result)                                                   \
  if (Dart_IsError(result)) {                                                  \
    intptr_t exit_code = 0;                                                    \
    Syslog::PrintErr("Error: %s\n", Dart_GetError(result));                    \
    if (Dart_IsCompilationError(result)) {                                     \
      exit_code = kCompilationErrorExitCode;                                   \
    } else if (Dart_IsApiError(result)) {                                      \
      exit_code = kApiErrorExitCode;                                           \
    } else {                                                                   \
      exit_code = kErrorExitCode;                                              \
    }                                                                          \
    Dart_ExitScope();                                                          \
    Dart_ShutdownIsolate();                                                    \
    exit(exit_code);                                                           \
  }

// The environment provided through the command line using -D options.
static dart::SimpleHashMap* environment = nullptr;

static bool ProcessEnvironmentOption(const char* arg,
                                     CommandLineOptions* vm_options) {
  return OptionProcessor::ProcessEnvironmentOption(arg, vm_options,
                                                   &environment);
}

// The core snapshot to use when creating isolates. Normally nullptr, but loaded
// from a file when creating AppJIT snapshots.
const uint8_t* isolate_snapshot_data = nullptr;
const uint8_t* isolate_snapshot_instructions = nullptr;

// Global state that indicates whether a snapshot is to be created and
// if so which file to write the snapshot into. The ordering of this list must
// match kSnapshotKindNames below.
enum SnapshotKind {
  kCore,
  kApp,
  kAppJIT,
  kAppAOTAssembly,
  kAppAOTElf,
  kAppAOTMachODylib,
  kVMAOTAssembly,
};
static SnapshotKind snapshot_kind = kCore;

// The ordering of this list must match the SnapshotKind enum above.
static const char* const kSnapshotKindNames[] = {
    // clang-format off
    "core",
    "app",
    "app-jit",
    "app-aot-assembly",
    "app-aot-elf",
    "app-aot-macho-dylib",
    "vm-aot-assembly",
    nullptr,
    // clang-format on
};

#define STRING_OPTIONS_LIST(V)                                                 \
  V(load_vm_snapshot_data, load_vm_snapshot_data_filename)                     \
  V(load_vm_snapshot_instructions, load_vm_snapshot_instructions_filename)     \
  V(load_isolate_snapshot_data, load_isolate_snapshot_data_filename)           \
  V(load_isolate_snapshot_instructions,                                        \
    load_isolate_snapshot_instructions_filename)                               \
  V(vm_snapshot_data, vm_snapshot_data_filename)                               \
  V(vm_snapshot_instructions, vm_snapshot_instructions_filename)               \
  V(isolate_snapshot_data, isolate_snapshot_data_filename)                     \
  V(isolate_snapshot_instructions, isolate_snapshot_instructions_filename)     \
  V(blobs_container_filename, blobs_container_filename)                        \
  V(assembly, assembly_filename)                                               \
  V(elf, elf_filename)                                                         \
  V(macho, macho_filename)                                                     \
  V(loading_unit_manifest, loading_unit_manifest_filename)                     \
  V(save_debugging_info, debugging_info_filename)                              \
  V(save_obfuscation_map, obfuscation_map_filename)

#define BOOL_OPTIONS_LIST(V)                                                   \
  V(compile_all, compile_all)                                                  \
  V(help, help)                                                                \
  V(obfuscate, obfuscate)                                                      \
  V(strip, strip)                                                              \
  V(verbose, verbose)                                                          \
  V(version, version)

#define STRING_OPTION_DEFINITION(flag, variable)                               \
  static const char* variable = nullptr;                                       \
  DEFINE_STRING_OPTION(flag, variable)
STRING_OPTIONS_LIST(STRING_OPTION_DEFINITION)
#undef STRING_OPTION_DEFINITION

#define BOOL_OPTION_DEFINITION(flag, variable)                                 \
  static bool variable = false;                                                \
  DEFINE_BOOL_OPTION(flag, variable)
BOOL_OPTIONS_LIST(BOOL_OPTION_DEFINITION)
#undef BOOL_OPTION_DEFINITION

DEFINE_ENUM_OPTION(snapshot_kind, SnapshotKind, snapshot_kind);
DEFINE_CB_OPTION(ProcessEnvironmentOption);

static bool IsSnapshottingForPrecompilation() {
  return (snapshot_kind == kAppAOTAssembly) || (snapshot_kind == kAppAOTElf) ||
         (snapshot_kind == kAppAOTMachODylib) ||
         (snapshot_kind == kVMAOTAssembly);
}

// clang-format off
static void PrintUsage() {
  Syslog::PrintErr(
"Usage: gen_snapshot [<vm-flags>] [<options>] <dart-kernel-file>             \n"
"                                                                            \n"
"Common options:                                                             \n"
"--help                                                                      \n"
"  Display this message (add --verbose for information about all VM options).\n"
"--version                                                                   \n"
"  Print the SDK version.                                                    \n"
"                                                                            \n"
"To create a core snapshot:                                                  \n"
"--snapshot_kind=core                                                        \n"
"--vm_snapshot_data=<output-file>                                            \n"
"--isolate_snapshot_data=<output-file>                                       \n"
"<dart-kernel-file>                                                          \n"
"                                                                            \n"
"To create an AOT application snapshot as assembly suitable for compilation  \n"
"as a static or dynamic library:                                             \n"
"--snapshot_kind=app-aot-assembly                                            \n"
"--assembly=<output-file>                                                    \n"
"[--strip]                                                                   \n"
"[--obfuscate]                                                               \n"
"[--save-debugging-info=<debug-filename>]                                    \n"
"[--save-obfuscation-map=<map-filename>]                                     \n"
"<dart-kernel-file>                                                          \n"
"                                                                            \n"
"To create an AOT application snapshot as an ELF shared library:             \n"
"--snapshot_kind=app-aot-elf                                                 \n"
"--elf=<output-file>                                                         \n"
"[--strip]                                                                   \n"
"[--obfuscate]                                                               \n"
"[--save-debugging-info=<debug-filename>]                                    \n"
"[--save-obfuscation-map=<map-filename>]                                     \n"
"<dart-kernel-file>                                                          \n"
"                                                                            \n"
"To create an AOT application snapshot as an Mach-O dynamic library (dylib): \n"
"--snapshot_kind=app-aot-macho-dylib                                         \n"
"--macho=<output-file>                                                       \n"
"[--strip]                                                                   \n"
"[--obfuscate]                                                               \n"
"[--save-debugging-info=<debug-filename>]                                    \n"
"[--save-obfuscation-map=<map-filename>]                                     \n"
"<dart-kernel-file>                                                          \n"
"                                                                            \n"
"AOT snapshots can be obfuscated: that is all identifiers will be renamed    \n"
"during compilation. This mode is enabled with --obfuscate flag. Mapping     \n"
"between original and obfuscated names can be serialized as a JSON array     \n"
"using --save-obfuscation-map=<filename> option. See dartbug.com/30524       \n"
"for implementation details and limitations of the obfuscation pass.         \n"
"                                                                            \n"
"\n");
  if (verbose) {
    Syslog::PrintErr(
"The following options are only used for VM development and may\n"
"be changed in any future version:\n");
    const char* print_flags = "--print_flags";
    char* error = Dart_SetVMFlags(1, &print_flags);
    ASSERT(error == nullptr);
  }
}
// clang-format on

// Parse out the command line arguments. Returns -1 if the arguments
// are incorrect, 0 otherwise.
static int ParseArguments(int argc,
                          char** argv,
                          CommandLineOptions* vm_options,
                          CommandLineOptions* inputs) {
  // Skip the binary name.
  int i = 1;

  // Parse out the vm options.
  while ((i < argc) && OptionProcessor::IsValidShortFlag(argv[i])) {
    if (OptionProcessor::TryProcess(argv[i], vm_options)) {
      i += 1;
      continue;
    }
    vm_options->AddArgument(argv[i]);
    i += 1;
  }

  // Parse out the kernel inputs.
  while (i < argc) {
    inputs->AddArgument(argv[i]);
    i++;
  }

  if (help) {
    PrintUsage();
    Platform::Exit(0);
  } else if (version) {
    Syslog::PrintErr("Dart SDK version: %s\n", Dart_VersionString());
    Platform::Exit(0);
  }

  // Verify consistency of arguments.
  if (inputs->count() < 1) {
    Syslog::PrintErr("At least one input is required\n");
    return -1;
  }

  switch (snapshot_kind) {
    case kCore: {
      if ((vm_snapshot_data_filename == nullptr) ||
          (isolate_snapshot_data_filename == nullptr)) {
        Syslog::PrintErr(
            "Building a core snapshot requires specifying output files for "
            "--vm_snapshot_data and --isolate_snapshot_data.\n\n");
        return -1;
      }
      break;
    }
    case kApp:
    case kAppJIT: {
      if ((load_vm_snapshot_data_filename == nullptr) ||
          (isolate_snapshot_data_filename == nullptr) ||
          (isolate_snapshot_instructions_filename == nullptr)) {
        Syslog::PrintErr(
            "Building an app JIT snapshot requires specifying input files for "
            "--load_vm_snapshot_data and --load_vm_snapshot_instructions, an "
            " output file for --isolate_snapshot_data, and an output "
            "file for --isolate_snapshot_instructions.\n\n");
        return -1;
      }
      break;
    }
    case kAppAOTElf: {
      if (elf_filename == nullptr) {
        Syslog::PrintErr(
            "Building an AOT snapshot as ELF requires specifying "
            "an output file for --elf.\n\n");
        return -1;
      }
      break;
    }
    case kAppAOTMachODylib: {
      if (macho_filename == nullptr) {
        Syslog::PrintErr(
            "Building an AOT snapshot as a Mach-O dynamic library requires "
            " specifying an output file for --macho.\n\n");
        return -1;
      }
      break;
    }
    case kAppAOTAssembly:
    case kVMAOTAssembly: {
      if (assembly_filename == nullptr) {
        Syslog::PrintErr(
            "Building an AOT snapshot as assembly requires specifying "
            "an output file for --assembly.\n\n");
        return -1;
      }
#if defined(DART_TARGET_OS_WINDOWS)
      if (debugging_info_filename != nullptr) {
        // TODO(https://github.com/dart-lang/sdk/issues/60812): Support PDB.
        Syslog::PrintErr(
            "warning: ignoring --save-debugging-info when "
            "generating assembly for Windows.\n\n");
      }
#endif
      break;
    }
  }

  if (!obfuscate && obfuscation_map_filename != nullptr) {
    Syslog::PrintErr(
        "--save-obfuscation_map=<...> should only be specified when "
        "obfuscation is enabled by the --obfuscate flag.\n\n");
    return -1;
  }

  if (!IsSnapshottingForPrecompilation()) {
    if (obfuscate) {
      Syslog::PrintErr(
          "Obfuscation can only be enabled when building an AOT snapshot.\n\n");
      return -1;
    }

    if (debugging_info_filename != nullptr) {
      Syslog::PrintErr(
          "--save-debugging-info=<...> can only be enabled when building an "
          "AOT snapshot.\n\n");
      return -1;
    }

    if (strip) {
      Syslog::PrintErr(
          "Stripping can only be enabled when building an AOT snapshot.\n\n");
      return -1;
    }
  }

  return 0;
}

PRINTF_ATTRIBUTE(1, 2) static void PrintErrAndExit(const char* format, ...) {
  va_list args;
  va_start(args, format);
  Syslog::VPrintErr(format, args);
  va_end(args);

  // ExitScope and ShutdownIsolate will abort() if there is no current isolate.
  if (Dart_CurrentIsolate() != nullptr) {
    Dart_ExitScope();
    Dart_ShutdownIsolate();
  }
  exit(kErrorExitCode);
}

static File* OpenFile(const char* filename) {
  File* file = File::Open(nullptr, filename, File::kWriteTruncate);
  if (file == nullptr) {
    PrintErrAndExit("Error: Unable to write file: %s\n\n", filename);
  }
  return file;
}

static void WriteFile(const char* filename,
                      const uint8_t* buffer,
                      const intptr_t size) {
  File* file = OpenFile(filename);
  RefCntReleaseScope<File> rs(file);
  if (!file->WriteFully(buffer, size)) {
    PrintErrAndExit("Error: Unable to write file: %s\n\n", filename);
  }
}

static void ReadFile(const char* filename, uint8_t** buffer, intptr_t* size) {
  File* file = File::Open(nullptr, filename, File::kRead);
  if (file == nullptr) {
    PrintErrAndExit("Error: Unable to read file: %s\n", filename);
  }
  RefCntReleaseScope<File> rs(file);
  *size = file->Length();
  *buffer = reinterpret_cast<uint8_t*>(malloc(*size));
  if (!file->ReadFully(*buffer, *size)) {
    PrintErrAndExit("Error: Unable to read file: %s\n", filename);
  }
}

static void MallocFinalizer(void* isolate_callback_data, void* peer) {
  free(peer);
}

static void MaybeLoadExtraInputs(const CommandLineOptions& inputs) {
  for (intptr_t i = 1; i < inputs.count(); i++) {
    uint8_t* buffer = nullptr;
    intptr_t size = 0;
    ReadFile(inputs.GetArgument(i), &buffer, &size);
    Dart_Handle td = Dart_NewExternalTypedDataWithFinalizer(
        Dart_TypedData_kUint8, buffer, size, buffer, size, MallocFinalizer);
    CHECK_RESULT(td);
    Dart_Handle result = Dart_LoadLibrary(td);
    CHECK_RESULT(result);
  }
}

static void MaybeLoadCode() {
  if (compile_all && (snapshot_kind == kAppJIT)) {
    Dart_Handle result = Dart_CompileAll();
    CHECK_RESULT(result);
  }
}

static void CreateAndWriteCoreSnapshot() {
  ASSERT(snapshot_kind == kCore);
  ASSERT(vm_snapshot_data_filename != nullptr);
  ASSERT(isolate_snapshot_data_filename != nullptr);

  Dart_Handle result;
  uint8_t* vm_snapshot_data_buffer = nullptr;
  intptr_t vm_snapshot_data_size = 0;
  uint8_t* isolate_snapshot_data_buffer = nullptr;
  intptr_t isolate_snapshot_data_size = 0;

  // First create a snapshot.
  result = Dart_CreateSnapshot(&vm_snapshot_data_buffer, &vm_snapshot_data_size,
                               &isolate_snapshot_data_buffer,
                               &isolate_snapshot_data_size,
                               /*is_core=*/true);
  CHECK_RESULT(result);

  // Now write the vm isolate and isolate snapshots out to the
  // specified file and exit.
  WriteFile(vm_snapshot_data_filename, vm_snapshot_data_buffer,
            vm_snapshot_data_size);
  if (vm_snapshot_instructions_filename != nullptr) {
    // Create empty file for the convenience of build systems.
    WriteFile(vm_snapshot_instructions_filename, nullptr, 0);
  }
  WriteFile(isolate_snapshot_data_filename, isolate_snapshot_data_buffer,
            isolate_snapshot_data_size);
  if (isolate_snapshot_instructions_filename != nullptr) {
    // Create empty file for the convenience of build systems.
    WriteFile(isolate_snapshot_instructions_filename, nullptr, 0);
  }
}

static std::unique_ptr<MappedMemory> MapFile(const char* filename,
                                             File::MapType type,
                                             const uint8_t** buffer) {
  File* file = File::Open(nullptr, filename, File::kRead);
  if (file == nullptr) {
    Syslog::PrintErr("Failed to open: %s\n", filename);
    exit(kErrorExitCode);
  }
  RefCntReleaseScope<File> rs(file);
  intptr_t length = file->Length();
  if (length == 0) {
    // Can't map an empty file.
    *buffer = nullptr;
    return nullptr;
  }
  MappedMemory* mapping = file->Map(type, 0, length);
  if (mapping == nullptr) {
    Syslog::PrintErr("Failed to read: %s\n", filename);
    exit(kErrorExitCode);
  }
  *buffer = reinterpret_cast<const uint8_t*>(mapping->address());
  return std::unique_ptr<MappedMemory>(mapping);
}

static void CreateAndWriteAppSnapshot() {
  ASSERT(snapshot_kind == kApp);
  ASSERT(isolate_snapshot_data_filename != nullptr);

  Dart_Handle result;
  uint8_t* isolate_snapshot_data_buffer = nullptr;
  intptr_t isolate_snapshot_data_size = 0;

  result = Dart_CreateSnapshot(nullptr, nullptr, &isolate_snapshot_data_buffer,
                               &isolate_snapshot_data_size, /*is_core=*/false);
  CHECK_RESULT(result);

  WriteFile(isolate_snapshot_data_filename, isolate_snapshot_data_buffer,
            isolate_snapshot_data_size);
  if (isolate_snapshot_instructions_filename != nullptr) {
    // Create empty file for the convenience of build systems.
    WriteFile(isolate_snapshot_instructions_filename, nullptr, 0);
  }
}

static void CreateAndWriteAppJITSnapshot() {
  ASSERT(snapshot_kind == kAppJIT);
  ASSERT(isolate_snapshot_data_filename != nullptr);
  ASSERT(isolate_snapshot_instructions_filename != nullptr);

  Dart_Handle result;
  uint8_t* isolate_snapshot_data_buffer = nullptr;
  intptr_t isolate_snapshot_data_size = 0;
  uint8_t* isolate_snapshot_instructions_buffer = nullptr;
  intptr_t isolate_snapshot_instructions_size = 0;

  result = Dart_CreateAppJITSnapshotAsBlobs(
      &isolate_snapshot_data_buffer, &isolate_snapshot_data_size,
      &isolate_snapshot_instructions_buffer,
      &isolate_snapshot_instructions_size);
  CHECK_RESULT(result);

  WriteFile(isolate_snapshot_data_filename, isolate_snapshot_data_buffer,
            isolate_snapshot_data_size);
  WriteFile(isolate_snapshot_instructions_filename,
            isolate_snapshot_instructions_buffer,
            isolate_snapshot_instructions_size);
}

static void StreamingWriteCallback(void* callback_data,
                                   const uint8_t* buffer,
                                   intptr_t size) {
  File* file = reinterpret_cast<File*>(callback_data);
  if ((file != nullptr) && !file->WriteFully(buffer, size)) {
    PrintErrAndExit("Error: Unable to write snapshot file\n\n");
  }
}

static void StreamingCloseCallback(void* callback_data) {
  File* file = reinterpret_cast<File*>(callback_data);
  file->Release();
}

static File* OpenLoadingUnitManifest() {
  File* manifest_file = OpenFile(loading_unit_manifest_filename);
  if (!manifest_file->Print("{ \"loadingUnits\": [\n ")) {
    PrintErrAndExit("Error: Unable to write file: %s\n\n",
                    loading_unit_manifest_filename);
  }
  return manifest_file;
}

static void WriteLoadingUnitManifest(File* manifest_file,
                                     intptr_t id,
                                     const char* path,
                                     const char* debug_path = nullptr) {
  TextBuffer line(128);
  if (id != 1) {
    line.AddString(",\n ");
  }
  line.Printf("{\n  \"id\": %" Pd ",\n  \"path\": \"", id);
  line.AddEscapedString(path);
  if (debug_path != nullptr) {
    line.Printf("\",\n  \"debugPath\": \"");
    line.AddEscapedString(debug_path);
  }
  line.AddString("\",\n  \"libraries\": [\n   ");
  Dart_Handle uris = Dart_LoadingUnitLibraryUris(id);
  CHECK_RESULT(uris);
  intptr_t length;
  CHECK_RESULT(Dart_ListLength(uris, &length));
  for (intptr_t i = 0; i < length; i++) {
    const char* uri;
    CHECK_RESULT(Dart_StringToCString(Dart_ListGetAt(uris, i), &uri));
    if (i != 0) {
      line.AddString(",\n   ");
    }
    line.AddString("\"");
    line.AddEscapedString(uri);
    line.AddString("\"");
  }
  line.AddString("\n  ]}");
  if (!manifest_file->Print("%s", line.buffer())) {
    PrintErrAndExit("Error: Unable to write file: %s\n\n",
                    loading_unit_manifest_filename);
  }
}

static void CloseLoadingUnitManifest(File* manifest_file) {
  if (!manifest_file->Print("]}\n")) {
    PrintErrAndExit("Error: Unable to write file: %s\n\n",
                    loading_unit_manifest_filename);
  }
  manifest_file->Release();
}

static void NextLoadingUnit(void* callback_data,
                            intptr_t loading_unit_id,
                            void** write_callback_data,
                            void** write_debug_callback_data,
                            const char* main_filename,
                            const char* suffix) {
  char* filename = loading_unit_id == 1
                       ? Utils::StrDup(main_filename)
                       : Utils::SCreate("%s-%" Pd ".part.%s", main_filename,
                                        loading_unit_id, suffix);
  File* file = OpenFile(filename);
  *write_callback_data = file;

  char* debug_filename = nullptr;
  if (debugging_info_filename != nullptr) {
    debug_filename =
        loading_unit_id == 1
            ? Utils::StrDup(debugging_info_filename)
            : Utils::SCreate("%s-%" Pd ".part.so", debugging_info_filename,
                             loading_unit_id);
    File* debug_file = OpenFile(debug_filename);
    *write_debug_callback_data = debug_file;
  }

  WriteLoadingUnitManifest(reinterpret_cast<File*>(callback_data),
                           loading_unit_id, filename, debug_filename);
  free(debug_filename);

  free(filename);
}

static void NextAsmCallback(void* callback_data,
                            intptr_t loading_unit_id,
                            void** write_callback_data,
                            void** write_debug_callback_data) {
  NextLoadingUnit(callback_data, loading_unit_id, write_callback_data,
                  write_debug_callback_data, assembly_filename, "S");
}

static void NextElfCallback(void* callback_data,
                            intptr_t loading_unit_id,
                            void** write_callback_data,
                            void** write_debug_callback_data) {
  NextLoadingUnit(callback_data, loading_unit_id, write_callback_data,
                  write_debug_callback_data, elf_filename, "so");
}

static void CreateAndWritePrecompiledSnapshot() {
  ASSERT(IsSnapshottingForPrecompilation());

  if (snapshot_kind == kVMAOTAssembly) {
    File* file = OpenFile(assembly_filename);
    RefCntReleaseScope<File> rs(file);
    Dart_Handle result =
        Dart_CreateVMAOTSnapshotAsAssembly(StreamingWriteCallback, file);
    CHECK_RESULT(result);
    return;
  }

  Dart_AotBinaryFormat format;
  const char* kind_str = nullptr;
  const char* filename = nullptr;
  // Default to the assembly ones just to avoid having to type-specify here.
  auto* next_callback = NextAsmCallback;
  auto* create_multiple_callback = Dart_CreateAppAOTSnapshotAsAssemblies;
  switch (snapshot_kind) {
    case kAppAOTAssembly:
      kind_str = "assembly code";
      filename = assembly_filename;
      format = Dart_AotBinaryFormat_Assembly;
      break;
    case kAppAOTElf:
      kind_str = "ELF library";
      filename = elf_filename;
      format = Dart_AotBinaryFormat_Elf;
      next_callback = NextElfCallback;
      create_multiple_callback = Dart_CreateAppAOTSnapshotAsElfs;
      break;
    case kAppAOTMachODylib:
      kind_str = "MachO dynamic library";
      filename = macho_filename;
      format = Dart_AotBinaryFormat_MachO_Dylib;
      // Not currently implemented.
      next_callback = nullptr;
      create_multiple_callback = nullptr;
      break;
    default:
      UNREACHABLE();
  }
  ASSERT(kind_str != nullptr);
  ASSERT(filename != nullptr);

  // Precompile with specified embedder entry points
  Dart_Handle result = Dart_Precompile();
  CHECK_RESULT(result);

  if (strip && (debugging_info_filename == nullptr)) {
    Syslog::PrintErr(
        "Warning: Generating %s without DWARF debugging"
        " information.\n",
        kind_str);
  }

  char* identifier = Utils::Basename(filename);

  // Create a precompiled snapshot.
  if (loading_unit_manifest_filename == nullptr) {
    File* file = OpenFile(filename);
    RefCntReleaseScope<File> rs(file);
    File* debug_file = nullptr;
    if (debugging_info_filename != nullptr) {
      debug_file = OpenFile(debugging_info_filename);
    }
    result = Dart_CreateAppAOTSnapshotAsBinary(format, StreamingWriteCallback,
                                               file, strip, debug_file,
                                               identifier, filename);
    if (debug_file != nullptr) debug_file->Release();
    if (identifier != nullptr) {
      free(identifier);
      identifier = nullptr;
    }
    CHECK_RESULT(result);
  } else {
    ASSERT(create_multiple_callback != nullptr);
    ASSERT(next_callback != nullptr);
    File* manifest_file = OpenLoadingUnitManifest();
    result = create_multiple_callback(next_callback, manifest_file, strip,
                                      StreamingWriteCallback,
                                      StreamingCloseCallback);
    if (identifier != nullptr) {
      free(identifier);
      identifier = nullptr;
    }
    CHECK_RESULT(result);
    CloseLoadingUnitManifest(manifest_file);
  }

  if (obfuscate && !strip) {
    Syslog::PrintErr(
        "Warning: The generated %s contains unobfuscated DWARF "
        "debugging information.\n"
        "         To avoid this, use --strip to remove it.\n",
        kind_str);
  }

  // Serialize obfuscation map if requested.
  if (obfuscation_map_filename != nullptr) {
    ASSERT(obfuscate);
    uint8_t* buffer = nullptr;
    intptr_t size = 0;
    result = Dart_GetObfuscationMap(&buffer, &size);
    CHECK_RESULT(result);
    WriteFile(obfuscation_map_filename, buffer, size);
  }
}

static int CreateIsolateAndSnapshot(const CommandLineOptions& inputs) {
  uint8_t* kernel_buffer = nullptr;
  intptr_t kernel_buffer_size = 0;
  ReadFile(inputs.GetArgument(0), &kernel_buffer, &kernel_buffer_size);

  Dart_IsolateFlags isolate_flags;
  Dart_IsolateFlagsInitialize(&isolate_flags);
  if (IsSnapshottingForPrecompilation()) {
    isolate_flags.obfuscate = obfuscate;
  }

  auto isolate_group_data = std::unique_ptr<IsolateGroupData>(
      new IsolateGroupData(nullptr, nullptr, nullptr, nullptr, false));
  Dart_Isolate isolate;
  char* error = nullptr;

  bool loading_kernel_failed = false;
  if (isolate_snapshot_data == nullptr) {
    // We need to capture the vmservice library in the core snapshot, so load it
    // in the main isolate as well.
    isolate_flags.load_vmservice_library = true;
    isolate = Dart_CreateIsolateGroupFromKernel(
        nullptr, nullptr, kernel_buffer, kernel_buffer_size, &isolate_flags,
        isolate_group_data.get(), /*isolate_data=*/nullptr, &error);
    loading_kernel_failed = (isolate == nullptr);
  } else {
    isolate = Dart_CreateIsolateGroup(nullptr, nullptr, isolate_snapshot_data,
                                      isolate_snapshot_instructions,
                                      &isolate_flags, isolate_group_data.get(),
                                      /*isolate_data=*/nullptr, &error);
  }
  if (isolate == nullptr) {
    Syslog::PrintErr("%s\n", error);
    free(error);
    free(kernel_buffer);
    // The only real reason when `gen_snapshot` fails to create an isolate from
    // a valid kernel file is if loading the kernel results in a "compile-time"
    // error.
    //
    // There are other possible reasons, like memory allocation failures, but
    // those are very uncommon.
    //
    // The Dart API doesn't allow us to distinguish the different error cases,
    // so we'll use [kCompilationErrorExitCode] for failed kernel loading, since
    // a compile-time error is the most probable cause.
    return loading_kernel_failed ? kCompilationErrorExitCode : kErrorExitCode;
  }

  Dart_EnterScope();
  Dart_Handle result =
      Dart_SetEnvironmentCallback(DartUtils::EnvironmentCallback);
  CHECK_RESULT(result);

  // The root library has to be set to generate AOT snapshots, and sometimes we
  // set one for the core snapshot too.
  // If the input dill file has a root library, then Dart_LoadScript will
  // ignore this dummy uri and set the root library to the one reported in
  // the dill file. Since dill files are not dart script files,
  // trying to resolve the root library URI based on the dill file name
  // would not help.
  //
  // If the input dill file does not have a root library, then
  // Dart_LoadScript will error.
  //
  // TODO(kernel): Dart_CreateIsolateGroupFromKernel should respect the root
  // library in the kernel file, though this requires auditing the other
  // loading paths in the embedders that had to work around this.
  result = Dart_SetRootLibrary(
      Dart_LoadLibraryFromKernel(kernel_buffer, kernel_buffer_size));
  CHECK_RESULT(result);

  MaybeLoadExtraInputs(inputs);

  MaybeLoadCode();

  switch (snapshot_kind) {
    case kCore:
      CreateAndWriteCoreSnapshot();
      break;
    case kApp:
      CreateAndWriteAppSnapshot();
      break;
    case kAppJIT:
      CreateAndWriteAppJITSnapshot();
      break;
    case kAppAOTAssembly:
    case kAppAOTElf:
    case kAppAOTMachODylib:
    case kVMAOTAssembly:
      CreateAndWritePrecompiledSnapshot();
      break;
    default:
      UNREACHABLE();
  }

  Dart_ExitScope();
  Dart_ShutdownIsolate();

  free(kernel_buffer);
  return 0;
}

int main(int argc, char** argv) {
#if !defined(DART_HOST_OS_WINDOWS)
  // Very early so any crashes during startup can also be symbolized.
  EXEUtils::LoadDartProfilerSymbols(argv[0]);
#endif

  const int EXTRA_VM_ARGUMENTS = 7;
  CommandLineOptions vm_options(argc + EXTRA_VM_ARGUMENTS);
  CommandLineOptions inputs(argc);

  // When running from the command line we assume that we are optimizing for
  // throughput, and therefore use a larger new gen semi space size and a faster
  // new gen growth factor unless others have been specified.
  if (kWordSize <= 4) {
    vm_options.AddArgument("--new_gen_semi_max_size=16");
  } else {
    vm_options.AddArgument("--new_gen_semi_max_size=32");
  }
  vm_options.AddArgument("--new_gen_growth_factor=4");
  vm_options.AddArgument("--deterministic");

  // Parse command line arguments.
  if (ParseArguments(argc, argv, &vm_options, &inputs) < 0) {
    PrintUsage();
    return kErrorExitCode;
  }
  DartUtils::SetEnvironment(environment);

  if (!Platform::Initialize()) {
    Syslog::PrintErr("Initialization failed\n");
    return kErrorExitCode;
  }
  Console::SaveConfig();
  Loader::InitOnce();
  DartUtils::SetOriginalWorkingDirectory();
  // Start event handler.
  TimerUtils::InitOnce();
  EventHandler::Start();

  if (IsSnapshottingForPrecompilation()) {
    vm_options.AddArgument("--precompilation");
    // AOT snapshot can be deployed to another machine,
    // so generated code should not depend on the CPU features
    // of the system where snapshot was generated.
    vm_options.AddArgument("--target_unknown_cpu");
  } else if (snapshot_kind == kAppJIT) {
    // App-jit snapshot can be deployed to another machine,
    // so generated code should not depend on the CPU features
    // of the system where snapshot was generated.
    vm_options.AddArgument("--target_unknown_cpu");
#if !defined(TARGET_ARCH_IA32)
    vm_options.AddArgument("--link_natives_lazily");
#endif
  }

  char* error = Dart_SetVMFlags(vm_options.count(), vm_options.arguments());
  if (error != nullptr) {
    Syslog::PrintErr("Setting VM flags failed: %s\n", error);
    free(error);
    return kErrorExitCode;
  }

  Dart_InitializeParams init_params;
  memset(&init_params, 0, sizeof(init_params));
  init_params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  init_params.file_open = DartUtils::OpenFile;
  init_params.file_read = DartUtils::ReadFile;
  init_params.file_write = DartUtils::WriteFile;
  init_params.file_close = DartUtils::CloseFile;
  init_params.entropy_source = DartUtils::EntropySource;
  init_params.start_kernel_isolate = false;
#if defined(DART_HOST_OS_FUCHSIA)
  init_params.vmex_resource = Platform::GetVMEXResource();
#endif

  std::unique_ptr<MappedMemory> mapped_vm_snapshot_data;
  std::unique_ptr<MappedMemory> mapped_vm_snapshot_instructions;
  std::unique_ptr<MappedMemory> mapped_isolate_snapshot_data;
  std::unique_ptr<MappedMemory> mapped_isolate_snapshot_instructions;
  if (load_vm_snapshot_data_filename != nullptr) {
    mapped_vm_snapshot_data =
        MapFile(load_vm_snapshot_data_filename, File::kReadOnly,
                &init_params.vm_snapshot_data);
  }
  if (load_vm_snapshot_instructions_filename != nullptr) {
    mapped_vm_snapshot_instructions =
        MapFile(load_vm_snapshot_instructions_filename, File::kReadExecute,
                &init_params.vm_snapshot_instructions);
  }
  if (load_isolate_snapshot_data_filename != nullptr) {
    mapped_isolate_snapshot_data =
        MapFile(load_isolate_snapshot_data_filename, File::kReadOnly,
                &isolate_snapshot_data);
  }
  if (load_isolate_snapshot_instructions_filename != nullptr) {
    mapped_isolate_snapshot_instructions =
        MapFile(load_isolate_snapshot_instructions_filename, File::kReadExecute,
                &isolate_snapshot_instructions);
  }

  error = Dart_Initialize(&init_params);
  if (error != nullptr) {
    Syslog::PrintErr("VM initialization failed: %s\n", error);
    free(error);
    return kErrorExitCode;
  }

  int result = CreateIsolateAndSnapshot(inputs);
  if (result != 0) {
    return result;
  }

  error = Dart_Cleanup();
  if (error != nullptr) {
    Syslog::PrintErr("VM cleanup failed: %s\n", error);
    free(error);
  }
  EventHandler::Stop();
  return 0;
}

}  // namespace bin
}  // namespace dart

int main(int argc, char** argv) {
  return dart::bin::main(argc, argv);
}
