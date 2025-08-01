// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/computer/computer_call_hierarchy.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analysis_server/src/services/search/search_engine_internal.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer/src/test_utilities/test_code_format.dart';
import 'package:matcher/expect.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../abstract_single_unit.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CallHierarchyComputerFindTargetTest);
    defineReflectiveTests(CallHierarchyComputerIncomingCallsTest);
    defineReflectiveTests(CallHierarchyComputerOutgoingCallsTest);
  });
}

/// Matches a [CallHierarchyItem] with the given name/kind/file.
Matcher _isItem(
  CallHierarchyKind kind,
  String displayName,
  String file, {
  required String? containerName,
  required SourceRange nameRange,
  required SourceRange codeRange,
}) => TypeMatcher<CallHierarchyItem>()
    .having((e) => e.kind, 'kind', kind)
    .having((e) => e.displayName, 'displayName', displayName)
    .having((e) => e.containerName, 'containerName', containerName)
    .having((e) => e.file, 'file', file)
    .having((e) => e.nameRange, 'nameRange', nameRange)
    .having((e) => e.codeRange, 'codeRange', codeRange);

/// Matches a [CallHierarchyCalls] result with the given element/ranges.
Matcher _isResult(
  CallHierarchyKind kind,
  String displayName,
  String file, {
  required String? containerName,
  required SourceRange nameRange,
  required SourceRange codeRange,
  List<SourceRange>? ranges,
}) {
  var matcher = TypeMatcher<CallHierarchyCalls>().having(
    (c) => c.item,
    'item',
    _isItem(
      kind,
      displayName,
      file,
      containerName: containerName,
      nameRange: nameRange,
      codeRange: codeRange,
    ),
  );

  if (ranges != null) {
    matcher = matcher.having((c) => c.ranges, 'ranges', ranges);
  }

  return matcher;
}

abstract class AbstractCallHierarchyTest extends AbstractSingleUnitTest {
  final startOfFile = SourceRange(0, 0);

  /// Gets the entire range for [code].
  SourceRange entireRange(TestCode code) => SourceRange(0, code.code.length);

  Future<CallHierarchyItem?> findTarget(TestCode code) async {
    var offset = code.position.offset;
    expect(offset, greaterThanOrEqualTo(0));
    addTestSource(code.code);

    var result = await getResolvedUnit(testFile);

    return DartCallHierarchyComputer(result).findTarget(offset);
  }

  TestCode parseCode(String content) {
    return TestCode.parse(normalizeSource(content));
  }

  /// Gets the expected range that follows the string [prefix] in [content] with a
  /// length of [match.length].
  SourceRange rangeAfterPrefix(String prefix, TestCode code, String match) =>
      SourceRange(code.code.indexOf(prefix) + prefix.length, match.length);

  /// Gets the expected range that starts at [search] in [code] with a
  /// length of [match.length].
  SourceRange rangeAtSearch(String search, TestCode code, [String? match]) {
    var offset = code.code.indexOf(search);
    expect(offset, greaterThanOrEqualTo(0));
    return SourceRange(offset, (match ?? search).length);
  }
}

@reflectiveTest
class CallHierarchyComputerFindTargetTest extends AbstractCallHierarchyTest {
  late String otherFile;

  Future<void> expectNoTarget(TestCode code) async {
    await expectTarget(code, isNull);
  }

  Future<void> expectTarget(TestCode code, Matcher matcher) async {
    var target = await findTarget(code);
    expect(target, matcher);
  }

  @override
  void setUp() {
    super.setUp();
    otherFile = convertPath('$testPackageLibPath/other.dart');
  }

  Future<void> test_args() async {
    await expectNoTarget(parseCode('f(int ^a) {}'));
  }

  Future<void> test_block() async {
    await expectNoTarget(parseCode('f() {^}'));
  }

  Future<void> test_comment() async {
    await expectNoTarget(parseCode('f() {} // this is a ^comment'));
  }

  Future<void> test_constructor() async {
    var code = parseCode('''
class Foo {
  [!Fo^o(String a) {}!]
}
''');

    var target = await findTarget(code);
    expect(
      target,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo',
        testFile.path,
        containerName: 'Foo',
        nameRange: rangeAtSearch('Foo(', code, 'Foo'),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_constructorCall() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  final foo = Fo^o();
}
''');

    var otherCode = parseCode('''
class Foo {
  [!Foo();!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('Foo(', otherCode, 'Foo'),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  @SkippedTest() // TODO(scheglov): implement augmentation
  Future<void> test_constructorCall_to_augmentation() async {
    var code = parseCode('''
part 'other.dart';

class Foo {}

void f() {
  Foo.na^med();
}
''');

    var otherCode = parseCode('''
part of 'test.dart';
augment class Foo {
  [!Foo.named(){}!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo.named',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('named', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_dotShorthand_constructor_named() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  Foo foo = .nam^ed();
}
''');

    var otherCode = parseCode('''
class Foo {
  [!Foo.named();!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo.named',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('named', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_dotShorthand_constructor_unnamed() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  Foo foo = .ne^w();
}
''');

    var otherCode = parseCode('''
[!class Foo {}!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('Foo {', otherCode, 'Foo'),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_dotShorthand_extensionType() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  Foo foo = .ba^r;
}
''');

    var otherCode = parseCode('''
extension type Foo(int x) {
  [!static Foo get bar => Foo(1);!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.property,
        'get bar',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('bar', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_dotShorthand_getter() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  Foo foo = .ba^r;
}
''');

    var otherCode = parseCode('''
class Foo {
  [!static Foo get bar => Foo();!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.property,
        'get bar',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('bar', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_dotShorthand_method() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  Foo foo = .ba^r();
}
''');

    var otherCode = parseCode('''
class Foo {
  [!static Foo bar() => Foo();!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'bar',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('bar', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_extension_method() async {
    var code = parseCode('''
extension StringExtension on String {
  [!void myMet^hod() {}!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        testFile.path,
        containerName: 'StringExtension',
        nameRange: rangeAtSearch('myMethod', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_extension_methodCall() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  ''.myMet^hod();
}
''');

    var otherCode = parseCode('''
extension StringExtension on String {
  [!void myMethod() {}!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        otherFile,
        containerName: 'StringExtension',
        nameRange: rangeAtSearch('myMethod', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_function() async {
    var code = parseCode('''
[!void myFun^ction() {}!]
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        testFile.path,
        containerName: 'test.dart',
        nameRange: rangeAtSearch('myFunction', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_function_startOfParameterList() async {
    var code = parseCode('''
[!void myFunction^() {}!]
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        testFile.path,
        containerName: 'test.dart',
        nameRange: rangeAtSearch('myFunction', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_function_startOfTypeParameterList() async {
    var code = parseCode('''
[!void myFunction^<T>() {}!]
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        testFile.path,
        containerName: 'test.dart',
        nameRange: rangeAtSearch('myFunction', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_functionCall() async {
    var code = parseCode('''
import 'other.dart' as other;

void f() {
  other.myFun^ction();
}
''');

    var otherCode = parseCode('''
[!void myFunction() {}!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        otherFile,
        containerName: 'other.dart',
        nameRange: rangeAtSearch('myFunction', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_functionCallInNullAwareElementInList() async {
    var code = parseCode('''
import 'other.dart' as other;

void f() {
  <String>[?other.myFun^ction()];
}
''');

    var otherCode = parseCode('''
[!String? myFunction() => null;!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        otherFile,
        containerName: 'other.dart',
        nameRange: rangeAtSearch('myFunction', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_functionCallInNullAwareElementInMapKey() async {
    var code = parseCode('''
import 'other.dart' as other;

void f() {
  <String, int>{?other.myFun^ction(): 0};
}
''');

    var otherCode = parseCode('''
[!String? myFunction() => null;!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        otherFile,
        containerName: 'other.dart',
        nameRange: rangeAtSearch('myFunction', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_functionCallInNullAwareElementInMapValue() async {
    var code = parseCode('''
import 'other.dart' as other;

void f() {
  <int, String>{0: ?other.myFun^ction()};
}
''');

    var otherCode = parseCode('''
[!String? myFunction() => null;!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        otherFile,
        containerName: 'other.dart',
        nameRange: rangeAtSearch('myFunction', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_functionCallInNullAwareElementInSet() async {
    var code = parseCode('''
import 'other.dart' as other;

void f() {
  <String>{?other.myFun^ction()};
}
''');

    var otherCode = parseCode('''
[!String? myFunction() => null;!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.function,
        'myFunction',
        otherFile,
        containerName: 'other.dart',
        nameRange: rangeAtSearch('myFunction', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_getter() async {
    var code = parseCode('''
class Foo {
  [!String get fo^o => '';!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.property,
        'get foo',
        testFile.path,
        containerName: 'Foo',
        nameRange: rangeAtSearch('foo', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_getterCall() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  final foo = ba^r;
}
''');

    var otherCode = parseCode('''
[!String get bar => '';!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.property,
        'get bar',
        otherFile,
        containerName: 'other.dart',
        nameRange: rangeAtSearch('bar', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_implicitConstructorCall() async {
    // Even if a constructor is implicit, we might want to be able to get the
    // incoming calls, so we should return the class location as a stand-in
    // (although with the Kind still set to constructor).
    var code = parseCode('''
import 'other.dart';

void f() {
  final foo = Fo^o();
}
''');

    var otherCode = parseCode('''
[!class Foo {}!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('Foo {', otherCode, 'Foo'),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_method() async {
    var code = parseCode('''
class Foo {
  [!void myMet^hod() {}!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        testFile.path,
        containerName: 'Foo',
        nameRange: rangeAtSearch('myMethod', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_method_startOfParameterList() async {
    var code = parseCode('''
class Foo {
  [!void myMethod^() {}!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        testFile.path,
        containerName: 'Foo',
        nameRange: rangeAtSearch('myMethod', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_method_startOfTypeParameterList() async {
    var code = parseCode('''
class Foo {
  [!void myMethod^<T>() {}!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        testFile.path,
        containerName: 'Foo',
        nameRange: rangeAtSearch('myMethod', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_methodCall() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  Foo().myMet^hod();
}
''');

    var otherCode = parseCode('''
class Foo {
  [!void myMethod() {}!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('myMethod', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_methodCall_to_augmentation() async {
    var code = parseCode('''
part 'other.dart';

class Foo {}

void f() {
  Foo().myMet^hod();
}
''');

    var otherCode = parseCode('''
part of 'test.dart';

augment class Foo {
  [!void myMethod() {}!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('myMethod', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_mixin_method() async {
    var code = parseCode('''
mixin Bar {
  [!void myMet^hod() {}!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        testFile.path,
        containerName: 'Bar',
        nameRange: rangeAtSearch('myMethod', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_mixin_methodCall() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  Foo().myMet^hod();
}
''');

    var otherCode = parseCode('''
class Bar {
  [!void myMethod() {}!]
}

class Foo with Bar {}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.method,
        'myMethod',
        otherFile,
        containerName: 'Bar',
        nameRange: rangeAtSearch('myMethod', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_namedConstructor() async {
    var code = parseCode('''
class Foo {
  [!Foo.Ba^r(String a) {}!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo.Bar',
        testFile.path,
        containerName: 'Foo',
        nameRange: rangeAtSearch('Bar', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_namedConstructor_typeName() async {
    var code = parseCode('''
class Foo {
  Fo^o.Bar(String a) {}
}
''');

    await expectNoTarget(code);
  }

  Future<void> test_namedConstructorCall() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  final foo = Foo.Ba^r();
}
''');

    var otherCode = parseCode('''
class Foo {
  [!Foo.Bar();!]
}
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.constructor,
        'Foo.Bar',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('Bar', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_namedConstructorCall_typeName() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  final foo = Fo^o.Bar();
}
''');

    var otherCode = parseCode('''
class Foo {
  Foo.Bar();
}
''');

    newFile(otherFile, otherCode.code);
    await expectNoTarget(code);
  }

  Future<void> test_setter() async {
    var code = parseCode('''
class Foo {
  [!set fo^o(String value) {}!]
}
''');

    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.property,
        'set foo',
        testFile.path,
        containerName: 'Foo',
        nameRange: rangeAtSearch('foo', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_setterCall() async {
    var code = parseCode('''
import 'other.dart';

void f() {
  ba^r = '';
}
''');

    var otherCode = parseCode('''
[!set bar(String value) {}!]
''');

    newFile(otherFile, otherCode.code);
    await expectTarget(
      code,
      _isItem(
        CallHierarchyKind.property,
        'set bar',
        otherFile,
        containerName: 'other.dart',
        nameRange: rangeAtSearch('bar', otherCode),
        codeRange: otherCode.range.sourceRange,
      ),
    );
  }

  Future<void> test_whitespace() async {
    await expectNoTarget(parseCode(' ^  void f() {}'));
  }

  Future<void> test_wildcardVariable() async {
    var code = parseCode('''
f() {
  [!^_() {}!]
}
''');

    var target = await findTarget(code);
    expect(
      target,
      _isItem(
        CallHierarchyKind.function,
        '_',
        testFile.path,
        containerName: 'f',
        nameRange: rangeAtSearch('_', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }

  Future<void> test_wildcardVariable_preWildcards() async {
    var code = parseCode('''
// @dart = 3.4
// (pre wildcard-variables)

f() {
  [!_() {}!]
  ^_();
}
''');

    var target = await findTarget(code);
    expect(
      target,
      _isItem(
        CallHierarchyKind.function,
        '_',
        testFile.path,
        containerName: 'f',
        nameRange: rangeAtSearch('_', code),
        codeRange: code.range.sourceRange,
      ),
    );
  }
}

@reflectiveTest
class CallHierarchyComputerIncomingCallsTest extends AbstractCallHierarchyTest {
  late String otherFile;
  late SearchEngine searchEngine;

  Future<List<CallHierarchyCalls>> findIncomingCalls(TestCode code) async {
    var target = (await findTarget(code))!;
    return findIncomingCallsForTarget(target);
  }

  Future<List<CallHierarchyCalls>> findIncomingCallsForTarget(
    CallHierarchyItem target,
  ) async {
    var targetFile = getFile(target.file);
    var result = await getResolvedUnit(targetFile);
    expect(result.diagnostics, isEmpty);

    return DartCallHierarchyComputer(
      result,
    ).findIncomingCalls(target, searchEngine);
  }

  @override
  void setUp() {
    super.setUp();
    otherFile = convertPath('$testPackageLibPath/other.dart');
    searchEngine = SearchEngineImpl([driverFor(testFile)]);
  }

  Future<void> test_constructor() async {
    var code = parseCode('''
class Foo {
  Fo^o();
}
''');

    var otherCode = parseCode('''
import 'test.dart';

final foo1 = Foo();
/*[0*/class Bar {
  final foo2 = Foo();
  /*[1*/Foo get foo3 => Foo();/*1]*/
  /*[2*/Bar() {
    final foo4 = Foo();
  }/*2]*/
  /*[3*/void bar() {
    final foo5 = Foo();
    final foo6 = Foo();
  }/*3]*/
}/*0]*/
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'Foo');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo1 = ')],
        ),
        _isResult(
          CallHierarchyKind.class_,
          'Bar',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('Bar {', otherCode, 'Bar'),
          codeRange: otherCode.ranges[0].sourceRange,
          ranges: [rangeAfter('foo2 = ')],
        ),
        _isResult(
          CallHierarchyKind.property,
          'get foo3',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('foo3', otherCode),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [rangeAfter('foo3 => ')],
        ),
        _isResult(
          CallHierarchyKind.constructor,
          'Bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('Bar() {', otherCode, 'Bar'),
          codeRange: otherCode.ranges[2].sourceRange,
          ranges: [rangeAfter('foo4 = ')],
        ),
        _isResult(
          CallHierarchyKind.method,
          'bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('bar() {', otherCode, 'bar'),
          codeRange: otherCode.ranges[3].sourceRange,
          ranges: [rangeAfter('foo5 = '), rangeAfter('foo6 = ')],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_constructor_named() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

[!void f() {
  Foo foo1 = .nam^ed();
}!]
''');

    var otherCode = parseCode('''
class Foo {
  Foo.named();
}

Foo foo2 = .named();
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix, TestCode code) =>
        rangeAfterPrefix(prefix, code, 'named');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          testFile.path,
          containerName: 'test.dart',
          nameRange: rangeAtSearch('f() {', code, 'f'),
          codeRange: code.range.sourceRange,
          ranges: [rangeAfter('foo1 = .', code)],
        ),
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo2 = .', otherCode)],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_constructor_unnamed() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

[!void f() {
  Foo foo1 = .ne^w();
}!]
''');

    var otherCode = parseCode('''
class Foo {}

Foo foo2 = .new();
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix, TestCode code) =>
        rangeAfterPrefix(prefix, code, 'new');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          testFile.path,
          containerName: 'test.dart',
          nameRange: rangeAtSearch('f() {', code, 'f'),
          codeRange: code.range.sourceRange,
          ranges: [rangeAfter('foo1 = .', code)],
        ),
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo2 = .', otherCode)],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_extensionType() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

[!void f() {
  Foo foo1 = .gett^er;
}!]
''');

    var otherCode = parseCode('''
extension type Foo(int x) {
  static Foo get getter => Foo(1);
}

Foo foo2 = .getter;
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix, TestCode code) =>
        rangeAfterPrefix(prefix, code, 'getter');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          testFile.path,
          containerName: 'test.dart',
          nameRange: rangeAtSearch('f() {', code, 'f'),
          codeRange: code.range.sourceRange,
          ranges: [rangeAfter('foo1 = .', code)],
        ),
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo2 = .', otherCode)],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_getter() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

[!void f() {
  Foo foo1 = .gett^er;
}!]
''');

    var otherCode = parseCode('''
class Foo {
  static Foo get getter => Foo();
}

Foo foo2 = .getter;
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix, TestCode code) =>
        rangeAfterPrefix(prefix, code, 'getter');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          testFile.path,
          containerName: 'test.dart',
          nameRange: rangeAtSearch('f() {', code, 'f'),
          codeRange: code.range.sourceRange,
          ranges: [rangeAfter('foo1 = .', code)],
        ),
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo2 = .', otherCode)],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_method() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

[!void f() {
  Foo foo1 = .meth^od();
}!]
''');

    var otherCode = parseCode('''
class Foo {
  static Foo method() => Foo();
}

Foo foo2 = .method();
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix, TestCode code) =>
        rangeAfterPrefix(prefix, code, 'method');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          testFile.path,
          containerName: 'test.dart',
          nameRange: rangeAtSearch('f() {', code, 'f'),
          codeRange: code.range.sourceRange,
          ranges: [rangeAfter('foo1 = .', code)],
        ),
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo2 = .', otherCode)],
        ),
      ]),
    );
  }

  Future<void> test_extension_method() async {
    var code = parseCode('''
extension StringExtension on String {
  void myMet^hod() {}
}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  ''.myMethod();
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myMethod');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter("''.")],
        ),
      ]),
    );
  }

  Future<void> test_fileModifications() async {
    var code = parseCode('''
void o^ne() {}
void two() {
  one();
}
''');

    var target = (await findTarget(code))!;

    // Ensure there are some results before modification.
    var calls = await findIncomingCallsForTarget(target);
    expect(calls, isNotEmpty);

    // Modify the file so that the target offset is no longer the original item.
    updateTestSource(testCode.replaceAll('one()', 'three()'));

    // Ensure there are now no results for the original target.
    calls = await findIncomingCallsForTarget(target);
    expect(calls, isEmpty);
  }

  Future<void> test_function() async {
    var code = parseCode('''
String myFun^ction() => '';
''');

    var otherCode = parseCode('''
import 'test.dart';

final foo1 = myFunction();

/*[0*/class Bar {
  final foo2 = myFunction();
  /*[1*/String get foo3 => myFunction();/*1]*/
  /*[2*/Bar() {
    final foo4 = myFunction();
  }/*2]*/
  /*[3*/void bar() {
    final foo5 = myFunction();
    final foo6 = myFunction();
  }/*3]*/
}/*0]*/
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myFunction');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo1 = ')],
        ),
        _isResult(
          CallHierarchyKind.class_,
          'Bar',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('Bar {', otherCode, 'Bar'),
          codeRange: otherCode.ranges[0].sourceRange,
          ranges: [rangeAfter('foo2 = ')],
        ),
        _isResult(
          CallHierarchyKind.property,
          'get foo3',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('foo3', otherCode),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [rangeAfter('foo3 => ')],
        ),
        _isResult(
          CallHierarchyKind.constructor,
          'Bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('Bar() {', otherCode, 'Bar'),
          codeRange: otherCode.ranges[2].sourceRange,
          ranges: [rangeAfter('foo4 = ')],
        ),
        _isResult(
          CallHierarchyKind.method,
          'bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('bar() {', otherCode, 'bar'),
          codeRange: otherCode.ranges[3].sourceRange,
          ranges: [rangeAfter('foo5 = '), rangeAfter('foo6 = ')],
        ),
      ]),
    );
  }

  Future<void> test_getter() async {
    var code = parseCode('''
String get f^oo => '';
''');

    var otherCode = parseCode('''
import 'test.dart';

final foo1 = foo;
/*[0*/class Bar {
  final foo2 = foo;
  /*[1*/Foo get foo3 => foo;/*1]*/
  /*[2*/Bar() {
    final foo4 = foo;
  }/*2]*/
  /*[3*/void bar() {
    final foo5 = foo;
    final foo6 = foo;
  }/*3]*/
}/*0]*/
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'foo');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo1 = ')],
        ),
        _isResult(
          CallHierarchyKind.class_,
          'Bar',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('Bar {', otherCode, 'Bar'),
          codeRange: otherCode.ranges[0].sourceRange,
          ranges: [rangeAfter('foo2 = ')],
        ),
        _isResult(
          CallHierarchyKind.property,
          'get foo3',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('foo3', otherCode),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [rangeAfter('foo3 => ')],
        ),
        _isResult(
          CallHierarchyKind.constructor,
          'Bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('Bar() {', otherCode, 'Bar'),
          codeRange: otherCode.ranges[2].sourceRange,
          ranges: [rangeAfter('foo4 = ')],
        ),
        _isResult(
          CallHierarchyKind.method,
          'bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('bar() {', otherCode, 'bar'),
          codeRange: otherCode.ranges[3].sourceRange,
          ranges: [rangeAfter('foo5 = '), rangeAfter('foo6 = ')],
        ),
      ]),
    );
  }

  Future<void> test_implicitConstructor() async {
    // We still expect to be able to navigate with implicit constructors. This
    // is done by the target being the class, but with a kind of Constructor.
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

[!void f() {
  final foo1 = Fo^o();
}!]
''');

    var otherCode = parseCode('''
class Foo {}

final foo2 = Foo();
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix, TestCode code) =>
        rangeAfterPrefix(prefix, code, 'Foo');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          testFile.path,
          containerName: 'test.dart',
          nameRange: rangeAtSearch('f() {', code, 'f'),
          codeRange: code.range.sourceRange,
          ranges: [rangeAfter('foo1 = ', code)],
        ),
        _isResult(
          CallHierarchyKind.file,
          'other.dart',
          otherFile,
          containerName: null,
          nameRange: startOfFile,
          codeRange: entireRange(otherCode),
          ranges: [rangeAfter('foo2 = ', otherCode)],
        ),
      ]),
    );
  }

  Future<void> test_method() async {
    var code = parseCode('''
class Foo {
  void myMet^hod() {}
}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  Foo().myMethod();
  final tearoff = Foo().myMethod;
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myMethod');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter('Foo().'), rangeAfter('tearoff = Foo().')],
        ),
      ]),
    );
  }

  Future<void> test_method_from_augmentation() async {
    var code = parseCode('''
part 'other.dart';

class Foo {
  void myMet^hod() {}
}
''');

    var otherCode = parseCode('''
part of 'test.dart';

augment class Foo {
  [!void f() {
    myMethod();
  }!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(calls, [
      _isResult(
        CallHierarchyKind.method,
        'f',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('f() {', otherCode, 'f'),
        codeRange: otherCode.range.sourceRange,
      ),
    ]);
  }

  Future<void> test_methodInNullAwareElementInList() async {
    var code = parseCode('''
class Foo {
  bool? myMet^hod() => null;
}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  dynamic tearoff;
  <bool>[
    ?Foo().myMethod(),
    ?tearoff = Foo().myMethod,
  ];
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myMethod');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter('Foo().'), rangeAfter('tearoff = Foo().')],
        ),
      ]),
    );
  }

  Future<void> test_methodInNullAwareElementInMapKey() async {
    var code = parseCode('''
class Foo {
  bool? myMet^hod() => null;
}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  dynamic tearoff;
  <bool, num>{
    ?Foo().myMethod(): 0,
    ?tearoff = Foo().myMethod: 1,
  };
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myMethod');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter('Foo().'), rangeAfter('tearoff = Foo().')],
        ),
      ]),
    );
  }

  Future<void> test_methodInNullAwareElementInMapValue() async {
    var code = parseCode('''
class Foo {
  bool? myMet^hod() => null;
}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  dynamic tearoff;
  <String, bool>{
    "foo": ?Foo().myMethod(),
    "bar": ?tearoff = Foo().myMethod,
  };
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myMethod');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter('Foo().'), rangeAfter('tearoff = Foo().')],
        ),
      ]),
    );
  }

  Future<void> test_methodInNullAwareElementInSet() async {
    var code = parseCode('''
class Foo {
  bool? myMet^hod() => null;
}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  dynamic tearoff;
  <bool>{
    ?Foo().myMethod(),
    ?tearoff = Foo().myMethod,
  };
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myMethod');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter('Foo().'), rangeAfter('tearoff = Foo().')],
        ),
      ]),
    );
  }

  Future<void> test_mixin_method() async {
    var code = parseCode('''
mixin Bar {
  void myMet^hod() {}
}

class Foo with Bar {}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  Foo().myMethod();
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'myMethod');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter('Foo().')],
        ),
      ]),
    );
  }

  Future<void> test_namedConstructor() async {
    var code = parseCode('''
class Foo {
  Foo.B^ar();
}
''');

    var otherCode = parseCode('''
import 'test.dart';

[!void f() {
  final foo = Foo.Bar();
}!]
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'Bar');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfter('foo = Foo.')],
        ),
      ]),
    );
  }

  Future<void> test_setter() async {
    var code = parseCode('''
set fo^o(String value) {}
''');

    var otherCode = parseCode('''
import 'test.dart';

class Bar {
  /*[0*/Bar() {
    /*a*/foo = '';
  }/*0]*/
  /*[1*/void bar() {
    /*b*/foo = '';
    /*c*/foo = '';
  }/*1]*/
}
''');

    // Gets the expected range that follows the string [prefix].
    SourceRange rangeAfter(String prefix) =>
        rangeAfterPrefix(prefix, otherCode, 'foo');

    newFile(otherFile, otherCode.code);
    var calls = await findIncomingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'Bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('Bar() {', otherCode, 'Bar'),
          codeRange: otherCode.ranges[0].sourceRange,
          ranges: [rangeAfter('/*a*/')],
        ),
        _isResult(
          CallHierarchyKind.method,
          'bar',
          otherFile,
          containerName: 'Bar',
          nameRange: rangeAtSearch('bar() {', otherCode, 'bar'),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [rangeAfter('/*b*/'), rangeAfter('/*c*/')],
        ),
      ]),
    );
  }
}

@reflectiveTest
class CallHierarchyComputerOutgoingCallsTest extends AbstractCallHierarchyTest {
  late String otherFile;

  Future<List<CallHierarchyCalls>> findOutgoingCalls(TestCode code) async {
    var target = (await findTarget(code))!;
    return findOutgoingCallsForTarget(target);
  }

  Future<List<CallHierarchyCalls>> findOutgoingCallsForTarget(
    CallHierarchyItem target,
  ) async {
    var targetFile = getFile(target.file);
    var result = await getResolvedUnit(targetFile);
    expect(result.diagnostics, isEmpty);

    return DartCallHierarchyComputer(result).findOutgoingCalls(target);
  }

  @override
  void setUp() {
    super.setUp();
    otherFile = convertPath('$testPackageLibPath/other.dart');
  }

  Future<void> test_constructor() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Fo^o() {
    final a = A();
    final constructorTearoffA = A.new;
    final b = B();
    final constructorTearoffB = B.new;
  }
}
''');

    var otherCode = parseCode('''
class A {
  /*[0*/A();/*0]*/
}

/*[1*/class B {
}/*1]*/
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('A();', otherCode, 'A'),
          codeRange: otherCode.ranges[0].sourceRange,
          ranges: [
            rangeAtSearch('A()', code, 'A'),
            rangeAfterPrefix('constructorTearoffA = A.', code, 'new'),
          ],
        ),
        _isResult(
          CallHierarchyKind.constructor,
          'B',
          otherFile,
          containerName: 'B',
          nameRange: rangeAtSearch('B {', otherCode, 'B'),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [
            rangeAtSearch('B()', code, 'B'),
            rangeAfterPrefix('constructorTearoffB = B.', code, 'new'),
          ],
        ),
      ]),
    );
  }

  @SkippedTest() // TODO(scheglov): implement augmentation
  Future<void> test_constructor_from_augmentation() async {
    var code = parseCode('''
part 'other.dart';

class Foo {}

void ba^r() {
  Foo.named();
}
''');

    var otherCode = parseCode('''
part of 'test.dart';

augment class Foo {
  [!Foo.named() {
  }!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(calls, [
      _isResult(
        CallHierarchyKind.constructor,
        'Foo.named',
        otherFile,
        containerName: 'Foo',
        nameRange: rangeAtSearch('named() {', otherCode, 'named'),
        codeRange: otherCode.range.sourceRange,
      ),
    ]);
  }

  Future<void> test_dotShorthand_constructor_named() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.b^ar() {
    A a = .named();
  }
}
''');

    var otherCode = parseCode('''
class A {
  [!A.named();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A.named',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('named', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfterPrefix('a = .', code, 'named')],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_constructor_unnamed() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.b^ar() {
    A a = .new();
  }
}
''');

    var otherCode = parseCode('''
[!class A {}!]
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('A {', otherCode, 'A'),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfterPrefix('a = .', code, 'new')],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_extensionType() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.b^ar() {
    A a = .getter;
  }
}
''');

    var otherCode = parseCode('''
extension type A(int x) {
  [!static A get getter => A(1);!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.property,
          'get getter',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('getter', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfterPrefix('a = .', code, 'getter')],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_getter() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.b^ar() {
    A a = .getter;
  }
}
''');

    var otherCode = parseCode('''
class A {
  [!static A get getter => A();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.property,
          'get getter',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('getter', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfterPrefix('a = .', code, 'getter')],
        ),
      ]),
    );
  }

  Future<void> test_dotShorthand_method() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.b^ar() {
    A a = .method();
  }
}
''');

    var otherCode = parseCode('''
class A {
  [!static A method() => A();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.method,
          'method',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('method', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [rangeAfterPrefix('a = .', code, 'method')],
        ),
      ]),
    );
  }

  Future<void> test_extension_method() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

extension StringExtension on String {
  void fo^o() {
    ''.bar();
    final tearoff = ''.bar;
  }
}
''');

    var otherCode = parseCode('''
extension StringExtension on String {
  [!void bar() {}!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.method,
          'bar',
          otherFile,
          containerName: 'StringExtension',
          nameRange: rangeAtSearch('bar() {', otherCode, 'bar'),
          codeRange: otherCode.range.sourceRange,
          ranges: [
            rangeAtSearch('bar();', code, 'bar'),
            rangeAtSearch('bar;', code, 'bar'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_fileModifications() async {
    var code = parseCode('''
void o^ne() {
  two();
}
void two() {}
''');

    var target = (await findTarget(code))!;

    // Ensure there are some results before modification.
    var calls = await findOutgoingCallsForTarget(target);
    expect(calls, isNotEmpty);

    // Modify the file so that the target offset is no longer the original item.
    updateTestSource(testCode.replaceAll('one()', 'three()'));

    // Ensure there are now no results for the original target.
    calls = await findOutgoingCallsForTarget(target);
    expect(calls, isEmpty);
  }

  Future<void> test_function() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

void fo^o() {
  [!void nested() {
    f(); // not a call of 'foo'
  }!]
  f(); // 1
  final tearoff = f;
  nested();
  final nestedTearoff = nested;
}
''');

    var otherCode = parseCode('''
[!void f() {}!]
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.function,
          'f',
          otherFile,
          containerName: 'other.dart',
          nameRange: rangeAtSearch('f() {', otherCode, 'f'),
          codeRange: otherCode.range.sourceRange,
          ranges: [
            rangeAtSearch('f(); // 1', code, 'f'),
            rangeAfterPrefix('tearoff = ', code, 'f'),
          ],
        ),
        _isResult(
          CallHierarchyKind.function,
          'nested',
          testFile.path,
          containerName: 'foo',
          nameRange: rangeAtSearch('nested() {', code, 'nested'),
          codeRange: code.range.sourceRange,
          ranges: [
            rangeAtSearch('nested();', code, 'nested'),
            rangeAfterPrefix('nestedTearoff = ', code, 'nested'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_getter() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

String get fo^o {
  final a = A();
  final b = a.b;
  final c = A().b;
  return '';
}
''');

    var otherCode = parseCode('''
/*[0*/class A {
  /*[1*/String get b => '';/*1]*/
}/*0]*/
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('A {', otherCode, 'A'),
          codeRange: otherCode.ranges[0].sourceRange,
        ),
        _isResult(
          CallHierarchyKind.property,
          'get b',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('b => ', otherCode, 'b'),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [
            rangeAfterPrefix('a.', code, 'b'),
            rangeAfterPrefix('A().', code, 'b'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_implicitConstructor() async {
    // We can still begin navigating from an implicit constructor (so we can
    // search for inbound calls), so we should ensure that trying to fetch
    // outbound calls returns empty (and doesn't fail).
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

void f() {
  final foo1 = Fo^o();
}
''');

    var otherCode = parseCode('''
class Foo {}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(calls, isEmpty);
  }

  Future<void> test_method() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  void fo^o() {
    final a = A();
    a.bar();
    final tearoff = a.bar;
    // non-calls
    var x = 1;
    var y = x;
    a.field;
  }
}
''');

    var otherCode = parseCode('''
/*[0*/class A {
  String field;
  /*[1*/void bar() {}/*1]*/
}/*0]*/
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('A {', otherCode, 'A'),
          codeRange: otherCode.ranges[0].sourceRange,
        ),
        _isResult(
          CallHierarchyKind.method,
          'bar',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('bar() {', otherCode, 'bar'),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [
            rangeAfterPrefix('a.', code, 'bar'),
            rangeAfterPrefix('tearoff = a.', code, 'bar'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_method_from_augmentation() async {
    var code = parseCode('''
part 'other.dart';

class Foo {}

void ba^r() {
  Foo().myMethod();
}
''');

    var otherCode = parseCode('''
part of 'test.dart';

augment class Foo {
  [!void myMethod() {
  }!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      contains(
        _isResult(
          CallHierarchyKind.method,
          'myMethod',
          otherFile,
          containerName: 'Foo',
          nameRange: rangeAtSearch('myMethod() {', otherCode, 'myMethod'),
          codeRange: otherCode.range.sourceRange,
        ),
      ),
    );
  }

  Future<void> test_mixin_method() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

mixin MyMixin {
  void f^() {
    final a = A();
    a.foo();
    A().foo();
    final tearoff = a.foo;
  }
}
''');

    var otherCode = parseCode('''
mixin OtherMixin {
  /*[0*/void foo() {}/*0]*/
}
/*[1*/class A with OtherMixin {}/*1]*/
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('A with', otherCode, 'A'),
          codeRange: otherCode.ranges[1].sourceRange,
        ),
        _isResult(
          CallHierarchyKind.method,
          'foo',
          otherFile,
          containerName: 'OtherMixin',
          nameRange: rangeAtSearch('foo() {', otherCode, 'foo'),
          codeRange: otherCode.ranges[0].sourceRange,
          ranges: [
            rangeAfterPrefix('a.', code, 'foo'),
            rangeAfterPrefix('A().', code, 'foo'),
            rangeAfterPrefix('tearoff = a.', code, 'foo'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_namedConstructor() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.B^ar() {
    final a = A.named();
    final constructorTearoff = A.named;
  }
}
''');

    var otherCode = parseCode('''
void f() {}
class A {
  [!A.named();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A.named',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('named', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [
            rangeAfterPrefix('a = A.', code, 'named'),
            rangeAfterPrefix('constructorTearoff = A.', code, 'named'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_namedConstructorInNullAwareElementInList() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.B^ar(bool b) {
    dynamic a1;
    dynamic a2;
    <Object>[
      ?a1 = b ? A.named() : null,
      ?a2 = b ? A.named : null,
    ];
  }
}
''');

    var otherCode = parseCode('''
void f() {}
class A {
  [!A.named();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A.named',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('named', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [
            rangeAfterPrefix('?a1 = b ? A.', code, 'named'),
            rangeAfterPrefix('?a2 = b ? A.', code, 'named'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_namedConstructorInNullAwareElementInMapKey() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.B^ar(bool b) {
    dynamic a1;
    dynamic a2;
    <Object, Symbol>{
      ?a1 = b ? A.named() : null: #foo,
      ?a2 = b ? A.named : null: #bar,
    };
  }
}
''');

    var otherCode = parseCode('''
void f() {}
class A {
  [!A.named();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A.named',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('named', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [
            rangeAfterPrefix('?a1 = b ? A.', code, 'named'),
            rangeAfterPrefix('?a2 = b ? A.', code, 'named'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_namedConstructorInNullAwareElementInMapValue() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.B^ar(bool b) {
    dynamic a1;
    dynamic a2;
    <Symbol, Object>{
      #foo: ?a1 = b ? A.named() : null,
      #bar: ?a2 = b ? A.named : null,
    };
  }
}
''');

    var otherCode = parseCode('''
void f() {}
class A {
  [!A.named();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A.named',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('named', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [
            rangeAfterPrefix('?a1 = b ? A.', code, 'named'),
            rangeAfterPrefix('?a2 = b ? A.', code, 'named'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_namedConstructorInNullAwareElementInSet() async {
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'other.dart';

class Foo {
  Foo.B^ar(bool b) {
    dynamic a1;
    dynamic a2;
    <Object>{
      ?a1 = b ? A.named() : null,
      ?a2 = b ? A.named : null,
    };
  }
}
''');

    var otherCode = parseCode('''
void f() {}
class A {
  [!A.named();!]
}
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A.named',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('named', otherCode),
          codeRange: otherCode.range.sourceRange,
          ranges: [
            rangeAfterPrefix('?a1 = b ? A.', code, 'named'),
            rangeAfterPrefix('?a2 = b ? A.', code, 'named'),
          ],
        ),
      ]),
    );
  }

  Future<void> test_prefixedTypes() async {
    // Prefixed type names that are not tear-offs should never be included.
    var code = parseCode('''
// ignore_for_file: unused_local_variable
import 'dart:io' as io;

void ^f(io.File f) {
  io.Directory? d;
}
''');

    var calls = await findOutgoingCalls(code);
    expect(calls, isEmpty);
  }

  Future<void> test_setter() async {
    var code = parseCode('''
import 'other.dart';

set fo^o(String value) {
  final a = A();
  a.b = '';
  A().b = '';
}
''');

    var otherCode = parseCode('''
/*[0*/class A {
  /*[1*/set b(String value) {}/*1]*/
}/*0]*/
''');

    newFile(otherFile, otherCode.code);
    var calls = await findOutgoingCalls(code);
    expect(
      calls,
      unorderedEquals([
        _isResult(
          CallHierarchyKind.constructor,
          'A',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('A {', otherCode, 'A'),
          codeRange: otherCode.ranges[0].sourceRange,
        ),
        _isResult(
          CallHierarchyKind.property,
          'set b',
          otherFile,
          containerName: 'A',
          nameRange: rangeAtSearch('b(String ', otherCode, 'b'),
          codeRange: otherCode.ranges[1].sourceRange,
          ranges: [
            rangeAfterPrefix('a.', code, 'b'),
            rangeAfterPrefix('A().', code, 'b'),
          ],
        ),
      ]),
    );
  }
}
