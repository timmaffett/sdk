// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../analyzer.dart';

const _desc = r'Sort unnamed constructor declarations first.';

class SortUnnamedConstructorsFirst extends LintRule {
  SortUnnamedConstructorsFirst()
    : super(
        name: LintNames.sort_unnamed_constructors_first,
        description: _desc,
      );

  @override
  DiagnosticCode get diagnosticCode =>
      LinterLintCode.sort_unnamed_constructors_first;

  @override
  void registerNodeProcessors(NodeLintRegistry registry, RuleContext context) {
    var visitor = _Visitor(this);
    registry.addClassDeclaration(this, visitor);
    registry.addEnumDeclaration(this, visitor);
    registry.addExtensionTypeDeclaration(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final LintRule rule;

  _Visitor(this.rule);

  void check(NodeList<ClassMember> members) {
    var seenConstructor = false;
    // Members are sorted by source position in the AST.
    for (var member in members) {
      if (member is ConstructorDeclaration) {
        if (member.name == null) {
          if (seenConstructor) {
            rule.reportAtNode(member.returnType);
          }
        } else {
          seenConstructor = true;
        }
      }
    }
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    check(node.members);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    check(node.members);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    if (node.representation.constructorName == null) return;
    check(node.members);
  }
}
