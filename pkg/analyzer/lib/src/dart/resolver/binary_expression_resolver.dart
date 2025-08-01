// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/flow_analysis/flow_analysis.dart';
import 'package:_fe_analyzer_shared/src/types/shared_type.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_provider.dart';
import 'package:analyzer/src/dart/element/type_schema.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/dart/resolver/resolution_result.dart';
import 'package:analyzer/src/dart/resolver/type_property_resolver.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/super_context.dart';

/// Helper for resolving [BinaryExpression]s.
class BinaryExpressionResolver {
  final ResolverVisitor _resolver;
  final TypePropertyResolver _typePropertyResolver;

  BinaryExpressionResolver({required ResolverVisitor resolver})
    : _resolver = resolver,
      _typePropertyResolver = resolver.typePropertyResolver;

  DiagnosticReporter get _diagnosticReporter => _resolver.diagnosticReporter;

  TypeProviderImpl get _typeProvider => _resolver.typeProvider;

  TypeSystemImpl get _typeSystem => _resolver.typeSystem;

  void resolve(BinaryExpressionImpl node, {required TypeImpl contextType}) {
    var operator = node.operator.type;

    if (operator == TokenType.AMPERSAND_AMPERSAND) {
      _resolveLogicalAnd(node);
      return;
    }

    if (operator == TokenType.BANG_EQ || operator == TokenType.EQ_EQ) {
      _resolveEqual(node, notEqual: operator == TokenType.BANG_EQ);
      return;
    }

    if (operator == TokenType.BAR_BAR) {
      _resolveLogicalOr(node);
      return;
    }

    if (operator == TokenType.QUESTION_QUESTION) {
      _resolveIfNull(node, contextType: contextType);
      return;
    }

    if (operator.isUserDefinableOperator && operator.isBinaryOperator) {
      _resolveUserDefinable(node, contextType: contextType);
      return;
    }

    // Report an error if not already reported by the parser.
    if (operator != TokenType.BANG_EQ_EQ && operator != TokenType.EQ_EQ_EQ) {
      _diagnosticReporter.atToken(
        node.operator,
        CompileTimeErrorCode.NOT_BINARY_OPERATOR,
        arguments: [operator.lexeme],
      );
    }

    _resolveUnsupportedOperator(node);
  }

  void _checkNonBoolOperand(
    Expression operand,
    String operator, {
    required Map<SharedTypeView, NonPromotionReason> Function()? whyNotPromoted,
  }) {
    _resolver.boolExpressionVerifier.checkForNonBoolExpression(
      operand,
      diagnosticCode: CompileTimeErrorCode.NON_BOOL_OPERAND,
      arguments: [operator],
      whyNotPromoted: whyNotPromoted,
    );
  }

  void _resolveEqual(BinaryExpressionImpl node, {required bool notEqual}) {
    _resolver.analyzeExpression(
      node.leftOperand,
      SharedTypeSchemaView(UnknownInferredType.instance),
    );
    var left = _resolver.popRewrite()!;

    var flowAnalysis = _resolver.flowAnalysis;
    var flow = flowAnalysis.flow;
    ExpressionInfo<SharedTypeView>? leftInfo;
    var leftExtensionOverride = left is ExtensionOverride;
    if (!leftExtensionOverride) {
      leftInfo = flow?.equalityOperand_end(left);
    }

    // When evaluating exactly a dot shorthand in the RHS, we save the LHS type
    // to provide the context type for the shorthand.
    if (_resolver.isDotShorthand(node.rightOperand)) {
      _resolver.pushDotShorthandContext(
        node.rightOperand,
        SharedTypeSchemaView(left.typeOrThrow),
      );
    }

    _resolver.analyzeExpression(
      node.rightOperand,
      SharedTypeSchemaView(UnknownInferredType.instance),
    );
    var right = _resolver.popRewrite()!;
    var whyNotPromoted = flowAnalysis.flow?.whyNotPromoted(right);

    if (!leftExtensionOverride) {
      flow?.equalityOperation_end(
        node,
        leftInfo,
        SharedTypeView(left.typeOrThrow),
        flow.equalityOperand_end(right),
        SharedTypeView(right.typeOrThrow),
        notEqual: notEqual,
      );
    }

    _resolveUserDefinableElement(
      node,
      TokenType.EQ_EQ.lexeme,
      promoteLeftTypeToNonNull: true,
    );
    _resolveUserDefinableType(node);
    _resolver.checkForArgumentTypeNotAssignableForArgument(
      node.rightOperand,
      promoteParameterToNullable: true,
      whyNotPromoted: whyNotPromoted,
    );

    void reportNullComparison(SyntacticEntity start, SyntacticEntity end) {
      var errorCode =
          notEqual
              ? WarningCode.UNNECESSARY_NULL_COMPARISON_ALWAYS_NULL_FALSE
              : WarningCode.UNNECESSARY_NULL_COMPARISON_ALWAYS_NULL_TRUE;
      var offset = start.offset;
      _diagnosticReporter.atOffset(
        offset: offset,
        length: end.end - offset,
        diagnosticCode: errorCode,
      );
    }

    if (left is SimpleIdentifierImpl && right is NullLiteralImpl) {
      var element = left.element;
      if (element is PromotableElementImpl &&
          flowAnalysis.isDefinitelyUnassigned(left, element)) {
        reportNullComparison(left, node.operator);
      }
    } else if (right is SimpleIdentifierImpl && left is NullLiteralImpl) {
      var element = right.element;
      if (element is PromotableElementImpl &&
          flowAnalysis.isDefinitelyUnassigned(right, element)) {
        reportNullComparison(node.operator, right);
      }
    }
  }

  void _resolveIfNull(
    BinaryExpressionImpl node, {
    required TypeImpl contextType,
  }) {
    var left = node.leftOperand;
    var right = node.rightOperand;
    var flow = _resolver.flowAnalysis.flow;

    // An if-null expression `E` of the form `e1 ?? e2` with context type `K` is
    // analyzed as follows:
    //
    // - Let `T1` be the type of `e1` inferred with context type `K?`.
    _resolver.analyzeExpression(
      left,
      SharedTypeSchemaView(_typeSystem.makeNullable(contextType)),
    );
    left = _resolver.popRewrite()!;
    var t1 = left.typeOrThrow;

    // - Let `T2` be the type of `e2` inferred with context type `J`, where:
    //   - If `K` is `_`, `J = T1`.
    TypeImpl j;
    if (contextType is DynamicType ||
        contextType is InvalidType ||
        contextType is UnknownInferredType) {
      j = t1;
    } else
    //   - Otherwise, `J = K`.
    {
      j = contextType;
    }
    flow?.ifNullExpression_rightBegin(left, SharedTypeView(t1));
    _resolver.analyzeExpression(right, SharedTypeSchemaView(j));
    right = _resolver.popRewrite()!;
    flow?.ifNullExpression_end();
    var t2 = right.typeOrThrow;

    // - Let `T` be `UP(NonNull(T1), T2)`.
    var nonNullT1 = _typeSystem.promoteToNonNull(t1);
    var t = _typeSystem.leastUpperBound(nonNullT1, t2);

    // - Let `S` be the greatest closure of `K`.
    var s =
        _resolver.operations
            .greatestClosureOfSchema(SharedTypeSchemaView(contextType))
            .unwrapTypeView<TypeImpl>();

    DartType staticType;
    // If `inferenceUpdate3` is not enabled, then the type of `E` is `T`.
    if (!_resolver.definingLibrary.featureSet.isEnabled(
      Feature.inference_update_3,
    )) {
      staticType = t;
    } else
    // - If `T <: S`, then the type of `E` is `T`.
    if (_typeSystem.isSubtypeOf(t, s)) {
      staticType = t;
    } else
    // - Otherwise, if `NonNull(T1) <: S` and `T2 <: S`, then the type of `E` is
    //   `S`.
    if (_typeSystem.isSubtypeOf(nonNullT1, s) &&
        _typeSystem.isSubtypeOf(t2, s)) {
      staticType = s;
    } else
    // - Otherwise, the type of `E` is `T`.
    {
      staticType = t;
    }

    node.recordStaticType(staticType, resolver: _resolver);

    _resolver.checkForArgumentTypeNotAssignableForArgument(right);
  }

  void _resolveLogicalAnd(BinaryExpressionImpl node) {
    var left = node.leftOperand;
    var right = node.rightOperand;
    var flow = _resolver.flowAnalysis.flow;

    flow?.logicalBinaryOp_begin();
    _resolver.analyzeExpression(
      left,
      SharedTypeSchemaView(_typeProvider.boolType),
    );
    left = _resolver.popRewrite()!;
    var leftWhyNotPromoted = _resolver.flowAnalysis.flow?.whyNotPromoted(left);

    flow?.logicalBinaryOp_rightBegin(left, node, isAnd: true);
    _resolver.checkUnreachableNode(right);

    _resolver.analyzeExpression(
      right,
      SharedTypeSchemaView(_typeProvider.boolType),
    );
    right = _resolver.popRewrite()!;
    var rightWhyNotPromoted = _resolver.flowAnalysis.flow?.whyNotPromoted(
      right,
    );

    _resolver.nullSafetyDeadCodeVerifier.flowEnd(right);
    flow?.logicalBinaryOp_end(node, right, isAnd: true);

    _checkNonBoolOperand(left, '&&', whyNotPromoted: leftWhyNotPromoted);
    _checkNonBoolOperand(right, '&&', whyNotPromoted: rightWhyNotPromoted);

    node.recordStaticType(_typeProvider.boolType, resolver: _resolver);
  }

  void _resolveLogicalOr(BinaryExpressionImpl node) {
    var left = node.leftOperand;
    var right = node.rightOperand;
    var flow = _resolver.flowAnalysis.flow;

    flow?.logicalBinaryOp_begin();
    _resolver.analyzeExpression(
      left,
      SharedTypeSchemaView(_typeProvider.boolType),
    );
    left = _resolver.popRewrite()!;
    var leftWhyNotPromoted = _resolver.flowAnalysis.flow?.whyNotPromoted(left);

    flow?.logicalBinaryOp_rightBegin(left, node, isAnd: false);
    _resolver.checkUnreachableNode(right);

    _resolver.analyzeExpression(
      right,
      SharedTypeSchemaView(_typeProvider.boolType),
    );
    right = _resolver.popRewrite()!;
    var rightWhyNotPromoted = _resolver.flowAnalysis.flow?.whyNotPromoted(
      right,
    );

    _resolver.nullSafetyDeadCodeVerifier.flowEnd(right);
    flow?.logicalBinaryOp_end(node, right, isAnd: false);

    _checkNonBoolOperand(left, '||', whyNotPromoted: leftWhyNotPromoted);
    _checkNonBoolOperand(right, '||', whyNotPromoted: rightWhyNotPromoted);

    node.recordStaticType(_typeProvider.boolType, resolver: _resolver);
  }

  void _resolveRightOperand(BinaryExpressionImpl node, TypeImpl contextType) {
    var left = node.leftOperand;

    var invokeType = node.staticInvokeType;
    TypeImpl rightContextType;
    if (invokeType != null && invokeType.formalParameters.isNotEmpty) {
      // If this is a user-defined operator, set the right operand context
      // using the operator method's parameter type.
      var rightParam = invokeType.formalParameters[0];
      rightContextType = _typeSystem.refineNumericInvocationContext(
        left.staticType,
        node.element,
        contextType,
        rightParam.type,
      );
    } else {
      rightContextType = UnknownInferredType.instance;
    }

    _resolver.analyzeExpression(
      node.rightOperand,
      SharedTypeSchemaView(rightContextType),
    );
    var right = _resolver.popRewrite()!;
    var whyNotPromoted = _resolver.flowAnalysis.flow?.whyNotPromoted(right);

    _resolveUserDefinableType(node);
    _resolver.checkForArgumentTypeNotAssignableForArgument(
      right,
      whyNotPromoted: whyNotPromoted,
    );
  }

  void _resolveUnsupportedOperator(BinaryExpressionImpl node) {
    _resolver.analyzeExpression(
      node.leftOperand,
      _resolver.operations.unknownType,
    );
    _resolver.popRewrite();
    _resolver.analyzeExpression(
      node.rightOperand,
      _resolver.operations.unknownType,
    );
    _resolver.popRewrite();
    node.recordStaticType(InvalidTypeImpl.instance, resolver: _resolver);
  }

  void _resolveUserDefinable(
    BinaryExpressionImpl node, {
    required TypeImpl contextType,
  }) {
    var left = node.leftOperand;

    _resolver.analyzeExpression(
      node.leftOperand,
      SharedTypeSchemaView(UnknownInferredType.instance),
    );
    left = _resolver.popRewrite()!;

    if (left is SuperExpressionImpl) {
      if (SuperContext.of(left) != SuperContext.valid) {
        _resolver.analyzeExpression(
          node.rightOperand,
          SharedTypeSchemaView(InvalidTypeImpl.instance),
        );
        _resolver.popRewrite();
        node.recordStaticType(InvalidTypeImpl.instance, resolver: _resolver);
        return;
      }
    }

    var operator = node.operator;
    _resolveUserDefinableElement(node, operator.lexeme);

    _resolveRightOperand(node, contextType);
  }

  void _resolveUserDefinableElement(
    BinaryExpressionImpl node,
    String methodName, {
    bool promoteLeftTypeToNonNull = false,
  }) {
    ExpressionImpl leftOperand = node.leftOperand;

    if (leftOperand is ExtensionOverrideImpl) {
      var extension = leftOperand.element;
      var member = extension.getMethod(methodName);
      if (member == null) {
        // Extension overrides can only be used with named extensions so it is
        // safe to assume `extension.name` is non-`null`.
        _diagnosticReporter.atToken(
          node.operator,
          CompileTimeErrorCode.UNDEFINED_EXTENSION_OPERATOR,
          arguments: [methodName, extension.name!],
        );
      }
      node.element = member;
      node.staticInvokeType = member?.type;
      return;
    }

    var leftType = leftOperand.typeOrThrow;

    if (identical(leftType, NeverTypeImpl.instance)) {
      _resolver.diagnosticReporter.atNode(
        leftOperand,
        WarningCode.RECEIVER_OF_TYPE_NEVER,
      );
      return;
    }

    if (promoteLeftTypeToNonNull) {
      leftType = _typeSystem.promoteToNonNull(leftType);
    }

    ResolutionResult result = _typePropertyResolver.resolve(
      receiver: leftOperand,
      receiverType: leftType,
      name: methodName,
      hasRead: true,
      hasWrite: false,
      propertyErrorEntity: node.operator,
      nameErrorEntity: node,
    );

    node.element = result.getter2 as MethodElement?;
    node.staticInvokeType = result.getter2?.type;
    if (result.needsGetterError) {
      if (leftOperand is SuperExpression) {
        _diagnosticReporter.atToken(
          node.operator,
          CompileTimeErrorCode.UNDEFINED_SUPER_OPERATOR,
          arguments: [methodName, leftType],
        );
      } else {
        _diagnosticReporter.atToken(
          node.operator,
          CompileTimeErrorCode.UNDEFINED_OPERATOR,
          arguments: [methodName, leftType],
        );
      }
    }
  }

  void _resolveUserDefinableType(BinaryExpressionImpl node) {
    var leftOperand = node.leftOperand;

    TypeImpl leftType;
     if (leftOperand is ExtensionOverrideImpl) {
      leftType = leftOperand.extendedType!;
    } else {
      leftType = leftOperand.typeOrThrow;
      leftType = _typeSystem.resolveToBound(leftType);
    }

    if (identical(leftType, NeverTypeImpl.instance)) {
      node.recordStaticType(NeverTypeImpl.instance, resolver: _resolver);
      return;
    }

    var staticType = node.staticInvokeType?.returnType;
    if (node.operator.type == TokenType.EQ_EQ) {
      staticType = _typeSystem.typeProvider.boolType;
    } else if (leftType is DynamicType) {
      staticType ??= DynamicTypeImpl.instance;
    } else {
      staticType ??= InvalidTypeImpl.instance;
    }
    if (leftOperand is! ExtensionOverride) {
      staticType = _typeSystem.refineBinaryExpressionType(
        leftType,
        node.operator.type,
        node.rightOperand.typeOrThrow,
        staticType,
        node.element,
      );
    }
    node.recordStaticType(staticType, resolver: _resolver);
  }
}
