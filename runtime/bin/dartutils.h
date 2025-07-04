// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_BIN_DARTUTILS_H_
#define RUNTIME_BIN_DARTUTILS_H_

#include "bin/isolate_data.h"
#include "include/dart_api.h"
#include "include/dart_native_api.h"
#include "platform/assert.h"
#include "platform/globals.h"
#include "platform/hashmap.h"
#include "platform/syslog.h"

namespace dart {
namespace bin {

// Forward declarations.
class File;
class OSError;

/* Handles error handles returned from Dart API functions.  If a value
 * is an error, uses Dart_PropagateError to throw it to the enclosing
 * Dart activation.  Otherwise, returns the original handle.
 *
 * This function can be used to wrap most API functions, but API
 * functions can also be nested without this error check, since all
 * API functions return any error handles passed in as arguments, unchanged.
 */
static inline Dart_Handle ThrowIfError(Dart_Handle handle) {
  if (Dart_IsError(handle)) {
    Dart_PropagateError(handle);
  }
  return handle;
}

static inline void* GetHashmapKeyFromString(char* key) {
  return reinterpret_cast<void*>(key);
}

class CommandLineOptions {
 public:
  explicit CommandLineOptions(int max_count)
      : count_(0), max_count_(max_count), arguments_(nullptr) {
    const int kWordSize = sizeof(intptr_t);
    arguments_ = reinterpret_cast<const char**>(malloc(max_count * kWordSize));
    if (arguments_ == nullptr) {
      max_count_ = 0;
    }
  }
  ~CommandLineOptions() {
    free(arguments_);
    count_ = 0;
    max_count_ = 0;
    arguments_ = nullptr;
  }

  void Reset() { count_ = 0; }

  int count() const { return count_; }
  int max_count() const { return max_count_; }
  const char** arguments() const { return arguments_; }

  const char* GetArgument(int index) const {
    return (index >= 0 && index < count_) ? arguments_[index] : nullptr;
  }
  void AddArgument(const char* argument) {
    if (count_ < max_count_) {
      arguments_[count_] = argument;
      count_ += 1;
    } else {
      abort();  // We should never get into this situation.
    }
  }

  void AddArguments(const char** argv, int argc) {
    if (count_ + argc >= max_count_) {
      abort();  // We should never get into this situation.
    }
    for (int i = 0; i < argc; ++i) {
      arguments_[count_++] = argv[i];
    }
  }

  Dart_Handle CreateRuntimeOptions();

#if defined(DEBUG)
  void DebugPrint() const {
    for (int i = 0; i < count(); ++i) {
      Syslog::PrintErr("[%d] = %s\n", i, GetArgument(i));
    }
  }
#endif  // defined(DEBUG)

  void operator delete(void* pointer) { abort(); }

 private:
  void* operator new(size_t size);

  int count_;
  int max_count_;
  const char** arguments_;

  DISALLOW_COPY_AND_ASSIGN(CommandLineOptions);
};

class DartUtils {
 public:
  // Returns the integer value of a Dart object. If the object is not
  // an integer value an API error is propagated.
  static int64_t GetIntegerValue(Dart_Handle value_obj);
  // Returns the integer value of a Dart object. If the object is not
  // an integer value or outside the requested range an API error is
  // propagated.
  static int64_t GetInt64ValueCheckRange(Dart_Handle value_obj,
                                         int64_t lower,
                                         int64_t upper);
  // Returns the intptr_t value of a Dart object. If the object is not
  // an integer value or the value is outside the intptr_t range an
  // API error is propagated.
  static intptr_t GetIntptrValue(Dart_Handle value_obj);
  // Checks that the value object is an integer object that fits in a
  // signed 64-bit integer. If it is, the value is returned in the
  // value out parameter and true is returned. Otherwise, false is
  // returned.
  static bool GetInt64Value(Dart_Handle value_obj, int64_t* value);
  // Returns the string value of a Dart object. If the object is not
  // a string value an API error is propagated.
  static const char* GetStringValue(Dart_Handle str_obj);
  // Returns the boolean value of a Dart object. If the object is not
  // a boolean value an API error is propagated.
  static bool GetBooleanValue(Dart_Handle bool_obj);
  // Returns the boolean value of the argument at index. If the argument
  // is not a boolean value an API error is propagated.
  static bool GetNativeBooleanArgument(Dart_NativeArguments args,
                                       intptr_t index);
  // Returns the integer value of the argument at index. If the argument
  // is not an integer value an API error is propagated.
  static int64_t GetNativeIntegerArgument(Dart_NativeArguments args,
                                          intptr_t index);
  // Returns the intptr_t value of the argument at index. If the argument
  // is not an integer value or the value is outside the intptr_t range an
  // API error is propagated.
  static intptr_t GetNativeIntptrArgument(Dart_NativeArguments args,
                                          intptr_t index);
  // Returns the string value of the argument at index. If the argument
  // is not a string value an API error is propagated.
  static const char* GetNativeStringArgument(Dart_NativeArguments args,
                                             intptr_t index);
  static const char* GetNativeTypedDataArgument(Dart_NativeArguments args,
                                                intptr_t index);
  static Dart_Handle SetIntegerField(Dart_Handle handle,
                                     const char* name,
                                     int64_t val);
  static Dart_Handle SetStringField(Dart_Handle handle,
                                    const char* name,
                                    const char* val);
  static bool IsDartSchemeURL(const char* url_name);
  static bool IsDartIOLibURL(const char* url_name);
  static bool IsDartCLILibURL(const char* url_name);
  static bool IsDartHttpLibURL(const char* url_name);
  static bool IsDartBuiltinLibURL(const char* url_name);

  // Returns directory name including the last path separator.
  //
  // The return value must be `free`d by the caller.
  static char* DirName(const char* url);
  static void* MapExecutable(const char* name, intptr_t* file_len);
  static void* OpenFile(const char* name, bool write);
  static void* OpenFileUri(const char* uri, bool write);
  static void ReadFile(uint8_t** data, intptr_t* file_len, void* stream);
  static void WriteFile(const void* buffer, intptr_t num_bytes, void* stream);
  static void CloseFile(void* stream);
  static bool EntropySource(uint8_t* buffer, intptr_t length);
  static Dart_Handle ReadStringFromFile(const char* filename);
  static Dart_Handle MakeUint8Array(const void* buffer, intptr_t length);
  static Dart_Handle PrepareForScriptLoading(bool is_service_isolate,
                                             bool trace_loading,
                                             bool flag_profile_microtasks);
  static Dart_Handle SetupPackageConfig(const char* packages_file);

  static Dart_Handle SetupIOLibrary(const char* namespc_path,
                                    const char* script_uri,
                                    bool disable_exit);

  static bool PostNull(Dart_Port port_id);
  static bool PostInt32(Dart_Port port_id, int32_t value);
  static bool PostInt64(Dart_Port port_id, int64_t value);
  static bool PostString(Dart_Port port_id, const char* value);

  static Dart_Handle GetDartType(const char* library_url,
                                 const char* class_name);
  // Create a new Dart OSError object with the current OS error.
  static Dart_Handle NewDartOSError();
  // Create a new Dart OSError object with the provided OS error.
  static Dart_Handle NewDartOSError(OSError* os_error);
  static Dart_Handle NewDartExceptionWithOSError(const char* library_url,
                                                 const char* exception_name,
                                                 const char* message,
                                                 Dart_Handle os_error);
  static Dart_Handle NewDartExceptionWithMessage(const char* library_url,
                                                 const char* exception_name,
                                                 const char* message);
  static Dart_Handle NewDartArgumentError(const char* message);
  static Dart_Handle NewDartFormatException(const char* message);
  static Dart_Handle NewDartUnsupportedError(const char* message);
  static Dart_Handle NewDartIOException(const char* exception_name,
                                        const char* message,
                                        Dart_Handle os_error);

  // Create a new Dart String object from a UTF8 encoded C String.
  static Dart_Handle NewString(const char* str) {
    ASSERT(str != nullptr);
    return Dart_NewStringFromUTF8(reinterpret_cast<const uint8_t*>(str),
                                  strlen(str));
  }

  // Create a new Dart String object from a formatted string.
  static Dart_Handle NewStringFormatted(const char* format, ...);

  // Allocate length bytes for a C string with Dart_ScopeAllocate.
  static char* ScopedCString(intptr_t length) {
    char* result = nullptr;
    result =
        reinterpret_cast<char*>(Dart_ScopeAllocate(length * sizeof(*result)));
    return result;
  }

  // Copy str into a buffer allocated with Dart_ScopeAllocate.
  static char* ScopedCopyCString(const char* str) {
    size_t str_len = strlen(str);
    char* result = ScopedCString(str_len + 1);
    memmove(result, str, str_len);
    result[str_len] = '\0';
    return result;
  }

  static char* ScopedCStringFormatted(const char* format, ...)
      PRINTF_ATTRIBUTE(1, 2);
  static char* ScopedCStringVFormatted(const char* format, va_list args);

  // Create a new Dart InternalError object with the provided message.
  static Dart_Handle NewError(const char* format, ...);
  static Dart_Handle NewInternalError(const char* message);

  static Dart_Handle LookupBuiltinLib() {
    return Dart_LookupLibrary(NewString(kBuiltinLibURL));
  }

  static bool SetOriginalWorkingDirectory();

  static Dart_Handle ResolveScript(Dart_Handle url);

  enum MagicNumber {
    kAppJITMagicNumber,
    kKernelMagicNumber,
    kKernelListMagicNumber,
    kBytecodeMagicNumber,
    kGzipMagicNumber,
    kAotELFMagicNumber,
    // Only the host-endian magic numbers are recognized, not the reverse-endian
    // ("cigam") ones, as we can't load a reverse-endian snapshot anyway.
    kAotMachO32MagicNumber,
    kAotMachO64MagicNumber,
    kAotPEMagicNumber,
    kAotCoffARM32MagicNumber,
    kAotCoffARM64MagicNumber,
    kAotCoffRISCV32MagicNumber,
    kAotCoffRISCV64MagicNumber,
    kUnknownMagicNumber
  };
  static constexpr int64_t kMaxMagicNumberSize = 8;

  // Note: The check for AOT magic number must match up with the enum
  // order above.
  static bool IsAotMagicNumber(MagicNumber number) {
    return (number >= DartUtils::kAotELFMagicNumber) &&
           (number <= DartUtils::kAotCoffRISCV64MagicNumber);
  }

  // Returns the bitsize corresponding to the magic number if the bitsize
  // is specified by the magic number, otherwise returns -1.
  static intptr_t MagicNumberBitSize(MagicNumber number) {
    if (number == DartUtils::kAotMachO32MagicNumber ||
        number == DartUtils::kAotCoffARM32MagicNumber ||
        number == DartUtils::kAotCoffRISCV32MagicNumber) {
      return 32;
    }
    if (number == DartUtils::kAotMachO64MagicNumber ||
        number == DartUtils::kAotCoffARM64MagicNumber ||
        number == DartUtils::kAotCoffRISCV64MagicNumber) {
      return 64;
    }
    return -1;
  }

  // Checks if the file is a script snapshot, kernel file, or gzip file
  // by reading the first kMaxMagicNumberSize bytes of the file.
  static MagicNumber SniffForMagicNumber(const char* filename);

  // Checks if the buffer is a script snapshot, kernel file, or gzip file.
  static MagicNumber SniffForMagicNumber(const uint8_t* text_buffer,
                                         intptr_t buffer_len);

  // Global state that stores the original working directory..
  static const char* original_working_directory;

  static constexpr const char* kDartScheme = "dart:";
  static constexpr const char* kAsyncLibURL = "dart:async";
  static constexpr const char* kBuiltinLibURL = "dart:_builtin";
  static constexpr const char* kConcurrentLibURL = "dart:concurrent";
  static constexpr const char* kCoreLibURL = "dart:core";
  static constexpr const char* kInternalLibURL = "dart:_internal";
  static constexpr const char* kIsolateLibURL = "dart:isolate";
  static constexpr const char* kHttpLibURL = "dart:_http";
  static constexpr const char* kIOLibURL = "dart:io";
  static constexpr const char* kIOLibPatchURL = "dart:io-patch";
  static constexpr const char* kCLILibURL = "dart:cli";
  static constexpr const char* kCLILibPatchURL = "dart:cli-patch";
  static constexpr const char* kUriLibURL = "dart:uri";
  static constexpr const char* kHttpScheme = "http:";
  static constexpr const char* kVMServiceLibURL = "dart:vmservice";

  static void SetEnvironment(dart::SimpleHashMap* environment);
  static Dart_Handle EnvironmentCallback(Dart_Handle name);

 private:
  static Dart_Handle SetWorkingDirectory();
  static Dart_Handle PrepareBuiltinLibrary(Dart_Handle builtin_lib,
                                           Dart_Handle internal_lib,
                                           bool is_service_isolate,
                                           bool trace_loading);
  static Dart_Handle PrepareCoreLibrary(Dart_Handle core_lib,
                                        Dart_Handle io_lib,
                                        bool is_service_isolate);
  static Dart_Handle PrepareAsyncLibrary(Dart_Handle async_lib,
                                         Dart_Handle isolate_lib,
                                         bool flag_profile_microtasks);
  static Dart_Handle PrepareIOLibrary(Dart_Handle io_lib);
  static Dart_Handle PrepareIsolateLibrary(Dart_Handle isolate_lib);
  static Dart_Handle PrepareCLILibrary(Dart_Handle cli_lib);

  static dart::SimpleHashMap* environment_;

  DISALLOW_ALLOCATION();
  DISALLOW_IMPLICIT_CONSTRUCTORS(DartUtils);
};

class CObject {
 public:
  // These match the constants in sdk/lib/io/common.dart.
  static constexpr int kSuccess = 0;
  static constexpr int kArgumentError = 1;
  static constexpr int kOSError = 2;
  static constexpr int kFileClosedError = 3;

  explicit CObject(Dart_CObject* cobject) : cobject_(cobject) {}
  Dart_CObject_Type type() { return cobject_->type; }
  Dart_TypedData_Type byte_array_type() {
    ASSERT(type() == Dart_CObject_kTypedData ||
           type() == Dart_CObject_kExternalTypedData);
    return cobject_->value.as_typed_data.type;
  }

  bool IsNull() { return type() == Dart_CObject_kNull; }
  bool IsBool() { return type() == Dart_CObject_kBool; }
  bool IsInt32() { return type() == Dart_CObject_kInt32; }
  bool IsInt64() { return type() == Dart_CObject_kInt64; }
  bool IsInt32OrInt64() { return IsInt32() || IsInt64(); }
  bool IsIntptr() { return IsInt32OrInt64(); }
  bool IsDouble() { return type() == Dart_CObject_kDouble; }
  bool IsString() { return type() == Dart_CObject_kString; }
  bool IsArray() { return type() == Dart_CObject_kArray; }
  bool IsTypedData() { return type() == Dart_CObject_kTypedData; }
  bool IsUint8Array() {
    return type() == Dart_CObject_kTypedData &&
           byte_array_type() == Dart_TypedData_kUint8;
  }
  bool IsSendPort() { return type() == Dart_CObject_kSendPort; }

  bool IsTrue() {
    return type() == Dart_CObject_kBool && cobject_->value.as_bool;
  }

  bool IsFalse() {
    return type() == Dart_CObject_kBool && !cobject_->value.as_bool;
  }

  void* operator new(size_t size) { return Dart_ScopeAllocate(size); }

  static CObject* Null();
  static CObject* True();
  static CObject* False();
  static CObject* Bool(bool value);
  static Dart_CObject* NewInt32(int32_t value);
  static Dart_CObject* NewInt64(int64_t value);
  static Dart_CObject* NewIntptr(intptr_t value);
  static Dart_CObject* NewDouble(double value);
  static Dart_CObject* NewString(const char* str);
  static Dart_CObject* NewArray(intptr_t length);
  static Dart_CObject* NewUint8Array(const void* data, intptr_t length);
  static Dart_CObject* NewExternalUint8Array(intptr_t length,
                                             uint8_t* data,
                                             void* peer,
                                             Dart_HandleFinalizer callback);
  static Dart_CObject* NewNativePointer(intptr_t ptr,
                                        intptr_t size,
                                        Dart_HandleFinalizer callback);

  static Dart_CObject* NewIOBuffer(int64_t length);
  static void ShrinkIOBuffer(Dart_CObject* cobject, int64_t new_length);
  static void FreeIOBufferData(Dart_CObject* object);

  Dart_CObject* AsApiCObject() { return cobject_; }

  // Create a new CObject array with an illegal arguments error.
  static CObject* IllegalArgumentError();
  // Create a new CObject array with a file closed error.
  static CObject* FileClosedError();
  // Create a new CObject array with the current OS error.
  static CObject* NewOSError();
  // Create a new CObject array with the specified OS error.
  static CObject* NewOSError(OSError* os_error);

 protected:
  CObject() : cobject_(nullptr) {}
  Dart_CObject* cobject_;

 private:
  static Dart_CObject* New(Dart_CObject_Type type, int additional_bytes = 0);

  static Dart_CObject api_null_;
  static Dart_CObject api_true_;
  static Dart_CObject api_false_;
  static CObject null_;
  static CObject true_;
  static CObject false_;

 private:
  DISALLOW_COPY_AND_ASSIGN(CObject);
};

#define DECLARE_COBJECT_CONSTRUCTORS(t)                                        \
  explicit CObject##t(Dart_CObject* cobject) : CObject(cobject) {              \
    ASSERT(type() == Dart_CObject_k##t);                                       \
    cobject_ = cobject;                                                        \
  }                                                                            \
  explicit CObject##t(CObject* cobject) : CObject() {                          \
    ASSERT(cobject != nullptr);                                                \
    ASSERT(cobject->type() == Dart_CObject_k##t);                              \
    cobject_ = cobject->AsApiCObject();                                        \
  }

#define DECLARE_COBJECT_TYPED_DATA_CONSTRUCTORS(t)                             \
  explicit CObject##t##Array(Dart_CObject* cobject) : CObject(cobject) {       \
    ASSERT(type() == Dart_CObject_kTypedData);                                 \
    ASSERT(byte_array_type() == Dart_TypedData_k##t);                          \
    cobject_ = cobject;                                                        \
  }                                                                            \
  explicit CObject##t##Array(CObject* cobject) : CObject() {                   \
    ASSERT(cobject != nullptr);                                                \
    ASSERT(cobject->type() == Dart_CObject_kTypedData);                        \
    ASSERT(cobject->byte_array_type() == Dart_TypedData_k##t);                 \
    cobject_ = cobject->AsApiCObject();                                        \
  }

#define DECLARE_COBJECT_EXTERNAL_TYPED_DATA_CONSTRUCTORS(t)                    \
  explicit CObjectExternal##t##Array(Dart_CObject* cobject)                    \
      : CObject(cobject) {                                                     \
    ASSERT(type() == Dart_CObject_kExternalTypedData);                         \
    ASSERT(byte_array_type() == Dart_TypedData_k##t);                          \
    cobject_ = cobject;                                                        \
  }                                                                            \
  explicit CObjectExternal##t##Array(CObject* cobject) : CObject() {           \
    ASSERT(cobject != nullptr);                                                \
    ASSERT(cobject->type() == Dart_CObject_kExternalTypedData);                \
    ASSERT(cobject->byte_array_type() == Dart_TypedData_k##t);                 \
    cobject_ = cobject->AsApiCObject();                                        \
  }

class CObjectBool : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(Bool)

  bool Value() const { return cobject_->value.as_bool; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectBool);
};

class CObjectInt32 : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(Int32)

  int32_t Value() const { return cobject_->value.as_int32; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectInt32);
};

class CObjectInt64 : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(Int64)

  int64_t Value() const { return cobject_->value.as_int64; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectInt64);
};

class CObjectIntptr : public CObject {
 public:
  explicit CObjectIntptr(Dart_CObject* cobject) : CObject(cobject) {
    ASSERT(type() == Dart_CObject_kInt32 || type() == Dart_CObject_kInt64);
    cobject_ = cobject;
  }
  explicit CObjectIntptr(CObject* cobject) : CObject() {
    ASSERT(cobject != nullptr);
    ASSERT(cobject->type() == Dart_CObject_kInt64 ||
           cobject->type() == Dart_CObject_kInt32);
    cobject_ = cobject->AsApiCObject();
  }

  intptr_t Value() {
    intptr_t result;
    if (type() == Dart_CObject_kInt32) {
      result = cobject_->value.as_int32;
    } else {
      ASSERT(sizeof(result) == 8);
      result = static_cast<intptr_t>(cobject_->value.as_int64);
    }
    return result;
  }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectIntptr);
};

class CObjectDouble : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(Double)

  double Value() const { return cobject_->value.as_double; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectDouble);
};

class CObjectString : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(String)

  intptr_t Length() const { return strlen(cobject_->value.as_string); }
  const char* CString() const { return cobject_->value.as_string; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectString);
};

class CObjectArray : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(Array)

  intptr_t Length() const { return cobject_->value.as_array.length; }
  CObject* operator[](intptr_t index) const {
    return new CObject(cobject_->value.as_array.values[index]);
  }
  void SetAt(intptr_t index, CObject* value) {
    cobject_->value.as_array.values[index] = value->AsApiCObject();
  }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectArray);
};

class CObjectSendPort : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(SendPort)

  Dart_Port Value() const { return cobject_->value.as_send_port.id; }
  Dart_Port OriginId() const { return cobject_->value.as_send_port.origin_id; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectSendPort);
};

class CObjectTypedData : public CObject {
 public:
  explicit CObjectTypedData(Dart_CObject* cobject) : CObject(cobject) {
    ASSERT(type() == Dart_CObject_kTypedData);
    cobject_ = cobject;
  }
  explicit CObjectTypedData(CObject* cobject) : CObject() {
    ASSERT(cobject != nullptr);
    ASSERT(cobject->type() == Dart_CObject_kTypedData);
    cobject_ = cobject->AsApiCObject();
  }

  Dart_TypedData_Type Type() const {
    return cobject_->value.as_typed_data.type;
  }
  intptr_t Length() const { return cobject_->value.as_typed_data.length; }
  const uint8_t* Buffer() const { return cobject_->value.as_typed_data.values; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectTypedData);
};

class CObjectUint8Array : public CObject {
 public:
  DECLARE_COBJECT_TYPED_DATA_CONSTRUCTORS(Uint8)

  intptr_t Length() const { return cobject_->value.as_typed_data.length; }
  const uint8_t* Buffer() const { return cobject_->value.as_typed_data.values; }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectUint8Array);
};

class CObjectExternalUint8Array : public CObject {
 public:
  DECLARE_COBJECT_EXTERNAL_TYPED_DATA_CONSTRUCTORS(Uint8)

  intptr_t Length() const {
    return cobject_->value.as_external_typed_data.length;
  }
  uint8_t* Data() const { return cobject_->value.as_external_typed_data.data; }
  void* Peer() const { return cobject_->value.as_external_typed_data.peer; }
  Dart_HandleFinalizer Callback() const {
    return cobject_->value.as_external_typed_data.callback;
  }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectExternalUint8Array);
};

/***
 * This class is intended for internal use by dart:io implementation and
 * has no connection to dart:ffi Pointer class.
 *
 * It represents a pointer to a native resource of a known type.
 *
 * The receiving side will only see this pointer as an integer and will not
 * see the specified finalizer.
 *
 * The specified finalizer will only be invoked if the message is not delivered.
 **/
class CObjectNativePointer : public CObject {
 public:
  DECLARE_COBJECT_CONSTRUCTORS(NativePointer)

  intptr_t Ptr() const { return cobject_->value.as_native_pointer.ptr; }
  intptr_t Size() const { return cobject_->value.as_native_pointer.size; }
  Dart_HandleFinalizer Callback() const {
    return cobject_->value.as_native_pointer.callback;
  }

 private:
  DISALLOW_COPY_AND_ASSIGN(CObjectNativePointer);
};

class ScopedBlockingCall {
 public:
  ScopedBlockingCall() { Dart_ThreadDisableProfiling(); }

  ~ScopedBlockingCall() { Dart_ThreadEnableProfiling(); }

 private:
  DISALLOW_ALLOCATION();
  DISALLOW_COPY_AND_ASSIGN(ScopedBlockingCall);
};

struct MagicNumberData {
  static constexpr intptr_t kMaxLength = 8;

  intptr_t length;
  const uint8_t bytes[kMaxLength];
};

extern MagicNumberData appjit_magic_number;
extern MagicNumberData aotelf_magic_number;
extern MagicNumberData kernel_magic_number;
extern MagicNumberData kernel_list_magic_number;
extern MagicNumberData gzip_magic_number;

}  // namespace bin
}  // namespace dart

#endif  // RUNTIME_BIN_DARTUTILS_H_
