// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/object.h"

#include "lib/invocation_mirror.h"
#include "platform/unaligned.h"
#include "vm/code_patcher.h"
#include "vm/dart_entry.h"
#include "vm/hash_table.h"
#include "vm/isolate_reload.h"
#include "vm/log.h"
#include "vm/object_store.h"
#include "vm/resolver.h"
#include "vm/stub_code.h"
#include "vm/symbols.h"

namespace dart {

#if !defined(PRODUCT) && !defined(DART_PRECOMPILED_RUNTIME)

DECLARE_FLAG(bool, trace_reload);
DECLARE_FLAG(bool, trace_reload_verbose);
DECLARE_FLAG(bool, two_args_smi_icd);

void CallSiteResetter::ZeroEdgeCounters(const Function& function) {
  ic_data_array_ = function.ic_data_array();
  if (ic_data_array_.IsNull()) {
    return;
  }
  ASSERT(ic_data_array_.Length() > 0);
  edge_counters_ ^=
      ic_data_array_.At(Function::ICDataArrayIndices::kEdgeCounters);
  if (edge_counters_.IsNull()) {
    return;
  }
  // Fill edge counters array with zeros.
  for (intptr_t i = 0; i < edge_counters_.Length(); i++) {
    edge_counters_.SetAt(i, Object::smi_zero());
  }
}

CallSiteResetter::CallSiteResetter(Zone* zone)
    : thread_(Thread::Current()),
      zone_(zone),
      instrs_(Instructions::Handle(zone)),
      pool_(ObjectPool::Handle(zone)),
      object_(Object::Handle(zone)),
      name_(String::Handle(zone)),
      old_cls_(Class::Handle(zone)),
      new_cls_(Class::Handle(zone)),
      old_lib_(Library::Handle(zone)),
      new_lib_(Library::Handle(zone)),
      new_function_(Function::Handle(zone)),
      new_field_(Field::Handle(zone)),
      entries_(Array::Handle(zone)),
      old_target_(Function::Handle(zone)),
      new_target_(Function::Handle(zone)),
      caller_(Function::Handle(zone)),
      args_desc_array_(Array::Handle(zone)),
      ic_data_array_(Array::Handle(zone)),
      edge_counters_(Array::Handle(zone)),
      descriptors_(PcDescriptors::Handle(zone)),
      ic_data_(ICData::Handle(zone)) {}

void CallSiteResetter::ResetCaches(const Code& code) {
  // Iterate over the Code's object pool and reset all ICDatas.
  // SubtypeTestCaches are reset during the same heap traversal as type
  // testing stub deoptimization.
#ifdef TARGET_ARCH_IA32
  // IA32 does not have an object pool, but, we can iterate over all
  // embedded objects by using the variable length data section.
  if (!code.is_alive()) {
    return;
  }
  instrs_ = code.instructions();
  ASSERT(!instrs_.IsNull());
  uword base_address = instrs_.PayloadStart();
  intptr_t offsets_length = code.pointer_offsets_length();
  const int32_t* offsets = code.untag()->data();
  for (intptr_t i = 0; i < offsets_length; i++) {
    int32_t offset = offsets[i];
    ObjectPtr* object_ptr = reinterpret_cast<ObjectPtr*>(base_address + offset);
    ObjectPtr raw_object = LoadUnaligned(object_ptr);
    if (!raw_object->IsHeapObject()) {
      continue;
    }
    object_ = raw_object;
    if (object_.IsICData()) {
      Reset(ICData::Cast(object_));
    }
  }
#else
  pool_ = code.object_pool();
  ASSERT(!pool_.IsNull());
  ResetCaches(pool_);
#endif
}

static void FindICData(const Array& ic_data_array,
                       intptr_t deopt_id,
                       ICData* ic_data) {
  // ic_data_array is sorted because of how it is constructed in
  // Function::SaveICDataMap.
  intptr_t lo = Function::ICDataArrayIndices::kFirstICData;
  intptr_t hi = ic_data_array.Length() - 1;
  while (lo <= hi) {
    intptr_t mid = (hi - lo + 1) / 2 + lo;
    ASSERT(mid >= lo);
    ASSERT(mid <= hi);
    *ic_data ^= ic_data_array.At(mid);
    if (ic_data->deopt_id() == deopt_id) {
      return;
    } else if (ic_data->deopt_id() > deopt_id) {
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  }
  FATAL("Missing deopt id %" Pd "\n", deopt_id);
}

void CallSiteResetter::ResetSwitchableCalls(const Code& code) {
  if (code.is_optimized()) {
    return;  // No switchable calls in optimized code.
  }

  object_ = code.owner();
  if (!object_.IsFunction()) {
    return;  // No switchable calls in stub code.
  }
  const Function& function = Function::Cast(object_);

  if (function.kind() == UntaggedFunction::kIrregexpFunction) {
    // Regex matchers do not support breakpoints or stepping, and they only call
    // core library functions that cannot change due to reload. As a performance
    // optimization, avoid this matching of ICData to PCs for these functions'
    // large number of instance calls.
    ASSERT(!function.is_debuggable());
    return;
  }

  ic_data_array_ = function.ic_data_array();
  if (ic_data_array_.IsNull()) {
    // The megamorphic miss stub and some recognized function doesn't populate
    // their ic_data_array. Check this only happens for functions without IC
    // calls.
#if defined(DEBUG)
    descriptors_ = code.pc_descriptors();
    PcDescriptors::Iterator iter(descriptors_, UntaggedPcDescriptors::kIcCall);
    while (iter.MoveNext()) {
      FATAL("%s has IC calls but no ic_data_array\n",
            function.ToFullyQualifiedCString());
    }
#endif
    return;
  }

  descriptors_ = code.pc_descriptors();
  PcDescriptors::Iterator iter(descriptors_, UntaggedPcDescriptors::kIcCall);
  while (iter.MoveNext()) {
    uword pc = code.PayloadStart() + iter.PcOffset();
    CodePatcher::GetInstanceCallAt(pc, code, &object_);
    // This check both avoids unnecessary patching to reduce log spam and
    // prevents patching over breakpoint stubs.
    if (!object_.IsICData()) {
      FindICData(ic_data_array_, iter.DeoptId(), &ic_data_);
      ASSERT(ic_data_.rebind_rule() == ICData::kInstance);
      ASSERT(ic_data_.NumArgsTested() == 1);
      const Code& stub =
          ic_data_.is_tracking_exactness()
              ? StubCode::OneArgCheckInlineCacheWithExactnessCheck()
              : StubCode::OneArgCheckInlineCache();
      CodePatcher::PatchInstanceCallAt(pc, code, ic_data_, stub);
      if (FLAG_trace_ic) {
        OS::PrintErr("Instance call at %" Px
                     " resetting to polymorphic dispatch, %s\n",
                     pc, ic_data_.ToCString());
      }
    }
  }
}

void CallSiteResetter::ResetCaches(const ObjectPool& pool) {
  for (intptr_t i = 0; i < pool.Length(); i++) {
    ObjectPool::EntryType entry_type = pool.TypeAt(i);
    if (entry_type != ObjectPool::EntryType::kTaggedObject) {
      continue;
    }
    object_ = pool.ObjectAt(i);
    if (object_.IsICData()) {
      Reset(ICData::Cast(object_));
    }
  }
}

void Class::CopyStaticFieldValues(ProgramReloadContext* reload_context,
                                  const Class& old_cls) const {
  const Array& old_field_list = Array::Handle(old_cls.fields());
  Field& old_field = Field::Handle();
  String& old_name = String::Handle();

  const Array& field_list = Array::Handle(fields());
  Field& field = Field::Handle();
  String& name = String::Handle();

  for (intptr_t i = 0; i < field_list.Length(); i++) {
    field = Field::RawCast(field_list.At(i));
    name = field.name();
    // Find the corresponding old field, if it exists, and migrate
    // over the field value.
    for (intptr_t j = 0; j < old_field_list.Length(); j++) {
      old_field = Field::RawCast(old_field_list.At(j));
      old_name = old_field.name();
      if (name.Equals(old_name)) {
        if (field.is_static()) {
          // We only copy values if requested and if the field is not a const
          // field. We let const fields be updated with a reload.
          if (!field.is_const()) {
            // Make new field point to the old field value so that both
            // old and new code see and update same value.
            reload_context->isolate_group()->FreeStaticField(field);
            field.set_field_id_unsafe(old_field.field_id());
          }
          reload_context->AddStaticFieldMapping(old_field, field);
        }
      }
    }
  }
}

void Class::CopyCanonicalConstants(const Class& old_cls) const {
#if defined(DEBUG)
  {
    // Class has no canonical constants allocated.
    const Array& my_constants = Array::Handle(constants());
    ASSERT(my_constants.IsNull() || my_constants.Length() == 0);
  }
#endif  // defined(DEBUG).
  // Copy old constants into new class.
  const Array& old_constants = Array::Handle(old_cls.constants());
  if (old_constants.IsNull() || old_constants.Length() == 0) {
    return;
  }
  TIR_Print("Copied %" Pd " canonical constants for class `%s`\n",
            old_constants.Length(), ToCString());
  set_constants(old_constants);
}

void Class::CopyDeclarationType(const Class& old_cls) const {
  const Type& old_declaration_type = Type::Handle(old_cls.declaration_type());
  if (old_declaration_type.IsNull()) {
    return;
  }
  set_declaration_type(old_declaration_type);
}

class EnumMapTraits {
 public:
  static bool ReportStats() { return false; }
  static const char* Name() { return "EnumMapTraits"; }

  static bool IsMatch(const Object& a, const Object& b) {
    return a.ptr() == b.ptr();
  }

  static uword Hash(const Object& obj) {
    ASSERT(obj.IsString());
    return String::Cast(obj).Hash();
  }
};

void Class::PatchFieldsAndFunctions() const {
  // Move all old functions and fields to a patch class so that they
  // still refer to their original script.
  const auto& kernel_info = KernelProgramInfo::Handle(KernelProgramInfo());
  const PatchClass& patch = PatchClass::Handle(
      PatchClass::New(*this, kernel_info, Script::Handle(script())));
  ASSERT(!patch.IsNull());
  const Library& lib = Library::Handle(library());
  patch.set_kernel_library_index(lib.kernel_library_index());

  const Array& funcs = Array::Handle(current_functions());
  Function& func = Function::Handle();
  Object& owner = Object::Handle();
  for (intptr_t i = 0; i < funcs.Length(); i++) {
    func = Function::RawCast(funcs.At(i));
    if ((func.token_pos() == TokenPosition::kMinSource) ||
        func.IsClosureFunction()) {
      // Eval functions do not need to have their script updated.
      //
      // Closure functions refer to the parent's script which we can
      // rely on being updated for us, if necessary.
      continue;
    }

    // If the source for this function is already patched, leave it alone.
    owner = func.RawOwner();
    ASSERT(!owner.IsNull());
    if (!owner.IsPatchClass()) {
      ASSERT(owner.ptr() == this->ptr());
      func.set_owner(patch);
    }
  }

  Thread* thread = Thread::Current();
  SafepointWriteRwLocker ml(thread, thread->isolate_group()->program_lock());
  const Array& field_list = Array::Handle(fields());
  Field& field = Field::Handle();
  for (intptr_t i = 0; i < field_list.Length(); i++) {
    field = Field::RawCast(field_list.At(i));
    owner = field.RawOwner();
    ASSERT(!owner.IsNull());
    if (!owner.IsPatchClass()) {
      ASSERT(owner.ptr() == this->ptr());
      field.set_owner(patch);
    }
    field.ForceDynamicGuardedCidAndLength();
  }
}

void Class::MigrateImplicitStaticClosures(ProgramReloadContext* irc,
                                          const Class& new_cls) const {
  const Array& funcs = Array::Handle(current_functions());
  Thread* thread = Thread::Current();
  Function& old_func = Function::Handle();
  String& selector = String::Handle();
  Function& new_func = Function::Handle();
  Closure& old_closure = Closure::Handle();
  Closure& new_closure = Closure::Handle();
  for (intptr_t i = 0; i < funcs.Length(); i++) {
    old_func ^= funcs.At(i);
    if (old_func.is_static() && old_func.HasImplicitClosureFunction()) {
      selector = old_func.name();
      new_func = Resolver::ResolveFunction(thread->zone(), new_cls, selector);
      if (!new_func.IsNull() && new_func.is_static()) {
        old_func = old_func.ImplicitClosureFunction();
        old_closure = old_func.ImplicitStaticClosure();
        new_func = new_func.ImplicitClosureFunction();
        new_closure = new_func.ImplicitStaticClosure();
        if (old_closure.IsCanonical()) {
          new_closure.SetCanonical();
        }
        irc->AddBecomeMapping(old_closure, new_closure);
      }
    }
  }
}

class EnumClassConflict : public ClassReasonForCancelling {
 public:
  EnumClassConflict(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

  StringPtr ToString() {
    return String::NewFormatted(
        from_.is_enum_class()
            ? "Enum class cannot be redefined to be a non-enum class: %s"
            : "Class cannot be redefined to be a enum class: %s",
        from_.ToCString());
  }
};

class EnsureFinalizedError : public ClassReasonForCancelling {
 public:
  EnsureFinalizedError(Zone* zone,
                       const Class& from,
                       const Class& to,
                       const Error& error)
      : ClassReasonForCancelling(zone, from, to), error_(error) {}

 private:
  const Error& error_;

  ErrorPtr ToError() { return error_.ptr(); }

  StringPtr ToString() { return String::New(error_.ToErrorCString()); }
};

class DeeplyImmutableChange : public ClassReasonForCancelling {
 public:
  DeeplyImmutableChange(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

 private:
  StringPtr ToString() {
    return String::NewFormatted(
        "Classes cannot change their @pragma('vm:deeply-immutable'): %s",
        from_.ToCString());
  }
};

class ConstToNonConstClass : public ClassReasonForCancelling {
 public:
  ConstToNonConstClass(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

 private:
  StringPtr ToString() {
    return String::NewFormatted("Const class cannot become non-const: %s",
                                from_.ToCString());
  }
};

class ConstClassFieldRemoved : public ClassReasonForCancelling {
 public:
  ConstClassFieldRemoved(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

 private:
  StringPtr ToString() {
    return String::NewFormatted("Const class cannot remove fields: %s",
                                from_.ToCString());
  }
};

class NativeFieldsConflict : public ClassReasonForCancelling {
 public:
  NativeFieldsConflict(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

 private:
  StringPtr ToString() {
    return String::NewFormatted("Number of native fields changed in %s",
                                from_.ToCString());
  }
};

class TypeParametersChanged : public ClassReasonForCancelling {
 public:
  TypeParametersChanged(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

  StringPtr ToString() {
    return String::NewFormatted(
        "Limitation: type parameters have changed for %s", from_.ToCString());
  }

  void AppendTo(JSONArray* array) {
    JSONObject jsobj(array);
    jsobj.AddProperty("type", "ReasonForCancellingReload");
    jsobj.AddProperty("kind", "TypeParametersChanged");
    jsobj.AddProperty("class", to_);
    jsobj.AddProperty("message",
                      "Limitation: changing type parameters "
                      "does not work with hot reload.");
  }
};

class PreFinalizedConflict : public ClassReasonForCancelling {
 public:
  PreFinalizedConflict(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

 private:
  StringPtr ToString() {
    return String::NewFormatted(
        "Original class ('%s') is prefinalized and replacement class "
        "('%s') is not ",
        from_.ToCString(), to_.ToCString());
  }
};

class InstanceSizeConflict : public ClassReasonForCancelling {
 public:
  InstanceSizeConflict(Zone* zone, const Class& from, const Class& to)
      : ClassReasonForCancelling(zone, from, to) {}

 private:
  StringPtr ToString() {
    return String::NewFormatted("Instance size mismatch between '%s' (%" Pd
                                ") and replacement "
                                "'%s' ( %" Pd ")",
                                from_.ToCString(), from_.host_instance_size(),
                                to_.ToCString(), to_.host_instance_size());
  }
};

// This is executed before iterating over the instances.
void Class::CheckReload(const Class& replacement,
                        ProgramReloadContext* context) const {
  ASSERT(ProgramReloadContext::IsSameClass(*this, replacement));

  if (!is_declaration_loaded()) {
    // The old class hasn't been used in any meaningful way, so the VM is okay
    // with any change.
    return;
  }

  // Ensure is_enum_class etc have been set.
  replacement.EnsureDeclarationLoaded();

  // Class cannot change enum property.
  if (is_enum_class() != replacement.is_enum_class()) {
    context->group_reload_context()->AddReasonForCancelling(
        new (context->zone())
            EnumClassConflict(context->zone(), *this, replacement));
    return;
  }

  if (is_finalized()) {
    // Make sure the declaration types parameter count matches for the two
    // classes.
    // ex. class A<int,B> {} cannot be replace with class A<B> {}.
    auto group_context = context->group_reload_context();
    if (NumTypeParameters() != replacement.NumTypeParameters()) {
      group_context->AddReasonForCancelling(
          new (context->zone())
              TypeParametersChanged(context->zone(), *this, replacement));
      return;
    }
  }

  if (is_finalized() || is_allocate_finalized()) {
    auto thread = Thread::Current();

    // Ensure the replacement class is also finalized.
    const Error& error = Error::Handle(
        is_allocate_finalized() ? replacement.EnsureIsAllocateFinalized(thread)
                                : replacement.EnsureIsFinalized(thread));
    if (!error.IsNull()) {
      context->group_reload_context()->AddReasonForCancelling(
          new (context->zone())
              EnsureFinalizedError(context->zone(), *this, replacement, error));
      return;  // No reason to check other properties.
    }
    ASSERT(replacement.is_finalized());
    TIR_Print("Finalized replacement class for %s\n", ToCString());
  }

  if (is_deeply_immutable() != replacement.is_deeply_immutable()) {
    context->group_reload_context()->AddReasonForCancelling(
        new (context->zone())
            DeeplyImmutableChange(context->zone(), *this, replacement));
    return;  // No reason to check other properties.
  }

  if (is_finalized() && is_const() && (constants() != Array::null()) &&
      (Array::LengthOf(constants()) > 0)) {
    // Consts can't become non-consts.
    if (!replacement.is_const()) {
      context->group_reload_context()->AddReasonForCancelling(
          new (context->zone())
              ConstToNonConstClass(context->zone(), *this, replacement));
      return;
    }

    // Consts can't lose fields.
    bool field_removed = false;
    const Array& old_fields = Array::Handle(
        OffsetToFieldMap(IsolateGroup::Current()->heap_walk_class_table()));
    const Array& new_fields = Array::Handle(replacement.OffsetToFieldMap());
    if (new_fields.Length() < old_fields.Length()) {
      field_removed = true;
    } else {
      Field& old_field = Field::Handle();
      Field& new_field = Field::Handle();
      String& old_name = String::Handle();
      String& new_name = String::Handle();
      for (intptr_t i = 0, n = old_fields.Length(); i < n; i++) {
        old_field ^= old_fields.At(i);
        new_field ^= new_fields.At(i);
        if (old_field.IsNull()) {
          continue;
        }
        if (new_field.IsNull()) {
          field_removed = true;
          break;
        }
        old_name = old_field.name();
        new_name = new_field.name();
        if (!old_name.Equals(new_name)) {
          field_removed = true;
          break;
        }
      }
    }
    if (field_removed) {
      context->group_reload_context()->AddReasonForCancelling(
          new (context->zone())
              ConstClassFieldRemoved(context->zone(), *this, replacement));
      return;
    }
  }

  // Native field count cannot change.
  if (num_native_fields() != replacement.num_native_fields()) {
    context->group_reload_context()->AddReasonForCancelling(
        new (context->zone())
            NativeFieldsConflict(context->zone(), *this, replacement));
    return;
  }

  // Just checking.
  ASSERT(is_enum_class() == replacement.is_enum_class());
  ASSERT(num_native_fields() == replacement.num_native_fields());

  if (is_finalized()) {
    if (!CanReloadFinalized(replacement, context)) return;
  }
  if (is_prefinalized()) {
    if (!CanReloadPreFinalized(replacement, context)) return;
  }
  TIR_Print("Class `%s` can be reloaded (%" Pd " and %" Pd ")\n", ToCString(),
            id(), replacement.id());
}

void Class::MarkFieldBoxedDuringReload(ClassTable* class_table,
                                       const Field& field) const {
  if (!field.is_unboxed()) {
    return;
  }

  field.set_is_unboxed_unsafe(false);

  // Make sure to update the bitmap used for scanning.
  auto unboxed_fields_map = class_table->GetUnboxedFieldsMapAt(id());
  const auto start_index = field.HostOffset() >> kCompressedWordSizeLog2;
  const auto end_index =
      start_index + (Class::UnboxedFieldSizeInBytesByCid(field.guarded_cid()) >>
                     kCompressedWordSizeLog2);
  ASSERT(unboxed_fields_map.Get(start_index));
  for (intptr_t i = start_index; i < end_index; i++) {
    unboxed_fields_map.Clear(i);
  }
  class_table->SetUnboxedFieldsMapAt(id(), unboxed_fields_map);
}

bool Class::RequiresInstanceMorphing(ClassTable* class_table,
                                     const Class& replacement) const {
  if (!is_allocate_finalized()) {
    // No instances of this class exists on the heap - nothing to morph.
    return false;
  }

  // Get the field maps for both classes. These field maps walk the class
  // hierarchy.
  auto isolate_group = IsolateGroup::Current();

  // heap_walk_class_table is the original class table before it was
  // updated by reloading sources.
  const Array& fields =
      Array::Handle(OffsetToFieldMap(isolate_group->heap_walk_class_table()));
  const Array& replacement_fields =
      Array::Handle(replacement.OffsetToFieldMap());

  // Check that the size of the instance is the same.
  if (fields.Length() != replacement_fields.Length()) return true;

  // Check that we have the same next field offset. This check is not
  // redundant with the one above because the instance OffsetToFieldMap
  // array length is based on the instance size (which may be aligned up).
  if (host_next_field_offset() != replacement.host_next_field_offset()) {
    return true;
  }

  // Verify that field names / offsets match across the entire hierarchy.
  Field& field = Field::Handle();
  String& field_name = String::Handle();
  Field& replacement_field = Field::Handle();
  String& replacement_field_name = String::Handle();

  for (intptr_t i = 0; i < fields.Length(); i++) {
    if (fields.At(i) == Field::null()) {
      ASSERT(replacement_fields.At(i) == Field::null());
      continue;
    }
    field = Field::RawCast(fields.At(i));
    replacement_field = Field::RawCast(replacement_fields.At(i));
    field_name = field.name();
    replacement_field_name = replacement_field.name();
    if (!field_name.Equals(replacement_field_name)) return true;
    if (field.is_unboxed() && !replacement_field.is_unboxed()) {
      return true;
    }
    if (field.is_unboxed() && (field.type() != replacement_field.type())) {
      return true;
    }
    if (!field.is_unboxed() && replacement_field.is_unboxed()) {
      // No actual morphing is required in this case but we need to mark
      // the field boxed.
      replacement.MarkFieldBoxedDuringReload(class_table, replacement_field);
    }
    if (field.needs_load_guard()) {
      ASSERT(!field.is_unboxed());
      ASSERT(!replacement_field.is_unboxed());
      replacement_field.set_needs_load_guard(true);
    }
  }
  return false;
}

bool Class::CanReloadFinalized(const Class& replacement,
                               ProgramReloadContext* context) const {
  // Make sure the declaration types argument count matches for the two classes.
  // ex. class A<int,B> {} cannot be replace with class A<B> {}.
  auto group_context = context->group_reload_context();
  auto class_table = group_context->isolate_group()->class_table();
  if (NumTypeArguments() != replacement.NumTypeArguments()) {
    group_context->AddReasonForCancelling(
        new (context->zone())
            TypeParametersChanged(context->zone(), *this, replacement));
    return false;
  }
  if (RequiresInstanceMorphing(class_table, replacement)) {
    ASSERT(id() == replacement.id());
    const classid_t cid = id();
    // We unconditionally create an instance morpher. As a side effect of
    // building the morpher, we will mark all new fields as guarded on load.
    auto instance_morpher = InstanceMorpher::CreateFromClassDescriptors(
        context->zone(), class_table, *this, replacement);
    group_context->EnsureHasInstanceMorpherFor(cid, instance_morpher);
  }
  return true;
}

bool Class::CanReloadPreFinalized(const Class& replacement,
                                  ProgramReloadContext* context) const {
  // The replacement class must also prefinalized.
  if (!replacement.is_prefinalized()) {
    context->group_reload_context()->AddReasonForCancelling(
        new (context->zone())
            PreFinalizedConflict(context->zone(), *this, replacement));
    return false;
  }
  // Check the instance sizes are equal.
  if (host_instance_size() != replacement.host_instance_size()) {
    context->group_reload_context()->AddReasonForCancelling(
        new (context->zone())
            InstanceSizeConflict(context->zone(), *this, replacement));
    return false;
  }
  return true;
}

void Library::CheckReload(const Library& replacement,
                          ProgramReloadContext* context) const {
  // Carry over the loaded bit of any deferred prefixes.
  Object& object = Object::Handle();
  LibraryPrefix& prefix = LibraryPrefix::Handle();
  LibraryPrefix& original_prefix = LibraryPrefix::Handle();
  String& name = String::Handle();
  String& original_name = String::Handle();
  DictionaryIterator it(replacement);
  while (it.HasNext()) {
    object = it.GetNext();
    if (!object.IsLibraryPrefix()) continue;
    prefix ^= object.ptr();
    if (!prefix.is_deferred_load()) continue;

    name = prefix.name();
    DictionaryIterator original_it(*this);
    while (original_it.HasNext()) {
      object = original_it.GetNext();
      if (!object.IsLibraryPrefix()) continue;
      original_prefix ^= object.ptr();
      if (!original_prefix.is_deferred_load()) continue;
      original_name = original_prefix.name();
      if (!name.Equals(original_name)) continue;

      // The replacement of the old prefix with the new prefix
      // in Isolate::loaded_prefixes_set_ implicitly carried
      // the loaded state over to the new prefix.
      context->AddBecomeMapping(original_prefix, prefix);
    }
  }
}

void CallSiteResetter::Reset(const ICData& ic) {
  ICData::RebindRule rule = ic.rebind_rule();
  if (rule == ICData::kInstance) {
    const intptr_t num_args = ic.NumArgsTested();
    const intptr_t len = ic.Length();
    // We need at least one non-sentinel entry to require a check
    // for the smi fast path case.
    if (num_args == 2 && len >= 2) {
      if (ic.IsImmutable()) {
        return;
      }
      name_ = ic.target_name();
      const Class& smi_class = Class::Handle(zone_, Smi::Class());
      const Function& smi_op_target = Function::Handle(
          zone_, Resolver::ResolveDynamicAnyArgs(zone_, smi_class, name_,
                                                 /*allow_add=*/true));
      GrowableArray<intptr_t> class_ids(2);
      Function& target = Function::Handle(zone_);
      ic.GetCheckAt(0, &class_ids, &target);
      if ((target.ptr() == smi_op_target.ptr()) && (class_ids[0] == kSmiCid) &&
          (class_ids[1] == kSmiCid)) {
        // The smi fast path case, preserve the initial entry but reset the
        // count.
        ic.ClearCountAt(0, *this);
        ic.TruncateTo(/*num_checks=*/1, *this);
        return;
      }
      // Fall back to the normal behavior with cached empty ICData arrays.
    }
    ic.Clear(*this);
    ic.set_is_megamorphic(false);
    return;
  } else if (rule == ICData::kNoRebind || rule == ICData::kNSMDispatch) {
    // TODO(30877) we should account for addition/removal of NSM.
    // Don't rebind dispatchers.
    return;
  } else if (rule == ICData::kStatic || rule == ICData::kSuper) {
    old_target_ = ic.GetTargetAt(0);
    if (old_target_.IsNull()) {
      FATAL("old_target is nullptr.\n");
    }
    name_ = old_target_.name();

    if (rule == ICData::kStatic) {
      ASSERT(old_target_.is_static() ||
             old_target_.kind() == UntaggedFunction::kConstructor);
      // This can be incorrect if the call site was an unqualified invocation.
      new_cls_ = old_target_.Owner();
      new_target_ = Resolver::ResolveFunction(zone_, new_cls_, name_);
      if (new_target_.kind() != old_target_.kind()) {
        new_target_ = Function::null();
      }
    } else {
      // Super call.
      caller_ = ic.Owner();
      ASSERT(!caller_.is_static());
      new_cls_ = caller_.Owner();
      new_cls_ = new_cls_.SuperClass();
      new_target_ = Resolver::ResolveDynamicAnyArgs(zone_, new_cls_, name_,
                                                    /*allow_add=*/true);
    }
    args_desc_array_ = ic.arguments_descriptor();
    ArgumentsDescriptor args_desc(args_desc_array_);
    if (new_target_.IsNull() ||
        !new_target_.AreValidArguments(args_desc, nullptr)) {
      // TODO(rmacnak): Patch to a NSME stub.
      VTIR_Print("Cannot rebind static call to %s from %s\n",
                 old_target_.ToCString(),
                 Object::Handle(zone_, ic.Owner()).ToCString());
      return;
    }
    ic.ClearAndSetStaticTarget(new_target_, *this);
  } else {
    FATAL("Unexpected rebind rule.");
  }
}

#if defined(DART_DYNAMIC_MODULES)
static ArrayPtr PrepareNoSuchMethodErrorArguments(const Function& target,
                                                  bool incompatible_arguments) {
  InvocationMirror::Kind kind = InvocationMirror::Kind::kMethod;
  if (target.IsImplicitGetterFunction() || target.IsGetterFunction()) {
    kind = InvocationMirror::kGetter;
  } else if (target.IsImplicitSetterFunction() || target.IsSetterFunction()) {
    kind = InvocationMirror::kSetter;
  }
  const Class& owner = Class::Handle(target.Owner());
  auto& receiver = Instance::Handle();
  InvocationMirror::Level level;
  if (owner.IsTopLevel()) {
    if (incompatible_arguments) {
      receiver = target.UserVisibleSignature();
    }
    level = InvocationMirror::Level::kTopLevel;
  } else {
    receiver = owner.RareType();
    if (target.IsConstructor()) {
      level = InvocationMirror::Level::kConstructor;
    } else {
      level = InvocationMirror::Level::kStatic;
    }
  }
  const auto& member_name = String::Handle(target.name());
  const auto& invocation_type =
      Smi::Handle(Smi::New(InvocationMirror::EncodeType(level, kind)));

  // NoSuchMethodError._throwNew takes the following arguments:
  //   Object receiver,
  //   String memberName,
  //   int invocationType,
  //   int typeArgumentsLength,
  //   Object? typeArguments,
  //   List? arguments,
  //   List? argumentNames
  const Array& args = Array::Handle(Array::New(7));
  args.SetAt(0, receiver);
  args.SetAt(1, member_name);
  args.SetAt(2, invocation_type);
  args.SetAt(3, Object::smi_zero());
  args.SetAt(4, Object::null_type_arguments());
  args.SetAt(5, Object::null_object());
  args.SetAt(6, Object::null_object());
  return args.ptr();
}
#endif  // defined(DART_DYNAMIC_MODULES)

void CallSiteResetter::RebindBytecode(const Bytecode& bytecode) {
#if defined(DART_DYNAMIC_MODULES)
  pool_ = bytecode.object_pool();
  ASSERT(!pool_.IsNull());

  // Iterate over bytecode instructions and update
  // references to static methods and fields.
  const KBCInstr* instr =
      reinterpret_cast<const KBCInstr*>(bytecode.PayloadStart());
  const KBCInstr* end = reinterpret_cast<const KBCInstr*>(
      bytecode.PayloadStart() + bytecode.Size());
  while (instr < end) {
    switch (KernelBytecode::DecodeOpcode(instr)) {
      case KernelBytecode::kDirectCall:
      case KernelBytecode::kDirectCall_Wide:
      case KernelBytecode::kUncheckedDirectCall:
      case KernelBytecode::kUncheckedDirectCall_Wide: {
        const intptr_t idx = KernelBytecode::DecodeD(instr);
        object_ = pool_.ObjectAt(idx);
        if (object_.IsArray()) {
          break;
        }
        old_target_ ^= object_.ptr();
        args_desc_array_ ^= pool_.ObjectAt(idx + 1);
        ArgumentsDescriptor args_desc(args_desc_array_);
        // Re-resolve class in case it was deleted.
        old_cls_ = old_target_.Owner();
        old_lib_ = old_cls_.library();
        name_ = old_lib_.url();
        new_lib_ = Library::LookupLibrary(thread_, name_);
        if (!new_lib_.IsNull()) {
          if (old_cls_.IsTopLevel()) {
            new_cls_ = new_lib_.toplevel_class();
          } else {
            name_ = old_cls_.Name();
            new_cls_ = new_lib_.LookupClassAllowPrivate(name_);
          }
        } else {
          new_cls_ = Class::null();
        }
        if (!new_cls_.IsNull()) {
          name_ = old_target_.name();
          new_target_ = Resolver::ResolveFunction(zone_, new_cls_, name_);
          if (new_target_.IsNull() && Field::IsGetterName(name_)) {
            name_ = Field::NameFromGetter(name_);
            new_target_ = Resolver::ResolveFunction(zone_, new_cls_, name_);
            if (!new_target_.IsNull()) {
              name_ = old_target_.name();
              new_target_ = new_target_.GetMethodExtractor(name_);
            }
          }
        } else {
          new_target_ = Function::null();
        }
        if (new_target_.ptr() != old_target_.ptr()) {
          if (new_target_.IsNull() ||
              (new_target_.is_static() != old_target_.is_static())) {
            VTIR_Print("Cannot rebind function %s\n",
                       old_target_.ToFullyQualifiedCString());
            object_ = PrepareNoSuchMethodErrorArguments(
                old_target_, /*incompatible_arguments=*/false);
          } else if (!new_target_.AreValidArguments(args_desc, nullptr)) {
            VTIR_Print("Cannot rebind function %s - arguments mismatch\n",
                       old_target_.ToFullyQualifiedCString());
            object_ = PrepareNoSuchMethodErrorArguments(
                old_target_, /*incompatible_arguments=*/true);
          } else {
            object_ = new_target_.ptr();
          }
          pool_.SetObjectAt(idx, object_);
        }
        break;
      }
      case KernelBytecode::kLoadStatic:
      case KernelBytecode::kLoadStatic_Wide:
      case KernelBytecode::kStoreStaticTOS:
      case KernelBytecode::kStoreStaticTOS_Wide: {
        const intptr_t idx = KernelBytecode::DecodeD(instr);
        object_ = pool_.ObjectAt(idx);
        const Field& old_field = Field::Cast(object_);
        name_ = old_field.name();
        new_cls_ = old_field.Owner();
        new_field_ = new_cls_.LookupField(name_);
        if (!new_field_.IsNull() &&
            (new_field_.is_static() == old_field.is_static())) {
          pool_.SetObjectAt(idx, new_field_);
        } else {
          VTIR_Print("Cannot rebind field %s\n", old_field.ToCString());
        }
        break;
      }
      default:
        break;
    }
    instr = KernelBytecode::Next(instr);
  }
#else
  UNREACHABLE();
#endif  // defined(DART_DYNAMIC_MODULES)
}

#endif  // !defined(PRODUCT) && !defined(DART_PRECOMPILED_RUNTIME)

}  // namespace dart
