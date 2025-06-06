// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

import 'utils.dart';

const void_ = FundamentalType(PrimitiveType.void_);
const bool_ = FundamentalType(PrimitiveType.bool_);
const int8 = FundamentalType(PrimitiveType.int8);
const int16 = FundamentalType(PrimitiveType.int16);
const int32 = FundamentalType(PrimitiveType.int32);
const int64 = FundamentalType(PrimitiveType.int64);
const uint8 = FundamentalType(PrimitiveType.uint8);
const uint16 = FundamentalType(PrimitiveType.uint16);
const uint32 = FundamentalType(PrimitiveType.uint32);
const uint64 = FundamentalType(PrimitiveType.uint64);
const intptr = FundamentalType(PrimitiveType.intptr);
const float = FundamentalType(PrimitiveType.float);
const double_ = FundamentalType(PrimitiveType.double_);
const long = FundamentalType(PrimitiveType.long);
const ulong = FundamentalType(PrimitiveType.ulong);
const uintptr = FundamentalType(PrimitiveType.uintptr);
const wchar = FundamentalType(PrimitiveType.wchar);

enum PrimitiveType {
  void_,
  bool_,
  int8,
  int16,
  int32,
  int64,
  uint8,
  uint16,
  uint32,
  uint64,
  intptr,
  float,
  double_,
  long,
  ulong,
  uintptr,
  wchar,
}

const primitiveNames = {
  PrimitiveType.void_: "void",
  PrimitiveType.bool_: "bool",
  PrimitiveType.int8: "int8",
  PrimitiveType.int16: "int16",
  PrimitiveType.int32: "int32",
  PrimitiveType.int64: "int64",
  PrimitiveType.uint8: "uint8",
  PrimitiveType.uint16: "uint16",
  PrimitiveType.uint32: "uint32",
  PrimitiveType.uint64: "uint64",
  PrimitiveType.intptr: "intptr",
  PrimitiveType.float: "float",
  PrimitiveType.double_: "double",
  PrimitiveType.long: "long",
  PrimitiveType.ulong: "ulong",
  PrimitiveType.uintptr: "uintptr",
  PrimitiveType.wchar: "wchar",
};

const primitiveCType = {
  PrimitiveType.void_: "void",
  PrimitiveType.bool_: "bool",
  PrimitiveType.int8: "int8_t",
  PrimitiveType.int16: "int16_t",
  PrimitiveType.int32: "int32_t",
  PrimitiveType.int64: "int64_t",
  PrimitiveType.uint8: "uint8_t",
  PrimitiveType.uint16: "uint16_t",
  PrimitiveType.uint32: "uint32_t",
  PrimitiveType.uint64: "uint64_t",
  PrimitiveType.intptr: "intptr_t",
  PrimitiveType.float: "float",
  PrimitiveType.double_: "double",
  // People should use explicit sizes. But we also want to test `long`.
  // Suppressing lint.
  PrimitiveType.long: "/* NOLINT(runtime/int) */long",
  PrimitiveType.ulong: "/* NOLINT(runtime/int) */unsigned long",
  PrimitiveType.uintptr: "uintptr_t",
  PrimitiveType.wchar: "wchar_t",
};

const primitiveDartCType = {
  PrimitiveType.void_: "Void",
  PrimitiveType.bool_: "Bool",
  PrimitiveType.int8: "Int8",
  PrimitiveType.int16: "Int16",
  PrimitiveType.int32: "Int32",
  PrimitiveType.int64: "Int64",
  PrimitiveType.uint8: "Uint8",
  PrimitiveType.uint16: "Uint16",
  PrimitiveType.uint32: "Uint32",
  PrimitiveType.uint64: "Uint64",
  PrimitiveType.intptr: "IntPtr",
  PrimitiveType.float: "Float",
  PrimitiveType.double_: "Double",
  PrimitiveType.long: "Long",
  PrimitiveType.ulong: "UnsignedLong",
  PrimitiveType.uintptr: "UintPtr",
  PrimitiveType.wchar: "WChar",
};

/// Sizes equal on all platforms.
const primitiveSizesInBytes = {
  PrimitiveType.bool_: 1,
  PrimitiveType.int8: 1,
  PrimitiveType.int16: 2,
  PrimitiveType.int32: 4,
  PrimitiveType.int64: 8,
  PrimitiveType.uint8: 1,
  PrimitiveType.uint16: 2,
  PrimitiveType.uint32: 4,
  PrimitiveType.uint64: 8,
  PrimitiveType.float: 4,
  PrimitiveType.double_: 8,
};

const primitivesUnsigned = {
  PrimitiveType.bool_,
  PrimitiveType.uint8,
  PrimitiveType.uint16,
  PrimitiveType.uint32,
  PrimitiveType.uint64,
  PrimitiveType.uintptr,
  PrimitiveType.ulong,
  PrimitiveType.wchar,
};

abstract class CType {
  String get cType;
  String get dartCType;
  String get dartType;
  String get dartStructFieldAnnotation;

  /// Has a known [size] that is the same for all architectures.
  bool get hasSize;

  /// Get a size in bytes that is the same on all architectures.
  int get size;

  /// All members have a floating point type.
  bool get isOnlyFloatingPoint;

  /// All members have a integer type.
  bool get isOnlyInteger;

  /// All members have a bool type.
  bool get isOnlyBool;

  String toString() => dartCType;

  const CType();
}

class FundamentalType extends CType {
  final PrimitiveType primitive;

  const FundamentalType(this.primitive);

  bool get isVoid => primitive == PrimitiveType.void_;
  bool get isBool => primitive == PrimitiveType.bool_;
  bool get isFloatingPoint =>
      primitive == PrimitiveType.float || primitive == PrimitiveType.double_;
  bool get isInteger => !isFloatingPoint && !isBool;
  bool get isOnlyFloatingPoint => isFloatingPoint;
  bool get isOnlyInteger => isInteger;
  bool get isOnlyBool => isBool;
  bool get isUnsigned => primitivesUnsigned.contains(primitive);
  bool get isSigned => !isUnsigned;

  String get name => primitiveNames[primitive]!;

  String get cType => primitiveCType[primitive]!;
  String get dartCType => primitiveDartCType[primitive]!;
  String get dartType {
    if (isVoid) return 'void';
    if (isInteger) return 'int';
    if (isOnlyFloatingPoint) return 'double';
    if (isBool) return 'bool';
    throw 'Unknown type $primitive';
  }

  String get dartStructFieldAnnotation => "@${dartCType}()";
  bool get hasSize => primitiveSizesInBytes.containsKey(primitive);
  int get size {
    if (!hasSize) {
      throw "Size unknown.";
    }
    return primitiveSizesInBytes[primitive]!;
  }

  String get zero {
    if (isBool) return 'false';
    if (isInteger) return '0';
    if (isFloatingPoint) return '0.0';
    throw 'Unknown type $primitive';
  }

  String get addAssignOp {
    if (isBool) return '^=';
    if (isInteger || isFloatingPoint) return '+=';
    throw 'Unknown type $primitive';
  }
}

class PointerType extends CType {
  final CType pointerTo;

  PointerType(this.pointerTo);

  String get cType => "${pointerTo.cType}*";
  String get dartCType => "Pointer<${pointerTo.dartCType}>";
  String get dartType => "Pointer<${pointerTo.dartType}>";
  String get dartStructFieldAnnotation => "";
  bool get hasSize => false;
  int get size => throw "Size unknown";
  String get dartTypedData => switch (pointerTo) {
    float => 'Float32List',
    double_ => 'Float64List',
    FundamentalType() => '${pointerTo.dartCType}List',
    _ => throw UnimplementedError(),
  };

  bool get isOnlyFloatingPoint => false;
  bool get isOnlyInteger => true;
  bool get isOnlyBool => false;
}

/// Used to give [StructType] fields and [FunctionType] arguments names.
class Member {
  final CType type;
  final String name;

  Member(this.type, this.name);

  String dartStructField() {
    return "${type.dartStructFieldAnnotation} external ${type.dartType} $name;";
  }

  String get cStructField {
    String postFix = "";
    if (type case FixedLengthArrayType(:final dimensions)) {
      postFix =
          "[${dimensions.map((d) => d == 0 ? '' : d.toString()).join("][")}]";
    }
    return "${type.cType} $name$postFix;";
  }

  String toString() => "$type $name";
}

List<Member> generateMemberNames(List<CType> memberTypes) {
  int index = 0;
  List<Member> result = [];
  for (final type in memberTypes) {
    result.add(Member(type, "a$index"));
    index++;
  }
  return result;
}

abstract class CompositeType extends CType {
  final List<Member> members;

  /// To disambiguate same size structs.
  final String suffix;

  /// To override names.
  final String overrideName;

  CompositeType(List<CType> memberTypes)
    : this.members = generateMemberNames(memberTypes),
      this.suffix = "",
      this.overrideName = "";
  CompositeType.disambiguate(List<CType> memberTypes, this.suffix)
    : this.members = generateMemberNames(memberTypes),
      this.overrideName = "";
  CompositeType.override(List<CType> memberTypes, this.overrideName)
    : this.members = generateMemberNames(memberTypes),
      this.suffix = "";

  List<CType> get memberTypes => members.map((a) => a.type).toList();

  String get name;

  String get cType => name;
  String get dartCType => name;
  String get dartType => name;
  String get dartStructFieldAnnotation => "";
  String get cKeyword;
  String get dartSuperClass;

  bool get isOnlyFloatingPoint =>
      memberTypes.every((e) => e.isOnlyFloatingPoint);
  bool get isOnlyInteger => memberTypes.every((e) => e.isOnlyInteger);
  bool get isOnlyBool => memberTypes.every((e) => e.isOnlyBool);

  bool get isMixed => !isOnlyInteger && !isOnlyFloatingPoint && !isOnlyBool;

  bool get hasNestedStructs =>
      members.map((e) => e.type is StructType).contains(true);

  bool get hasInlineArrays =>
      members.map((e) => e.type is FixedLengthArrayType).contains(true);

  bool get hasMultiDimensionalInlineArrays => members
      .map((e) => e.type)
      .whereType<FixedLengthArrayType>()
      .where((e) => e.isMulti)
      .isNotEmpty;
}

class StructType extends CompositeType {
  final int? packing;

  StructType(List<CType> memberTypes, {int? this.packing}) : super(memberTypes);
  StructType.disambiguate(
    List<CType> memberTypes,
    String suffix, {
    int? this.packing,
  }) : super.disambiguate(memberTypes, suffix);
  StructType.override(
    List<CType> memberTypes,
    String overrideName, {
    int? this.packing,
  }) : super.override(memberTypes, overrideName);

  String get cKeyword => "struct";
  String get dartSuperClass => "Struct";

  bool get hasSize => memberTypes.every((e) => e.hasSize) && !hasPadding;
  int get size => memberTypes.fold(0, (int acc, e) => acc + e.size);

  bool get hasPacking => packing != null;

  bool get hasPadding {
    if (members.length < 2) {
      return false;
    }
    if (packing == 1) {
      return false;
    }

    /// Rough approximation, to not redo all ABI logic here.
    return members[0].type.size < members[1].type.size;
  }

  /// All members have the same type.
  bool get isHomogeneous => memberTypes.toSet().length == 1;

  String get name {
    String result = dartSuperClass;
    if (overrideName != "") {
      return result + overrideName;
    }
    if (hasSize) {
      result += "${size}Byte" + (size != 1 ? "s" : "");
    }
    if (hasPacking) {
      result += "Packed";
      if (packing! > 1) {
        result += "$packing";
      }
    }
    if (hasNestedStructs) {
      result += "Nested";
    }
    if (hasInlineArrays) {
      result += "InlineArray";
      if (hasMultiDimensionalInlineArrays) {
        result += "MultiDimensional";
      }
    }
    if (members.length == 0) {
      // No suffix.
    } else if (hasPadding) {
      result += "Alignment${memberTypes[1].dartCType}";
    } else if (isHomogeneous && members.length > 1 && !hasNestedStructs) {
      result += "Homogeneous${memberTypes.first.dartCType}";
    } else if (isOnlyFloatingPoint) {
      result += "Float";
    } else if (isOnlyInteger) {
      result += "Int";
    } else if (isOnlyBool) {
      result += "Bool";
    } else {
      result += "Mixed";
    }
    result += suffix;
    return result;
  }
}

class UnionType extends CompositeType {
  UnionType(List<CType> memberTypes) : super(memberTypes);

  String get cKeyword => "union";
  String get dartSuperClass => "Union";

  bool get hasSize => memberTypes.every((e) => e.hasSize);
  int get size => memberTypes.fold(0, (int acc, e) => math.max(acc, e.size));

  String get name {
    String result = dartSuperClass;
    if (overrideName != "") {
      return result + overrideName;
    }
    if (hasSize) {
      result += "${size}Byte" + (size != 1 ? "s" : "");
    }
    if (hasNestedStructs) {
      result += "Nested";
    }
    if (hasInlineArrays) {
      result += "InlineArray";
      if (hasMultiDimensionalInlineArrays) {
        result += "MultiDimensional";
      }
    }
    if (members.length == 0) {
      // No suffix.
    } else if (isOnlyFloatingPoint) {
      result += "Float";
    } else if (isOnlyInteger) {
      result += "Int";
    } else {
      result += "Mixed";
    }
    result += suffix;
    return result;
  }
}

class FixedLengthArrayType extends CType {
  final CType elementType;
  final int length;

  FixedLengthArrayType(this.elementType, this.length);

  factory FixedLengthArrayType.multi(CType elementType, List<int> dimensions) {
    if (dimensions.length == 1) {
      return FixedLengthArrayType(elementType, dimensions.single);
    }

    final remainingDimensions = dimensions.sublist(1);
    final nestedArray = FixedLengthArrayType.multi(
      elementType,
      remainingDimensions,
    );
    return FixedLengthArrayType(nestedArray, dimensions.first);
  }

  String get cType => elementType.cType;
  String get dartCType => "Array<${elementType.dartCType}>";
  String get dartType => "Array<${elementType.dartCType}>";

  String get dartStructFieldAnnotation {
    if (dimensions.length > 5) {
      return "@Array.multi([${dimensions.join(", ")}])";
    }
    return "@Array(${dimensions.join(", ")})";
  }

  List<int> get dimensions {
    final elementType = this.elementType;
    if (elementType is FixedLengthArrayType) {
      return [length, ...elementType.dimensions];
    }
    return [length];
  }

  bool get isMulti => elementType is FixedLengthArrayType;

  bool get hasSize => elementType.hasSize;
  int get size => elementType.size * length;

  bool get isOnlyFloatingPoint => elementType.isOnlyFloatingPoint;
  bool get isOnlyInteger => elementType.isOnlyInteger;
  bool get isOnlyBool => elementType.isOnlyBool;
}

class VariableLengthArrayType extends FixedLengthArrayType {
  VariableLengthArrayType(CType elementType, {this.variableDimension = 0})
    : super(elementType, variableDimension);

  factory VariableLengthArrayType.multi(
    CType elementType,
    List<int> fixedDimensions, {
    int variableDimension = 0,
  }) {
    final nestedArray = FixedLengthArrayType.multi(
      elementType,
      fixedDimensions,
    );
    return VariableLengthArrayType(
      nestedArray,
      variableDimension: variableDimension,
    );
  }

  final int variableDimension;

  String get dartStructFieldAnnotation {
    if (dimensions.length > 5) {
      return variableDimension > 0
          ? "@Array.variableMulti(variableDimension: $variableDimension, [${dimensions.skip(1).join(", ")}])"
          : "@Array.variableMulti([${dimensions.skip(1).join(", ")}])";
    }
    return variableDimension > 0
        ? "@Array.variableWithVariableDimension($variableDimension, ${dimensions.skip(1).join(", ")})"
        : "@Array.variable(${dimensions.skip(1).join(", ")})";
  }
}

class FunctionType extends CType {
  final List<Member> arguments;
  final int? varArgsIndex;
  final CType returnValue;
  final String reason;

  List<CType> get argumentTypes => arguments.map((a) => a.type).toList();

  FunctionType(
    List<CType> argumentTypes,
    this.returnValue,
    this.reason, {
    this.varArgsIndex,
  }) : this.arguments = generateMemberNames(argumentTypes);

  FunctionType withVariadicArguments({int index = 1}) {
    if (index == 0) {
      throw "C does not support varargs at 0th argument";
    }
    if (arguments.length <= index) {
      throw "Cannot start varargs after arguments";
    }
    return FunctionType(
      argumentTypes,
      returnValue,
      reason,
      varArgsIndex: index,
    );
  }

  String get cType =>
      throw "Are not represented without function or variable name in C.";

  String get dartCType {
    String argumentsDartCType;
    final varArgsIndex_ = varArgsIndex;
    if (varArgsIndex_ == null) {
      argumentsDartCType = argumentTypes.map((e) => e.dartCType).join(', ');
    } else {
      final normalArgTypes = argumentTypes.take(varArgsIndex_).toList();
      final varArgTypes = argumentTypes.skip(varArgsIndex_).toList();
      final normalArgsString = normalArgTypes
          .map((e) => e.dartCType)
          .join(', ');
      final varArgString = varArgTypes.map((e) => e.dartCType).join(', ');
      final unaryRecordType = varArgTypes.length == 1;
      if (unaryRecordType) {
        argumentsDartCType = '$normalArgsString, VarArgs<($varArgString,)>';
      } else {
        argumentsDartCType = '$normalArgsString, VarArgs<($varArgString)>';
      }
    }
    return "${returnValue.dartCType} Function($argumentsDartCType)";
  }

  String get dartType {
    final argumentsDartType = argumentTypes.map((e) => e.dartType).join(", ");
    return "${returnValue.dartType} Function($argumentsDartType)";
  }

  String get dartStructFieldAnnotation => throw "No nested function pointers.";

  bool get hasSize => false;
  int get size => throw "Unknown size.";

  bool get isOnlyFloatingPoint => throw "Not implemented";
  bool get isOnlyInteger => throw "Not implemented";
  bool get isOnlyBool => throw "Not implemented";

  /// Group consecutive [arguments] by same type.
  ///
  /// Used for naming.
  List<List<Member>> get argumentsGrouped {
    List<List<Member>> result = [];
    for (final a in arguments) {
      if (result.isEmpty) {
        result.add([a]);
      } else if (result.last.first.type.dartCType == a.type.dartCType) {
        result.last.add(a);
      } else {
        result.add([a]);
      }
    }
    return result;
  }

  /// A suitable name based on the signature.
  String get cName {
    String result = "";
    if (varArgsIndex != null) {
      result = "VariadicAt$varArgsIndex";
    } else if (arguments.containsComposites && returnValue is FundamentalType) {
      result = "Pass";
    } else if (returnValue is StructType &&
        argumentTypes.contains(returnValue)) {
      result = "ReturnStructArgument";
    } else if (returnValue is UnionType &&
        argumentTypes.contains(returnValue)) {
      result = "ReturnUnionArgument";
    } else if (returnValue is StructType) {
      if (arguments.length == (returnValue as StructType).members.length) {
        return "Return${returnValue.dartCType}";
      }
    } else if (returnValue is UnionType && arguments.length == 1) {
      return "Return${returnValue.dartCType}";
    } else if (returnValue == uint64 && arguments.isEmpty) {
      result = "SizeOf${reason}";
    } else {
      result = "Uncategorized";
    }

    for (final group in argumentsGrouped) {
      final dartCType = group.first.type.dartCType
          .replaceAll('<', '')
          .replaceAll('>', '');
      result += dartCType;
      if (group.length > 1) {
        result += "x${group.length}";
      }
    }
    return result.limitTo(50);
  }

  String get dartTestName => "test$cName";

  String get dartName => cName.lowerCaseFirst();

  /// Only valid for [TestType.structReturnArgument].
  Member get structReturnArgument =>
      arguments.firstWhere((a) => a.type == returnValue);
}

extension MemberList on List<Member> {
  bool get containsComposites => map((m) {
    final type = m.type;
    switch (type) {
      case CompositeType _:
        return true;
      case PointerType _:
        final pointerTo = type.pointerTo;
        switch (pointerTo) {
          case CompositeType _:
            return true;
        }
    }
    return false;
  }).contains(true);

  bool get containsPointers => any((m) => m.type is PointerType);
}

extension ListT<T> on List<T> {
  Iterable<S> mapWithIndex<S>(S Function(int, T) f) =>
      asMap().entries.map((e) => f(e.key, e.value));
}
