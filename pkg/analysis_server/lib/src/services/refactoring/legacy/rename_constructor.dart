// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart' hide Element;
import 'package:analysis_server/src/services/correction/status.dart';
import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analysis_server/src/services/refactoring/legacy/naming_conventions.dart';
import 'package:analysis_server/src/services/refactoring/legacy/refactoring.dart';
import 'package:analysis_server/src/services/refactoring/legacy/refactoring_internal.dart';
import 'package:analysis_server/src/services/refactoring/legacy/rename.dart';
import 'package:analysis_server/src/services/search/hierarchy.dart';
import 'package:analysis_server/src/utilities/change_builder.dart';
import 'package:analysis_server/src/utilities/strings.dart';
import 'package:analysis_server_plugin/edit/correction_utils.dart';
import 'package:analysis_server_plugin/src/utilities/selection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

/// A [Refactoring] for renaming [ConstructorElement]s.
class RenameConstructorRefactoringImpl extends RenameRefactoringImpl {
  final ResolvedUnitResult resolvedUnit;
  final CorrectionUtils utils;

  RenameConstructorRefactoringImpl(
    super.workspace,
    super.sessionHelper,
    this.resolvedUnit,
    ConstructorElement super.element,
  ) : utils = CorrectionUtils(resolvedUnit),
      super();

  @override
  ConstructorElement get element => super.element as ConstructorElement;

  @override
  String get refactoringName {
    return 'Rename Constructor';
  }

  @override
  Future<RefactoringStatus> checkFinalConditions() {
    var result = RefactoringStatus();
    return Future.value(result);
  }

  @override
  RefactoringStatus checkNewName() {
    var result = super.checkNewName();
    result.addStatus(validateConstructorName(newName));
    _analyzePossibleConflicts(result);
    return result;
  }

  @override
  Future<void> fillChange() async {
    // prepare references
    var matches = await searchEngine.searchReferences(element);
    var references = getSourceReferences(matches);
    // update references
    for (var reference in references) {
      // Handle implicit references.
      var coveringNode = await _nodeCoveringReference(reference);
      var coveringParent = coveringNode?.parent;
      if (coveringNode is ClassDeclaration) {
        _addDefaultConstructorToClass(
          reference: reference,
          classDeclaration: coveringNode,
        );
        continue;
      } else if (coveringParent is ConstructorDeclaration &&
          coveringParent.returnType.offset == reference.range.offset) {
        _addSuperInvocationToConstructor(
          reference: reference,
          constructor: coveringParent,
        );
        continue;
      }

      String replacement;
      if (newName.isNotEmpty) {
        replacement = '.$newName';
      } else {
        replacement = reference.isConstructorTearOff ? '.new' : '';
      }
      if (reference.isInvocationByEnumConstantWithoutArguments) {
        replacement += '()';
      }
      reference.addEdit(change, replacement);
    }
    // Update the declaration.
    if (element.isSynthetic) {
      await _replaceSynthetic();
    } else {
      doSourceChange_addSourceEdit(
        change,
        element.firstFragment.libraryFragment.source,
        newSourceEdit_range(
          _declarationNameRange(),
          newName.isNotEmpty ? '.$newName' : '',
        ),
      );
    }
  }

  void _addDefaultConstructorToClass({
    required SourceReference reference,
    required ClassDeclaration classDeclaration,
  }) {
    var className = classDeclaration.name.lexeme;
    _replaceInReferenceFile(
      reference: reference,
      range: range.endLength(classDeclaration.leftBracket, 0),
      replacement: '${utils.endOfLine}  $className() : super.$newName();',
    );
  }

  void _addSuperInvocationToConstructor({
    required SourceReference reference,
    required ConstructorDeclaration constructor,
  }) {
    var initializers = constructor.initializers;
    if (initializers.lastOrNull case var last?) {
      _replaceInReferenceFile(
        reference: reference,
        range: range.endLength(last, 0),
        replacement: ', super.$newName()',
      );
    } else {
      _replaceInReferenceFile(
        reference: reference,
        range: range.endLength(constructor.parameters, 0),
        replacement: ' : super.$newName()',
      );
    }
  }

  void _analyzePossibleConflicts(RefactoringStatus result) {
    var parentClass = element.enclosingElement;
    // Check if the "newName" is the name of the enclosing class.
    if (parentClass.name == newName) {
      result.addError(
        'The constructor should not have the same name '
        'as the name of the enclosing class.',
      );
    }
    // check if there are members with "newName" in the same ClassElement
    for (var newNameMember in getChildren(parentClass, newName)) {
      var message =
          formatList("{0} '{1}' already declares {2} with name '{3}'.", [
            capitalize(parentClass.kind.displayName),
            parentClass.displayName,
            getElementKindName(newNameMember),
            newName,
          ]);
      result.addError(message, newLocation_fromElement(newNameMember));
    }
  }

  SourceRange _declarationNameRange() {
    var fragment = element.firstFragment;
    var offset = fragment.periodOffset;
    if (offset != null) {
      var name = fragment.name;
      var nameEnd = fragment.nameOffset! + name.length;
      return range.startOffsetEndOffset(offset, nameEnd);
    } else {
      return SourceRange(
        fragment.typeNameOffset! + fragment.typeName!.length,
        0,
      );
    }
  }

  Future<AstNode?> _nodeCoveringReference(SourceReference reference) async {
    var element = reference.element;
    var unitResult = await sessionHelper.getResolvedUnitByElement(element);
    return unitResult?.unit
        .select(offset: reference.range.offset, length: 0)
        ?.coveringNode;
  }

  void _replaceInReferenceFile({
    required SourceReference reference,
    required SourceRange range,
    required String replacement,
  }) {
    doSourceChange_addFragmentEdit(
      change,
      reference.element.firstFragment,
      newSourceEdit_range(range, replacement),
    );
  }

  Future<void> _replaceSynthetic() async {
    var classElement = element.enclosingElement;

    var fragment = classElement.firstFragment;
    var result = await sessionHelper.getFragmentDeclaration(fragment);
    if (result == null) {
      return;
    }

    var resolvedUnit = result.resolvedUnit;
    if (resolvedUnit == null) {
      return;
    }

    var node = result.node;
    if (node is! NamedCompilationUnitMember) {
      return;
    }
    if (node is! ClassDeclaration && node is! EnumDeclaration) {
      return;
    }

    var edit = await buildEditForInsertedConstructor(
      node,
      resolvedUnit: resolvedUnit,
      session: sessionHelper.session,
      (builder) => builder.writeConstructorDeclaration(
        classElement.name!,
        constructorName: newName,
        isConst: node is EnumDeclaration,
      ),
      eol: utils.endOfLine,
    );
    if (edit == null) {
      return;
    }
    doSourceChange_addFragmentEdit(change, fragment, edit);
  }
}
