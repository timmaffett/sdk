// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/scanner/token.dart' show Token;
import 'package:kernel/ast.dart';
import 'package:kernel/type_algebra.dart';
import 'package:kernel/type_environment.dart';

import '../api_prototype/experimental_flags.dart';
import '../base/constant_context.dart' show ConstantContext;
import '../base/lookup_result.dart';
import '../base/messages.dart' show Message;
import '../base/scope.dart';
import '../builder/builder.dart';
import '../builder/declaration_builders.dart';
import '../builder/formal_parameter_builder.dart';
import '../builder/library_builder.dart';
import '../builder/named_type_builder.dart';
import '../builder/prefix_builder.dart';
import '../builder/type_builder.dart';
import '../codes/cfe_codes.dart' show LocatedMessage;
import '../source/source_library_builder.dart' show SourceLibraryBuilder;
import '../type_inference/inference_helper.dart' show InferenceHelper;
import 'constness.dart' show Constness;
import 'expression_generator.dart';
import 'forest.dart' show Forest;
import 'internal_ast.dart';

/// Alias for Expression | Generator
typedef Expression_Generator = dynamic;

/// Alias for Expression | Generator | Builder
typedef Expression_Generator_Builder = dynamic;

/// Alias for Expression | Generator | Initializer
typedef Expression_Generator_Initializer = dynamic;

/// Alias for Expression | Initializer
typedef Expression_Initializer = dynamic;

abstract class ExpressionGeneratorHelper implements InferenceHelper {
  SourceLibraryBuilder get libraryBuilder;

  ConstantContext get constantContext;

  /// Whether instance type parameters can be accessed.
  ///
  /// This is used when creating [NamedTypeBuilder]s within
  /// [ExpressionGenerator]s.
  InstanceTypeParameterAccessState get instanceTypeParameterAccessState;

  Forest get forest;

  MemberLookupResult? lookupSuperConstructor(
      String name, LibraryBuilder accessingLibrary);

  Expression toValue(Object? node);

  Member? lookupSuperMember(Name name, {bool isSetter});

  LibraryFeatures get libraryFeatures;

  bool isDeclaredInEnclosingCase(VariableDeclaration variable);

  Generator processLookupResult(
      {required LookupResult? lookupResult,
      required String name,
      required Token nameToken,
      required int nameOffset,
      required ScopeKind scopeKind,
      PrefixBuilder? prefix,
      Token? prefixToken});

  Expression_Generator_Initializer finishSend(Object receiver,
      List<TypeBuilder>? typeArguments, ArgumentsImpl arguments, int offset,
      {bool isTypeArgumentsInForest = false});

  Initializer buildInvalidInitializer(Expression expression,
      [int offset = TreeNode.noOffset]);

  List<Initializer> buildFieldInitializer(String name, int fieldNameOffset,
      int assignmentOffset, Expression expression,
      {FormalParameterBuilder? formal});

  Initializer buildSuperInitializer(
      bool isSynthetic, Constructor constructor, Arguments arguments,
      [int offset = TreeNode.noOffset]);

  Initializer buildRedirectingInitializer(Name name, Arguments arguments,
      {required int fileOffset});

  Expression buildStaticInvocation(Member target, Arguments arguments,
      {Constness constness = Constness.implicit,
      int charOffset = TreeNode.noOffset,
      required bool isConstructorInvocation});

  Expression buildExtensionMethodInvocation(
      int fileOffset, Procedure target, Arguments arguments,
      {required bool isTearOff});

  Expression buildUnresolvedError(String name, int charOffset,
      {Member candidate,
      bool isSuper,
      required UnresolvedKind kind,
      bool isStatic,
      Arguments? arguments,
      Expression? rhs,
      LocatedMessage message,
      int? length,
      bool errorHasBeenReported});

  LocatedMessage? checkArgumentsForFunction(FunctionNode function,
      Arguments arguments, int offset, List<TypeParameter> typeParameters);

  Expression wrapInDeferredCheck(
      Expression expression, PrefixBuilder prefix, int charOffset);

  bool isIdentical(Member? member);

  Expression buildMethodInvocation(
      Expression receiver, Name name, Arguments arguments, int offset,
      {bool isConstantExpression = false, bool isNullAware = false});

  Expression buildSuperInvocation(Name name, Arguments arguments, int offset,
      {bool isConstantExpression = false,
      bool isNullAware = false,
      bool isImplicitCall = false});

  Expression buildConstructorInvocation(
      TypeDeclarationBuilder type,
      Token nameToken,
      Token nameLastToken,
      Arguments? arguments,
      String name,
      List<TypeBuilder>? typeArguments,
      int charOffset,
      Constness constness,
      {bool isTypeArgumentsInForest = false,
      TypeDeclarationBuilder? typeAliasBuilder,
      required UnresolvedKind unresolvedKind});

  TypeBuilder validateTypeParameterUse(TypeBuilder typeBuilder,
      {required bool allowPotentiallyConstantType});

  void addProblemErrorIfConst(Message message, int charOffset, int length);

  Expression buildProblemErrorIfConst(
      Message message, int charOffset, int length);

  Expression wrapInLocatedProblem(Expression expression, LocatedMessage message,
      {List<LocatedMessage>? context});

  Expression evaluateArgumentsBefore(
      Arguments arguments, Expression expression);

  DartType buildDartType(TypeBuilder typeBuilder, TypeUse typeUse,
      {required bool allowPotentiallyConstantType});

  List<DartType> buildDartTypeArguments(
      List<TypeBuilder>? typeArguments, TypeUse typeUse,
      {required bool allowPotentiallyConstantType});

  void reportDuplicatedDeclaration(
      Builder existing, String name, int charOffset);

  /// Creates a synthetic variable declaration for the value of [expression].
  VariableDeclarationImpl createVariableDeclarationForValue(
      Expression expression);

  /// Creates a [VariableGet] of the [variable] using [charOffset] as the file
  /// offset of the created node.
  Expression createVariableGet(VariableDeclaration variable, int charOffset,
      {bool forNullGuardedAccess = false});

  /// Registers that [variable] is assigned to.
  ///
  /// This is needed for type promotion.
  void registerVariableAssignment(VariableDeclaration variable);

  TypeEnvironment get typeEnvironment;

  /// If explicit instantiations are supported in this library, create an
  /// instantiation of the result of [receiverFunction] using
  /// [typeArguments] followed by an invocation of [name] with [arguments].
  /// Otherwise create the errors for the corresponding invalid implicit
  /// creation expression.
  ///
  /// This is used to handle the syntax for implicit creation expression as
  /// an explicit instantiation with and invocation. For instance
  ///
  ///     a.b<c>.d()
  ///
  /// The parser treat the as the constructor invocation of constructor `d` on
  /// class `b` with prefix `a` with type arguments `<c>`, but with explicit
  /// instantiation it could instead be the explicit instantiation of expression
  /// `a.b` with type arguments `<c>` followed by and invocation of `d()`.
  ///
  /// If [inImplicitCreationContext] is `false`, then the expression is
  /// preceded by `new` or `const`, and an error should be reported instead of
  /// creating the instantiation and invocation.
  Expression createInstantiationAndInvocation(
      Expression Function() receiverFunction,
      List<TypeBuilder>? typeArguments,
      String className,
      String constructorName,
      Arguments arguments,
      {required int instantiationOffset,
      required int invocationOffset,
      required bool inImplicitCreationContext});
}

/// Checks that a generic [typedef] for a generic type declaration.
bool isProperRenameForTypeDeclaration(
    TypeEnvironment typeEnvironment, Typedef typedef, Library typedefLibrary) {
  DartType? rhsType = typedef.type;
  if (rhsType is! TypeDeclarationType) {
    return false;
  }

  List<TypeParameter> fromParameters = typedef.typeParameters;
  List<TypeParameter> toParameters = rhsType.typeDeclaration.typeParameters;
  List<DartType> typeArguments = rhsType.typeArguments;
  if (fromParameters.length != typeArguments.length) {
    return false;
  }
  for (int i = 0; i < fromParameters.length; ++i) {
    if (typeArguments[i] !=
        new TypeParameterType.withDefaultNullability(fromParameters[i])) {
      return false;
    }
  }

  Map<TypeParameter, DartType> substitutionMap = {};
  for (int i = 0; i < fromParameters.length; ++i) {
    substitutionMap[fromParameters[i]] =
        new TypeParameterType.withDefaultNullability(toParameters[i]);
  }
  Substitution substitution = Substitution.fromMap(substitutionMap);
  for (int i = 0; i < fromParameters.length; ++i) {
    if (!typeEnvironment.areMutualSubtypes(toParameters[i].bound,
        substitution.substituteType(fromParameters[i].bound))) {
      return false;
    }
  }

  return true;
}

enum UnresolvedKind {
  Unknown,
  Member,
  Method,
  Getter,
  Setter,
  Constructor,
}
