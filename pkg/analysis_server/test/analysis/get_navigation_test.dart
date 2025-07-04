// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/protocol/protocol.dart';
import 'package:analysis_server/protocol/protocol_generated.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'notification_navigation_test.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(GetNavigationTest);
  });
}

@reflectiveTest
class GetNavigationTest extends AbstractNavigationTest {
  static const String requestId = 'test-getNavigation';

  @override
  Future<void> setUp() async {
    super.setUp();
    await setRoots(included: [workspaceRootPath], excluded: []);
  }

  Future<void> test_beforeAnalysisComplete() async {
    addTestFile('''
void f() {
  var test = 0;
  print(test);
}
''');
    await _getNavigation(search: 'test);');
    assertHasRegion('test);');
    assertHasTarget('test = 0');
  }

  Future<void> test_comment_outsideReference() async {
    addTestFile('''
/// Returns a [String].
String f() {
}''');
    await waitForTasksFinished();
    await _getNavigation(search: 'Returns', length: 1);
    expect(regions, hasLength(0));
  }

  Future<void> test_comment_reference() async {
    addTestFile('''
/// Returns a [String].
String f() {
}''');
    await waitForTasksFinished();
    await _getNavigation(search: '[String', length: 1);
    expect(regions, hasLength(1));
    assertHasRegion('String]');
  }

  Future<void> test_comment_toolSeeCodeComment() async {
    var examplePath = 'examples/api/foo.dart';
    newFile('$testPackageLibPath/$examplePath', '');
    addTestFile('''
/// {@tool dartpad}
/// ** See code in $examplePath **
/// {@end-tool}
String f() {
}''');
    await waitForTasksFinished();
    await _getNavigation(search: examplePath, length: 1);
    expect(regions, hasLength(1));
    assertHasRegion(examplePath, length: examplePath.length);
  }

  Future<void> test_comment_toolSeeCodeComment_multiple() async {
    var examplePath = 'examples/api/foo.dart';
    var example2Path = 'examples/api/foo2.dart';
    newFile('$testPackageLibPath/$examplePath', '');
    newFile('$testPackageLibPath/$example2Path', '');
    addTestFile('''
/// {@tool dartpad}
/// ** See code in $examplePath **
/// {@end-tool}
///
/// {@tool dartpad}
/// ** See code in $example2Path **
/// {@end-tool}
String f() {
}''');
    await waitForTasksFinished();
    // Ensure we only get the expected region when there are multiple.
    await _getNavigation(search: example2Path, length: 1);
    expect(regions, hasLength(1));
    assertHasRegion(example2Path, length: example2Path.length);
  }

  Future<void> test_constructorInvocation() async {
    // Check that a constructor invocation navigates to the constructor and not
    // the class.
    // https://github.com/dart-lang/sdk/issues/46725
    addTestFile('''
class Foo {
  // ...
  // ...
  Foo() {}
  Foo.named() {}
  // ...
}

final a = Foo();
final b = new Foo.named(); // 0
''');
    await waitForTasksFinished();

    // Without `new` / unnamed
    await _getNavigation(search: 'Foo();');
    expect(regions, hasLength(1));
    expect(regions.first.targets, hasLength(1));
    var target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.CONSTRUCTOR);
    expect(target.offset, findOffset('Foo() {'));
    expect(target.length, 3);

    // With `new` / named
    await _getNavigation(search: 'named(); // 0');
    expect(regions, hasLength(1));
    expect(regions.first.targets, hasLength(1));
    target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.CONSTRUCTOR);
    expect(target.offset, findOffset('named() {'));
    expect(target.length, 5);
  }

  Future<void>
  test_constructorInvocation_insideNullAwareElement_inList() async {
    addTestFile('''
class Foo {
  Foo() {}
}

final foo = [?Foo()];
''');
    await waitForTasksFinished();

    await _getNavigation(search: 'Foo()];');
    expect(regions, hasLength(1));
    expect(regions.first.targets, hasLength(1));
    var target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.CONSTRUCTOR);
    expect(target.offset, findOffset('Foo() {'));
    expect(target.length, 3);
  }

  Future<void> test_constructorInvocation_insideNullAwareElement_inSet() async {
    addTestFile('''
class Foo {
  Foo() {}
}

final foo = {?Foo()};
''');
    await waitForTasksFinished();

    await _getNavigation(search: 'Foo()};');
    expect(regions, hasLength(1));
    expect(regions.first.targets, hasLength(1));
    var target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.CONSTRUCTOR);
    expect(target.offset, findOffset('Foo() {'));
    expect(target.length, 3);
  }

  Future<void> test_constructorInvocation_insideNullAwareKey_inMap() async {
    addTestFile('''
class Foo {
  Foo() {}
}

final foo = {?Foo(): "value"};
''');
    await waitForTasksFinished();

    await _getNavigation(search: 'Foo():');
    expect(regions, hasLength(1));
    expect(regions.first.targets, hasLength(1));
    var target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.CONSTRUCTOR);
    expect(target.offset, findOffset('Foo() {'));
    expect(target.length, 3);
  }

  Future<void> test_constructorInvocation_insideNullAwareValue_inMap() async {
    addTestFile('''
class Foo {
  Foo() {}
}

final foo = {"key": ?Foo()};
''');
    await waitForTasksFinished();

    await _getNavigation(search: 'Foo()};');
    expect(regions, hasLength(1));
    expect(regions.first.targets, hasLength(1));
    var target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.CONSTRUCTOR);
    expect(target.offset, findOffset('Foo() {'));
    expect(target.length, 3);
  }

  Future<void> test_documentation() async {
    addTestFile('''
/// [math]
import 'dart:math' as math;
''');
    await waitForTasksFinished();
    await _getNavigation(search: 'math]');
    expect(regions, hasLength(1));
    assertHasRegionString('math');
    expect(testTargets, hasLength(1));
    var target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.PREFIX);
    expect(target.offset, findOffset('math;'));
    expect(target.length, 4);
  }

  Future<void> test_documentation_library() async {
    addTestFile('''
/// [math]
library;

import 'dart:math' as math;
''');
    await waitForTasksFinished();
    await _getNavigation(search: 'math]');
    expect(regions, hasLength(1));
    assertHasRegionString('math');
    expect(testTargets, hasLength(1));
    var target = targets[regions.first.targets.first];
    expect(target.kind, ElementKind.PREFIX);
    expect(target.offset, findOffset('math;'));
    expect(target.length, 4);
  }

  Future<void> test_field_underscore() async {
    addTestFile('''
class C {
  int _ = 0;
}

f() {
  C()._;
}
''');
    await waitForTasksFinished();
    await _getNavigation(search: '_;');
    assertHasRegion('_;');
    assertHasTarget('_ = 0');
  }

  Future<void> test_fieldType() async {
    // This test mirrors test_navigation() from
    // integration_test/analysis/get_navigation_test.dart
    var text = r'''
class Foo {}

class Bar {
  Foo foo;
}
''';
    addTestFile(text);
    await _getNavigation(search: 'Foo foo');
    expect(targets, hasLength(1));
    var target = targets.first;
    expect(target.kind, ElementKind.CLASS);
    expect(target.offset, text.indexOf('Foo {'));
    expect(target.length, 3);
    expect(target.startLine, 1);
    expect(target.startColumn, 7);
  }

  Future<void> test_fileDoesNotExist() async {
    var file = convertPath('$testPackageLibPath/doesNotExist.dart');
    var request = _createGetNavigationRequest(file, 0, 100);
    var response = await serverChannel.simulateRequestFromClient(request);
    expect(response.error, isNull);
    var result = response.result!;
    expect(result['files'], isEmpty);
    expect(result['targets'], isEmpty);
    expect(result['regions'], isEmpty);
  }

  // TODO(scheglov): Rewrite these tests to work with any file.
  @FailingTest(reason: 'requires infrastructure rewriting')
  Future<void> test_fileOutsideOfRoot() async {
    var file = newFile('/outside.dart', '''
void f() {
  var test = 0;
  print(test);
}
''');
    await _getNavigation(file: file, search: 'test);');
    assertHasRegion('test);');
    assertHasTarget('test = 0');
  }

  Future<void> test_importDirective() async {
    addTestFile('''
import 'dart:math';

void f() {
}''');
    await waitForTasksFinished();
    await _getNavigation(offset: 0, length: 17);
    expect(regions, hasLength(1));
    assertHasRegionString("'dart:math'");
    expect(testTargets, hasLength(1));
    expect(testTargets[0].kind, ElementKind.LIBRARY);
  }

  Future<void> test_importUri() async {
    addTestFile('''
import 'dart:math';

void f() {
}''');
    await waitForTasksFinished();
    await _getNavigation(offset: 7, length: 11);
    expect(regions, hasLength(1));
    assertHasRegionString("'dart:math'");
    expect(testTargets, hasLength(1));
    expect(testTargets[0].kind, ElementKind.LIBRARY);
  }

  Future<void> test_importUri_configurations() async {
    var ioFile = newFile('$testPackageLibPath/io.dart', '');
    var htmlFile = newFile('$testPackageLibPath/html.dart', '');
    addTestFile('''
import 'foo.dart'
  if (dart.library.io) 'io.dart'
  if (dart.library.html) 'html.dart';

void f() {
}''');
    await waitForTasksFinished();

    // Request navigations for 'io.dart'
    await _getNavigation(offset: 41, length: 9);
    expect(regions, hasLength(1));
    assertHasRegionString("'io.dart'");
    expect(testTargets, hasLength(1));
    var target = testTargets.first;
    expect(target.kind, ElementKind.LIBRARY);
    expect(targetFiles[target.fileIndex], equals(ioFile.path));

    // Request navigations for 'html.dart'
    await _getNavigation(offset: 76, length: 11);
    expect(regions, hasLength(1));
    assertHasRegionString("'html.dart'");
    expect(testTargets, hasLength(1));
    target = testTargets.first;
    expect(target.kind, ElementKind.LIBRARY);
    expect(targetFiles[target.fileIndex], equals(htmlFile.path));
  }

  Future<void> test_invalidFilePathFormat_notAbsolute() async {
    var request = _createGetNavigationRequest('test.dart', 0, 0);
    var response = await handleRequest(request);
    assertResponseFailure(
      response,
      requestId: requestId,
      errorCode: RequestErrorCode.INVALID_FILE_PATH_FORMAT,
    );
  }

  Future<void> test_invalidFilePathFormat_notNormalized() async {
    var request = _createGetNavigationRequest(
      convertPath('/foo/../bar/test.dart'),
      0,
      0,
    );
    var response = await handleRequest(request);
    assertResponseFailure(
      response,
      requestId: requestId,
      errorCode: RequestErrorCode.INVALID_FILE_PATH_FORMAT,
    );
  }

  Future<void> test_multipleRegions() async {
    addTestFile('''
void f() {
  var aaa = 1;
  var bbb = 2;
  var ccc = 3;
  var ddd = 4;
  print(aaa + bbb + ccc + ddd);
}
''');
    await waitForTasksFinished();
    // request navigation
    var navCode = ' + bbb + ';
    await _getNavigation(search: navCode, length: navCode.length);
    // verify
    {
      assertHasRegion('aaa +');
      assertHasTarget('aaa = 1');
    }
    {
      assertHasRegion('bbb +');
      assertHasTarget('bbb = 2');
    }
    {
      assertHasRegion('ccc +');
      assertHasTarget('ccc = 3');
    }
    assertNoRegionAt('ddd)');
  }

  Future<void> test_operator_index() async {
    addTestFile('''
class A {
  operator [](index) => 0;
  operator []=(index, int value) {}
}

void f(A a) {
  a[0]; // []
  a[1] = 1; // []=
  a[2] += 2;
}
''');
    await waitForTasksFinished();
    {
      var search = '[0';
      await _getNavigation(search: search, length: 1);
      assertHasOperatorRegion(search, 1, '[](index)', 2);
    }
    {
      var search = ']; // []';
      await _getNavigation(search: search, length: 1);
      assertHasOperatorRegion(search, 1, '[](index)', 2);
    }
    {
      var search = '[1';
      await _getNavigation(search: search, length: 1);
      assertHasOperatorRegion(search, 1, '[]=(index', 3);
    }
    {
      var search = '] = 1';
      await _getNavigation(search: search, length: 1);
      assertHasOperatorRegion(search, 1, '[]=(index', 3);
    }
    {
      var search = '[2';
      await _getNavigation(search: search, length: 1);
      assertHasOperatorRegion(search, 1, '[]=(index', 3);
    }
    {
      var search = '] += 2';
      await _getNavigation(search: search, length: 1);
      assertHasOperatorRegion(search, 1, '[]=(index', 3);
    }
  }

  @FailingTest(issue: 'https://github.com/dart-lang/sdk/issues/60200')
  Future<void> test_parameter_generic() async {
    addTestFile('''
void f() {
  B().m(p: null);
}

class A<T> {
  void m({T? p}) {}
}

class B extends A<String> {}
''');
    await waitForTasksFinished();
    await _getNavigation(search: 'p: null');
    assertHasRegion('p: null');
    assertHasTarget('p}) {}');
  }

  Future<void> test_parameter_wildcard() async {
    addTestFile('''
var _ = 0;
f(int _) { }
''');
    await waitForTasksFinished();
    await _getNavigation(search: '_)');
    assertHasRegion('_)');
    assertHasTarget('_)');
  }

  Future<void> test_partDirective() async {
    var partFile = newFile('$testPackageLibPath/a.dart', '''
part of 'test.dart';
''');
    addTestFile('''
part 'a.dart';
''');
    await waitForTasksFinished();
    await _getNavigation(offset: 8);
    expect(regions, hasLength(1));
    assertHasRegionString("'a.dart'");
    expect(testTargets, hasLength(1));
    expect(testTargets[0].kind, ElementKind.COMPILATION_UNIT);
    assertHasFileTarget(partFile.path, 0, 0);
  }

  Future<void> test_partOfDirective_named() async {
    var partOfFile = newFile('$testPackageLibPath/a.dart', '''
library foo;
part 'test.dart';
''');
    addTestFile('''
part of foo;
''');
    await waitForTasksFinished();
    await _getNavigation(offset: 10);
    expect(regions, hasLength(1));
    assertHasRegionString('foo');
    expect(testTargets, hasLength(1));
    expect(testTargets[0].kind, ElementKind.LIBRARY);
    assertHasFileTarget(partOfFile.path, 0, 0);
  }

  Future<void> test_partOfDirective_uri() async {
    var partOfFile = newFile('$testPackageLibPath/a.dart', '''
part 'test.dart';
''');
    addTestFile('''
part of 'a.dart';
''');
    await waitForTasksFinished();
    await _getNavigation(offset: 11);
    expect(regions, hasLength(1));
    assertHasRegionString("'a.dart'");
    expect(testTargets, hasLength(1));
    expect(testTargets[0].kind, ElementKind.LIBRARY);
    assertHasFileTarget(partOfFile.path, 0, 0);
  }

  Future<void> test_prefix_wildcard() async {
    addTestFile('''
import 'dart:io' as _;
''');
    await waitForTasksFinished();
    await _getNavigation(search: '_');
    assertHasRegion('_');
    assertHasTarget('_');
  }

  Future<void> test_topLevelVariable_underscore() async {
    addTestFile('''
var _ = 0;

f(int _) {
  _;
}
''');
    await waitForTasksFinished();
    await _getNavigation(search: '_;');
    assertHasRegion('_;');
    assertHasTarget('_ = 0');
  }

  Future<void> test_typeParameter_wildcard() async {
    addTestFile('''
class C<_> {}
''');
    await waitForTasksFinished();
    await _getNavigation(search: '_');
    assertHasRegion('_');
    assertHasTarget('_');
  }

  Future<void> test_zeroLength_end() async {
    addTestFile('''
void f() {
  var test = 0;
  print(test);
}
''');
    await waitForTasksFinished();
    await _getNavigation(search: ');');
    assertHasRegion('test);');
    assertHasTarget('test = 0');
  }

  Future<void> test_zeroLength_start() async {
    addTestFile('''
void f() {
  var test = 0;
  print(test);
}
''');
    await waitForTasksFinished();
    await _getNavigation(search: 'test);');
    assertHasRegion('test);');
    assertHasTarget('test = 0');
  }

  Request _createGetNavigationRequest(String file, int offset, int length) {
    return AnalysisGetNavigationParams(
      file,
      offset,
      length,
    ).toRequest(requestId, clientUriConverter: server.uriConverter);
  }

  Future<void> _getNavigation({
    File? file,
    int? offset,
    String? search,
    int length = 0,
  }) async {
    file ??= testFile;

    if (offset == null) {
      if (search != null) {
        offset = offsetInFile(file, search);
      } else {
        throw ArgumentError("Either 'offset' or 'search' must be provided");
      }
    }

    var request = _createGetNavigationRequest(file.path, offset, length);
    var response = await serverChannel.simulateRequestFromClient(request);
    var result = AnalysisGetNavigationResult.fromResponse(
      response,
      clientUriConverter: server.uriConverter,
    );
    targetFiles = result.files;
    targets = result.targets;
    regions = result.regions;
  }
}
