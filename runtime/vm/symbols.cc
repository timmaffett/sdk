// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/symbols.h"

#include "platform/unicode.h"
#include "vm/canonical_tables.h"
#include "vm/handles.h"
#include "vm/hash_table.h"
#include "vm/heap/safepoint.h"
#include "vm/isolate.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/raw_object.h"
#include "vm/reusable_handles.h"
#include "vm/visitor.h"

namespace dart {

StringPtr Symbols::predefined_[Symbols::kNumberOfOneCharCodeSymbols];
String* Symbols::symbol_handles_[Symbols::kMaxPredefinedId];

#if !defined(DART_PRECOMPILED_RUNTIME)
static const char* const names[] = {
    // clang-format off
  nullptr,
#define DEFINE_SYMBOL_LITERAL(symbol, literal) literal,
  PREDEFINED_SYMBOLS_LIST(DEFINE_SYMBOL_LITERAL)
#undef DEFINE_SYMBOL_LITERAL
  "",  // matches kTokenTableStart.
#define DEFINE_TOKEN_SYMBOL_INDEX(t, s, p, a) s,
  DART_TOKEN_LIST(DEFINE_TOKEN_SYMBOL_INDEX)
  DART_KEYWORD_LIST(DEFINE_TOKEN_SYMBOL_INDEX)
#undef DEFINE_TOKEN_SYMBOL_INDEX
    // clang-format on
};
#endif

StringPtr StringFrom(const uint8_t* data, intptr_t len, Heap::Space space) {
  return String::FromLatin1(data, len, space);
}

StringPtr StringFrom(const uint16_t* data, intptr_t len, Heap::Space space) {
  return String::FromUTF16(data, len, space);
}

StringPtr StringSlice::ToSymbol() const {
  if (is_all() && str_.IsOld()) {
    str_.SetCanonical();
    return str_.ptr();
  } else {
    String& result =
        String::Handle(String::SubString(str_, begin_index_, len_, Heap::kOld));
    result.SetCanonical();
    result.SetHash(hash_);
    return result.ptr();
  }
}

StringPtr ConcatString::ToSymbol() const {
  String& result = String::Handle(String::Concat(str1_, str2_, Heap::kOld));
  result.SetCanonical();
  result.SetHash(hash_);
  return result.ptr();
}

const String& Symbols::Token(Token::Kind token) {
  const int tok_index = token;
  ASSERT((0 <= tok_index) && (tok_index < Token::kNumTokens));
  // First keyword symbol is in symbol_handles_[kTokenTableStart + 1].
  const intptr_t token_id = Symbols::kTokenTableStart + 1 + tok_index;
  ASSERT(symbol_handles_[token_id] != nullptr);
  return *symbol_handles_[token_id];
}

void Symbols::Init(IsolateGroup* vm_isolate_group) {
  // TODO(engine): Require a snapshot when running the JIT runtime too.
#if defined(DART_PRECOMPILED_RUNTIME)
  UNREACHABLE();
#else
  // Should only be run by the vm isolate.
  ASSERT(IsolateGroup::Current() == Dart::vm_isolate_group());
  ASSERT(vm_isolate_group == Dart::vm_isolate_group());
  Zone* zone = Thread::Current()->zone();

  // Create and setup a symbol table in the vm isolate.
  SetupSymbolTable(vm_isolate_group);

  // Create all predefined symbols.
  ASSERT((sizeof(names) / sizeof(const char*)) == Symbols::kNullCharId);

  CanonicalStringSet table(zone,
                           vm_isolate_group->object_store()->symbol_table());

  // First set up all the predefined string symbols.
  // Create symbols for language keywords. Some keywords are equal to
  // symbols we already created, so use New() instead of Add() to ensure
  // that the symbols are canonicalized.
  for (intptr_t i = 1; i < Symbols::kNullCharId; i++) {
    String* str = String::ReadOnlyHandle();
    *str = OneByteString::New(names[i], Heap::kOld);
    str->Hash();
    *str ^= table.InsertOrGet(*str);
    str->SetCanonical();  // Make canonical once entered.
    symbol_handles_[i] = str;
  }

  // Add Latin1 characters as Symbols, so that Symbols::FromCharCode is fast.
  for (intptr_t c = 0; c < kNumberOfOneCharCodeSymbols; c++) {
    intptr_t idx = (kNullCharId + c);
    ASSERT(idx < kMaxPredefinedId);
    ASSERT(Utf::IsLatin1(c));
    uint8_t ch = static_cast<uint8_t>(c);
    String* str = String::ReadOnlyHandle();
    *str = OneByteString::New(&ch, 1, Heap::kOld);
    str->Hash();
    *str ^= table.InsertOrGet(*str);
    ASSERT(predefined_[c] == nullptr);
    str->SetCanonical();  // Make canonical once entered.
    predefined_[c] = str->ptr();
    symbol_handles_[idx] = str;
  }

  vm_isolate_group->object_store()->set_symbol_table(table.Release());
#endif
}

void Symbols::InitFromSnapshot(IsolateGroup* vm_isolate_group) {
  for (intptr_t c = 0; c < kNumberOfOneCharCodeSymbols; c++) {
    intptr_t idx = (kNullCharId + c);
    predefined_[c] = symbol_handles_[idx]->ptr();
  }
}

void Symbols::SetupSymbolTable(IsolateGroup* isolate_group) {
  ASSERT(isolate_group != nullptr);

  // Setup the symbol table used within the String class.
  const intptr_t initial_size = (isolate_group == Dart::vm_isolate_group())
                                    ? kInitialVMIsolateSymtabSize
                                    : kInitialSymtabSize;
  class WeakArray& array = WeakArray::Handle(
      HashTables::New<CanonicalStringSet>(initial_size, Heap::kOld));
  isolate_group->object_store()->set_symbol_table(array);
}

void Symbols::GetStats(IsolateGroup* isolate_group,
                       intptr_t* size,
                       intptr_t* capacity) {
  ASSERT(isolate_group != nullptr);
  CanonicalStringSet table(isolate_group->object_store()->symbol_table());
  *size = table.NumOccupied();
  *capacity = table.NumEntries();
  table.Release();
}

StringPtr Symbols::New(Thread* thread, const char* cstr, intptr_t len) {
  ASSERT((cstr != nullptr) && (len >= 0));
  const uint8_t* utf8_array = reinterpret_cast<const uint8_t*>(cstr);
  return Symbols::FromUTF8(thread, utf8_array, len);
}

StringPtr Symbols::FromUTF8(Thread* thread,
                            const uint8_t* utf8_array,
                            intptr_t array_len) {
  if (array_len == 0 || utf8_array == nullptr) {
    return FromLatin1(thread, static_cast<uint8_t*>(nullptr), 0);
  }
  Utf8::Type type;
  intptr_t len = Utf8::CodeUnitCount(utf8_array, array_len, &type);
  ASSERT(len != 0);
  Zone* zone = thread->zone();
  if (type == Utf8::kLatin1) {
    uint8_t* characters = zone->Alloc<uint8_t>(len);
    if (!Utf8::DecodeToLatin1(utf8_array, array_len, characters, len)) {
      Utf8::ReportInvalidByte(utf8_array, array_len, len);
      return String::null();
    }
    return FromLatin1(thread, characters, len);
  }
  ASSERT((type == Utf8::kBMP) || (type == Utf8::kSupplementary));
  uint16_t* characters = zone->Alloc<uint16_t>(len);
  if (!Utf8::DecodeToUTF16(utf8_array, array_len, characters, len)) {
    Utf8::ReportInvalidByte(utf8_array, array_len, len);
    return String::null();
  }
  return FromUTF16(thread, characters, len);
}

StringPtr Symbols::FromLatin1(Thread* thread,
                              const uint8_t* latin1_array,
                              intptr_t len) {
  return NewSymbol(thread, Latin1Array(latin1_array, len));
}

StringPtr Symbols::FromUTF16(Thread* thread,
                             const uint16_t* utf16_array,
                             intptr_t len) {
  return NewSymbol(thread, UTF16Array(utf16_array, len));
}

StringPtr Symbols::FromConcat(Thread* thread,
                              const String& str1,
                              const String& str2) {
  if (str1.Length() == 0) {
    return New(thread, str2);
  } else if (str2.Length() == 0) {
    return New(thread, str1);
  } else {
    return NewSymbol(thread, ConcatString(str1, str2));
  }
}

StringPtr Symbols::FromGet(Thread* thread, const String& str) {
  return FromConcat(thread, GetterPrefix(), str);
}

StringPtr Symbols::FromSet(Thread* thread, const String& str) {
  return FromConcat(thread, SetterPrefix(), str);
}

StringPtr Symbols::FromDot(Thread* thread, const String& str) {
  return FromConcat(thread, str, Dot());
}

// TODO(srdjan): If this becomes performance critical code, consider looking
// up symbol from hash of pieces instead of concatenating them first into
// a string.
StringPtr Symbols::FromConcatAll(
    Thread* thread,
    const GrowableHandlePtrArray<const String>& strs) {
  const intptr_t strs_length = strs.length();
  GrowableArray<intptr_t> lengths(strs_length);

  intptr_t len_sum = 0;
  const intptr_t kOneByteChar = 1;
  intptr_t char_size = kOneByteChar;

  for (intptr_t i = 0; i < strs_length; i++) {
    const String& str = strs[i];
    const intptr_t str_len = str.Length();
    if ((String::kMaxElements - len_sum) < str_len) {
      Exceptions::ThrowOOM();
      UNREACHABLE();
    }
    len_sum += str_len;
    lengths.Add(str_len);
    char_size = Utils::Maximum(char_size, str.CharSize());
  }
  const bool is_one_byte_string = char_size == kOneByteChar;

  Zone* zone = thread->zone();
  if (is_one_byte_string) {
    uint8_t* buffer = zone->Alloc<uint8_t>(len_sum);
    const uint8_t* const orig_buffer = buffer;
    for (intptr_t i = 0; i < strs_length; i++) {
      NoSafepointScope no_safepoint;
      intptr_t str_len = lengths[i];
      if (str_len > 0) {
        const String& str = strs[i];
        ASSERT(str.IsOneByteString());
        const uint8_t* src_p = OneByteString::DataStart(str);
        memmove(buffer, src_p, str_len);
        buffer += str_len;
      }
    }
    ASSERT(len_sum == buffer - orig_buffer);
    return Symbols::FromLatin1(thread, orig_buffer, len_sum);
  } else {
    uint16_t* buffer = zone->Alloc<uint16_t>(len_sum);
    const uint16_t* const orig_buffer = buffer;
    for (intptr_t i = 0; i < strs_length; i++) {
      NoSafepointScope no_safepoint;
      intptr_t str_len = lengths[i];
      if (str_len > 0) {
        const String& str = strs[i];
        if (str.IsTwoByteString()) {
          memmove(buffer, TwoByteString::DataStart(str), str_len * 2);
        } else {
          // One-byte to two-byte string copy.
          ASSERT(str.IsOneByteString());
          const uint8_t* src_p = OneByteString::DataStart(str);
          for (int n = 0; n < str_len; n++) {
            buffer[n] = src_p[n];
          }
        }
        buffer += str_len;
      }
    }
    ASSERT(len_sum == buffer - orig_buffer);
    return Symbols::FromUTF16(thread, orig_buffer, len_sum);
  }
}

// StringType can be StringSlice, ConcatString, or {Latin1,UTF16}Array.
template <typename StringType>
StringPtr Symbols::NewSymbol(Thread* thread, const StringType& str) {
  REUSABLE_OBJECT_HANDLESCOPE(thread);
  REUSABLE_SMI_HANDLESCOPE(thread);
  REUSABLE_WEAK_ARRAY_HANDLESCOPE(thread);
  String& symbol = String::Handle(thread->zone());
  dart::Object& key = thread->ObjectHandle();
  Smi& value = thread->SmiHandle();
  class WeakArray& data = thread->WeakArrayHandle();
  {
    auto vm_isolate_group = Dart::vm_isolate_group();
    data = vm_isolate_group->object_store()->symbol_table();
    CanonicalStringSet table(&key, &value, &data);
    symbol ^= table.GetOrNull(str);
    table.Release();
  }
  if (symbol.IsNull()) {
    IsolateGroup* group = thread->isolate_group();
    ObjectStore* object_store = group->object_store();

    // Most common case: The symbol is already in the table.
    {
      // We do allow lock-free concurrent read access to the symbol table.
      // Both, the array in the ObjectStore as well as elements in the array
      // are accessed via store-release/load-acquire barriers.
      data = object_store->symbol_table();
      CanonicalStringSet table(&key, &value, &data);
      symbol ^= table.GetOrNull(str);
      table.Release();
    }
    // Otherwise we'll have to get exclusive access and get-or-insert it.
    if (symbol.IsNull()) {
      if (thread->OwnsSafepoint()) {
        data = object_store->symbol_table();
        CanonicalStringSet table(&key, &value, &data);
        symbol ^= table.InsertNewOrGet(str);
        object_store->set_symbol_table(table.Release());
      } else {
        SafepointMutexLocker ml(group->symbols_mutex());
        data = object_store->symbol_table();
        CanonicalStringSet table(&key, &value, &data);
        symbol ^= table.InsertNewOrGet(str);
        object_store->set_symbol_table(table.Release());
      }
    }
  }
  ASSERT(symbol.IsSymbol());
  ASSERT(symbol.HasHash());
  return symbol.ptr();
}

template <typename StringType>
StringPtr Symbols::Lookup(Thread* thread, const StringType& str) {
  REUSABLE_OBJECT_HANDLESCOPE(thread);
  REUSABLE_SMI_HANDLESCOPE(thread);
  REUSABLE_ARRAY_HANDLESCOPE(thread);
  String& symbol = String::Handle(thread->zone());
  dart::Object& key = thread->ObjectHandle();
  Smi& value = thread->SmiHandle();
  class WeakArray& data = thread->WeakArrayHandle();
  {
    auto vm_isolate_group = Dart::vm_isolate_group();
    data = vm_isolate_group->object_store()->symbol_table();
    CanonicalStringSet table(&key, &value, &data);
    symbol ^= table.GetOrNull(str);
    table.Release();
  }
  if (symbol.IsNull()) {
    IsolateGroup* group = thread->isolate_group();
    ObjectStore* object_store = group->object_store();
    // See `Symbols::NewSymbol` for more information why we separate the two
    // cases.
    if (thread->OwnsSafepoint()) {
      data = object_store->symbol_table();
      CanonicalStringSet table(&key, &value, &data);
      symbol ^= table.GetOrNull(str);
      table.Release();
    } else {
      data = object_store->symbol_table();
      CanonicalStringSet table(&key, &value, &data);
      symbol ^= table.GetOrNull(str);
      table.Release();
    }
  }
  ASSERT(symbol.IsNull() || symbol.IsSymbol());
  ASSERT(symbol.IsNull() || symbol.HasHash());
  return symbol.ptr();
}

StringPtr Symbols::LookupFromConcat(Thread* thread,
                                    const String& str1,
                                    const String& str2) {
  if (str1.Length() == 0) {
    return Lookup(thread, str2);
  } else if (str2.Length() == 0) {
    return Lookup(thread, str1);
  } else {
    return Lookup(thread, ConcatString(str1, str2));
  }
}

StringPtr Symbols::LookupFromGet(Thread* thread, const String& str) {
  return LookupFromConcat(thread, GetterPrefix(), str);
}

StringPtr Symbols::LookupFromSet(Thread* thread, const String& str) {
  return LookupFromConcat(thread, SetterPrefix(), str);
}

StringPtr Symbols::LookupFromDot(Thread* thread, const String& str) {
  return LookupFromConcat(thread, str, Dot());
}

StringPtr Symbols::New(Thread* thread, const String& str) {
  if (str.IsSymbol()) {
    return str.ptr();
  }
  return New(thread, str, 0, str.Length());
}

StringPtr Symbols::New(Thread* thread,
                       const String& str,
                       intptr_t begin_index,
                       intptr_t len) {
  return NewSymbol(thread, StringSlice(str, begin_index, len));
}

StringPtr Symbols::NewFormatted(Thread* thread, const char* format, ...) {
  va_list args;
  va_start(args, format);
  StringPtr result = NewFormattedV(thread, format, args);
  NoSafepointScope no_safepoint;
  va_end(args);
  return result;
}

StringPtr Symbols::NewFormattedV(Thread* thread,
                                 const char* format,
                                 va_list args) {
  va_list args_copy;
  va_copy(args_copy, args);
  intptr_t len = Utils::VSNPrint(nullptr, 0, format, args_copy);
  va_end(args_copy);

  char* buffer = thread->zone()->Alloc<char>(len + 1);
  Utils::VSNPrint(buffer, (len + 1), format, args);

  return Symbols::New(thread, buffer);
}

StringPtr Symbols::FromCharCode(Thread* thread, uint16_t char_code) {
  if (char_code > kMaxOneCharCodeSymbol) {
    return FromUTF16(thread, &char_code, 1);
  }
  return predefined_[char_code];
}

void Symbols::DumpStats(IsolateGroup* isolate_group) {
  intptr_t size = -1;
  intptr_t capacity = -1;
  // First dump VM symbol table stats.
  GetStats(Dart::vm_isolate_group(), &size, &capacity);
  OS::PrintErr("VM Isolate: Number of symbols : %" Pd "\n", size);
  OS::PrintErr("VM Isolate: Symbol table capacity : %" Pd "\n", capacity);
  // Now dump regular isolate symbol table stats.
  GetStats(isolate_group, &size, &capacity);
  OS::PrintErr("Isolate: Number of symbols : %" Pd "\n", size);
  OS::PrintErr("Isolate: Symbol table capacity : %" Pd "\n", capacity);
  // TODO(koda): Consider recording growth and collision stats in HashTable,
  // in DEBUG mode.
}

void Symbols::DumpTable(IsolateGroup* isolate_group) {
  OS::PrintErr("symbols:\n");
  CanonicalStringSet table(isolate_group->object_store()->symbol_table());
  table.Dump();
  table.Release();
}

}  // namespace dart
