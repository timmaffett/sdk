// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/types/shared_type.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_schema.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/dart/resolver/assignment_expression_resolver.dart';
import 'package:analyzer/src/dart/resolver/typed_literal_resolver.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/inference_log.dart';
import 'package:analyzer/src/generated/resolver.dart';

/// Helper for resolving [ForStatement]s and [ForElement]s.
class ForResolver {
  final ResolverVisitor _resolver;

  ForResolver({required ResolverVisitor resolver}) : _resolver = resolver;

  TypeSystemImpl get _typeSystem => _resolver.typeSystem;

  void resolveElement(ForElementImpl node, CollectionLiteralContext? context) {
    var forLoopParts = node.forLoopParts;
    void visitBody() {
      node.body.resolveElement(_resolver, context);
      _resolver.popRewrite();
    }

    if (forLoopParts is ForPartsImpl) {
      _forParts(node, forLoopParts, visitBody);
    } else if (forLoopParts is ForEachPartsWithPatternImpl) {
      _analyzePatternForIn(
        node: node,
        awaitKeyword: node.awaitKeyword,
        forLoopParts: forLoopParts,
        dispatchBody: () {
          _resolver.dispatchCollectionElement(node.body, context);
        },
      );
    } else if (forLoopParts is ForEachPartsImpl) {
      _forEachParts(node, node.awaitKeyword != null, forLoopParts, visitBody);
    }
  }

  void resolveStatement(ForStatementImpl node) {
    var forLoopParts = node.forLoopParts;
    void visitBody() {
      node.body.accept(_resolver);
    }

    if (forLoopParts is ForPartsImpl) {
      _forParts(node, forLoopParts, visitBody);
    } else if (forLoopParts is ForEachPartsWithPatternImpl) {
      _analyzePatternForIn(
        node: node,
        awaitKeyword: node.awaitKeyword,
        forLoopParts: forLoopParts,
        dispatchBody: () {
          _resolver.dispatchStatement(node.body);
        },
      );
    } else if (forLoopParts is ForEachPartsImpl) {
      _forEachParts(node, node.awaitKeyword != null, forLoopParts, visitBody);
    }
  }

  void _analyzePatternForIn({
    required AstNodeImpl node,
    required Token? awaitKeyword,
    required ForEachPartsWithPatternImpl forLoopParts,
    required void Function() dispatchBody,
  }) {
    _resolver.analyzePatternForIn(
      node: node,
      hasAwait: awaitKeyword != null,
      pattern: forLoopParts.pattern,
      expression: forLoopParts.iterable,
      dispatchBody: dispatchBody,
    );
    _resolver.popRewrite();
    _resolver.nullableDereferenceVerifier.expression(
      CompileTimeErrorCode.UNCHECKED_USE_OF_NULLABLE_VALUE_AS_ITERATOR,
      forLoopParts.iterable,
    );
  }

  /// Given an iterable expression from a foreach loop, attempt to infer
  /// a type for the elements being iterated over.  Inference is based
  /// on the type of the iterator or stream over which the foreach loop
  /// is defined.
  TypeImpl _computeForEachElementType(ExpressionImpl iterable, bool isAsync) {
    var iterableType = iterable.staticType;
    if (iterableType == null) {
      return InvalidTypeImpl.instance;
    }

    iterableType = _typeSystem.resolveToBound(iterableType);
    if (iterableType is DynamicType) {
      return DynamicTypeImpl.instance;
    }

    ClassElement iteratedElement =
        isAsync
            ? _resolver.typeProvider.streamElement
            : _resolver.typeProvider.iterableElement;

    var iteratedType = iterableType.asInstanceOf(iteratedElement);
    if (iteratedType == null) {
      return InvalidTypeImpl.instance;
    }

    return iteratedType.typeArguments.single;
  }

  void _forEachParts(
    AstNodeImpl node,
    bool isAsync,
    ForEachPartsImpl forEachParts,
    void Function() visitBody,
  ) {
    ExpressionImpl iterable = forEachParts.iterable;
    DeclaredIdentifierImpl? loopVariable;
    SimpleIdentifierImpl? identifier;
    Element? identifierElement;
    if (forEachParts is ForEachPartsWithDeclarationImpl) {
      loopVariable = forEachParts.loopVariable;
    } else if (forEachParts is ForEachPartsWithIdentifierImpl) {
      identifier = forEachParts.identifier;
      // TODO(scheglov): replace with lexical lookup
      inferenceLogWriter?.setExpressionVisitCodePath(
        identifier,
        ExpressionVisitCodePath.forEachIdentifier,
      );
      identifier.accept(_resolver);
      AssignmentExpressionShared(
        resolver: _resolver,
      ).checkFinalAlreadyAssigned(identifier, isForEachIdentifier: true);
    }

    TypeImpl? valueType;
    if (loopVariable != null) {
      var typeAnnotation = loopVariable.type;
      valueType = typeAnnotation?.type ?? UnknownInferredType.instance;
    }
    if (identifier != null) {
      identifierElement = identifier.element;
      if (identifierElement is VariableElement) {
        valueType = _resolver.localVariableTypeProvider.getType(
          identifier,
          isRead: false,
        );
      } else if (identifierElement is InternalSetterElement) {
        var parameters = identifierElement.formalParameters;
        if (parameters.isNotEmpty) {
          valueType = parameters[0].type;
        }
      }
    }
    InterfaceTypeImpl? targetType;
    if (valueType != null) {
      targetType =
          isAsync
              ? _resolver.typeProvider.streamType(valueType)
              : _resolver.typeProvider.iterableType(valueType);
    }

    _resolver.analyzeExpression(
      iterable,
      SharedTypeSchemaView(targetType ?? UnknownInferredType.instance),
    );
    iterable = _resolver.popRewrite()!;

    _resolver.nullableDereferenceVerifier.expression(
      CompileTimeErrorCode.UNCHECKED_USE_OF_NULLABLE_VALUE_AS_ITERATOR,
      iterable,
    );

    loopVariable?.accept(_resolver);
    var elementType = _computeForEachElementType(iterable, isAsync);
    if (loopVariable != null && loopVariable.type == null) {
      var loopVariableElement =
          loopVariable.declaredFragment?.element as LocalVariableElementImpl;
      loopVariableElement.type = elementType;
    }

    if (loopVariable != null) {
      var declaredElement = loopVariable.declaredElement!;
      _resolver.flowAnalysis.flow?.declare(
        declaredElement,
        SharedTypeView(declaredElement.type),
        initialized: true,
      );
    }

    _resolver.flowAnalysis.flow?.forEach_bodyBegin(node);
    if (identifierElement is PromotableElementImpl &&
        forEachParts is ForEachPartsWithIdentifier) {
      _resolver.flowAnalysis.flow?.write(
        forEachParts,
        identifierElement,
        SharedTypeView(elementType),
        null,
      );
    }

    visitBody();

    _resolver.flowAnalysis.flow?.forEach_end();
  }

  void _forParts(
    AstNodeImpl node,
    ForPartsImpl forParts,
    void Function() visitBody,
  ) {
    if (forParts is ForPartsWithDeclarationsImpl) {
      forParts.variables.accept(_resolver);
    } else if (forParts is ForPartsWithExpressionImpl) {
      if (forParts.initialization case var initialization?) {
        _resolver.analyzeExpression(
          initialization,
          _resolver.operations.unknownType,
        );
        _resolver.popRewrite();
      }
    } else if (forParts is ForPartsWithPatternImpl) {
      forParts.variables.accept(_resolver);
    } else {
      throw StateError('Unrecognized for loop parts');
    }

    _resolver.flowAnalysis.for_conditionBegin(node);

    var condition = forParts.condition;
    if (condition != null) {
      _resolver.analyzeExpression(
        condition,
        SharedTypeSchemaView(_resolver.typeProvider.boolType),
      );
      condition = _resolver.popRewrite()!;
      var whyNotPromoted = _resolver.flowAnalysis.flow?.whyNotPromoted(
        condition,
      );
      _resolver.boolExpressionVerifier.checkForNonBoolCondition(
        condition,
        whyNotPromoted: whyNotPromoted,
      );
    }

    var deadCodeForPartsState =
        _resolver.nullSafetyDeadCodeVerifier.for_conditionEnd();
    _resolver.flowAnalysis.for_bodyBegin(node, condition);
    visitBody();

    _resolver.flowAnalysis.flow?.for_updaterBegin();
    _resolver.nullSafetyDeadCodeVerifier.for_updaterBegin(
      forParts.updaters,
      deadCodeForPartsState,
    );
    for (var updater in forParts.updaters) {
      _resolver.analyzeExpression(updater, _resolver.operations.unknownType);
      _resolver.popRewrite();
    }

    _resolver.flowAnalysis.flow?.for_end();
  }
}
