// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/summary2/data_reader.dart';
import 'package:analyzer/src/summary2/data_writer.dart';

class ClassElementFlags {
  static const int _hasExtendsClause = 1 << 0;
  static const int _isAbstract = 1 << 1;
  static const int _isAugmentation = 1 << 2;
  static const int _isBase = 1 << 3;
  static const int _isFinal = 1 << 4;
  static const int _isInterface = 1 << 5;
  static const int _isMixinApplication = 1 << 6;
  static const int _isMixinClass = 1 << 7;
  static const int _isSealed = 1 << 8;
  static const int _isSimplyBounded = 1 << 9;

  static void read(SummaryDataReader reader, ClassFragmentImpl element) {
    var byte = reader.readUInt30();
    element.hasExtendsClause = (byte & _hasExtendsClause) != 0;
    element.isAbstract = (byte & _isAbstract) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isBase = (byte & _isBase) != 0;
    element.isFinal = (byte & _isFinal) != 0;
    element.isInterface = (byte & _isInterface) != 0;
    element.isMixinApplication = (byte & _isMixinApplication) != 0;
    element.isMixinClass = (byte & _isMixinClass) != 0;
    element.isSealed = (byte & _isSealed) != 0;
    element.isSimplyBounded = (byte & _isSimplyBounded) != 0;
  }

  static void write(BufferedSink sink, ClassFragmentImpl element) {
    var result = 0;
    result |= element.hasExtendsClause ? _hasExtendsClause : 0;
    result |= element.isAbstract ? _isAbstract : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isBase ? _isBase : 0;
    result |= element.isFinal ? _isFinal : 0;
    result |= element.isInterface ? _isInterface : 0;
    result |= element.isMixinApplication ? _isMixinApplication : 0;
    result |= element.isMixinClass ? _isMixinClass : 0;
    result |= element.isSealed ? _isSealed : 0;
    result |= element.isSimplyBounded ? _isSimplyBounded : 0;
    sink.writeUInt30(result);
  }
}

class ConstructorElementFlags {
  static const int _hasEnclosingTypeParameterReference = 1 << 0;
  static const int _isAugmentation = 1 << 1;
  static const int _isConst = 1 << 2;
  static const int _isExternal = 1 << 3;
  static const int _isFactory = 1 << 4;
  static const int _isSynthetic = 1 << 5;

  static void read(SummaryDataReader reader, ConstructorFragmentImpl element) {
    var byte = reader.readByte();
    element.hasEnclosingTypeParameterReference =
        (byte & _hasEnclosingTypeParameterReference) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isConst = (byte & _isConst) != 0;
    element.isExternal = (byte & _isExternal) != 0;
    element.isFactory = (byte & _isFactory) != 0;
    element.isSynthetic = (byte & _isSynthetic) != 0;
  }

  static void write(BufferedSink sink, ConstructorFragmentImpl element) {
    var result = 0;
    result |=
        element.hasEnclosingTypeParameterReference
            ? _hasEnclosingTypeParameterReference
            : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isConst ? _isConst : 0;
    result |= element.isExternal ? _isExternal : 0;
    result |= element.isFactory ? _isFactory : 0;
    result |= element.isSynthetic ? _isSynthetic : 0;
    sink.writeByte(result);
  }
}

class EnumElementFlags {
  static const int _isSimplyBounded = 1 << 0;
  static const int _isAugmentation = 1 << 1;

  static void read(SummaryDataReader reader, EnumFragmentImpl element) {
    var byte = reader.readByte();
    element.isSimplyBounded = (byte & _isSimplyBounded) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
  }

  static void write(BufferedSink sink, EnumFragmentImpl element) {
    var result = 0;
    result |= element.isSimplyBounded ? _isSimplyBounded : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    sink.writeByte(result);
  }
}

class ExtensionElementFlags {
  static const int _isAugmentation = 1 << 0;

  static void read(SummaryDataReader reader, ExtensionFragmentImpl element) {
    var byte = reader.readByte();
    element.isAugmentation = (byte & _isAugmentation) != 0;
  }

  static void write(BufferedSink sink, ExtensionFragmentImpl element) {
    var result = 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    sink.writeByte(result);
  }
}

class ExtensionTypeElementFlags {
  static const int _hasRepresentationSelfReference = 1 << 0;
  static const int _hasImplementsSelfReference = 1 << 1;
  static const int _isAugmentation = 1 << 2;
  static const int _isSimplyBounded = 1 << 3;

  static void read(
    SummaryDataReader reader,
    ExtensionTypeFragmentImpl element,
  ) {
    var byte = reader.readByte();
    element.hasRepresentationSelfReference =
        (byte & _hasRepresentationSelfReference) != 0;
    element.hasImplementsSelfReference =
        (byte & _hasImplementsSelfReference) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isSimplyBounded = (byte & _isSimplyBounded) != 0;
  }

  static void write(BufferedSink sink, ExtensionTypeFragmentImpl element) {
    var result = 0;
    result |=
        element.hasRepresentationSelfReference
            ? _hasRepresentationSelfReference
            : 0;
    result |=
        element.hasImplementsSelfReference ? _hasImplementsSelfReference : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isSimplyBounded ? _isSimplyBounded : 0;
    sink.writeByte(result);
  }
}

class FieldElementFlags {
  static const int _hasEnclosingTypeParameterReference = 1 << 0;
  static const int _hasImplicitType = 1 << 1;
  static const int _hasInitializer = 1 << 2;
  static const int _inheritsCovariant = 1 << 3;
  static const int _isAbstract = 1 << 4;
  static const int _isAugmentation = 1 << 5;
  static const int _isConst = 1 << 6;
  static const int _isCovariant = 1 << 7;
  static const int _isEnumConstant = 1 << 8;
  static const int _isExternal = 1 << 9;
  static const int _isFinal = 1 << 10;
  static const int _isLate = 1 << 11;
  static const int _isPromotable = 1 << 12;
  static const int _isStatic = 1 << 13;
  static const int _isSynthetic = 1 << 14;

  static void read(SummaryDataReader reader, FieldFragmentImpl element) {
    var byte = reader.readUInt30();
    element.hasEnclosingTypeParameterReference =
        (byte & _hasEnclosingTypeParameterReference) != 0;
    element.hasImplicitType = (byte & _hasImplicitType) != 0;
    element.hasInitializer = (byte & _hasInitializer) != 0;
    element.inheritsCovariant = (byte & _inheritsCovariant) != 0;
    element.isAbstract = (byte & _isAbstract) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isConst = (byte & _isConst) != 0;
    element.isCovariant = (byte & _isCovariant) != 0;
    element.isEnumConstant = (byte & _isEnumConstant) != 0;
    element.isExternal = (byte & _isExternal) != 0;
    element.isFinal = (byte & _isFinal) != 0;
    element.isLate = (byte & _isLate) != 0;
    element.isPromotable = (byte & _isPromotable) != 0;
    element.isStatic = (byte & _isStatic) != 0;
    element.isSynthetic = (byte & _isSynthetic) != 0;
  }

  static void write(BufferedSink sink, FieldFragmentImpl element) {
    var result = 0;
    result |=
        element.hasEnclosingTypeParameterReference
            ? _hasEnclosingTypeParameterReference
            : 0;
    result |= element.hasImplicitType ? _hasImplicitType : 0;
    result |= element.hasInitializer ? _hasInitializer : 0;
    result |= element.inheritsCovariant ? _inheritsCovariant : 0;
    result |= element.isAbstract ? _isAbstract : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isConst ? _isConst : 0;
    result |= element.isCovariant ? _isCovariant : 0;
    result |= element.isEnumConstant ? _isEnumConstant : 0;
    result |= element.isExternal ? _isExternal : 0;
    result |= element.isFinal ? _isFinal : 0;
    result |= element.isLate ? _isLate : 0;
    result |= element.isPromotable ? _isPromotable : 0;
    result |= element.isStatic ? _isStatic : 0;
    result |= element.isSynthetic ? _isSynthetic : 0;
    sink.writeUInt30(result);
  }
}

class FunctionElementFlags {
  static const int _hasImplicitReturnType = 1 << 0;
  static const int _isAsynchronous = 1 << 1;
  static const int _isAugmentation = 1 << 2;
  static const int _isExternal = 1 << 3;
  static const int _isGenerator = 1 << 4;
  static const int _isStatic = 1 << 5;

  static void read(
    SummaryDataReader reader,
    TopLevelFunctionFragmentImpl element,
  ) {
    var byte = reader.readByte();
    element.hasImplicitReturnType = (byte & _hasImplicitReturnType) != 0;
    element.isAsynchronous = (byte & _isAsynchronous) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isExternal = (byte & _isExternal) != 0;
    element.isGenerator = (byte & _isGenerator) != 0;
    element.isStatic = (byte & _isStatic) != 0;
  }

  static void write(BufferedSink sink, FunctionFragmentImpl element) {
    var result = 0;
    result |= element.hasImplicitReturnType ? _hasImplicitReturnType : 0;
    result |= element.isAsynchronous ? _isAsynchronous : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isExternal ? _isExternal : 0;
    result |= element.isGenerator ? _isGenerator : 0;
    result |= element.isStatic ? _isStatic : 0;
    sink.writeByte(result);
  }
}

class LibraryElementFlags {
  static const int _hasPartOfDirective = 1 << 0;
  static const int _isSynthetic = 1 << 1;

  static void read(SummaryDataReader reader, LibraryElementImpl element) {
    var byte = reader.readByte();
    element.hasPartOfDirective = (byte & _hasPartOfDirective) != 0;
    element.isSynthetic = (byte & _isSynthetic) != 0;
  }

  static void write(BufferedSink sink, LibraryElementImpl element) {
    var result = 0;
    result |= element.hasPartOfDirective ? _hasPartOfDirective : 0;
    result |= element.isSynthetic ? _isSynthetic : 0;
    sink.writeByte(result);
  }
}

class MethodElementFlags {
  static const int _hasImplicitReturnType = 1 << 0;
  static const int _hasEnclosingTypeParameterReference = 1 << 1;
  static const int _invokesSuperSelf = 1 << 2;
  static const int _isAbstract = 1 << 3;
  static const int _isAsynchronous = 1 << 4;
  static const int _isAugmentation = 1 << 5;
  static const int _isExternal = 1 << 6;
  static const int _isGenerator = 1 << 7;
  static const int _isStatic = 1 << 8;
  static const int _isSynthetic = 1 << 9;

  static void read(SummaryDataReader reader, MethodFragmentImpl element) {
    var bits = reader.readUInt30();
    element.hasImplicitReturnType = (bits & _hasImplicitReturnType) != 0;
    element.hasEnclosingTypeParameterReference =
        (bits & _hasEnclosingTypeParameterReference) != 0;
    element.invokesSuperSelf = (bits & _invokesSuperSelf) != 0;
    element.isAbstract = (bits & _isAbstract) != 0;
    element.isAsynchronous = (bits & _isAsynchronous) != 0;
    element.isAugmentation = (bits & _isAugmentation) != 0;
    element.isExternal = (bits & _isExternal) != 0;
    element.isGenerator = (bits & _isGenerator) != 0;
    element.isStatic = (bits & _isStatic) != 0;
    element.isSynthetic = (bits & _isSynthetic) != 0;
  }

  static void write(BufferedSink sink, MethodFragmentImpl element) {
    var result = 0;
    result |= element.hasImplicitReturnType ? _hasImplicitReturnType : 0;
    result |=
        element.hasEnclosingTypeParameterReference
            ? _hasEnclosingTypeParameterReference
            : 0;
    result |= element.invokesSuperSelf ? _invokesSuperSelf : 0;
    result |= element.isAbstract ? _isAbstract : 0;
    result |= element.isAsynchronous ? _isAsynchronous : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isExternal ? _isExternal : 0;
    result |= element.isGenerator ? _isGenerator : 0;
    result |= element.isStatic ? _isStatic : 0;
    result |= element.isSynthetic ? _isSynthetic : 0;
    sink.writeUInt30(result);
  }
}

class MixinElementFlags {
  static const int _isAugmentation = 1 << 0;
  static const int _isBase = 1 << 1;
  static const int _isSimplyBounded = 1 << 2;

  static void read(SummaryDataReader reader, MixinFragmentImpl element) {
    var byte = reader.readByte();
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isBase = (byte & _isBase) != 0;
    element.isSimplyBounded = (byte & _isSimplyBounded) != 0;
  }

  static void write(BufferedSink sink, MixinFragmentImpl element) {
    var result = 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isBase ? _isBase : 0;
    result |= element.isSimplyBounded ? _isSimplyBounded : 0;
    sink.writeByte(result);
  }
}

class ParameterElementFlags {
  static const int _hasImplicitType = 1 << 0;
  static const int _isExplicitlyCovariant = 1 << 1;
  static const int _isFinal = 1 << 2;

  static void read(
    SummaryDataReader reader,
    FormalParameterFragmentImpl element,
  ) {
    var byte = reader.readByte();
    element.hasImplicitType = (byte & _hasImplicitType) != 0;
    element.isExplicitlyCovariant = (byte & _isExplicitlyCovariant) != 0;
    element.isFinal = (byte & _isFinal) != 0;
  }

  static void write(BufferedSink sink, FormalParameterFragmentImpl element) {
    var result = 0;
    result |= element.hasImplicitType ? _hasImplicitType : 0;
    result |= element.isExplicitlyCovariant ? _isExplicitlyCovariant : 0;
    result |= element.isFinal ? _isFinal : 0;
    sink.writeByte(result);
  }
}

class PropertyAccessorElementFlags {
  static const int _hasEnclosingTypeParameterReference = 1 << 0;
  static const int _invokesSuperSelf = 1 << 1;
  static const int _isAugmentation = 1 << 2;
  static const int _isGetter = 1 << 3;
  static const int _isSetter = 1 << 4;
  static const int _hasImplicitReturnType = 1 << 5;
  static const int _isAbstract = 1 << 6;
  static const int _isAsynchronous = 1 << 7;
  static const int _isExternal = 1 << 8;
  static const int _isGenerator = 1 << 9;
  static const int _isStatic = 1 << 10;
  static const int _isSynthetic = 1 << 11;

  static bool isGetter(int flags) => (flags & _isGetter) != 0;

  static void read(
    SummaryDataReader reader,
    PropertyAccessorFragmentImpl element,
  ) {
    var byte = reader.readUInt30();
    setFlagsBasedOnFlagByte(element, byte);
  }

  static void setFlagsBasedOnFlagByte(
    PropertyAccessorFragmentImpl element,
    int byte,
  ) {
    element.hasEnclosingTypeParameterReference =
        (byte & _hasEnclosingTypeParameterReference) != 0;
    element.invokesSuperSelf = (byte & _invokesSuperSelf) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.hasImplicitReturnType = (byte & _hasImplicitReturnType) != 0;
    element.isAbstract = (byte & _isAbstract) != 0;
    element.isAsynchronous = (byte & _isAsynchronous) != 0;
    element.isExternal = (byte & _isExternal) != 0;
    element.isGenerator = (byte & _isGenerator) != 0;
    element.isStatic = (byte & _isStatic) != 0;
    element.isSynthetic = (byte & _isSynthetic) != 0;
  }

  static void write(BufferedSink sink, PropertyAccessorFragmentImpl element) {
    var result = 0;
    result |=
        element.hasEnclosingTypeParameterReference
            ? _hasEnclosingTypeParameterReference
            : 0;
    result |= element.invokesSuperSelf ? _invokesSuperSelf : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element is GetterFragmentImpl ? _isGetter : 0;
    result |= element is SetterFragmentImpl ? _isSetter : 0;
    result |= element.hasImplicitReturnType ? _hasImplicitReturnType : 0;
    result |= element.isAbstract ? _isAbstract : 0;
    result |= element.isAsynchronous ? _isAsynchronous : 0;
    result |= element.isExternal ? _isExternal : 0;
    result |= element.isGenerator ? _isGenerator : 0;
    result |= element.isStatic ? _isStatic : 0;
    result |= element.isSynthetic ? _isSynthetic : 0;
    sink.writeUInt30(result);
  }
}

class TopLevelVariableElementFlags {
  static const int _hasImplicitType = 1 << 0;
  static const int _hasInitializer = 1 << 1;
  static const int _isAugmentation = 1 << 2;
  static const int _isExternal = 1 << 3;
  static const int _isFinal = 1 << 4;
  static const int _isLate = 1 << 5;
  static const int _isSynthetic = 1 << 6;

  static void read(
    SummaryDataReader reader,
    TopLevelVariableFragmentImpl element,
  ) {
    var byte = reader.readByte();
    element.hasImplicitType = (byte & _hasImplicitType) != 0;
    element.hasInitializer = (byte & _hasInitializer) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isExternal = (byte & _isExternal) != 0;
    element.isFinal = (byte & _isFinal) != 0;
    element.isLate = (byte & _isLate) != 0;
    element.isSynthetic = (byte & _isSynthetic) != 0;
  }

  static void write(BufferedSink sink, TopLevelVariableFragmentImpl element) {
    var result = 0;
    result |= element.hasImplicitType ? _hasImplicitType : 0;
    result |= element.hasInitializer ? _hasInitializer : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isExternal ? _isExternal : 0;
    result |= element.isFinal ? _isFinal : 0;
    result |= element.isLate ? _isLate : 0;
    result |= element.isSynthetic ? _isSynthetic : 0;
    sink.writeByte(result);
  }
}

class TypeAliasElementFlags {
  static const int _hasSelfReference = 1 << 1;
  static const int _isAugmentation = 1 << 2;
  static const int _isSimplyBounded = 1 << 3;

  static void read(SummaryDataReader reader, TypeAliasFragmentImpl element) {
    var byte = reader.readByte();
    element.hasSelfReference = (byte & _hasSelfReference) != 0;
    element.isAugmentation = (byte & _isAugmentation) != 0;
    element.isSimplyBounded = (byte & _isSimplyBounded) != 0;
  }

  static void write(BufferedSink sink, TypeAliasFragmentImpl element) {
    var result = 0;
    result |= element.hasSelfReference ? _hasSelfReference : 0;
    result |= element.isAugmentation ? _isAugmentation : 0;
    result |= element.isSimplyBounded ? _isSimplyBounded : 0;
    sink.writeByte(result);
  }
}
