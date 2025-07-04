// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../common/elements.dart' show ElementEnvironment, JCommonElements;
import '../deferred_load/output_unit.dart' show OutputUnitData;
import '../elements/entities.dart';
import '../elements/types.dart';
import '../js_backend/interceptor_data.dart' show InterceptorData;
import '../js_model/js_world.dart' show JClosedWorld;
import '../universe/class_hierarchy.dart' show ClassHierarchy;

sealed class IsTestSpecialization {}

enum SimpleIsTestSpecialization implements IsTestSpecialization {
  isNull,
  isNotNull,
  isString,
  isBool,
  isNum,
  isInt,
  isArrayTop,
}

class InstanceOfIsTestSpecialization implements IsTestSpecialization {
  final InterfaceType interfaceType;

  const InstanceOfIsTestSpecialization(this.interfaceType);
}

class SpecializedChecks {
  static IsTestSpecialization? findIsTestSpecialization(
    DartType dartType,
    MemberEntity compiland,
    JClosedWorld closedWorld,
  ) {
    if (dartType is InterfaceType) {
      ClassEntity element = dartType.element;
      JCommonElements commonElements = closedWorld.commonElements;

      if (element == commonElements.nullClass ||
          element == commonElements.jsNullClass) {
        return SimpleIsTestSpecialization.isNull;
      }

      if (element == commonElements.jsStringClass ||
          element == commonElements.stringClass) {
        return SimpleIsTestSpecialization.isString;
      }

      if (element == commonElements.jsBoolClass ||
          element == commonElements.boolClass) {
        return SimpleIsTestSpecialization.isBool;
      }

      if (element == commonElements.doubleClass ||
          element == commonElements.jsNumberClass ||
          element == commonElements.numClass) {
        return SimpleIsTestSpecialization.isNum;
      }

      if (element == commonElements.jsIntClass ||
          element == commonElements.intClass ||
          element == commonElements.jsUInt32Class ||
          element == commonElements.jsUInt31Class ||
          element == commonElements.jsPositiveIntClass) {
        return SimpleIsTestSpecialization.isInt;
      }

      DartTypes dartTypes = closedWorld.dartTypes;
      // Top types should be constant folded outside the specializer. This test
      // protects logic below.
      if (dartTypes.isTopType(dartType)) return null;

      ElementEnvironment elementEnvironment = closedWorld.elementEnvironment;
      if (!dartTypes.isSubtype(
        elementEnvironment.getClassInstantiationToBounds(element),
        dartType,
      )) {
        return null;
      }

      if (element == commonElements.jsArrayClass) {
        return SimpleIsTestSpecialization.isArrayTop;
      }

      if (dartType.isObject) {
        assert(!dartTypes.isTopType(dartType)); // Checked above.
        return SimpleIsTestSpecialization.isNotNull;
      }

      ClassHierarchy classHierarchy = closedWorld.classHierarchy;
      InterceptorData interceptorData = closedWorld.interceptorData;
      OutputUnitData outputUnitData = closedWorld.outputUnitData;

      final topmost = closedWorld.getLubOfInstantiatedSubtypes(element);

      // No LUB means the test is always false, and should be constant folded
      // outside of this specializer.
      if (topmost == null) return null;

      if (classHierarchy.hasOnlySubclasses(topmost) &&
          !interceptorData.isInterceptedClass(topmost) &&
          outputUnitData.hasOnlyNonDeferredImportPathsToClass(
            compiland,
            topmost,
          )) {
        assert(!dartType.isObject); // Checked above.
        return InstanceOfIsTestSpecialization(
          elementEnvironment.getClassInstantiationToBounds(topmost),
        );
      }

      // Two ideas for further consideration:
      //
      // 1. It might be profitable to know the type of the tested value - for
      // example, `Pattern` and `Comparable` are both interfaces that are
      // impemented by many classes and cannot be handled by any of the tricks
      // above. However, if we know the tested value is a `Pattern` then `is
      // Comparable` can be compiled as `is String`.
      //
      // 2. We could re-introduce type testing using the `$isFoo` property. The
      // Rti `_is` stubs use this property, but in a polymorphic manner.
      // Specialized stubs would be monomorphic in the property symbol, but they
      // still need to use `getInterceptor` (although this can be specialized
      // too).  Using the `$isFoo` property directly in the code would be most
      // beneficial when the interceptor is needed for other reasons (including
      // additional checks), otherwise it is just a more verbose version of
      // calling the specialized Rti stub.
    }

    return null;
  }

  static FunctionEntity? findAsCheck(
    DartType dartType,
    JCommonElements commonElements,
  ) {
    if (dartType is InterfaceType) {
      if (dartType.typeArguments.isNotEmpty) return null;
      return _findAsCheck(dartType.element, commonElements, nullable: false);
    }
    if (dartType is NullableType) {
      DartType baseType = dartType.baseType;
      if (baseType is InterfaceType && baseType.typeArguments.isEmpty) {
        return _findAsCheck(baseType.element, commonElements, nullable: true);
      }
      return null;
    }
    return null;
  }

  /// Finds the method that implements the specialized check for a simple type.
  /// The specialized method will report a TypeError that includes a reported
  /// type.
  ///
  /// [nullable]: Find specialization for `element?`.
  static FunctionEntity? _findAsCheck(
    ClassEntity element,
    JCommonElements commonElements, {
    required bool nullable,
  }) {
    if (element == commonElements.jsStringClass ||
        element == commonElements.stringClass) {
      if (nullable) return commonElements.specializedAsStringNullable;
      return commonElements.specializedAsString;
    }

    if (element == commonElements.jsBoolClass ||
        element == commonElements.boolClass) {
      if (nullable) return commonElements.specializedAsBoolNullable;
      return commonElements.specializedAsBool;
    }

    if (element == commonElements.doubleClass) {
      if (nullable) return commonElements.specializedAsDoubleNullable;
      return commonElements.specializedAsDouble;
    }

    if (element == commonElements.jsNumberClass ||
        element == commonElements.numClass) {
      if (nullable) return commonElements.specializedAsNumNullable;
      return commonElements.specializedAsNum;
    }

    if (element == commonElements.jsIntClass ||
        element == commonElements.intClass ||
        element == commonElements.jsUInt32Class ||
        element == commonElements.jsUInt31Class ||
        element == commonElements.jsPositiveIntClass) {
      if (nullable) return commonElements.specializedAsIntNullable;
      return commonElements.specializedAsInt;
    }

    if (element == commonElements.objectClass) {
      if (!nullable) return commonElements.specializedAsObject;
    }

    if (element == commonElements.jsObjectClass) {
      if (nullable) return commonElements.specializedAsJSObjectNullable;
      return commonElements.specializedAsJSObject;
    }

    return null;
  }
}
