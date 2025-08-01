// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart';
import 'package:analysis_server/src/services/completion/statement/statement_completion.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../../abstract_single_unit.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(_ControlFlowCompletionTest);
    defineReflectiveTests(_DeclarationCompletionTest);
    defineReflectiveTests(_DoCompletionTest);
    defineReflectiveTests(_ExpressionCompletionTest);
    defineReflectiveTests(_ForCompletionTest);
    defineReflectiveTests(_ForEachCompletionTest);
    defineReflectiveTests(_IfCompletionTest);
    defineReflectiveTests(_SimpleCompletionTest);
    defineReflectiveTests(_SwitchCompletionTest);
    defineReflectiveTests(_TryCompletionTest);
    defineReflectiveTests(_WhileCompletionTest);
  });
}

class StatementCompletionTest extends AbstractSingleUnitTest {
  late SourceChange change;

  int _after(String source, String match) {
    match = normalizeSource(match);
    return source.indexOf(match) + match.length;
  }

  int _afterLast(String source, String match) {
    match = normalizeSource(match);
    return source.lastIndexOf(match) + match.length;
  }

  void _assertHasChange(
    String message,
    String expectedCode, [
    int Function(String)? cmp,
  ]) {
    expectedCode = normalizeSource(expectedCode);
    if (change.message == message) {
      if (change.edits.isNotEmpty) {
        var resultCode = SourceEdit.applySequence(
          testCode,
          change.edits[0].edits,
        );
        expect(resultCode, expectedCode.replaceAll('////', ''));
        if (cmp != null) {
          var offset = cmp(resultCode);
          expect(change.selection!.offset, offset);
        }
      } else {
        expect(testCode, expectedCode.replaceAll('////', ''));
        if (cmp != null) {
          var offset = cmp(testCode);
          expect(change.selection!.offset, offset);
        }
      }
      return;
    }
    fail('Expected to find |$message| but got: ${change.message}');
  }

  Future<void> _computeCompletion(int offset) async {
    var context = StatementCompletionContext(testAnalysisResult, offset);
    var processor = StatementCompletionProcessor(context);
    var completion = await processor.compute();
    change = completion.change;
  }

  Future<void> _prepareCompletion(
    String search,
    String sourceCode, {
    bool atEnd = false,
    int delta = 0,
  }) async {
    verifyNoTestUnitErrors = false;
    sourceCode = normalizeSource(sourceCode);
    await resolveTestCode(sourceCode.replaceAll('////', ''));
    var offset = findOffset(search);
    if (atEnd) {
      delta = search.length;
    }
    await _computeCompletion(offset + delta);
  }
}

@reflectiveTest
class _ControlFlowCompletionTest extends StatementCompletionTest {
  Future<void> test_doReturnExprLineComment() async {
    await _prepareCompletion('return 3', '''
ex(e) {
  do {
    return 3//
  } while (true);
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
ex(e) {
  do {
    return 3;//
  } while (true);
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_doReturnUnterminated() async {
    await _prepareCompletion('return', '''
ex(e) {
  do {
    return
  } while (true);
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
ex(e) {
  do {
    return;
  } while (true);
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_forEachReturn() async {
    await _prepareCompletion('return;', '''
ex(e) {
  for (var x in e) {
    return;
  }
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
ex(e) {
  for (var x in e) {
    return;
  }
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_forThrowUnterminated() async {
    await _prepareCompletion('throw e', '''
ex(e) {
  for (int i = 0; i < 3; i++) {
    throw e
  }
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
ex(e) {
  for (int i = 0; i < 3; i++) {
    throw e;
  }
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_ifNoBlock() async {
    await _prepareCompletion('return', '''
ex(e) {
  if (true) return 0
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
ex(e) {
  if (true) return 0;
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_ifThrow() async {
    await _prepareCompletion('throw e;', '''
ex(e) {
  if (true) {
    throw e;
  }
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
ex(e) {
  if (true) {
    throw e;
  }
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_ifThrowUnterminated() async {
    await _prepareCompletion('throw e', '''
ex(e) {
  if (true) {
    throw e
  }
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
ex(e) {
  if (true) {
    throw e;
  }
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_whileReturnExpr() async {
    await _prepareCompletion('+ 4', '''
ex(e) {
  while (true) {
    return 3 + 4
  }
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
ex(e) {
  while (true) {
    return 3 + 4;
  }
  ////
}
''', (s) => _afterLast(s, '  '));
  }
}

@reflectiveTest
class _DeclarationCompletionTest extends StatementCompletionTest {
  Future<void> test_classNameNoBody() async {
    await _prepareCompletion('Sample', '''
class Sample
''', atEnd: true);
    _assertHasChange('Complete class declaration', '''
class Sample {
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_extendsNoBody() async {
    await _prepareCompletion('Sample', '''
class Sample extends Object
''', atEnd: true);
    _assertHasChange('Complete class declaration', '''
class Sample extends Object {
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_functionDeclNoBody() async {
    await _prepareCompletion('source()', '''
String source()
''', atEnd: true);
    _assertHasChange('Complete function declaration', '''
String source() {
  ////
}
''', (s) => _after(s, '  '));
  }

  Future<void> test_functionDeclNoParen() async {
    await _prepareCompletion('source(', '''
String source(
''', atEnd: true);
    _assertHasChange('Complete function declaration', '''
String source() {
  ////
}
''', (s) => _after(s, '  '));
  }

  Future<void> test_implementsNoBody() async {
    await _prepareCompletion('Sample', '''
class Interface {}
class Sample implements Interface
''', atEnd: true);
    _assertHasChange('Complete class declaration', '''
class Interface {}
class Sample implements Interface {
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_methodDeclNoBody() async {
    await _prepareCompletion('source()', '''
class Sample {
  String source()
}
''', atEnd: true);
    _assertHasChange('Complete function declaration', '''
class Sample {
  String source() {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_methodDeclNoParen() async {
    await _prepareCompletion('source(', '''
class Sample {
  String source(
}
''', atEnd: true);
    _assertHasChange('Complete function declaration', '''
class Sample {
  String source() {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_variableDeclNoBody() async {
    await _prepareCompletion('source', '''
String source
''', atEnd: true);
    _assertHasChange('Complete variable declaration', '''
String source;
////
''', (s) => _after(s, ';\n'));
  }

  Future<void> test_withNoBody() async {
    await _prepareCompletion('Sample', '''
mixin class M {}
class Sample extends Object with M
''', atEnd: true);
    _assertHasChange('Complete class declaration', '''
mixin class M {}
class Sample extends Object with M {
  ////
}
''', (s) => _afterLast(s, '  '));
  }
}

@reflectiveTest
class _DoCompletionTest extends StatementCompletionTest {
  Future<void> test_emptyCondition() async {
    await _prepareCompletion('while ()', '''
void f() {
  do {
  } while ()
}
''', atEnd: true);
    _assertHasChange('Complete do-statement', '''
void f() {
  do {
  } while ();
}
''', (s) => _after(s, 'while ('));
  }

  Future<void> test_keywordOnly() async {
    await _prepareCompletion('do', '''
void f() {
  do ////
}
''', atEnd: true);
    _assertHasChange('Complete do-statement', '''
void f() {
  do {
    ////
  } while ();
}
''', (s) => _after(s, 'while ('));
  }

  Future<void> test_keywordStatement() async {
    await _prepareCompletion('do', '''
void f() {
  do ////
  return;
}
''', atEnd: true);
    _assertHasChange('Complete do-statement', '''
void f() {
  do {
    ////
  } while ();
  return;
}
''', (s) => _after(s, 'while ('));
  }

  Future<void> test_noBody() async {
    await _prepareCompletion('do', '''
void f() {
  do;
  while
}
''', atEnd: true);
    _assertHasChange('Complete do-statement', '''
void f() {
  do {
    ////
  } while ();
}
''', (s) => _after(s, 'while ('));
  }

  Future<void> test_noCondition() async {
    await _prepareCompletion('while', '''
void f() {
  do {
  } while
}
''', atEnd: true);
    _assertHasChange('Complete do-statement', '''
void f() {
  do {
  } while ();
}
''', (s) => _after(s, 'while ('));
  }

  Future<void> test_noWhile() async {
    await _prepareCompletion('}', '''
void f() {
  do {
  }
}
''', atEnd: true);
    _assertHasChange('Complete do-statement', '''
void f() {
  do {
  } while ();
}
''', (s) => _after(s, 'while ('));
  }
}

@reflectiveTest
class _ExpressionCompletionTest extends StatementCompletionTest {
  Future<void> test_listAssign() async {
    await _prepareCompletion('= ', '''
void f() {
  var x = [1, 2, 3
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  var x = [1, 2, 3];
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_listAssignMultiLine() async {
    // The indent of the final line is incorrect.
    await _prepareCompletion('3', '''
void f() {
  var x = [
    1,
    2,
    3
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  var x = [
    1,
    2,
    3,
  ];
    ////
}
''', (s) => _afterLast(s, '  '));
  }

  @failingTest
  Future<void> test_mapAssign() async {
    await _prepareCompletion('3: 3', '''
void f() {
  var x = {1: 1, 2: 2, 3: 3
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  var x = {1: 1, 2: 2, 3: 3};
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  @failingTest
  Future<void> test_mapAssignMissingColon() async {
    await _prepareCompletion('3', '''
void f() {
  var x = {1: 1, 2: 2, 3
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  var x = {1: 1, 2: 2, 3: };
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_returnString() async {
    await _prepareCompletion('text', '''
void f() {
  if (done()) {
    return 'text
  }
}
''', atEnd: true);
    _assertHasChange('Complete control flow block', '''
void f() {
  if (done()) {
    return 'text';
  }
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_stringAssign() async {
    await _prepareCompletion('= ', '''
void f() {
  var x = '
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  var x = '';
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_stringSingle() async {
    await _prepareCompletion('text', '''
void f() {
  print("text
}
''', atEnd: true);
    _assertHasChange('Insert a newline at the end of the current line', '''
void f() {
  print("text");
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_stringSingleRaw() async {
    await _prepareCompletion('text', '''
void f() {
  print(r"text
}
''', atEnd: true);
    _assertHasChange('Insert a newline at the end of the current line', '''
void f() {
  print(r"text");
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_stringTriple() async {
    await _prepareCompletion('text', '''
void f() {
  print(\'\'\'text
}
''', atEnd: true);
    _assertHasChange('Insert a newline at the end of the current line', '''
void f() {
  print(\'\'\'text\'\'\');
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_stringTripleRaw() async {
    await _prepareCompletion('text', r"""
void f() {
  print(r'''text
}
""", atEnd: true);
    _assertHasChange('Insert a newline at the end of the current line', r"""
void f() {
  print(r'''text''');
  ////
}
""", (s) => _afterLast(s, '  '));
  }
}

@reflectiveTest
class _ForCompletionTest extends StatementCompletionTest {
  Future<void> test_emptyCondition() async {
    await _prepareCompletion('0;', '''
void f() {
  for (int i = 0;)      /* */  ////
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (int i = 0; ; ) /* */ {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_emptyConditionWithBody() async {
    await _prepareCompletion('0;', '''
void f() {
  for (int i = 0;) {
  }
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (int i = 0; ; ) {
  }
}
''', (s) => _after(s, '0; '));
  }

  Future<void> test_emptyInitializers() async {
    // This does nothing, same as for Java.
    await _prepareCompletion('r (', '''
void f() {
  for () {
  }
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for () {
  }
}
''', (s) => _after(s, 'r ('));
  }

  Future<void> test_emptyInitializersAfterBody() async {
    await _prepareCompletion('}', '''
void f() {
  for () {
  }
}
''', atEnd: true);
    _assertHasChange('Insert a newline at the end of the current line', '''
void f() {
  for () {
  }
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_emptyInitializersEmptyCondition() async {
    await _prepareCompletion('/* */', '''
void f() {
  for (;/* */)
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (; /* */; ) {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_emptyParts() async {
    await _prepareCompletion(';)', '''
void f() {
  for (;;)
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (;;) {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_emptyUpdaters() async {
    await _prepareCompletion('/* */', '''
void f() {
  for (int i = 0; i < 10 /* */)
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (int i = 0; i < 10 /* */; ) {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_emptyUpdatersWithBody() async {
    await _prepareCompletion('/* */', '''
void f() {
  for (int i = 0; i < 10 /* */) {
  }
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (int i = 0; i < 10 /* */; ) {
  }
}
''', (s) => _after(s, '*/; '));
  }

  Future<void> test_keywordOnly() async {
    await _prepareCompletion('for', '''
void f() {
  for
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for () {
    ////
  }
}
''', (s) => _after(s, 'for ('));
  }

  Future<void> test_missingLeftSeparator() async {
    await _prepareCompletion('= 0', '''
void f() {
  for (int i = 0) {
  }
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (int i = 0; ; ) {
  }
}
''', (s) => _after(s, '0; '));
  }

  Future<void> test_noError() async {
    await _prepareCompletion(';)', '''
void f() {
  for (;;)
  return;
}
''', atEnd: true);
    _assertHasChange('Complete for-statement', '''
void f() {
  for (;;) {
    ////
  }
  return;
}
''', (s) => _after(s, '    '));
  }
}

@reflectiveTest
class _ForEachCompletionTest extends StatementCompletionTest {
  Future<void> test_emptyIdentifier() async {
    await _prepareCompletion('in xs)', '''
void f() {
  for (in xs)
}
''', atEnd: true);
    _assertHasChange('Complete for-each-statement', '''
void f() {
  for ( in xs) {
    ////
  }
}
''', (s) => _after(s, 'for ('));
  }

  Future<void> test_emptyIdentifierAndIterable() async {
    // Analyzer parser produces
    //    for (_s_ in _s_) ;
    // Fasta parser produces
    //    for (in; ;) ;
    await _prepareCompletion('in)', '''
void f() {
  for (in)
}
''', atEnd: true);
    _assertHasChange('Complete for-each-statement', '''
void f() {
  for ( in ) {
    ////
  }
}
''', (s) => _after(s, 'for ('));
  }

  Future<void> test_emptyIterable() async {
    await _prepareCompletion('in)', '''
void f() {
  for (var x in)
}
''', atEnd: true);
    _assertHasChange('Complete for-each-statement', '''
void f() {
  for (var x in ) {
    ////
  }
}
''', (s) => _after(s, 'in '));
  }

  Future<void> test_noError() async {
    await _prepareCompletion('])', '''
void f() {
  for (var x in [1,2])
  return;
}
''', atEnd: true);
    _assertHasChange('Complete for-each-statement', '''
void f() {
  for (var x in [1,2]) {
    ////
  }
  return;
}
''', (s) => _after(s, '    '));
  }
}

@reflectiveTest
class _IfCompletionTest extends StatementCompletionTest {
  Future<void> test_afterCondition() async {
    await _prepareCompletion(
      'if (true) ', // Trigger completion after space.
      '''
void f() {
  if (true) ////
}
''',
      atEnd: true,
    );
    _assertHasChange('Complete if-statement', '''
void f() {
  if (true) {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_emptyCondition() async {
    await _prepareCompletion('if ()', '''
void f() {
  if ()
}
''', atEnd: true);
    _assertHasChange('Complete if-statement', '''
void f() {
  if () {
    ////
  }
}
''', (s) => _after(s, 'if ('));
  }

  Future<void> test_keywordOnly() async {
    await _prepareCompletion('if', '''
void f() {
  if ////
}
''', atEnd: true);
    _assertHasChange('Complete if-statement', '''
void f() {
  if () {
    ////
  }
}
''', (s) => _after(s, 'if ('));
  }

  Future<void> test_noError() async {
    await _prepareCompletion('if (true)', '''
void f() {
  if (true)
  return;
}
''', atEnd: true);
    _assertHasChange('Complete if-statement', '''
void f() {
  if (true) {
    ////
  }
  return;
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_withCondition() async {
    await _prepareCompletion(
      'if (tr', // Trigger completion from within expression.
      '''
void f() {
  if (true)
}
''',
      atEnd: true,
    );
    _assertHasChange('Complete if-statement', '''
void f() {
  if (true) {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_withCondition_noRightParenthesis() async {
    await _prepareCompletion('if (true', '''
void f() {
  if (true
}
''', atEnd: true);
    _assertHasChange('Complete if-statement', '''
void f() {
  if (true) {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_withElse() async {
    await _prepareCompletion('else', '''
void f() {
  if () {
  } else
}
''', atEnd: true);
    _assertHasChange('Complete if-statement', '''
void f() {
  if () {
  } else {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_withElse_BAD() async {
    await _prepareCompletion('if ()', '''
void f() {
  if ()
  else
}
''', atEnd: true);
    _assertHasChange(
      // Note: if-statement completion should not trigger.
      'Insert a newline at the end of the current line',
      '''
void f() {
  if ()
  else
}
''',
      (s) => _after(s, 'if ()'),
    );
  }

  Future<void> test_withElseNoThen() async {
    await _prepareCompletion('else', '''
void f() {
  if ()
  else
}
''', atEnd: true);
    _assertHasChange('Complete if-statement', '''
void f() {
  if ()
  else {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_withinEmptyCondition() async {
    await _prepareCompletion('if (', '''
void f() {
  if ()
}
''', atEnd: true);
    _assertHasChange('Complete if-statement', '''
void f() {
  if () {
    ////
  }
}
''', (s) => _after(s, 'if ('));
  }
}

@reflectiveTest
class _SimpleCompletionTest extends StatementCompletionTest {
  Future<void> test_enter() async {
    await _prepareCompletion('v = 1;', '''
void f() {
  int v = 1;
}
''', atEnd: true);
    _assertHasChange('Insert a newline at the end of the current line', '''
void f() {
  int v = 1;
  ////
}
''');
  }

  Future<void> test_expressionBody() async {
    await _prepareCompletion('=> 1', '''
class Thing extends Object {
  int foo() => 1
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
class Thing extends Object {
  int foo() => 1;
  ////
}
''');
  }

  Future<void> test_noCloseParen() async {
    await _prepareCompletion('ing(3', '''
void f() {
  var s = 'sample'.substring(3
}
''', atEnd: true);
    _assertHasChange('Insert a newline at the end of the current line', '''
void f() {
  var s = 'sample'.substring(3);
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_noCloseParenWithSemicolon1() async {
    var before = '''
void f() {
  var s = 'sample'.substring(3;
}
''';
    var after = '''
void f() {
  var s = 'sample'.substring(3);
  ////
}
''';
    // Check completion both before semicolon.
    await _prepareCompletion('ing(3', before, atEnd: true);
    _assertHasChange(
      'Insert a newline at the end of the current line',
      after,
      (s) => _afterLast(s, '  '),
    );
  }

  Future<void> test_noCloseParenWithSemicolon2() async {
    var before = '''
void f() {
  var s = 'sample'.substring(3;
}
''';
    var after = '''
void f() {
  var s = 'sample'.substring(3);
  ////
}
''';
    // Check completion after the semicolon.
    await _prepareCompletion('ing(3;', before, atEnd: true);
    _assertHasChange(
      'Insert a newline at the end of the current line',
      after,
      (s) => _afterLast(s, '  '),
    );
  }

  Future<void> test_semicolonFn() async {
    await _prepareCompletion('=> 3', '''
void f() {
  int f() => 3
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  int f() => 3;
  ////
}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_semicolonFnBody() async {
    // It would be reasonable to add braces in this case. Unfortunately,
    // the incomplete line parses as two statements ['int;', 'g();'], not one.
    await _prepareCompletion('g()', '''
void f() {
  int g()
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  int g();
  ////
}
''', (s) => _afterLast(s, '();\n  '));
  }

  @failingTest
  Future<void> test_semicolonFnBodyWithDef() async {
    // This ought to be the same as test_semicolonFnBody() but the definition
    // of f() removes an error and it appears to be a different case.
    // Suggestions for unifying the two are welcome.

    // Analyzer parser produces
    //   int; f();
    // Fasta parser produces
    //   int f; ();
    // Neither of these is ideal.
    // TODO(danrubel): Improve parser recovery in this situation.
    await _prepareCompletion('f()', '''
void f() {
  int f()
}
f() {}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  int f();
  ////
}
f() {}
''', (s) => _afterLast(s, '  '));
  }

  Future<void> test_semicolonFnExpr() async {
    await _prepareCompletion('=>', '''
void f() {
  int f() =>
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  int f() => ;
  ////
}
''', (s) => _afterLast(s, '=> '));
  }

  Future<void> test_semicolonFnSpaceExpr() async {
    await _prepareCompletion('=>', '''
void f() {
  int f() => ////
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  int f() => ;
  ////
}
''', (s) => _afterLast(s, '=> '));
  }

  Future<void> test_semicolonVar() async {
    await _prepareCompletion('v = 1', '''
void f() {
  int v = 1
}
''', atEnd: true);
    _assertHasChange('Add a semicolon and newline', '''
void f() {
  int v = 1;
  ////
}
''', (s) => _afterLast(s, '  '));
  }
}

@reflectiveTest
class _SwitchCompletionTest extends StatementCompletionTest {
  @FailingTest(issue: 'https://github.com/dart-lang/sdk/issues/49759')
  Future<void> test_caseNoColon() async {
    await _prepareCompletion('label', '''
void f(x) {
  switch (x) {
    case label
  }
}
''', atEnd: true);
    _assertHasChange('Complete switch-statement', '''
void f(x) {
  switch (x) {
    case label: ////
  }
}
''', (s) => _after(s, 'label: '));
  }

  Future<void> test_caseNoColon_language219() async {
    await _prepareCompletion('label', '''
// @dart=2.19
void f(x) {
  switch (x) {
    case label
  }
}
''', atEnd: true);
    _assertHasChange('Complete switch-statement', '''
// @dart=2.19
void f(x) {
  switch (x) {
    case label: ////
  }
}
''', (s) => _after(s, 'label: '));
  }

  Future<void> test_defaultNoColon() async {
    await _prepareCompletion('default', '''
void f(x) {
  switch (x) {
    default
  }
}
''', atEnd: true);
    _assertHasChange('Complete switch-statement', '''
void f(x) {
  switch (x) {
    default: ////
  }
}
''', (s) => _after(s, 'default: '));
  }

  Future<void> test_emptyCondition() async {
    await _prepareCompletion('switch', '''
void f() {
  switch ()
}
''', atEnd: true);
    _assertHasChange('Complete switch-statement', '''
void f() {
  switch () {
    ////
  }
}
''', (s) => _after(s, 'switch ('));
  }

  Future<void> test_keywordOnly() async {
    await _prepareCompletion('switch', '''
void f() {
  switch////
}
''', atEnd: true);
    _assertHasChange('Complete switch-statement', '''
void f() {
  switch () {
    ////
  }
}
''', (s) => _after(s, 'switch ('));
  }

  Future<void> test_keywordSpace() async {
    await _prepareCompletion('switch', '''
void f() {
  switch ////
}
''', atEnd: true);
    _assertHasChange('Complete switch-statement', '''
void f() {
  switch () {
    ////
  }
}
''', (s) => _after(s, 'switch ('));
  }
}

@reflectiveTest
class _TryCompletionTest extends StatementCompletionTest {
  Future<void> test_catchOnly() async {
    await _prepareCompletion('{} catch', '''
void f() {
  try {
  } catch(e){} catch ////
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } catch(e){} catch () {
    ////
  }
}
''', (s) => _after(s, 'catch ('));
  }

  Future<void> test_catchSecond() async {
    await _prepareCompletion('} catch ', '''
void f() {
  try {
  } catch() {
  } catch(e){} catch ////
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } catch() {
  } catch(e){} catch () {
    ////
  }
}
''', (s) => _afterLast(s, 'catch ('));
  }

  Future<void> test_finallyOnly() async {
    await _prepareCompletion('finally', '''
void f() {
  try {
  } finally
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } finally {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_keywordOnly() async {
    await _prepareCompletion('try', '''
void f() {
  try////
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_keywordSpace() async {
    await _prepareCompletion('try', '''
void f() {
  try ////
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
    ////
  }
}
''', (s) => _after(s, '    '));
  }

  Future<void> test_onCatch() async {
    await _prepareCompletion('on', '''
void f() {
  try {
  } on catch
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } on catch () {
    ////
  }
}
''', (s) => _after(s, 'catch ('));
  }

  Future<void> test_onCatchComment() async {
    await _prepareCompletion('on', '''
void f() {
  try {
  } on catch
  //
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } on catch () {
    ////
  }
  //
}
''', (s) => _after(s, 'catch ('));
  }

  Future<void> test_onOnly() async {
    await _prepareCompletion('on', '''
void f() {
  try {
  } on
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } on  {
    ////
  }
}
''', (s) => _after(s, ' on '));
  }

  Future<void> test_onSpace() async {
    await _prepareCompletion('on', '''
void f() {
  try {
  } on ////
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } on  {
    ////
  }
}
''', (s) => _after(s, ' on '));
  }

  Future<void> test_onSpaces() async {
    await _prepareCompletion('on', '''
void f() {
  try {
  } on  ////
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } on  {
    ////
  }
}
''', (s) => _after(s, ' on '));
  }

  Future<void> test_onType() async {
    await _prepareCompletion('on', '''
void f() {
  try {
  } on Exception
}
''', atEnd: true);
    _assertHasChange('Complete try-statement', '''
void f() {
  try {
  } on Exception {
    ////
  }
}
''', (s) => _after(s, '    '));
  }
}

@reflectiveTest
class _WhileCompletionTest extends StatementCompletionTest {
  /*
     The implementation of completion for while-statements is shared with
     if-statements. Here we check that the wrapper for while-statements
     functions as expected. The individual test cases are covered by the
     _IfCompletionTest tests. If the implementation changes then the same
     set of tests defined for if-statements should be duplicated here.
   */
  Future<void> test_keywordOnly() async {
    await _prepareCompletion('while', '''
void f() {
  while ////
}
''', atEnd: true);
    _assertHasChange('Complete while-statement', '''
void f() {
  while () {
    ////
  }
}
''', (s) => _after(s, 'while ('));
  }
}
