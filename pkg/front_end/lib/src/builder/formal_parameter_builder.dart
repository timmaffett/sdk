// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/parser/formal_parameter_kind.dart'
    show FormalParameterKind;
import 'package:_fe_analyzer_shared/src/scanner/scanner.dart' show Token;
import 'package:kernel/ast.dart'
    show
        DartType,
        DynamicType,
        Expression,
        InvalidExpression,
        NullLiteral,
        VariableDeclaration;
import 'package:kernel/class_hierarchy.dart';

import '../base/constant_context.dart' show ConstantContext;
import '../base/lookup_result.dart';
import '../base/modifiers.dart';
import '../base/scope.dart' show LookupScope;
import '../kernel/body_builder.dart' show BodyBuilder;
import '../kernel/body_builder_context.dart';
import '../kernel/internal_ast.dart' show VariableDeclarationImpl;
import '../kernel/wildcard_lowering.dart';
import '../source/fragment_factory.dart';
import '../source/source_constructor_builder.dart';
import '../source/source_factory_builder.dart';
import '../source/source_library_builder.dart';
import '../source/source_property_builder.dart';
import 'builder.dart';
import 'constructor_builder.dart';
import 'declaration_builders.dart';
import 'member_builder.dart';
import 'omitted_type_builder.dart';
import 'property_builder.dart';
import 'type_builder.dart';
import 'variable_builder.dart';

abstract class ParameterBuilder {
  TypeBuilder get type;

  /// The kind of this parameter, i.e. if it's required, positional optional,
  /// or named optional.
  FormalParameterKind get kind;

  bool get isPositional;

  bool get isRequiredPositional;

  bool get isNamed;

  bool get isRequiredNamed;

  String? get name;
}

/// A builder for a formal parameter, i.e. a parameter on a method or
/// constructor.
class FormalParameterBuilder extends NamedBuilderImpl
    with LookupResultMixin
    implements VariableBuilder, ParameterBuilder, InferredTypeListener {
  static const String noNameSentinel = 'no name sentinel';

  @override
  final int fileOffset;

  final Modifiers modifiers;

  @override
  TypeBuilder type;

  @override
  final String name;

  @override
  final Uri fileUri;

  @override
  final FormalParameterKind kind;

  /// The variable declaration created for this formal parameter.
  @override
  VariableDeclaration? variable;

  /// The first token of the default value, if any.
  ///
  /// This is stored until outlines have been built through
  /// [buildOutlineExpressions].
  Token? initializerToken;

  bool initializerWasInferred = false;

  /// True if the initializer was declared by the programmer.
  final bool hasImmediatelyDeclaredInitializer;

  /// True if the initializer was declared by the programmer, either directly
  /// or inferred from a super parameter.
  bool hasDeclaredInitializer;

  final bool isExtensionThis;

  /// Whether this formal parameter is a wildcard variable.
  final bool isWildcard;

  FormalParameterBuilder(
      this.kind, this.modifiers, this.type, this.name, this.fileOffset,
      {required this.fileUri,
      this.isExtensionThis = false,
      required this.hasImmediatelyDeclaredInitializer,
      this.isWildcard = false})
      : this.hasDeclaredInitializer = hasImmediatelyDeclaredInitializer {
    type.registerInferredTypeListener(this);
  }

  @override
  // Coverage-ignore(suite): Not run.
  Builder? get parent => null;

  @override
  bool get isRequiredPositional => kind.isRequiredPositional;

  // TODO(johnniwinther): This was previously named `isOptional` so we might
  // have some uses that intended to use the now existing `isOptional` method.
  bool get isOptionalPositional => !isRequiredPositional;

  @override
  bool get isRequiredNamed => kind.isRequiredNamed;

  @override
  bool get isPositional => kind.isPositional;

  @override
  bool get isNamed => kind.isNamed;

  bool get isOptional => kind.isOptional;

  bool get isInitializingFormal => modifiers.isInitializingFormal;

  bool get isSuperInitializingFormal => modifiers.isSuperInitializingFormal;

  bool get isCovariantByDeclaration => modifiers.isCovariant;

  @override
  bool get isConst => modifiers.isConst;

  // An initializing formal parameter might be final without its
  // VariableDeclaration being final. See
  // [ProcedureBuilder.computeFormalParameterInitializerScope]..
  @override
  bool get isAssignable =>
      variable!.isAssignable &&
      !isInitializingFormal &&
      !isSuperInitializingFormal;

  @override
  NamedBuilder get getable => this;

  @override
  NamedBuilder? get setable => isAssignable ? this : null;

  @override
  // Coverage-ignore(suite): Not run.
  String get fullNameForErrors => name;

  VariableDeclaration build(SourceLibraryBuilder library) {
    if (variable == null) {
      bool isTypeOmitted = type is OmittedTypeBuilder;
      DartType? builtType = type.build(library, TypeUse.parameterType);
      variable = new VariableDeclarationImpl(
          name == noNameSentinel ? null : name,
          // `null` is used in [VariableDeclarationImpl] to signal an omitted
          // type.
          type: isTypeOmitted ? null : builtType,
          isFinal: modifiers.isFinal,
          isConst: false,
          isInitializingFormal: isInitializingFormal,
          isSuperInitializingFormal: isSuperInitializingFormal,
          isCovariantByDeclaration: isCovariantByDeclaration,
          isRequired: isRequiredNamed,
          hasDeclaredInitializer: hasDeclaredInitializer,
          isLowered: isExtensionThis,
          isSynthesized: name == noNameSentinel,
          isWildcard: isWildcard)
        ..fileOffset = fileOffset;
    }
    return variable!;
  }

  @override
  void onInferredType(DartType type) {
    if (variable != null) {
      variable!.type = type;
    }
  }

  FormalParameterBuilder forPrimaryConstructor(FragmentFactory builderFactory) {
    return new FormalParameterBuilder(
        kind,
        modifiers | Modifiers.InitializingFormal,
        builderFactory.addInferableType(),
        name,
        fileOffset,
        fileUri: fileUri,
        isExtensionThis: isExtensionThis,
        hasImmediatelyDeclaredInitializer: hasImmediatelyDeclaredInitializer)
      ..variable = variable;
  }

  FormalParameterBuilder forFormalParameterInitializerScope() {
    if (isInitializingFormal) {
      return new FormalParameterBuilder(
          kind,
          modifiers | Modifiers.Final | Modifiers.InitializingFormal,
          type,
          name,
          fileOffset,
          fileUri: fileUri,
          isExtensionThis: isExtensionThis,
          hasImmediatelyDeclaredInitializer: hasImmediatelyDeclaredInitializer)
        ..variable = variable;
    } else if (isSuperInitializingFormal) {
      return new FormalParameterBuilder(
          kind,
          modifiers | Modifiers.Final | Modifiers.SuperInitializingFormal,
          type,
          name,
          fileOffset,
          fileUri: fileUri,
          isExtensionThis: isExtensionThis,
          hasImmediatelyDeclaredInitializer: hasImmediatelyDeclaredInitializer)
        ..variable = variable;
    } else {
      return this;
    }
  }

  void finalizeInitializingFormal(
      DeclarationBuilder declarationBuilder,
      SourceConstructorBuilder constructorBuilder,
      ClassHierarchyBase hierarchy) {
    String fieldName = isWildcardLoweredFormalParameter(name) ? '_' : name;
    LookupResult? result = declarationBuilder.lookupLocalMember(fieldName);
    Builder? fieldBuilder = result?.getable;
    if (result is DuplicateMemberLookupResult) {
      fieldBuilder = result.declarations.first;
    }
    if (fieldBuilder is SourcePropertyBuilder && fieldBuilder.hasField) {
      DartType fieldType = fieldBuilder.inferFieldType(hierarchy);
      fieldType = constructorBuilder.substituteFieldType(fieldType);
      type.registerInferredType(fieldType);
    } else {
      type.registerInferredType(const DynamicType());
    }
  }

  static bool needsDefaultValuesBuiltAsOutlineExpressions(
      MemberBuilder memberBuilder) {
    // For modular compilation we need to include default values for optional
    // and named parameters in several cases:
    // * for const constructors to enable constant evaluation,
    // * for instance methods because these might be needed to generated
    //   noSuchMethod forwarders,
    // * for generative constructors to support forwarding constructors
    //   in mixin applications, and
    // * for factories, to uphold the invariant that optional parameters always
    //   have default values, even during modular compilation.
    if (memberBuilder is ConstructorBuilder) {
      return true;
    } else if (memberBuilder is SourceFactoryBuilder) {
      return true;
    } else {
      // Coverage-ignore-block(suite): Not run.
      return memberBuilder.isClassInstanceMember;
    }
  }

  /// Builds the default value from this [initializerToken] if this is a
  /// formal parameter on a const constructor or instance method.
  void buildOutlineExpressions(SourceLibraryBuilder libraryBuilder,
      DeclarationBuilder? declarationBuilder,
      {required LookupScope scope, required bool buildDefaultValue}) {
    if (buildDefaultValue) {
      if (initializerToken != null) {
        BodyBuilderContext bodyBuilderContext = new ParameterBodyBuilderContext(
            libraryBuilder, declarationBuilder, this);
        BodyBuilder bodyBuilder = libraryBuilder.loader
            .createBodyBuilderForOutlineExpression(
                libraryBuilder, bodyBuilderContext, scope, fileUri);
        bodyBuilder.constantContext = ConstantContext.required;
        assert(!initializerWasInferred);
        Expression initializer =
            bodyBuilder.parseFieldInitializer(initializerToken!);
        initializer = bodyBuilder.typeInferrer.inferParameterInitializer(
            bodyBuilder, initializer, variable!.type, hasDeclaredInitializer);
        variable!.initializer = initializer..parent = variable;
        if (initializer is InvalidExpression) {
          variable!.isErroneouslyInitialized = true;
        }
        initializerWasInferred = true;
        bodyBuilder.performBacklogComputations();
      } else if (kind.isOptional) {
        // As done by BodyBuilder.endFormalParameter.
        variable!.initializer = new NullLiteral()..parent = variable;
      }
    }
    initializerToken = null;
  }

  @override
  String toString() => '$runtimeType($name)';
}

class FunctionTypeParameterBuilder implements ParameterBuilder {
  @override
  final FormalParameterKind kind;

  @override
  final TypeBuilder type;

  @override
  final String? name;

  FunctionTypeParameterBuilder(this.kind, this.type, this.name);

  @override
  bool get isNamed => kind.isNamed;

  @override
  bool get isRequiredNamed => kind.isRequiredNamed;

  @override
  bool get isPositional => kind.isPositional;

  @override
  bool get isRequiredPositional => kind.isRequiredPositional;
}
