// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../analyzer.dart';

const _desc = r'Avoid control flow in `finally` blocks.';

class ControlFlowInFinally extends LintRule {
  ControlFlowInFinally()
    : super(name: LintNames.control_flow_in_finally, description: _desc);

  @override
  DiagnosticCode get diagnosticCode => LinterLintCode.control_flow_in_finally;

  @override
  void registerNodeProcessors(NodeLintRegistry registry, RuleContext context) {
    var visitor = _Visitor(this);
    registry.addBreakStatement(this, visitor);
    registry.addContinueStatement(this, visitor);
    registry.addReturnStatement(this, visitor);
  }
}

/// Do not extend this class, it is meant to be used from
/// [ControlFlowInFinally] which is in a separate rule to allow a more granular
/// configurability given that reporting throw statements in a finally clause is
/// controversial.
mixin ControlFlowInFinallyBlockReporter {
  LintRule get rule;

  void reportIfFinallyAncestorExists(
    AstNode node, {
    required String kind,
    AstNode? ancestor,
  }) {
    var tryStatement = node.thisOrAncestorOfType<TryStatement>();
    var finallyBlock = tryStatement?.finallyBlock;
    bool finallyBlockAncestorPredicate(AstNode n) => n == finallyBlock;
    if (tryStatement == null ||
        finallyBlock == null ||
        node.thisOrAncestorMatching(finallyBlockAncestorPredicate) == null) {
      return;
    }

    var enablerNode = _findEnablerNode(
      ancestor,
      finallyBlockAncestorPredicate,
      node,
      tryStatement,
    );
    if (enablerNode == null) {
      rule.reportAtNode(node, arguments: [kind]);
    }
  }

  AstNode? _findEnablerNode(
    AstNode? ancestor,
    bool Function(AstNode n) finallyBlockAncestorPredicate,
    AstNode node,
    TryStatement tryStatement,
  ) {
    AstNode? enablerNode;
    if (ancestor == null) {
      bool functionBlockPredicate(AstNode n) =>
          n is FunctionBody &&
          n.thisOrAncestorMatching(finallyBlockAncestorPredicate) != null;
      enablerNode = node.thisOrAncestorMatching(functionBlockPredicate);
    } else {
      enablerNode = ancestor.thisOrAncestorMatching((n) => n == tryStatement);
    }

    return enablerNode;
  }
}

class _Visitor extends SimpleAstVisitor<void>
    with ControlFlowInFinallyBlockReporter {
  @override
  final LintRule rule;

  _Visitor(this.rule);

  @override
  void visitBreakStatement(BreakStatement node) {
    reportIfFinallyAncestorExists(node, ancestor: node.target, kind: 'break');
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    reportIfFinallyAncestorExists(
      node,
      ancestor: node.target,
      kind: 'continue',
    );
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    reportIfFinallyAncestorExists(node, kind: 'return');
  }
}
