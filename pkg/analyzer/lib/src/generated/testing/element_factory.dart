// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer_operations.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/dart/analysis/session.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/source.dart' show NonExistingSource;
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:analyzer/src/summary2/reference.dart';
import 'package:analyzer/src/utilities/extensions/string.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart';

/// The class `ElementFactory` defines utility methods used to create elements
/// for testing purposes. The elements that are created are complete in the
/// sense that as much of the element model as can be created, given the
/// provided information, has been created.
@internal
class ElementFactory {
  /// The element representing the class 'Object'.
  static ClassElementImpl? _objectElement;
  static InterfaceType? _objectType;

  static ClassElementImpl get object {
    return _objectElement ??= classElement("Object", null);
  }

  static InterfaceType get objectType {
    return _objectType ??= object.instantiateImpl(
      typeArguments: const [],
      nullabilitySuffix: NullabilitySuffix.none,
    );
  }

  static ClassElementImpl classElement(
      String typeName, InterfaceType? superclassType,
      [List<String>? parameterNames]) {
    var fragment = ClassElementImpl(typeName, 0);
    fragment.constructors = const <ConstructorElementImpl>[];
    fragment.supertype = superclassType;
    if (parameterNames != null) {
      fragment.typeParameters = typeParameters(parameterNames);
    }

    ClassElementImpl2(Reference.root(), fragment);

    return fragment;
  }

  static ClassElementImpl classElement2(String typeName,
          [List<String>? parameterNames]) =>
      classElement(typeName, objectType, parameterNames);

  static ClassElementImpl classElement3({
    required String name,
    List<TypeParameterElementImpl>? typeParameters,
    List<String> typeParameterNames = const [],
    InterfaceType? supertype,
    List<InterfaceType> mixins = const [],
    List<InterfaceType> interfaces = const [],
  }) {
    typeParameters ??= ElementFactory.typeParameters(typeParameterNames);
    supertype ??= objectType;

    var fragment = ClassElementImpl(name, 0);
    fragment.typeParameters = typeParameters;
    fragment.supertype = supertype;
    fragment.mixins = mixins;
    fragment.interfaces = interfaces;
    fragment.constructors = const <ConstructorElementImpl>[];

    ClassElementImpl2(Reference.root(), fragment);

    return fragment;
  }

  static ClassElementImpl classElement4(String typeName,
          {bool isBase = false,
          bool isInterface = false,
          bool isFinal = false,
          bool isSealed = false,
          bool isMixinClass = false}) =>
      classElement2(typeName)
        ..isBase = isBase
        ..isInterface = isInterface
        ..isFinal = isFinal
        ..isSealed = isSealed
        ..isMixinClass = isMixinClass;

  static ClassElementImpl classTypeAlias(
      String typeName, InterfaceType superclassType,
      [List<String>? parameterNames]) {
    ClassElementImpl element =
        classElement(typeName, superclassType, parameterNames);
    element.isMixinApplication = true;
    return element;
  }

  static ClassElementImpl classTypeAlias2(String typeName,
          [List<String>? parameterNames]) =>
      classTypeAlias(typeName, objectType, parameterNames);

  static ConstLocalVariableElementImpl constLocalVariableElement(String name) =>
      ConstLocalVariableElementImpl(name, 0);

  static ConstructorElementImpl constructorElement(
      ClassElementImpl definingClass, String? name, bool isConst,
      [List<TypeImpl> argumentTypes = const []]) {
    var offset = name == null ? -1 : 0;
    // A constructor declared as `C.new` is unnamed, and is modeled as such.
    var constructor = name == null || name == 'new'
        ? ConstructorElementImpl('', offset)
        : ConstructorElementImpl(name, offset);
    constructor.name2 = name ?? 'new';
    if (name != null) {
      if (name.isEmpty) {
        constructor.nameEnd = definingClass.name.length;
      } else {
        constructor.periodOffset = definingClass.name.length;
        constructor.nameEnd = definingClass.name.length + name.length + 1;
      }
    }
    constructor.isSynthetic = name == null;
    constructor.isConst = isConst;
    constructor.parameters = _requiredParameters(argumentTypes);
    constructor.enclosingElement3 = definingClass;
    if (!constructor.isSynthetic) {
      constructor.constantInitializers = <ConstructorInitializer>[];
    }
    return constructor;
  }

  static ConstructorElementImpl constructorElement2(
          ClassElementImpl definingClass, String? name,
          [List<TypeImpl> argumentTypes = const []]) =>
      constructorElement(definingClass, name, false, argumentTypes);

  static FieldElementImpl fieldElement(
      String name, bool isStatic, bool isFinal, bool isConst, TypeImpl type,
      {ExpressionImpl? initializer}) {
    FieldElementImpl field =
        isConst ? ConstFieldElementImpl(name, 0) : FieldElementImpl(name, 0);
    field.isConst = isConst;
    field.isFinal = isFinal;
    field.isStatic = isStatic;
    field.type = type;
    if (isConst) {
      (field as ConstFieldElementImpl).constantInitializer = initializer;
    }
    PropertyAccessorElementImpl_ImplicitGetter(field);
    if (!isConst && !isFinal) {
      PropertyAccessorElementImpl_ImplicitSetter(field);
    }
    return field;
  }

  static FieldFormalParameterElementImpl fieldFormalParameter(
          Identifier name) =>
      FieldFormalParameterElementImpl(
        name: name.name,
        nameOffset: name.offset,
        name2: name.name.nullIfEmpty,
        nameOffset2: name.offset.nullIfNegative,
        parameterKind: ParameterKind.REQUIRED,
      );

  /// Destroy any static state retained by [ElementFactory].  This should be
  /// called from the `setUp` method of any tests that use [ElementFactory], in
  /// order to ensure that state is not shared between multiple tests.
  static void flushStaticState() {
    _objectElement = null;
  }

  static GetterFragmentImpl getterElement(
      String name, bool isStatic, TypeImpl type) {
    FieldElementImpl field = FieldElementImpl(name, -1);
    field.isStatic = isStatic;
    field.isSynthetic = true;
    field.type = type;
    field.isFinal = true;
    GetterFragmentImpl getter = GetterFragmentImpl(name, 0);
    getter.name2 = name;
    getter.isSynthetic = false;
    getter.variable2 = field;
    getter.returnType = type;
    getter.isStatic = isStatic;
    field.getter = getter;
    return getter;
  }

  static LibraryElementImpl library(AnalysisContext context, String libraryName,
      {FeatureSet? featureSet}) {
    FeatureSet features = featureSet ?? FeatureSet.latestLanguageVersion();
    String fileName = "/$libraryName.dart";
    LibraryElementImpl library = LibraryElementImpl(
      context,
      _MockAnalysisSession(),
      libraryName,
      0,
      libraryName.length,
      features,
    );
    library.definingCompilationUnit = CompilationUnitElementImpl(
      library: library,
      source: NonExistingSource(fileName, toUri(fileName)),
      lineInfo: LineInfo([0]),
    );
    return library;
  }

  static LocalVariableElementImpl localVariableElement(Identifier name) =>
      LocalVariableElementImpl(name.name, name.offset);

  static LocalVariableElementImpl localVariableElement2(String name) =>
      LocalVariableElementImpl(name, 0);

  static MethodElementImpl methodElement(String methodName, DartType returnType,
      [List<TypeImpl> argumentTypes = const []]) {
    MethodElementImpl method = MethodElementImpl(methodName, 0);
    method.parameters = _requiredParameters(argumentTypes);
    method.returnType = returnType;
    return method;
  }

  static MethodElementImpl methodElementWithParameters(
      ClassElementImpl enclosingElement,
      String methodName,
      DartType returnType,
      List<ParameterElementImpl> parameters) {
    MethodElementImpl method = MethodElementImpl(methodName, 0);
    method.enclosingElement3 = enclosingElement;
    method.parameters = parameters;
    method.returnType = returnType;
    return method;
  }

  static MixinElementImpl mixinElement(
      {required String name,
      List<TypeParameterElementImpl>? typeParameters,
      List<String> typeParameterNames = const [],
      List<InterfaceType> constraints = const [],
      List<InterfaceType> interfaces = const [],
      bool isBase = false}) {
    typeParameters ??= ElementFactory.typeParameters(typeParameterNames);

    if (constraints.isEmpty) {
      constraints = [objectType];
    }

    var element = MixinElementImpl(name, 0);
    element.typeParameters = typeParameters;
    element.superclassConstraints = constraints;
    element.interfaces = interfaces;
    element.constructors = const <ConstructorElementImpl>[];
    element.isBase = isBase;
    return element;
  }

  static ParameterElementImpl namedParameter(String name) {
    return ParameterElementImpl(
      name: name,
      nameOffset: 0,
      name2: name,
      nameOffset2: 0,
      parameterKind: ParameterKind.NAMED,
    );
  }

  static ParameterElementImpl namedParameter2(String name, TypeImpl type) {
    var parameter = ParameterElementImpl(
      name: name,
      nameOffset: 0,
      name2: name,
      nameOffset2: 0,
      parameterKind: ParameterKind.NAMED,
    );
    parameter.type = type;
    return parameter;
  }

  static ParameterElementImpl positionalParameter(String name) {
    return ParameterElementImpl(
      name: name,
      nameOffset: 0,
      name2: name,
      nameOffset2: 0,
      parameterKind: ParameterKind.POSITIONAL,
    );
  }

  static ParameterElementImpl positionalParameter2(String name, TypeImpl type) {
    var parameter = ParameterElementImpl(
      name: name,
      nameOffset: 0,
      name2: name,
      nameOffset2: 0,
      parameterKind: ParameterKind.POSITIONAL,
    );
    parameter.type = type;
    return parameter;
  }

  static PrefixElementImpl prefix(String name) => PrefixElementImpl(name, 0);

  static ParameterElementImpl requiredParameter(String name) {
    return ParameterElementImpl(
      name: name,
      nameOffset: 0,
      name2: name,
      nameOffset2: 0,
      parameterKind: ParameterKind.REQUIRED,
    );
  }

  static ParameterElementImpl requiredParameter2(String name, TypeImpl type) {
    var parameter = ParameterElementImpl(
      name: name,
      nameOffset: 0,
      name2: name,
      nameOffset2: 0,
      parameterKind: ParameterKind.REQUIRED,
    );
    parameter.type = type;
    return parameter;
  }

  static PropertyAccessorElementImpl setterElement(
      String name, bool isStatic, TypeImpl type) {
    FieldElementImpl field = FieldElementImpl(name, -1);
    field.isStatic = isStatic;
    field.isSynthetic = true;
    field.type = type;
    GetterFragmentImpl getter = GetterFragmentImpl(name, -1);
    getter.name2 = name;
    getter.variable2 = field;
    getter.returnType = type;
    field.getter = getter;
    ParameterElementImpl parameter = requiredParameter2("a", type);
    SetterFragmentImpl setter = SetterFragmentImpl(name, -1);
    setter.name2 = name;
    setter.isSynthetic = true;
    setter.variable2 = field;
    setter.parameters = [parameter];
    setter.returnType = VoidTypeImpl.instance;
    setter.isStatic = isStatic;
    field.setter = setter;
    return setter;
  }

  static TopLevelVariableElementImpl topLevelVariableElement(Identifier name) =>
      TopLevelVariableElementImpl(name.name, name.offset);

  static TypeParameterElementImpl typeParameterElement(String name) {
    return TypeParameterElementImpl(name, 0);
  }

  static List<TypeParameterElementImpl> typeParameters(List<String> names) {
    return names.map((name) => typeParameterWithType(name)).toList();
  }

  static TypeParameterElementImpl typeParameterWithType(String name,
      [DartType? bound, Variance? variance]) {
    TypeParameterElementImpl typeParameter = typeParameterElement(name);
    typeParameter.bound = bound;
    typeParameter.variance = variance;
    return typeParameter;
  }

  static List<ParameterElementImpl> _requiredParameters(
      List<TypeImpl> argumentTypes) {
    var parameters = argumentTypes.mapIndexed((index, type) {
      var parameter = ParameterElementImpl(
        name: 'a$index',
        nameOffset: index,
        name2: 'a$index',
        nameOffset2: index,
        parameterKind: ParameterKind.REQUIRED,
      );
      parameter.type = type;
      return parameter;
    }).toList();
    return parameters;
  }
}

class _MockAnalysisSession implements AnalysisSessionImpl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
