// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/driver_event.dart' as driver_events;
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/analysis/status.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/fine/requirements.dart';
import 'package:analyzer/src/lint/linter.dart';
import 'package:analyzer/src/test_utilities/lint_registration_mixin.dart';
import 'package:analyzer/src/utilities/extensions/async.dart';
import 'package:analyzer/utilities/package_config_file_builder.dart';
import 'package:analyzer_testing/utilities/utilities.dart';
import 'package:analyzer_utilities/testing/tree_string_sink.dart';
import 'package:linter/src/rules.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../../util/element_printer.dart';
import '../resolution/context_collection_resolution.dart';
import '../resolution/node_text_expectations.dart';
import '../resolution/resolution.dart';
import 'result_printer.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(AnalysisDriver_PubPackageTest);
    defineReflectiveTests(AnalysisDriver_BlazeWorkspaceTest);
    defineReflectiveTests(AnalysisDriver_LintTest);
    defineReflectiveTests(FineAnalysisDriverTest);
    defineReflectiveTests(UpdateNodeTextExpectations);
  });
}

@reflectiveTest
class AnalysisDriver_BlazeWorkspaceTest extends BlazeWorkspaceResolutionTest {
  void test_nestedLib_notCanonicalUri() async {
    var outerLibPath = '$workspaceRootPath/my/outer/lib';

    var innerFile = newFile('$outerLibPath/inner/lib/b.dart', 'class B {}');
    var innerUri = Uri.parse('package:my.outer.lib.inner/b.dart');

    var analysisSession = contextFor(innerFile).currentSession;

    void assertInnerUri(ResolvedUnitResult result) {
      var innerSource =
          result.libraryFragment.libraryImports
              .map((import) => import.importedLibrary?.firstFragment.source)
              .nonNulls
              .where(
                (importedSource) => importedSource.fullName == innerFile.path,
              )
              .single;
      expect(innerSource.uri, innerUri);
    }

    // Reference "inner" using a non-canonical URI.
    {
      var a = newFile(convertPath('$outerLibPath/a.dart'), r'''
import 'inner/lib/b.dart';
''');
      var result = await analysisSession.getResolvedUnit(a.path);
      result as ResolvedUnitResult;
      assertInnerUri(result);
    }

    // Reference "inner" using the canonical URI, via relative.
    {
      var c = newFile('$outerLibPath/inner/lib/c.dart', r'''
import 'b.dart';
''');
      var result = await analysisSession.getResolvedUnit(c.path);
      result as ResolvedUnitResult;
      assertInnerUri(result);
    }

    // Reference "inner" using the canonical URI, via absolute.
    {
      var d = newFile('$outerLibPath/inner/lib/d.dart', '''
import '$innerUri';
''');
      var result = await analysisSession.getResolvedUnit(d.path);
      result as ResolvedUnitResult;
      assertInnerUri(result);
    }
  }
}

@reflectiveTest
class AnalysisDriver_LintTest extends PubPackageResolutionTest
    with LintRegistrationMixin {
  @override
  void setUp() {
    super.setUp();

    useEmptyByteStore();
    registerLintRule(_AlwaysReportedLint.instance);
    writeTestPackageAnalysisOptionsFile(
      analysisOptionsContent(rules: [_AlwaysReportedLint.code.name]),
    );
  }

  @override
  Future<void> tearDown() {
    unregisterLintRules();
    return super.tearDown();
  }

  test_getResolvedUnit_lint_existingFile() async {
    addTestFile('');
    await resolveTestFile();

    // Existing/empty file triggers the lint.
    _assertHasLintReported(result.diagnostics, _AlwaysReportedLint.code.name);
  }

  test_getResolvedUnit_lint_notExistingFile() async {
    await resolveTestFile();

    // No errors for a file that doesn't exist.
    assertErrorsInResult([]);
  }

  void _assertHasLintReported(List<Diagnostic> diagnostics, String name) {
    var matching =
        diagnostics.where((element) {
          var diagnosticCode = element.diagnosticCode;
          return diagnosticCode is LintCode && diagnosticCode.name == name;
        }).toList();
    expect(matching, hasLength(1));
  }
}

@reflectiveTest
class AnalysisDriver_PubPackageTest extends PubPackageResolutionTest
    with _EventsMixin {
  @override
  bool get retainDataForTesting => true;

  @override
  void setUp() {
    super.setUp();
    registerLintRules();
    useEmptyByteStore();
  }

  @override
  Future<void> tearDown() async {
    withFineDependencies = false;
    return super.tearDown();
  }

  test_addedFiles() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', '');

    var driver = driverFor(testFile);

    driver.addFile2(a);
    driver.addFile2(b);
    await driver.applyPendingFileChanges();
    expect(driver.addedFiles2, unorderedEquals([a, b]));

    driver.removeFile2(a);
    await driver.applyPendingFileChanges();
    expect(driver.addedFiles2, unorderedEquals([b]));
  }

  test_addFile() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(b);
    driver.addFile2(a);

    // The files are analyzed in the order of adding.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_addFile_afterRemove() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
import 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);
    driver.addFile2(a);
    driver.addFile2(b);

    // Initial analysis, `b` does not use `a`, so there is a hint.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[status] idle
''');

    // Update `b` to use `a`, no more hints.
    modifyFile2(b, r'''
import 'a.dart';
void f() {
  A;
}
''');

    // Remove and add `b`.
    driver.removeFile2(b);
    driver.addFile2(b);

    // `b` was analyzed, no more hints.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_addFile_notAbsolutePath() async {
    var driver = driverFor(testFile);
    expect(() {
      driver.addFile('not_absolute.dart');
    }, throwsArgumentError);
  }

  test_addFile_priorityFiles() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', '');
    var c = newFile('$testPackageLibPath/c.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);
    driver.priorityFiles2 = [b];

    // 1. The priority file is produced first.
    // 2. Each analyzed file produces `ResolvedUnitResult`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/c.dart
  library: /home/test/lib/c.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/c.dart
    uri: package:test/c.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_addFile_removeFile() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Add, and immediately remove.
    driver.addFile2(a);
    driver.removeFile2(a);

    // No files to analyze.
    await assertEventsText(collector, r'''
[status] working
[status] idle
''');
  }

  test_addFile_thenRemove() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);

    // Now remove `a`.
    driver.removeFile2(a);

    // We remove `a` before analysis started.
    // So, only `b` was analyzed.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_cachedPriorityResults() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a];

    // Get the result, not cached.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Get the (cached) result, not reported to the stream.
    collector.getResolvedUnit('A2', a);
    await assertEventsText(collector, r'''
[future] getResolvedUnit A2
  ResolvedUnitResult #0
''');

    // Get the (cached) result, reported to the stream.
    collector.getResolvedUnit('A3', a, sendCachedToStream: true);
    await assertEventsText(collector, r'''
[stream]
  ResolvedUnitResult #0
[future] getResolvedUnit A3
  ResolvedUnitResult #0
''');
  }

  test_cachedPriorityResults_flush_onAnyFileChange() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a];

    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Change a file.
    // The cache is flushed, so we get a new result.
    driver.changeFile2(a);
    collector.getResolvedUnit('A2', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A2
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');

    // Add `b`.
    // The cache is flushed, so we get a new result.
    driver.addFile2(b);
    collector.getResolvedUnit('A3', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A3
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[status] idle
''');

    // Remove `b`.
    // The cache is flushed, so we get a new result.
    driver.removeFile2(b);
    collector.getResolvedUnit('A4', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A4
  ResolvedUnitResult #4
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #4
[status] idle
''');
  }

  test_cachedPriorityResults_flush_onPrioritySetChange() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a];

    // Get the result for `a`, new.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Make `a` and `b` priority.
    // We still have the result for `a` cached.
    driver.priorityFiles2 = [a, b];
    collector.getResolvedUnit('A2', a);
    await assertEventsText(collector, r'''
[status] working
[future] getResolvedUnit A2
  ResolvedUnitResult #0
[status] idle
''');

    // Get the result for `b`, new.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');

    // Get the result for `b`, cached.
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[future] getResolvedUnit B2
  ResolvedUnitResult #1
''');

    // Only `b` is priority.
    // The result for `a` is flushed, so analyzed when asked.
    driver.priorityFiles2 = [b];
    collector.getResolvedUnit('A3', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A3
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
[status] idle
''');
  }

  test_cachedPriorityResults_notPriority() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Always analyzed the first time.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Analyzed again, because `a` is not priority.
    collector.getResolvedUnit('A2', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A2
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_cachedPriorityResults_wholeLibrary_priorityLibrary_askLibrary() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a];

    // Ask the result for `a`, should cache for both `a` and `b`.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');

    // Verify that the results for `a` and `b` are cached.
    // Note, no analysis.
    collector.getResolvedUnit('A2', a);
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[future] getResolvedUnit A2
  ResolvedUnitResult #0
[future] getResolvedUnit B1
  ResolvedUnitResult #1
''');

    // Ask for resolved library.
    // Note, no analysis.
    // Note, the units are cached.
    collector.getResolvedLibrary('L1', a);
    await assertEventsText(collector, r'''
[future] getResolvedLibrary L1
  ResolvedLibraryResult #2
    element: package:test/a.dart
    units
      ResolvedUnitResult #0
      ResolvedUnitResult #1
''');
  }

  test_cachedPriorityResults_wholeLibrary_priorityLibrary_askPart() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a];

    // Ask the result for `b`, should cache for both `a` and `b`.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Verify that the results for `a` and `b` are cached.
    // Note, no analysis.
    collector.getResolvedUnit('A1', a);
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[future] getResolvedUnit A1
  ResolvedUnitResult #1
[future] getResolvedUnit B2
  ResolvedUnitResult #0
''');

    // Ask for resolved library.
    // Note, no analysis.
    // Note, the units are cached.
    collector.getResolvedLibrary('L1', a);
    await assertEventsText(collector, r'''
[future] getResolvedLibrary L1
  ResolvedLibraryResult #2
    element: package:test/a.dart
    units
      ResolvedUnitResult #1
      ResolvedUnitResult #0
''');
  }

  test_cachedPriorityResults_wholeLibrary_priorityPart_askPart() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [b];

    // Ask the result for `b`, should cache for both `a` and `b`.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Verify that the results for `a` and `b` are cached.
    // Note, no analysis.
    collector.getResolvedUnit('A1', a);
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[future] getResolvedUnit A1
  ResolvedUnitResult #1
[future] getResolvedUnit B2
  ResolvedUnitResult #0
''');

    // Ask for resolved library.
    // Note, no analysis.
    // Note, the units are cached.
    collector.getResolvedLibrary('L1', a);
    await assertEventsText(collector, r'''
[future] getResolvedLibrary L1
  ResolvedLibraryResult #2
    element: package:test/a.dart
    units
      ResolvedUnitResult #1
      ResolvedUnitResult #0
''');
  }

  test_changeFile_implicitlyAnalyzed() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
import 'b.dart';
var A = B;
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
var B = 0;
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a];
    driver.addFile2(a);

    configuration.libraryConfiguration.unitConfiguration.nodeSelector = (
      result,
    ) {
      return result.findNode.simple('B;');
    };

    // We have a result only for "a".
    // The type of `B` is `int`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedNode: SimpleIdentifier
      token: B
      element: package:test/b.dart::@getter::B
      staticType: int
[status] idle
''');

    // Change "b" and notify.
    modifyFile2(b, r'''
var B = 1.2;
''');
    driver.changeFile2(b);

    // While "b" is not analyzed explicitly, it is analyzed implicitly.
    // The change causes "a" to be reanalyzed.
    // The type of `B` is now `double`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedNode: SimpleIdentifier
      token: B
      element: package:test/b.dart::@getter::B
      staticType: double
[status] idle
''');
  }

  test_changeFile_notAbsolutePath() async {
    var driver = driverFor(testFile);
    expect(() {
      driver.changeFile('not_absolute.dart');
    }, throwsArgumentError);
  }

  test_changeFile_notExisting_toEmpty() async {
    var b = newFile('$testPackageLibPath/b.dart', '''
// ignore:unused_import
import 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(b);

    // `b` is analyzed, has an error.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    errors
      31 +8 URI_DOES_NOT_EXIST
[status] idle
''');

    // Create `a`, empty.
    var a = newFile('$testPackageLibPath/a.dart', '');
    driver.addFile2(a);

    // Both `a` and `b` are analyzed.
    // No errors anymore.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_changeFile_notPriority_errorsFromBytes() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);

    // Initial analysis, no errors.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');

    // Update the file, has an error.
    // Note, we analyze the file.
    modifyFile2(a, ';');
    driver.changeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    errors
      0 +1 UNEXPECTED_TOKEN
[status] idle
''');

    // Update the file, no errors.
    // Note, we return errors from bytes.
    // We must update latest signatures, not reflected in the text.
    // If we don't, the next assert will fail.
    modifyFile2(a, '');
    driver.changeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[operation] getErrorsFromBytes
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ErrorsResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
[status] idle
''');

    // Update the file, has an error.
    // Note, we return errors from bytes.
    modifyFile2(a, ';');
    driver.changeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[operation] getErrorsFromBytes
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ErrorsResult #3
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
    errors
      0 +1 UNEXPECTED_TOKEN
[status] idle
''');
  }

  test_changeFile_notUsed() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', 'class B1 {}');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);

    // Nothing interesting, "a" is analyzed.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');

    // Change "b" and notify.
    modifyFile2(b, 'class B2 {}');
    driver.changeFile2(b);

    // Nothing depends on "b", so nothing is analyzed.
    await assertEventsText(collector, r'''
[status] working
[status] idle
''');
  }

  test_changeFile_potentiallyAffected_imported() async {
    newFile('$testPackageLibPath/a.dart', '');

    var b = newFile('$testPackageLibPath/b.dart', '''
import 'a.dart';
''');

    var c = newFile('$testPackageLibPath/c.dart', '''
import 'b.dart';
''');

    var d = newFile('$testPackageLibPath/d.dart', '''
import 'c.dart';
''');

    newFile('$testPackageLibPath/e.dart', '');

    var driver = driverFor(testFile);

    Future<LibraryElement> getLibrary(String shortName) async {
      var uriStr = 'package:test/$shortName';
      var result = await driver.getLibraryByUriValid(uriStr);
      return result.element;
    }

    var a_element = await getLibrary('a.dart');
    var b_element = await getLibrary('b.dart');
    var c_element = await getLibrary('c.dart');
    var d_element = await getLibrary('d.dart');
    var e_element = await getLibrary('e.dart');

    // We have all libraries loaded after analysis.
    driver.assertLoadedLibraryUriSet(
      included: [
        'package:test/a.dart',
        'package:test/b.dart',
        'package:test/c.dart',
        'package:test/d.dart',
        'package:test/e.dart',
      ],
    );

    // All libraries have the current session.
    var session1 = driver.currentSession;
    expect(a_element.session, session1);
    expect(b_element.session, session1);
    expect(c_element.session, session1);
    expect(d_element.session, session1);
    expect(e_element.session, session1);

    // Change `b.dart`, also removes `c.dart` and `d.dart` that import it.
    // But `a.dart` and `d.dart` is not affected.
    driver.changeFile2(b);
    var affectedPathList = await driver.applyPendingFileChanges();
    expect(affectedPathList, unorderedEquals([b.path, c.path, d.path]));

    // We have a new session.
    var session2 = driver.currentSession;
    expect(session2, isNot(session1));

    driver.assertLoadedLibraryUriSet(
      excluded: [
        'package:test/b.dart',
        'package:test/c.dart',
        'package:test/d.dart',
      ],
      included: ['package:test/a.dart', 'package:test/e.dart'],
    );

    // `a.dart` and `e.dart` moved to the new session.
    // Invalidated libraries stuck with the old session.
    expect(a_element.session, session2);
    expect(b_element.session, session1);
    expect(c_element.session, session1);
    expect(d_element.session, session1);
    expect(e_element.session, session2);
  }

  test_changeFile_potentiallyAffected_part() async {
    var a = newFile('$testPackageLibPath/a.dart', '''
part of 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', '''
part 'a.dart';
''');

    var c = newFile('$testPackageLibPath/c.dart', '''
import 'b.dart';
''');

    newFile('$testPackageLibPath/d.dart', '');

    var driver = driverFor(testFile);

    Future<LibraryElement> getLibrary(String shortName) async {
      var uriStr = 'package:test/$shortName';
      var result = await driver.getLibraryByUriValid(uriStr);
      return result.element;
    }

    var b_element = await getLibrary('b.dart');
    var c_element = await getLibrary('c.dart');
    var d_element = await getLibrary('d.dart');

    // We have all libraries loaded after analysis.
    driver.assertLoadedLibraryUriSet(
      included: [
        'package:test/b.dart',
        'package:test/c.dart',
        'package:test/d.dart',
      ],
    );

    // All libraries have the current session.
    var session1 = driver.currentSession;
    expect(b_element.session, session1);
    expect(c_element.session, session1);
    expect(d_element.session, session1);

    // Change `a.dart`, remove `b.dart` that part it.
    // Removes `c.dart` that imports `b.dart`.
    // But `d.dart` is not affected.
    driver.changeFile2(a);
    var affectedPathList = await driver.applyPendingFileChanges();
    expect(affectedPathList, unorderedEquals([a.path, b.path, c.path]));

    // We have a new session.
    var session2 = driver.currentSession;
    expect(session2, isNot(session1));

    driver.assertLoadedLibraryUriSet(
      excluded: ['package:test/b.dart', 'package:test/c.dart'],
      included: ['package:test/d.dart'],
    );

    // `d.dart` moved to the new session.
    // Invalidated libraries stuck with the old session.
    expect(b_element.session, session1);
    expect(c_element.session, session1);
    expect(d_element.session, session2);
  }

  test_changeFile_selfConsistent() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
import 'b.dart';
final A1 = 1;
final A2 = B1;
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
import 'a.dart';
final B1 = A1;
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a, b];
    driver.addFile2(a);
    driver.addFile2(b);

    configuration
        .libraryConfiguration
        .unitConfiguration
        .variableTypesSelector = (result) {
      return switch (result.uriStr) {
        'package:test/a.dart' => [
          result.findElement2.topVar('A1'),
          result.findElement2.topVar('A2'),
        ],
        'package:test/b.dart' => [result.findElement2.topVar('B1')],
        _ => [],
      };
    };

    // We have results for both "a" and "b".
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      A1: int
      A2: int
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    selectedVariableTypes
      B1: int
[status] idle
''');

    // Update "a".
    modifyFile2(a, r'''
import 'b.dart';
final A1 = 1.2;
final A2 = B1;
''');
    driver.changeFile2(a);

    // We again get results for both "a" and "b".
    // The results are consistent.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      A1: double
      A2: double
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    selectedVariableTypes
      B1: double
[status] idle
''');
  }

  test_changeFile_single() async {
    var a = newFile('$testPackageLibPath/a.dart', 'var V = 1;');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.priorityFiles2 = [a];

    configuration
        .libraryConfiguration
        .unitConfiguration
        .variableTypesSelector = (result) {
      switch (result.uriStr) {
        case 'package:test/a.dart':
          return [result.findElement2.topVar('V')];
        default:
          return [];
      }
    };

    // Initial analysis.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      V: int
[status] idle
''');

    // Update the file, but don't notify the driver.
    // No new results.
    modifyFile2(a, 'var V = 1.2;');
    await assertEventsText(collector, r'''
''');

    // Notify the driver about the change.
    // We get a new result.
    driver.changeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      V: double
[status] idle
''');
  }

  test_currentSession() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final v = 0;
''');

    var driver = driverFor(testFile);

    await driver.getResolvedUnit2(a);

    var session1 = driver.currentSession;
    expect(session1, isNotNull);

    modifyFile2(a, r'''
final v = 2;
''');
    driver.changeFile2(a);
    await driver.getResolvedUnit2(a);

    var session2 = driver.currentSession;
    expect(session2, isNotNull);

    // We get a new session.
    expect(session2, isNot(session1));
  }

  test_discoverAvailableFiles_packages() async {
    writeTestPackageConfig(
      PackageConfigFileBuilder()
        ..add(name: 'aaa', rootPath: '$packagesRootPath/aaa')
        ..add(name: 'bbb', rootPath: '$packagesRootPath/bbb'),
    );

    var t1 = newFile('$testPackageLibPath/t1.dart', '');
    var a1 = newFile('$packagesRootPath/aaa/lib/a1.dart', '');
    var a2 = newFile('$packagesRootPath/aaa/lib/src/a2.dart', '');
    var a3 = newFile('$packagesRootPath/aaa/lib/a3.txt', '');
    var b1 = newFile('$packagesRootPath/bbb/lib/b1.dart', '');
    var c1 = newFile('$packagesRootPath/ccc/lib/c1.dart', '');

    var driver = driverFor(testFile);
    driver.addFile2(t1);

    // Don't add `a1`, `a2`, or `b1` - they should be discovered.
    // And `c` is not in the package config, so should not be discovered.
    await driver.discoverAvailableFiles();

    var knownFiles = driver.knownFiles.resources;
    expect(knownFiles, contains(t1));
    expect(knownFiles, contains(a1));
    expect(knownFiles, contains(a2));
    expect(knownFiles, isNot(contains(a3)));
    expect(knownFiles, contains(b1));
    expect(knownFiles, isNot(contains(c1)));

    // We can wait for discovery more than once.
    await driver.discoverAvailableFiles();
  }

  test_discoverAvailableFiles_sdk() async {
    var driver = driverFor(testFile);
    await driver.discoverAvailableFiles();
    expect(
      driver.knownFiles.resources,
      containsAll([
        sdkRoot.getChildAssumingFile('lib/async/async.dart'),
        sdkRoot.getChildAssumingFile('lib/collection/collection.dart'),
        sdkRoot.getChildAssumingFile('lib/core/core.dart'),
        sdkRoot.getChildAssumingFile('lib/math/math.dart'),
      ]),
    );
  }

  test_getCachedResolvedUnit() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    // Not cached.
    // Note, no analysis.
    collector.getCachedResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[future] getCachedResolvedUnit A1
  null
''');

    driver.priorityFiles2 = [a];
    collector.getResolvedUnit('A2', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A2
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Has cached.
    // Note, no analysis.
    collector.getCachedResolvedUnit('A3', a);
    await assertEventsText(collector, r'''
[future] getCachedResolvedUnit A3
  ResolvedUnitResult #0
''');
  }

  test_getErrors() async {
    var a = newFile('$testPackageLibPath/a.dart', '''
var v = 0
''');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    collector.getErrors('A1', a);
    await assertEventsText(collector, r'''
[status] working
[future] getErrors A1
  ErrorsResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
    errors
      8 +1 EXPECTED_TOKEN
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    errors
      8 +1 EXPECTED_TOKEN
[status] idle
''');

    // The result is produced from bytes.
    collector.getErrors('A2', a);
    await assertEventsText(collector, r'''
[status] working
[operation] getErrorsFromBytes
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getErrors A2
  ErrorsResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
    errors
      8 +1 EXPECTED_TOKEN
[status] idle
''');
  }

  test_getErrors_library_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getErrors('A1', a);
    collector.getErrors('B1', b);

    // Note, both `getErrors()` returned during the library analysis.
    await assertEventsText(collector, r'''
[status] working
[future] getErrors A1
  ErrorsResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
[future] getErrors B1
  ErrorsResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: isPart
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_getErrors_notAbsolutePath() async {
    var driver = driverFor(testFile);
    var result = await driver.getErrors('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  test_getFilesDefiningClassMemberName_class() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {
  void m1() {}
}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
class B {
  void m2() {}
}
''');

    var c = newFile('$testPackageLibPath/c.dart', r'''
class C {
  void m2() {}
}
''');

    var d = newFile('$testPackageLibPath/d.dart', r'''
class D {
  void m3() {}
}
''');

    var driver = driverFor(testFile);
    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);
    driver.addFile2(d);

    await driver.assertFilesDefiningClassMemberName('m1', [a]);
    await driver.assertFilesDefiningClassMemberName('m2', [b, c]);
    await driver.assertFilesDefiningClassMemberName('m3', [d]);
  }

  test_getFilesDefiningClassMemberName_mixin() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
mixin A {
  void m1() {}
}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
mixin B {
  void m2() {}
}
''');

    var c = newFile('$testPackageLibPath/c.dart', r'''
mixin C {
  void m2() {}
}
''');

    var d = newFile('$testPackageLibPath/d.dart', r'''
mixin D {
  void m3() {}
}
''');

    var driver = driverFor(testFile);
    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);
    driver.addFile2(d);

    await driver.assertFilesDefiningClassMemberName('m1', [a]);
    await driver.assertFilesDefiningClassMemberName('m2', [b, c]);
    await driver.assertFilesDefiningClassMemberName('m3', [d]);
  }

  test_getFilesReferencingName() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
import 'a.dart';
void f(A a) {}
''');

    var c = newFile('$testPackageLibPath/c.dart', r'''
import 'a.dart';
void f(A a) {}
''');

    var d = newFile('$testPackageLibPath/d.dart', r'''
class A {}
void f(A a) {}
''');

    var e = newFile('$testPackageLibPath/e.dart', r'''
import 'a.dart';
void main() {}
''');

    var driver = driverFor(testFile);
    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);
    driver.addFile2(d);
    driver.addFile2(e);

    // `b` references an external `A`.
    // `c` references an external `A`.
    // `d` references the local `A`.
    // `e` does not reference `A` at all.
    await driver.assertFilesReferencingName(
      'A',
      includesAll: [b, c],
      excludesAll: [d, e],
    );

    // We get the same results second time.
    await driver.assertFilesReferencingName(
      'A',
      includesAll: [b, c],
      excludesAll: [d, e],
    );
  }

  test_getFilesReferencingName_discover() async {
    writeTestPackageConfig(
      PackageConfigFileBuilder()
        ..add(name: 'aaa', rootPath: '$packagesRootPath/aaa')
        ..add(name: 'bbb', rootPath: '$packagesRootPath/bbb'),
    );

    var t = newFile('$testPackageLibPath/t.dart', '''
int t = 0;
''');

    var a = newFile('$packagesRootPath/aaa/lib/a.dart', '''
int a = 0;
''');

    var b = newFile('$packagesRootPath/bbb/lib/b.dart', '''
int b = 0;
''');

    var c = newFile('$packagesRootPath/ccc/lib/c.dart', '''
int c = 0;
''');

    var driver = driverFor(testFile);
    driver.addFile2(t);

    await driver.assertFilesReferencingName(
      'int',
      includesAll: [t, a, b],
      excludesAll: [c],
    );
  }

  test_getFileSync_changedFile() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var b = newFile('$testPackageLibPath/b.dart', r'''
import 'a.dart';

void f(A a) {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Ensure that `a` library cycle is loaded.
    // So, `a` is in the library context.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Update the file, changing its API signature.
    // Note that we don't call `changeFile`.
    modifyFile2(a, 'class A {}\n');

    // Get the file.
    // We have not called `changeFile(a)`, so we should not read the file.
    // Moreover, doing this will create a new library cycle [a.dart].
    // Library cycles are compared by their identity, so we would try to
    // reload linked summary for [a.dart], and crash.
    expect(driver.getFileSyncValid(a).lineInfo.lineCount, 1);

    // We have not read `a.dart`, so `A` is still not declared.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    errors
      25 +1 UNDEFINED_CLASS
[stream]
  ResolvedUnitResult #1
[status] idle
''');

    // Notify the driver that the file was changed.
    driver.changeFile2(a);

    // ...and apply this change.
    await driver.applyPendingFileChanges();
    await assertEventsText(collector, r'''
[status] working
[status] idle
''');

    // So, `class A {}` is declared now.
    expect(driver.getFileSyncValid(a).lineInfo.lineCount, 2);

    // ...and `b` has no errors.
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B2
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
[status] idle
''');
  }

  test_getFileSync_library() async {
    var content = 'class A {}';
    var a = newFile('$testPackageLibPath/a.dart', content);
    var driver = driverFor(testFile);
    var result = driver.getFileSyncValid(a);
    expect(result.path, a.path);
    expect(result.uri.toString(), 'package:test/a.dart');
    expect(result.content, content);
    expect(result.isLibrary, isTrue);
    expect(result.isPart, isFalse);
  }

  test_getFileSync_notAbsolutePath() async {
    var driver = driverFor(testFile);
    var result = driver.getFileSync('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  test_getFileSync_part() async {
    var content = 'part of lib;';
    var a = newFile('$testPackageLibPath/a.dart', content);
    var driver = driverFor(testFile);
    var result = driver.getFileSyncValid(a);
    expect(result.path, a.path);
    expect(result.uri.toString(), 'package:test/a.dart');
    expect(result.content, content);
    expect(result.isLibrary, isFalse);
    expect(result.isPart, isTrue);
  }

  test_getIndex() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
void foo() {}

void f() {
  foo();
}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getIndex('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getIndex A1
  strings
    --nullString--
    foo
    package:test/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_getIndex_notAbsolutePath() async {
    var driver = driverFor(testFile);
    expect(() async {
      await driver.getIndex('not_absolute.dart');
    }, throwsArgumentError);
  }

  test_getLibraryByUri() async {
    var aUriStr = 'package:test/a.dart';
    var bUriStr = 'package:test/b.dart';

    newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';

class A {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';

class B {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    var result = await driver.getLibraryByUri(aUriStr);
    result as LibraryElementResult;
    expect(result.element.getClass('A'), isNotNull);
    expect(result.element.getClass('B'), isNotNull);

    // It is an error to ask for a library when we know that it is a part.
    expect(
      await driver.getLibraryByUri(bUriStr),
      isA<NotLibraryButPartResult>(),
    );

    // No analysis.
    await assertEventsText(collector, r'''
[status] working
[status] idle
''');
  }

  test_getLibraryByUri_cannotResolveUri() async {
    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getLibraryByUri('X', 'foo:bar');

    await assertEventsText(collector, r'''
[future] getLibraryByUri X
  CannotResolveUriResult
''');
  }

  test_getLibraryByUri_notLibrary_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part of 'b.dart';
''');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    var uriStr = 'package:test/a.dart';
    collector.getLibraryByUri('X', uriStr);

    await assertEventsText(collector, r'''
[future] getLibraryByUri X
  NotLibraryButPartResult
''');
  }

  test_getLibraryByUri_subsequentCallsDoesNoWork() async {
    var aUriStr = 'package:test/a.dart';
    var bUriStr = 'package:test/b.dart';

    newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';

class A {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';

class B {}
''');

    for (var run = 0; run < 5; run++) {
      var driver = driverFor(testFile);
      var collector = DriverEventCollector(driver);

      var result = await driver.getLibraryByUri(aUriStr);
      result as LibraryElementResult;
      expect(result.element.getClass('A'), isNotNull);
      expect(result.element.getClass('B'), isNotNull);

      // It is an error to ask for a library when we know that it is a part.
      expect(
        await driver.getLibraryByUri(bUriStr),
        isA<NotLibraryButPartResult>(),
      );

      if (run == 0) {
        // First `getLibraryByUri` call does actual work.
        await assertEventsText(collector, r'''
[status] working
[status] idle
''');
      } else {
        // Subsequent `getLibraryByUri` just grabs the result via rootReference
        // and thus does no actual work.
        await assertEventsText(collector, '');
      }
    }
  }

  test_getLibraryByUri_unresolvedUri() async {
    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    var result = await driver.getLibraryByUri('package:foo/foo.dart');
    expect(result, isA<CannotResolveUriResult>());

    // No analysis.
    await assertEventsText(collector, '');
  }

  test_getParsedLibrary() async {
    var content = 'class A {}';
    var a = newFile('$testPackageLibPath/a.dart', content);

    var driver = driverFor(testFile);
    var result = driver.getParsedLibrary2(a);
    result as ParsedLibraryResult;
    expect(result.units, hasLength(1));
    expect(result.units[0].path, a.path);
    expect(result.units[0].content, content);
    expect(result.units[0].unit, isNotNull);
    expect(result.units[0].diagnostics, isEmpty);
  }

  test_getParsedLibrary_invalidPath_notAbsolute() async {
    var driver = driverFor(testFile);
    var result = driver.getParsedLibrary('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  test_getParsedLibrary_notLibraryButPart() async {
    var driver = driverFor(testFile);
    var a = newFile('$testPackageLibPath/a.dart', 'part of my;');
    var result = driver.getParsedLibrary2(a);
    expect(result, isA<NotLibraryButPartResult>());
  }

  test_getParsedLibraryByUri() async {
    var content = 'class A {}';
    var a = newFile('$testPackageLibPath/a.dart', content);

    var driver = driverFor(testFile);

    var uri = Uri.parse('package:test/a.dart');
    var result = driver.getParsedLibraryByUri(uri);
    result as ParsedLibraryResult;
    expect(result.units, hasLength(1));
    expect(result.units[0].uri, uri);
    expect(result.units[0].path, a.path);
    expect(result.units[0].content, content);
  }

  test_getParsedLibraryByUri_cannotResolveUri() async {
    var driver = driverFor(testFile);
    var uri = Uri.parse('foo:bar');
    expect(driver.getParsedLibraryByUri(uri), isA<CannotResolveUriResult>());
  }

  test_getParsedLibraryByUri_notLibrary_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part of 'b.dart';
''');

    var driver = driverFor(a);
    var uri = Uri.parse('package:test/a.dart');
    expect(driver.getParsedLibraryByUri(uri), isA<NotLibraryButPartResult>());
  }

  test_getParsedLibraryByUri_notLibraryButPart() async {
    newFile('$testPackageLibPath/a.dart', 'part of my;');
    var driver = driverFor(testFile);
    var uri = Uri.parse('package:test/a.dart');
    var result = driver.getParsedLibraryByUri(uri);
    expect(result, isA<NotLibraryButPartResult>());
  }

  test_getParsedLibraryByUri_unresolvedUri() async {
    var driver = driverFor(testFile);
    var uri = Uri.parse('package:unknown/a.dart');
    var result = driver.getParsedLibraryByUri(uri);
    expect(result, isA<CannotResolveUriResult>());
  }

  test_getResolvedLibrary() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getResolvedLibrary('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedLibrary A1
  ResolvedLibraryResult #0
    element: package:test/a.dart
    units
      ResolvedUnitResult #1
        path: /home/test/lib/a.dart
        uri: package:test/a.dart
        flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_getResolvedLibrary_cachePriority() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a];

    collector.getResolvedLibrary('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedLibrary A1
  ResolvedLibraryResult #0
    element: package:test/a.dart
    units
      ResolvedUnitResult #1
        path: /home/test/lib/a.dart
        uri: package:test/a.dart
        flags: exists isLibrary
      ResolvedUnitResult #2
        path: /home/test/lib/b.dart
        uri: package:test/b.dart
        flags: exists isPart
[stream]
  ResolvedUnitResult #1
[stream]
  ResolvedUnitResult #2
[status] idle
''');

    // Ask again, the same cached instance should be returned.
    // Note, no analysis.
    // Note, the result is cached.
    collector.getResolvedLibrary('A2', a);
    await assertEventsText(collector, r'''
[future] getResolvedLibrary A2
  ResolvedLibraryResult #0
''');

    // Ask `a`, returns cached.
    // Note, no analysis.
    collector.getResolvedUnit('A3', a);
    await assertEventsText(collector, r'''
[future] getResolvedUnit A3
  ResolvedUnitResult #1
''');

    // Ask `b`, returns cached.
    // Note, no analysis.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[future] getResolvedUnit B1
  ResolvedUnitResult #2
''');
  }

  test_getResolvedLibrary_notAbsolutePath() async {
    var driver = driverFor(testFile);
    var result = await driver.getResolvedLibrary('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  test_getResolvedLibrary_notLibrary_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part of 'b.dart';
''');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    collector.getResolvedLibrary('X', a);

    await assertEventsText(collector, r'''
[status] working
[future] getResolvedLibrary X
  NotLibraryButPartResult
[status] idle
''');
  }

  test_getResolvedLibrary_pending_changeFile() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Ask the resolved library.
    // We used to record the request with the `LibraryFileKind`.
    collector.getResolvedLibrary('A1', a);

    // ...the request is pending, notify that the file changed.
    // This forces its reading, and rebuilding its `kind`.
    // So, the old `kind` is not valid anymore.
    // This used to cause infinite processing of the request.
    // https://github.com/dart-lang/sdk/issues/54708
    driver.changeFile2(a);

    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedLibrary A1
  ResolvedLibraryResult #0
    element: package:test/a.dart
    units
      ResolvedUnitResult #1
        path: /home/test/lib/a.dart
        uri: package:test/a.dart
        flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_getResolvedLibraryByUri() async {
    newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    var uri = Uri.parse('package:test/a.dart');
    collector.getResolvedLibraryByUri('A1', uri);

    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedLibraryByUri A1
  ResolvedLibraryResult #0
    element: package:test/a.dart
    units
      ResolvedUnitResult #1
        path: /home/test/lib/a.dart
        uri: package:test/a.dart
        flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_getResolvedLibraryByUri_cannotResolveUri() async {
    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    var uri = Uri.parse('foo:bar');
    collector.getResolvedLibraryByUri('X', uri);

    await assertEventsText(collector, r'''
[future] getResolvedLibraryByUri X
  CannotResolveUriResult
''');
  }

  test_getResolvedLibraryByUri_library_pending_getResolvedUnit() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(a);

    var collector = DriverEventCollector(driver);
    collector.getResolvedUnit('A1', a);
    collector.getResolvedUnit('B1', b);

    var uri = Uri.parse('package:test/a.dart');
    collector.getResolvedLibraryByUri('A2', uri);

    // Note, the library is resolved only once.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[future] getResolvedLibraryByUri A2
  ResolvedLibraryResult #2
    element: package:test/a.dart
    units
      ResolvedUnitResult #0
      ResolvedUnitResult #1
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_getResolvedLibraryByUri_notLibrary_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part of 'b.dart';
''');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    var uri = Uri.parse('package:test/a.dart');
    collector.getResolvedLibraryByUri('X', uri);

    await assertEventsText(collector, r'''
[status] working
[future] getResolvedLibraryByUri X
  NotLibraryButPartResult
[status] idle
''');
  }

  test_getResolvedLibraryByUri_notLibraryButPart() async {
    newFile('$testPackageLibPath/a.dart', 'part of my;');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    var uri = Uri.parse('package:test/a.dart');
    collector.getResolvedLibraryByUri('A1', uri);

    await assertEventsText(collector, r'''
[status] working
[future] getResolvedLibraryByUri A1
  NotLibraryButPartResult
[status] idle
''');
  }

  test_getResolvedLibraryByUri_unresolvedUri() async {
    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    var uri = Uri.parse('package:unknown/a.dart');
    collector.getResolvedLibraryByUri('A1', uri);

    await assertEventsText(collector, r'''
[future] getResolvedLibraryByUri A1
  CannotResolveUriResult
''');
  }

  test_getResolvedUnit() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getResolvedUnit_added() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    collector.getResolvedUnit('A1', a);

    // Note, no separate `ErrorsResult`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getResolvedUnit_importLibrary_thenRemoveIt() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
import 'a.dart';
class B extends A {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);

    // No errors in `a` or `b`.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');

    // Remove `a` and reanalyze.
    deleteFile(a.path);
    driver.removeFile2(a);

    // The unresolved URI error must be reported.
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B2
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    errors
      7 +8 URI_DOES_NOT_EXIST
      33 +1 EXTENDS_NON_CLASS
[stream]
  ResolvedUnitResult #2
[status] idle
''');

    // Restore `a`.
    newFile(a.path, 'class A {}');
    driver.addFile2(a);

    // No errors in `b` again.
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B2
  ResolvedUnitResult #3
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #3
[operation] getErrorsFromBytes
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ErrorsResult #4
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
[status] idle
''');
  }

  test_getResolvedUnit_library_added_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);
    collector.getResolvedUnit('A1', a);

    // Note, the library is resolved only once.
    // Note, no separate `ErrorsResult` for `a` or `b`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_getResolvedUnit_library_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getResolvedUnit('A1', a);
    collector.getResolvedUnit('B1', b);

    // Note, the library is resolved only once.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_getResolvedUnit_library_pending_getErrors_part() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getErrors('B1', b);
    collector.getResolvedUnit('A1', a);

    // Note, the library is resolved only once.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getErrors B1
  ErrorsResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: isPart
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_getResolvedUnit_notDartFile() async {
    var a = newFile('$testPackageLibPath/a.txt', r'''
final foo = 0;
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    configuration
        .libraryConfiguration
        .unitConfiguration
        .variableTypesSelector = (result) {
      return [result.findElement2.topVar('foo')];
    };

    // The extension of the file does not matter.
    // If asked, we analyze it as Dart.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.txt
  library: /home/test/lib/a.txt
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.txt
    uri: package:test/a.txt
    flags: exists isLibrary
    selectedVariableTypes
      foo: int
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getResolvedUnit_part_doesNotExist_lints() async {
    newFile('$testPackageRootPath/analysis_options.yaml', r'''
linter:
  rules:
    - omit_local_variable_types
''');

    await assertErrorsInCode(
      r'''
library my.lib;
part 'a.dart';
''',
      [error(CompileTimeErrorCode.URI_DOES_NOT_EXIST, 21, 8)],
    );
  }

  test_getResolvedUnit_part_empty_lints() async {
    newFile('$testPackageRootPath/analysis_options.yaml', r'''
linter:
  rules:
    - omit_local_variable_types
''');

    newFile('$testPackageLibPath/a.dart', '');

    await assertErrorsInCode(
      r'''
library my.lib;
part 'a.dart';
''',
      [error(CompileTimeErrorCode.PART_OF_NON_PART, 21, 8)],
    );
  }

  test_getResolvedUnit_part_hasPartOfName_notThisLibrary_lints() async {
    newFile('$testPackageRootPath/analysis_options.yaml', r'''
linter:
  rules:
    - omit_local_variable_types
''');

    newFile('$testPackageLibPath/a.dart', r'''
part of other.lib;
''');

    await assertErrorsInCode(
      r'''
library my.lib;
part 'a.dart';
''',
      [error(CompileTimeErrorCode.PART_OF_DIFFERENT_LIBRARY, 21, 8)],
    );
  }

  test_getResolvedUnit_part_hasPartOfUri_notThisLibrary_lints() async {
    newFile('$testPackageRootPath/analysis_options.yaml', r'''
linter:
  rules:
    - omit_local_variable_types
''');

    newFile('$testPackageLibPath/a.dart', r'''
part of 'not_test.dart';
''');

    await assertErrorsInCode(
      r'''
library my.lib;
part 'a.dart';
''',
      [error(CompileTimeErrorCode.PART_OF_DIFFERENT_LIBRARY, 21, 8)],
    );
  }

  test_getResolvedUnit_part_library() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getResolvedUnit('B1', b);
    collector.getResolvedUnit('A1', a);

    // Note, the library is resolved only once.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_getResolvedUnit_part_pending_getErrors_library() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getErrors('A1', a);
    collector.getResolvedUnit('B1', b);

    // Note, the library is resolved only once.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[future] getErrors A1
  ErrorsResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_getResolvedUnit_pending_getErrors() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getResolvedUnit('A1', a);
    collector.getErrors('A2', a);

    // Note, the library is resolved only once.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getErrors A2
  ErrorsResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getResolvedUnit_pending_getErrors2() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getErrors('A1', a);
    collector.getResolvedUnit('A2', a);

    // Note, the library is resolved only once.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A2
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getErrors A1
  ErrorsResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getResolvedUnit_pending_getIndex() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getIndex('A1', a);
    collector.getResolvedUnit('A2', a);

    // Note, no separate `getIndex` result.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A2
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getIndex A1
  strings
    --nullString--
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getResolvedUnit_thenRemove() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Schedule resolved unit computation.
    collector.getResolvedUnit('A1', a);

    // ...and remove the file.
    driver.removeFile2(a);

    // The future with the result still completes.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getResolvedUnit_twoPendingFutures() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Ask the same file twice.
    collector.getResolvedUnit('A1', a);
    collector.getResolvedUnit('A2', a);

    // Both futures complete.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[future] getResolvedUnit A2
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_getUnitElement() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
void foo() {}
void bar() {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    configuration.unitElementConfiguration.elementSelector = (unitFragment) {
      return unitFragment.functions
          .map((fragment) => fragment.element)
          .toList();
    };

    collector.getUnitElement('A1', a);
    await assertEventsText(collector, r'''
[status] working
[future] getUnitElement A1
  path: /home/test/lib/a.dart
  uri: package:test/a.dart
  flags: isLibrary
  enclosing: <null>
  selectedElements
    package:test/a.dart::@function::foo
    package:test/a.dart::@function::bar
[status] idle
''');
  }

  test_getUnitElement_doesNotExist_afterResynthesized() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
import 'package:test/b.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    collector.getResolvedLibrary('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedLibrary A1
  ResolvedLibraryResult #0
    element: package:test/a.dart
    units
      ResolvedUnitResult #1
        path: /home/test/lib/a.dart
        uri: package:test/a.dart
        flags: exists isLibrary
        errors
          7 +21 URI_DOES_NOT_EXIST
[stream]
  ResolvedUnitResult #1
[status] idle
''');

    collector.getUnitElement('A2', a);
    await assertEventsText(collector, r'''
[status] working
[future] getUnitElement A2
  path: /home/test/lib/a.dart
  uri: package:test/a.dart
  flags: isLibrary
  enclosing: <null>
[status] idle
''');
  }

  test_getUnitElement_invalidPath_notAbsolute() async {
    var driver = driverFor(testFile);
    var result = await driver.getUnitElement('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  test_hermetic_modifyLibraryFile_resolvePart() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
part 'b.dart';
final A = 0;
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
final B = A;
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    configuration
        .libraryConfiguration
        .unitConfiguration
        .variableTypesSelector = (result) {
      switch (result.uriStr) {
        case 'package:test/b.dart':
          return [result.findElement2.topVar('B')];
        default:
          return [];
      }
    };

    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    selectedVariableTypes
      B: int
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Modify the library, but don't notify the driver.
    // The driver should use the previous library content and elements.
    modifyFile2(a, r'''
part 'b.dart';
final A = 1.2;
''');

    // Note, still `B: int`, not `B: double` yet.
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit B2
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    selectedVariableTypes
      B: int
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
[status] idle
''');
  }

  test_importOfNonLibrary_part_afterLibrary() async {
    var a = newFile('$testPackageLibPath/a.dart', '''
part 'b.dart';
''');

    newFile('$testPackageLibPath/b.dart', '''
part of 'a.dart';
class B {}
''');

    var c = newFile('$testPackageLibPath/c.dart', '''
import 'b.dart';
''');

    var driver = driverFor(testFile);

    // This ensures that `a` linked library is cached.
    await driver.getResolvedUnit2(a);

    // Should not fail because of considering `b` part as `a` library.
    await driver.getResolvedUnit2(c);
  }

  test_knownFiles() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
// ignore:unused_import
import 'b.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
''');

    var c = newFile('$testPackageLibPath/c.dart', r'''
''');

    var driver = driverFor(testFile);

    driver.addFile2(a);
    driver.addFile2(c);
    await pumpEventQueue(times: 5000);
    expect(driver.knownFiles.resources, contains(a));
    expect(driver.knownFiles.resources, contains(b));
    expect(driver.knownFiles.resources, contains(c));

    // Remove `a` and analyze.
    // Both `a` and `b` are not known now.
    driver.removeFile2(a);
    await pumpEventQueue(times: 5000);
    expect(driver.knownFiles.resources, isNot(contains(a)));
    expect(driver.knownFiles.resources, isNot(contains(b)));
    expect(driver.knownFiles.resources, contains(c));
  }

  test_knownFiles_beforeAnalysis() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var driver = driverFor(testFile);

    // `a` is added, but not processed yet.
    // So, the set of known files is empty yet.
    driver.addFile2(a);
    expect(driver.knownFiles, isEmpty);
  }

  test_linkedBundleProvider_changeFile() async {
    var a = newFile('$testPackageLibPath/a.dart', 'var V = 1;');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.priorityFiles2 = [a];

    configuration
        .libraryConfiguration
        .unitConfiguration
        .variableTypesSelector = (result) {
      switch (result.uriStr) {
        case 'package:test/a.dart':
          return [result.findElement2.topVar('V')];
        default:
          return [];
      }
    };

    // Initial analysis.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      V: int
[status] idle
''');

    // When no fine-grained dependencies, we don't cache bundles.
    // So, [LinkedBundleProvider] is empty, and not printed.
    assertDriverStateString(testFile, r'''
files
  /home/test/lib/a.dart
    uri: package:test/a.dart
    current
      id: file_0
      kind: library_0
        libraryImports
          library_1 dart:core synthetic
        fileKinds: library_0
        cycle_0
          dependencies: dart:core
          libraries: library_0
          apiSignature_0
      unlinkedKey: k00
libraryCycles
  /home/test/lib/a.dart
    current: cycle_0
      key: k01
    get: []
    put: [k01]
elementFactory
  hasElement
    package:test/a.dart
''');

    // Update the file, but don't notify the driver.
    // No new results.
    modifyFile2(a, 'var V = 1.2;');
    await assertEventsText(collector, r'''
''');

    // Notify the driver about the change.
    // We get a new result.
    driver.changeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      V: double
[status] idle
''');

    assertDriverStateString(testFile, r'''
files
  /home/test/lib/a.dart
    uri: package:test/a.dart
    current
      id: file_0
      kind: library_6
        libraryImports
          library_1 dart:core synthetic
        fileKinds: library_6
        cycle_2
          dependencies: dart:core
          libraries: library_6
          apiSignature_1
      unlinkedKey: k02
libraryCycles
  /home/test/lib/a.dart
    current: cycle_2
      key: k03
    get: []
    put: [k01, k03]
elementFactory
  hasElement
    package:test/a.dart
''');
  }

  test_missingDartLibrary_async() async {
    var driver = driverFor(testFile);

    sdkRoot.getChildAssumingFile('lib/async/async.dart').delete();

    var a = newFile('$testPackageLibPath/a.dart', '');
    var result = await driver.getErrors(a.path);
    result as ErrorsResult;
    assertErrorsInList(result.diagnostics, [
      error(CompileTimeErrorCode.MISSING_DART_LIBRARY, 0, 0),
    ]);
  }

  test_missingDartLibrary_core() async {
    var driver = driverFor(testFile);

    sdkRoot.getChildAssumingFile('lib/core/core.dart').delete();

    var a = newFile('$testPackageLibPath/a.dart', '');
    var result = await driver.getErrors(a.path);
    result as ErrorsResult;
    assertErrorsInList(result.diagnostics, [
      error(CompileTimeErrorCode.MISSING_DART_LIBRARY, 0, 0),
    ]);
  }

  test_parseFileSync_appliesPendingFileChanges() async {
    var initialContent = 'initial content';
    var updatedContent = 'updated content';
    var a = newFile('$testPackageLibPath/a.dart', initialContent);

    // Check initial content.
    var driver = driverFor(testFile);
    var parsed = driver.parseFileSync(a.path) as ParsedUnitResult;
    expect(parsed.content, initialContent);

    // Update the file.
    newFile(a.path, updatedContent);
    driver.changeFile(a.path);

    // Expect parseFileSync to return the updated content.
    parsed = driver.parseFileSync(a.path) as ParsedUnitResult;
    expect(parsed.content, updatedContent);
  }

  test_parseFileSync_changedFile() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// ignore:unused_import
import 'a.dart';
void f(A a) {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Ensure that [a] library cycle is loaded.
    // So, `a` is in the library context.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');

    // Update the file, changing its API signature.
    // Note that we don't call `changeFile`.
    modifyFile2(a, r'''
class A {}
''');

    // Parse the file.
    // We have not called `changeFile(a)`, so we should not read the file.
    // Moreover, doing this will create a new library cycle [a].
    // Library cycles are compared by their identity, so we would try to
    // reload linked summary for [a], and crash.
    {
      var parseResult = driver.parseFileSync2(a) as ParsedUnitResult;
      expect(parseResult.unit.declarations, isEmpty);
    }

    // We have not read `a`, so `A` is still not declared.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    errors
      48 +1 UNDEFINED_CLASS
[stream]
  ResolvedUnitResult #1
[status] idle
''');

    // Notify the driver that `a` was changed.
    driver.changeFile2(a);

    // The pending change to `a` declares `A`.
    // So, `b` does not have errors anymore.
    collector.getResolvedUnit('B2', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B2
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
[status] idle
''');

    // We apply pending changes while handling request.
    // So, now `class A {}` is declared.
    {
      var result = driver.parseFileSync2(a) as ParsedUnitResult;
      assertParsedNodeText(result.unit, r'''
CompilationUnit
  declarations
    ClassDeclaration
      classKeyword: class
      name: A
      leftBracket: {
      rightBracket: }
''');
    }
  }

  test_parseFileSync_doesNotReadImportedFiles() async {
    newFile('$testPackageLibPath/a.dart', r'''
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// ignore:unused_import
import 'a.dart';
''');

    var driver = driverFor(testFile);
    expect(driver.knownFiles, isEmpty);

    // Don't read `a` when parse.
    driver.parseFileSync2(b);
    expect(driver.knownFiles.resources, unorderedEquals([b]));

    // Still don't read `a.dart` when parse the second time.
    driver.parseFileSync2(b);
    expect(driver.knownFiles.resources, unorderedEquals([b]));
  }

  test_parseFileSync_notAbsolutePath() async {
    var driver = driverFor(testFile);
    var result = driver.parseFileSync('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  test_parseFileSync_notDart() async {
    var a = newFile('$testPackageLibPath/a.txt', r'''
class A {}
''');

    var driver = driverFor(testFile);

    var result = driver.parseFileSync2(a) as ParsedUnitResult;
    assertParsedNodeText(result.unit, r'''
CompilationUnit
  declarations
    ClassDeclaration
      classKeyword: class
      name: A
      leftBracket: {
      rightBracket: }
''');

    expect(driver.knownFiles.resources, unorderedEquals([a]));
  }

  test_partOfName_getErrors_afterLibrary() async {
    // Note, we put the library into a different directory.
    // Otherwise we will discover it.
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Process `a` so that we know that it's a library for `b`.
    collector.getErrors('A1', a);
    await assertEventsText(collector, r'''
[status] working
[future] getErrors A1
  ErrorsResult #0
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: isLibrary
[operation] analyzeFile
  file: /home/test/lib/hidden/a.dart
  library: /home/test/lib/hidden/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');

    // We return cached errors.
    // TODO(scheglov): don't switch to analysis?
    collector.getErrors('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] getErrorsFromBytes
  file: /home/test/lib/b.dart
  library: /home/test/lib/hidden/a.dart
[future] getErrors B1
  ErrorsResult #3
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: isPart
[status] idle
''');
  }

  test_partOfName_getErrors_beforeLibrary_addedFiles() async {
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// preEnhancedParts
// @dart = 3.4
part of a;
final a = A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We discover all added files are maybe libraries.
    driver.addFile2(a);
    driver.addFile2(b);

    // Because `a` is added, we know how to analyze `b`.
    // So, it has no errors.
    collector.getErrors('B1', b);
    await assertEventsText(collector, r'''
[status] working
[future] getErrors B1
  ErrorsResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: isPart
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/hidden/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_partOfName_getErrors_beforeLibrary_discovered() async {
    newFile('$testPackageLibPath/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part 'b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We discover sibling files as libraries.
    // So, we know that `a` is the library of `b`.
    // So, no errors.
    collector.getErrors('B1', b);
    await assertEventsText(collector, r'''
[status] working
[future] getErrors B1
  ErrorsResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: isPart
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_partOfName_getErrors_beforeLibrary_notDiscovered() async {
    newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We don't know that `a` is the library of `b`.
    // So, we treat it as its own library, has errors.
    collector.getErrors('B1', b);
    await assertEventsText(collector, r'''
[status] working
[future] getErrors B1
  ErrorsResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: isPart
    errors
      60 +1 CREATION_WITH_NON_TYPE
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    errors
      60 +1 CREATION_WITH_NON_TYPE
[status] idle
''');
  }

  test_partOfName_getResolvedUnit_afterLibrary() async {
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Process `a` so that we know that it's a library for `b`.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/hidden/a.dart
  library: /home/test/lib/hidden/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');

    // We know that `b` is analyzed as part of `a`.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/hidden/a.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #2
[status] idle
''');
  }

  test_partOfName_getResolvedUnit_beforeLibrary_addedFiles() async {
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We discover all added files are maybe libraries.
    driver.addFile2(a);
    driver.addFile2(b);

    // Because `a` is added, we know how to analyze `b`.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/hidden/a.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_partOfName_getResolvedUnit_beforeLibrary_notDiscovered() async {
    newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We don't know that `a` is the library of `b`.
    // So, we treat it as its own library.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    errors
      60 +1 CREATION_WITH_NON_TYPE
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_partOfName_getResolvedUnit_changePart_invalidatesLibraryCycle() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
import 'dart:async';
part 'b.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);

    // Analyze the library without the part.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    errors
      61 +8 URI_DOES_NOT_EXIST
      42 +12 UNUSED_IMPORT
[status] idle
''');

    // Create the part file.
    // This should invalidate library file state (specifically the library
    // cycle), so that we can re-link the library, and get new dependencies.
    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of 'a.dart';
Future<int>? f;
''');
    driver.changeFile2(b);

    // This should not crash.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/a.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
[status] idle
''');
  }

  test_partOfName_getResolvedUnit_hasLibrary_noPart() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library my.lib;
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of my.lib;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Discover the library.
    driver.getFileSync2(a);

    // There is no library which `b` is a part of, so `A` is unresolved.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    errors
      65 +1 CREATION_WITH_NON_TYPE
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_partOfName_getResolvedUnit_noLibrary() async {
    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of my.lib;
var a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // There is no library which `b` is a part of, so `A` is unresolved.
    collector.getResolvedUnit('B1', b);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    errors
      63 +1 CREATION_WITH_NON_TYPE
[stream]
  ResolvedUnitResult #0
[status] idle
''');
  }

  test_partOfName_getUnitElement_afterLibrary() async {
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // Process `a` so that we know that it's a library for `b`.
    collector.getResolvedUnit('A1', a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/hidden/a.dart
  library: /home/test/lib/hidden/a.dart
[future] getResolvedUnit A1
  ResolvedUnitResult #0
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #0
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');

    // We know that `a` is the library for `b`.
    collector.getUnitElement('B1', b);
    await assertEventsText(collector, r'''
[status] working
[future] getUnitElement B1
  path: /home/test/lib/b.dart
  uri: package:test/b.dart
  flags: isPart
  enclosing: #F0
[status] idle
''');
  }

  test_partOfName_getUnitElement_beforeLibrary_addedFiles() async {
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We discover all added files are maybe libraries.
    driver.addFile2(a);
    driver.addFile2(b);

    // Because `a` is added, we know how to analyze `b`.
    collector.getUnitElement('B1', b);
    await assertEventsText(collector, r'''
[status] working
[future] getUnitElement B1
  path: /home/test/lib/b.dart
  uri: package:test/b.dart
  flags: isPart
  enclosing: #F0
[operation] analyzeFile
  file: /home/test/lib/hidden/a.dart
  library: /home/test/lib/hidden/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_partOfName_getUnitElement_noLibrary() async {
    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We don't know the library for `b`.
    // So, we treat it as its own library.
    collector.getUnitElement('B1', b);
    await assertEventsText(collector, r'''
[status] working
[future] getUnitElement B1
  path: /home/test/lib/b.dart
  uri: package:test/b.dart
  flags: isPart
  enclosing: <null>
[status] idle
''');
  }

  test_partOfName_results_afterLibrary() async {
    // Note, we put the library into a different directory.
    // Otherwise we will discover it.
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // The order does not matter.
    // It used to matter, but not anymore.
    driver.addFile2(a);
    driver.addFile2(b);

    // We discover all added libraries.
    // So, we know that `a` is the library of `b`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/hidden/a.dart
  library: /home/test/lib/hidden/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_partOfName_results_beforeLibrary() async {
    // Note, we put the library into a different directory.
    // Otherwise we will discover it.
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // The order does not matter.
    // It used to matter, but not anymore.
    driver.addFile2(b);
    driver.addFile2(a);

    // We discover all added libraries.
    // So, we know that `a` is the library of `b`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/hidden/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_partOfName_results_beforeLibrary_priority() async {
    // Note, we put the library into a different directory.
    // Otherwise we will discover it.
    var a = newFile('$testPackageLibPath/hidden/a.dart', r'''
// @dart = 3.4
// preEnhancedParts
library a;
part '../b.dart';
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // The order does not matter.
    // It used to matter, but not anymore.
    driver.addFile2(b);
    driver.addFile2(a);
    driver.priorityFiles2 = [b];

    // We discover all added libraries.
    // So, we know that `a` is the library of `b`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/hidden/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/hidden/a.dart
    uri: package:test/hidden/a.dart
    flags: exists isLibrary
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
[status] idle
''');
  }

  test_partOfName_results_noLibrary() async {
    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(b);

    // There is no library for `b`.
    // So, we analyze `b` as its own library.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    errors
      60 +1 CREATION_WITH_NON_TYPE
[status] idle
''');
  }

  test_partOfName_results_noLibrary_priority() async {
    var b = newFile('$testPackageLibPath/b.dart', r'''
// @dart = 3.4
// preEnhancedParts
part of a;
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(b);
    driver.priorityFiles2 = [b];

    // There is no library for `b`.
    // So, we analyze `b` as its own library.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isPart
    errors
      60 +1 CREATION_WITH_NON_TYPE
[status] idle
''');
  }

  test_priorities_changed_importing_rest() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
import 'c.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
class B {}
''');

    var c = newFile('$testPackageLibPath/c.dart', r'''
import 'b.dart';
''');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);

    // Discard results so far.
    await collector.nextStatusIdle();
    collector.take();

    modifyFile2(b, r'''
class B2 {}
''');
    driver.changeFile2(b);

    // We analyze `b` first, because it was changed.
    // Then we analyze `c`, because it imports `b`.
    // Then we analyze `a`, because it also affected.
    // Note, there is no specific rule that says when `a` is analyzed.
    configuration.withStreamResolvedUnitResults = false;
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[operation] analyzeFile
  file: /home/test/lib/c.dart
  library: /home/test/lib/c.dart
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[status] idle
''');
  }

  test_priorities_changed_importing_withErrors_rest() async {
    // Note, is affected by `b`, but does not import it.
    var a = newFile('$testPackageLibPath/a.dart', r'''
export 'b.dart';
''');

    // We will change this file.
    var b = newFile('$testPackageLibPath/b.dart', r'''
class B {}
''');

    // Note, does not import `b` directly.
    var c = newFile('$testPackageLibPath/c.dart', r'''
import 'a.dart';
class C extends X {}
''');

    // Note, does import `b`.
    var d = newFile('$testPackageLibPath/d.dart', r'''
import 'b.dart';
''');

    var driver = driverFor(a);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);
    driver.addFile2(d);

    // Discard results so far.
    await collector.nextStatusIdle();
    collector.take();

    modifyFile2(b, r'''
class B2 {}
''');
    driver.changeFile2(b);

    // We analyze `b` first, because it was changed.
    // The we analyze `d` because it import `b`.
    // Then we analyze `c` because it has errors.
    // Then we analyze `a` because it is affected.
    // For `a` because it just exports, there are no special rules.
    configuration.withStreamResolvedUnitResults = false;
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[operation] analyzeFile
  file: /home/test/lib/d.dart
  library: /home/test/lib/d.dart
[operation] analyzeFile
  file: /home/test/lib/c.dart
  library: /home/test/lib/c.dart
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[status] idle
''');
  }

  test_priorities_changedAll() async {
    // Make sure that `test2` is its own analysis context.
    var test1Path = '$workspaceRootPath/test1';
    writePackageConfig(
      test1Path,
      PackageConfigFileBuilder()..add(name: 'test1', rootPath: test1Path),
    );

    // Make sure that `test2` is its own analysis context.
    var test2Path = '$workspaceRootPath/test2';
    writePackageConfig(
      test2Path,
      PackageConfigFileBuilder()..add(name: 'test2', rootPath: test2Path),
    );

    // `b` imports `a`, so `b` is reanalyzed when `a` API changes.
    var a = newFile('$test1Path/lib/a.dart', 'class A {}');
    var b = newFile('$test1Path/lib/b.dart', "import 'a.dart';");

    // `d` imports `c`, so `d` is reanalyzed when `b` API changes.
    var c = newFile('$test2Path/lib/c.dart', 'class C {}');
    var d = newFile('$test2Path/lib/d.dart', "import 'c.dart';");

    var collector = DriverEventCollector.forCollection(
      analysisContextCollection,
    );

    var driver1 = driverFor(a);
    var driver2 = driverFor(c);

    // Ensure that we actually have two separate analysis contexts.
    expect(driver1, isNot(same(driver2)));

    // Subscribe for analysis.
    driver1.addFile2(a);
    driver1.addFile2(b);
    driver2.addFile2(c);
    driver2.addFile2(d);

    // Discard results so far.
    await collector.nextStatusIdle();
    collector.take();

    // Change `a` and `c` in a way that changed their API signatures.
    modifyFile2(a, 'class A2 {}');
    modifyFile2(c, 'class C2 {}');
    driver1.changeFile2(a);
    driver2.changeFile2(c);

    // Note, `a` and `c` analyzed first, because they were changed.
    // Even though they are in different drivers.
    configuration.withStreamResolvedUnitResults = false;
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test1/lib/a.dart
  library: /home/test1/lib/a.dart
[operation] analyzeFile
  file: /home/test2/lib/c.dart
  library: /home/test2/lib/c.dart
[operation] analyzeFile
  file: /home/test1/lib/b.dart
  library: /home/test1/lib/b.dart
[operation] analyzeFile
  file: /home/test2/lib/d.dart
  library: /home/test2/lib/d.dart
[status] idle
''');
  }

  test_priorities_getResolvedUnit_beforePriority() async {
    // Make sure that `test1` is its own analysis context.
    var test1Path = '$workspaceRootPath/test1';
    writePackageConfig(
      test1Path,
      PackageConfigFileBuilder()..add(name: 'test1', rootPath: test1Path),
    );

    // Make sure that `test2` is its own analysis context.
    var test2Path = '$workspaceRootPath/test2';
    writePackageConfig(
      test2Path,
      PackageConfigFileBuilder()..add(name: 'test2', rootPath: test2Path),
    );

    var a = newFile('$test1Path/lib/a.dart', '');
    var b = newFile('$test2Path/lib/b.dart', '');
    var c = newFile('$test2Path/lib/c.dart', '');

    var collector = DriverEventCollector.forCollection(
      analysisContextCollection,
    );

    var driver1 = driverFor(a);
    var driver2 = driverFor(c);

    // Ensure that we actually have two separate analysis contexts.
    expect(driver1, isNot(same(driver2)));

    // Subscribe for analysis.
    driver1.addFile2(a);
    driver2.addFile2(b);
    driver2.addFile2(c);

    driver1.priorityFiles2 = [a];
    driver2.priorityFiles2 = [c];

    collector.driver = driver2;
    collector.getResolvedUnit('B1', b);

    // We asked for `b`, so it is analyzed.
    // Even if it is not a priority file.
    // Even if it is in the `driver2`.
    configuration.withStreamResolvedUnitResults = false;
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test2/lib/b.dart
  library: /home/test2/lib/b.dart
[future] getResolvedUnit B1
  ResolvedUnitResult #0
    path: /home/test2/lib/b.dart
    uri: package:test2/b.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test1/lib/a.dart
  library: /home/test1/lib/a.dart
[operation] analyzeFile
  file: /home/test2/lib/c.dart
  library: /home/test2/lib/c.dart
[status] idle
''');
  }

  test_priorities_priority_rest() async {
    // Make sure that `test1` is its own analysis context.
    var test1Path = '$workspaceRootPath/test1';
    writePackageConfig(
      test1Path,
      PackageConfigFileBuilder()..add(name: 'test1', rootPath: test1Path),
    );

    // Make sure that `test2` is its own analysis context.
    var test2Path = '$workspaceRootPath/test2';
    writePackageConfig(
      test2Path,
      PackageConfigFileBuilder()..add(name: 'test2', rootPath: test2Path),
    );

    var a = newFile('$test1Path/lib/a.dart', '');
    var b = newFile('$test1Path/lib/b.dart', '');
    var c = newFile('$test2Path/lib/c.dart', '');
    var d = newFile('$test2Path/lib/d.dart', '');

    var collector = DriverEventCollector.forCollection(
      analysisContextCollection,
    );

    var driver1 = driverFor(a);
    var driver2 = driverFor(c);

    // Ensure that we actually have two separate analysis contexts.
    expect(driver1, isNot(same(driver2)));

    driver1.addFile2(a);
    driver1.addFile2(b);
    driver1.priorityFiles2 = [a];

    driver2.addFile2(c);
    driver2.addFile2(d);
    driver2.priorityFiles2 = [c];

    configuration.withStreamResolvedUnitResults = false;
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test1/lib/a.dart
  library: /home/test1/lib/a.dart
[operation] analyzeFile
  file: /home/test2/lib/c.dart
  library: /home/test2/lib/c.dart
[operation] analyzeFile
  file: /home/test1/lib/b.dart
  library: /home/test1/lib/b.dart
[operation] analyzeFile
  file: /home/test2/lib/d.dart
  library: /home/test2/lib/d.dart
[status] idle
''');
  }

  test_removeFile_addFile() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);

    // Initial analysis.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');

    driver.removeFile2(a);
    driver.addFile2(a);

    // The cache key for `a` errors is the same, return from bytes.
    // Note, no analysis.
    await assertEventsText(collector, r'''
[status] working
[operation] getErrorsFromBytes
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ErrorsResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: isLibrary
[status] idle
''');
  }

  test_removeFile_changeFile_implicitlyAnalyzed() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
import 'b.dart';
final A = B;
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
final B = 0;
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.priorityFiles2 = [a, b];
    driver.addFile2(a);
    driver.addFile2(b);

    configuration
        .libraryConfiguration
        .unitConfiguration
        .variableTypesSelector = (result) {
      switch (result.uriStr) {
        case 'package:test/a.dart':
          return [result.findElement2.topVar('A')];
        case 'package:test/b.dart':
          return [result.findElement2.topVar('B')];
        default:
          return [];
      }
    };

    // We have results for both `a` and `b`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      A: int
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    selectedVariableTypes
      B: int
[status] idle
''');

    // Remove `b` and send the change notification.
    modifyFile2(b, r'''
final B = 1.2;
''');
    driver.removeFile2(b);
    driver.changeFile2(b);

    // While `b` is not analyzed explicitly, it is analyzed implicitly.
    // We don't get a result for `b`.
    // But the change causes `a` to be reanalyzed.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    selectedVariableTypes
      A: double
[status] idle
''');
  }

  test_removeFile_changeFile_notAnalyzed() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // We don't analyze `a`, so we get nothing.
    await assertEventsText(collector, r'''
''');

    // Remove `a`, and also change it.
    // Still nothing, we still don't analyze `a`.
    driver.removeFile2(a);
    driver.changeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[status] idle
''');
  }

  test_removeFile_invalidate_importers() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
import 'a.dart';
final a = new A();
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);

    // No errors in `b`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[status] idle
''');

    // Remove `a`, so `b` is reanalyzed and has an error.
    deleteFile(a.path);
    driver.removeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
    errors
      7 +8 URI_DOES_NOT_EXIST
      31 +1 CREATION_WITH_NON_TYPE
[status] idle
''');
  }

  test_removeFile_notAbsolutePath() async {
    var driver = driverFor(testFile);
    expect(() {
      driver.removeFile('not_absolute.dart');
    }, throwsArgumentError);
  }

  test_results_order() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
// ignore:unused_import
import 'd.dart';
''');

    var b = newFile('$testPackageLibPath/b.dart', '');

    var c = newFile('$testPackageLibPath/c.dart', r'''
// ignore:unused_import
import 'd.dart';
''');

    var d = newFile('$testPackageLibPath/d.dart', r'''
// ignore:unused_import
import 'b.dart';
''');

    var e = newFile('$testPackageLibPath/e.dart', r'''
// ignore:unused_import
export 'b.dart';
''');

    // This file intentionally has an error.
    var f = newFile('$testPackageLibPath/f.dart', r'''
// ignore:unused_import
import 'e.dart';
class F extends X {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);
    driver.addFile2(d);
    driver.addFile2(e);
    driver.addFile2(f);

    // Initial analysis, all files analyzed in order of adding.
    // Note, `f` has an error.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/c.dart
  library: /home/test/lib/c.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/c.dart
    uri: package:test/c.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/d.dart
  library: /home/test/lib/d.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/d.dart
    uri: package:test/d.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/e.dart
  library: /home/test/lib/e.dart
[stream]
  ResolvedUnitResult #4
    path: /home/test/lib/e.dart
    uri: package:test/e.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/f.dart
  library: /home/test/lib/f.dart
[stream]
  ResolvedUnitResult #5
    path: /home/test/lib/f.dart
    uri: package:test/f.dart
    flags: exists isLibrary
    errors
      57 +1 EXTENDS_NON_CLASS
[status] idle
''');

    // Update `b` with changing its API signature.
    modifyFile2(b, r'''
class B {}
''');
    driver.changeFile2(b);

    // 1. The changed `b` is the first.
    // 2. Then `d` that imports the changed `b`.
    // 3. Then `f` that has an error (even if it is unrelated).
    // 4. Then the rest, in order of adding.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #6
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/d.dart
  library: /home/test/lib/d.dart
[stream]
  ResolvedUnitResult #7
    path: /home/test/lib/d.dart
    uri: package:test/d.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/f.dart
  library: /home/test/lib/f.dart
[stream]
  ResolvedUnitResult #8
    path: /home/test/lib/f.dart
    uri: package:test/f.dart
    flags: exists isLibrary
    errors
      57 +1 EXTENDS_NON_CLASS
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #9
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/c.dart
  library: /home/test/lib/c.dart
[stream]
  ResolvedUnitResult #10
    path: /home/test/lib/c.dart
    uri: package:test/c.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/e.dart
  library: /home/test/lib/e.dart
[stream]
  ResolvedUnitResult #11
    path: /home/test/lib/e.dart
    uri: package:test/e.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_results_order_allChangedFirst_thenImports() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
class B {}
''');

    var c = newFile('$testPackageLibPath/c.dart', r'''
''');

    var d = newFile('$testPackageLibPath/d.dart', r'''
// ignore:unused_import
import 'a.dart';
''');

    var e = newFile('$testPackageLibPath/e.dart', r'''
// ignore:unused_import
import 'b.dart';
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);
    driver.addFile2(c);
    driver.addFile2(d);
    driver.addFile2(e);

    // Initial analysis, all files analyzed in order of adding.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/c.dart
  library: /home/test/lib/c.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/c.dart
    uri: package:test/c.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/d.dart
  library: /home/test/lib/d.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/d.dart
    uri: package:test/d.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/e.dart
  library: /home/test/lib/e.dart
[stream]
  ResolvedUnitResult #4
    path: /home/test/lib/e.dart
    uri: package:test/e.dart
    flags: exists isLibrary
[status] idle
''');

    // Change b.dart and then a.dart files.
    modifyFile2(a, r'''
class A2 {}
''');
    modifyFile2(b, r'''
class B2 {}
''');
    driver.changeFile2(b);
    driver.changeFile2(a);

    // First `a` and `b`.
    // Then `d` and `e` because they import `a` and `b`.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #5
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #6
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/d.dart
  library: /home/test/lib/d.dart
[stream]
  ResolvedUnitResult #7
    path: /home/test/lib/d.dart
    uri: package:test/d.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/e.dart
  library: /home/test/lib/e.dart
[stream]
  ResolvedUnitResult #8
    path: /home/test/lib/e.dart
    uri: package:test/e.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_results_removeFile_changeFile() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final v = 0;
''');

    var b = getFile('$testPackageLibPath/b.dart');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);

    // Initial analysis.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');

    // Update `a` to have an error.
    modifyFile2(a, r'''
final v = 0
''');

    // It does not matter what we do with `b`, it is not analyzed anyway.
    // But we notify that `a` was changed, so it is analyzed.
    driver.removeFile2(b);
    driver.changeFile2(a);
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
    errors
      10 +1 EXPECTED_TOKEN
[status] idle
''');
  }

  test_results_skipNotAffected() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    var b = newFile('$testPackageLibPath/b.dart', r'''
class B {}
''');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);

    // Initial analysis.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/b.dart
    uri: package:test/b.dart
    flags: exists isLibrary
[status] idle
''');

    // Update `a` and notify.
    modifyFile2(a, r'''
class A2 {}
''');
    driver.changeFile2(a);

    // Only `a` is analyzed, `b` is not affected.
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #2
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_schedulerStatus_hasAddedFile() async {
    var a = newFile('$testPackageLibPath/a.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);

    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/a.dart
    uri: package:test/a.dart
    flags: exists isLibrary
[status] idle
''');
  }

  test_schedulerStatus_noAddedFile() async {
    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    // No files, so no status changes.
    await assertEventsText(collector, r'''
''');
  }

  test_status_anyWorkTransitionsToAnalyzing() async {
    var a = newFile('$testPackageLibPath/a.dart', '');
    var b = newFile('$testPackageLibPath/b.dart', '');

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver);

    driver.addFile2(a);
    driver.addFile2(b);

    // Initial analysis.
    configuration.withStreamResolvedUnitResults = false;
    await assertEventsText(collector, r'''
[status] working
[operation] analyzeFile
  file: /home/test/lib/a.dart
  library: /home/test/lib/a.dart
[operation] analyzeFile
  file: /home/test/lib/b.dart
  library: /home/test/lib/b.dart
[status] idle
''');

    // Any work transitions to analyzing, and back to idle.
    await driver.getFilesReferencingName('X');
    await assertEventsText(collector, r'''
[status] working
[status] idle
''');
  }
}

/// Tracks events reported into the `results` stream, and results of `getXyz`
/// requests. We are interested in relative orders, identity of the objects,
/// absence of duplicate events, etc.
class DriverEventCollector {
  final IdProvider idProvider;
  late AnalysisDriver driver;
  List<DriverEvent> events = [];
  final List<Completer<void>> statusIdleCompleters = [];

  DriverEventCollector(this.driver, {IdProvider? idProvider})
    : idProvider = idProvider ?? IdProvider() {
    _listenSchedulerEvents(driver.scheduler);
  }

  DriverEventCollector.forCollection(
    AnalysisContextCollectionImpl collection, {
    IdProvider? idProvider,
  }) : idProvider = idProvider ?? IdProvider() {
    _listenSchedulerEvents(collection.scheduler);
  }

  void getCachedResolvedUnit(String name, File file) {
    var value = driver.getCachedResolvedUnit2(file);
    events.add(GetCachedResolvedUnitEvent(name: name, result: value));
  }

  void getErrors(String name, File file) {
    var future = driver.getErrors(file.path);
    unawaited(
      future.then((value) {
        events.add(GetErrorsEvent(name: name, result: value));
      }),
    );
  }

  void getIndex(String name, File file) async {
    var value = await driver.getIndex(file.path);
    events.add(GetIndexEvent(name: name, result: value));
  }

  void getLibraryByUri(String name, String uriStr) {
    var future = driver.getLibraryByUri(uriStr);
    unawaited(
      future.then((value) {
        events.add(GetLibraryByUriEvent(name: name, result: value));
      }),
    );
  }

  void getResolvedLibrary(String name, File file) {
    var future = driver.getResolvedLibrary(file.path);
    unawaited(
      future.then((value) {
        events.add(GetResolvedLibraryEvent(name: name, result: value));
      }),
    );
  }

  void getResolvedLibraryByUri(String name, Uri uri) {
    var future = driver.getResolvedLibraryByUri(uri);
    unawaited(
      future.then((value) {
        events.add(GetResolvedLibraryByUriEvent(name: name, result: value));
      }),
    );
  }

  void getResolvedUnit(
    String name,
    File file, {
    bool sendCachedToStream = false,
  }) {
    var future = driver.getResolvedUnit(
      file.path,
      sendCachedToStream: sendCachedToStream,
    );

    unawaited(
      future.then((value) {
        events.add(GetResolvedUnitEvent(name: name, result: value));
      }),
    );
  }

  void getUnitElement(String name, File file) {
    var future = driver.getUnitElement2(file);
    unawaited(
      future.then((value) {
        events.add(GetUnitElementEvent(name: name, result: value));
      }),
    );
  }

  Future<void> nextStatusIdle() {
    var completer = Completer<void>();
    statusIdleCompleters.add(completer);
    return completer.future;
  }

  List<DriverEvent> take() {
    var result = events;
    events = [];
    return result;
  }

  void _listenSchedulerEvents(AnalysisDriverScheduler scheduler) {
    scheduler.eventsBroadcast.listen((event) {
      switch (event) {
        case AnalysisStatus():
          events.add(SchedulerStatusEvent(event));
          if (event.isIdle) {
            statusIdleCompleters.completeAll();
            statusIdleCompleters.clear();
          }
        case driver_events.AnalyzeFile():
        case driver_events.AnalyzedLibrary():
        case driver_events.CannotReuseLinkedBundle():
        case driver_events.GetErrorsCannotReuse():
        case driver_events.GetErrorsFromBytes():
        case driver_events.LinkLibraryCycle():
        case driver_events.ProduceErrorsCannotReuse():
        case driver_events.ReuseLinkLibraryCycleBundle():
        case ErrorsResult():
        case ResolvedUnitResult():
          events.add(ResultStreamEvent(object: event));
      }
    });
  }
}

@reflectiveTest
class FineAnalysisDriverTest extends PubPackageResolutionTest
    with _EventsMixin {
  @override
  bool get retainDataForTesting => true;

  @override
  void setUp() {
    super.setUp();
    registerLintRules();
    useEmptyByteStore();
  }

  @override
  Future<void> tearDown() async {
    testFineAfterLibraryAnalyzerHook = null;
    withFineDependencies = false;
    return super.tearDown();
  }

  test_dependency_class_constructor_named_instanceGetterSetter_u1() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.foo(int _);
  int get foo {}
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  var a = A.foo(0);
  a.foo;
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            foo: #M2
            foo=: #M3
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M4
          methods
            foo: #M2
            foo=: #M3
[status] idle
''',
      updatedA: r'''
class A {
  A.foo(double _);
  int get foo {}
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M8
        interface: #M5
          map
            foo: #M2
            foo=: #M3
  requirements
    topLevels
      dart:core
        double: #M9
        int: #M6
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: foo
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M8
          methods
            foo: #M2
            foo=: #M3
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_instanceGetterSetter_u2() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.foo(int _);
  int get foo {}
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  var a = A.foo(0);
  a.foo;
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            foo: #M2
            foo=: #M3
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M4
          methods
            foo: #M2
            foo=: #M3
[status] idle
''',
      updatedA: r'''
class A {
  A.foo(int _);
  double get foo {}
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M8
        declaredGetters
          foo: #M9
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M4
        interface: #M10
          map
            foo: #M9
            foo=: #M3
  requirements
    topLevels
      dart:core
        double: #M11
        int: #M6
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M8
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M4
          methods
            foo: #M9
            foo=: #M3
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_instanceGetterSetter_u3() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.foo(int _);
  int get foo {}
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  var a = A.foo(0);
  a.foo;
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            foo: #M2
            foo=: #M3
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M4
          methods
            foo: #M2
            foo=: #M3
[status] idle
''',
      updatedA: r'''
class A {
  A.foo(int _);
  int get foo {}
  set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M8
        declaredConstructors
          foo: #M4
        interface: #M9
          map
            foo: #M2
            foo=: #M8
  requirements
    topLevels
      dart:core
        double: #M10
        int: #M6
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo=
    expectedId: #M3
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M4
          methods
            foo: #M2
            foo=: #M8
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_instanceMethod_u1() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.foo(int _);
  int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo(0).foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        declaredConstructors
          foo: #M2
        interface: #M3
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M2
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.foo(double _);
  int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        declaredConstructors
          foo: #M6
        interface: #M3
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        double: #M7
        int: #M4
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: foo
    expectedId: #M2
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M6
          methods
            foo: #M1
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_instanceMethod_u2() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.foo(int _);
  int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo(0).foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        declaredConstructors
          foo: #M2
        interface: #M3
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M2
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.foo(int _);
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M6
        declaredConstructors
          foo: #M2
        interface: #M7
          map
            foo: #M6
  requirements
    topLevels
      dart:core
        double: #M8
        int: #M4
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M2
          methods
            foo: #M6
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_invocation() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.named(int _);
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.named(0);
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M4
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            named: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.named(double _);
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M5
        interface: #M2
  requirements
    topLevels
      dart:core
        double: #M6
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: named
    expectedId: #M1
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            named: #M5
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_invocation_add() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.c1();
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.c2();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      32 +2 UNDEFINED_METHOD
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
        interface: #M2
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M3
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            c2: <null>
          requestedMethods
            c2: <null>
    interfaces
      package:test/a.dart
        A
          constructors
            c2: <null>
[status] idle
''',
      updatedA: r'''
class A {
  A.c1();
  A.c2();
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M4
        interface: #M2
  requirements
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: c2
    expectedId: <null>
    actualId: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            c2: #M4
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_invocation_notUsed() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.c1();
  A.c2(int _);
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.c1();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            c1: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.c1();
  A.c2(double _);
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M6
        interface: #M3
  requirements
    topLevels
      dart:core
        double: #M7
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_invocation_remove() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.c1();
  A.c2();
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.c2();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M4
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            c2: #M2
[status] idle
''',
      updatedA: r'''
class A {
  A.c1();
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
        interface: #M3
  requirements
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      32 +2 UNDEFINED_METHOD
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: c2
    expectedId: #M2
    actualId: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            c2: <null>
          requestedMethods
            c2: <null>
    interfaces
      package:test/a.dart
        A
          constructors
            c2: <null>
[status] idle
''',
    );
  }

  test_dependency_class_constructor_named_superInvocation() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.named(int _);
}
''',
      testCode: r'''
import 'a.dart';
class B extends A {
  B.foo() : super.named(0);
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M4
        declaredConstructors
          foo: #M5
        interface: #M6
  requirements
    topLevels
      dart:core
        A: <null>
        named: <null>
      package:test/a.dart
        A: #M0
        named: <null>
    interfaces
      package:test/a.dart
        A
          interfaceId: #M2
          constructors
            named: #M1
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
        named: <null>
      package:test/a.dart
        A: #M0
        named: <null>
    instances
      package:test/a.dart
        A
    interfaces
      package:test/a.dart
        A
          constructors
            named: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.named(double _);
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M7
        interface: #M2
  requirements
    topLevels
      dart:core
        double: #M8
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: named
    expectedId: #M1
    actualId: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M4
        declaredConstructors
          foo: #M5
        interface: #M6
  requirements
    topLevels
      dart:core
        A: <null>
        named: <null>
      package:test/a.dart
        A: #M0
        named: <null>
    interfaces
      package:test/a.dart
        A
          interfaceId: #M2
          constructors
            named: #M7
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: named
    expectedId: #M1
    actualId: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
        named: <null>
      package:test/a.dart
        A: #M0
        named: <null>
    instances
      package:test/a.dart
        A
    interfaces
      package:test/a.dart
        A
          constructors
            named: #M7
[status] idle
''',
    );
  }

  test_dependency_class_constructor_unnamed() async {
    configuration
      ..includeDefaultConstructors()
      ..withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A(int _);
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A(0);
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          new: #M1
        interface: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M4
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            new: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A(double _);
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          new: #M5
        interface: #M2
  requirements
    topLevels
      dart:core
        double: #M6
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: new
    expectedId: #M1
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            new: #M5
[status] idle
''',
    );
  }

  test_dependency_class_declared_constructor() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInterfaceElement('A');
      A.getNamedConstructor('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.foo(int _);
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.foo(double _);
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M4
        interface: #M2
  requirements
    topLevels
      dart:core
        double: #M5
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: foo
    expectedId: #M1
    actualId: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M4
[status] idle
''',
    );
  }

  test_dependency_class_declared_constructor_notUsed() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInterfaceElement('A');
      A.getNamedConstructor('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.foo(int _);
  A.bar(int _);
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          bar: #M1
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A {
  A.foo(int _);
  A.bar(double _);
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          bar: #M5
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        double: #M6
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_declared_field() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getField('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  final int foo = 0;
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A {
  final double foo = 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
  requirements
    topLevels
      dart:core
        double: #M8
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M5
[status] idle
''',
    );
  }

  test_dependency_class_declared_field_notUsed() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getField('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  final int foo = 0;
  final int bar = 0;
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A {
  final int foo = 0;
  final double bar = 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M7
          foo: #M2
        declaredGetters
          bar: #M8
          foo: #M4
        interface: #M9
          map
            bar: #M8
            foo: #M4
  requirements
    topLevels
      dart:core
        double: #M10
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_declared_getter() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getGetter('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int get foo => 0;
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A {
  double get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
  requirements
    topLevels
      dart:core
        double: #M8
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M2
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: #M6
[status] idle
''',
    );
  }

  test_dependency_class_declared_getter_notUsed() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getGetter('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int get foo => 0;
  int get bar => 0;
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: #M4
[status] idle
''',
      updatedA: r'''
class A {
  int get foo => 0;
  double get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M7
          foo: #M2
        declaredGetters
          bar: #M8
          foo: #M4
        interface: #M9
          map
            bar: #M8
            foo: #M4
  requirements
    topLevels
      dart:core
        double: #M10
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_declared_method() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getMethod('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedMethods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
  requirements
    topLevels
      dart:core
        double: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedMethods
            foo: #M4
[status] idle
''',
    );
  }

  test_dependency_class_declared_method_notUsed() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getMethod('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int foo() {}
  int bar() {}
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
          map
            bar: #M1
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedMethods
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A {
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M2
        interface: #M6
          map
            bar: #M5
            foo: #M2
  requirements
    topLevels
      dart:core
        double: #M7
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_declared_methods_add() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.methods;
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  void foo() {}
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredMethods: #M1
[status] idle
''',
      updatedA: r'''
class A {
  void foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceChildrenIdsMismatch
    libraryUri: package:test/a.dart
    instanceName: A
    childrenPropertyName: methods
    expectedIds: #M1
    actualIds: #M1 #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredMethods: #M1 #M3
[status] idle
''',
    );
  }

  test_dependency_class_declared_setter() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getSetter('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedSetters
            foo=: #M2
[status] idle
''',
      updatedA: r'''
class A {
  set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo=: #M6
  requirements
    topLevels
      dart:core
        double: #M8
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo=
    expectedId: #M2
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedSetters
            foo=: #M6
[status] idle
''',
    );
  }

  test_dependency_class_declared_setter_notUsed() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getSetter('foo');
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  set foo(int _) {}
  set bar(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredSetters
          bar=: #M3
          foo=: #M4
        interface: #M5
          map
            bar=: #M3
            foo=: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedSetters
            foo=: #M4
[status] idle
''',
      updatedA: r'''
class A {
  set foo(int _) {}
  set bar(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M7
          foo: #M2
        declaredSetters
          bar=: #M8
          foo=: #M4
        interface: #M9
          map
            bar=: #M8
            foo=: #M4
  requirements
    topLevels
      dart:core
        double: #M10
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_getter_inherited_fromGeneric_extends_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  T get foo {}
}

class B extends A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A<T> {
  T get foo {}
}

class B extends A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M8
        interface: #M9
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
    );
  }

  test_dependency_class_getter_inherited_fromGeneric_implements_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  T get foo {}
}

class B implements A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A<T> {
  T get foo {}
}

class B implements A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M8
        interface: #M9
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
    );
  }

  test_dependency_class_getter_inherited_fromGeneric_with_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  T get foo {}
}

class B with A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A<T> {
  T get foo {}
}

class B with A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M8
        interface: #M9
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
    );
  }

  test_dependency_class_getter_inherited_private() async {
    // Test that there is a dependency between `f()` and `A._foo`.
    // So, that we re-analyze `f()` body when `A._foo` changes.
    // Currently this dependency is implicit: we analyze the whole library
    // when any of its files changes.
    configuration.withStreamResolvedUnitResults = false;

    newFile(testFile.path, r'''
class A {
  int get _foo => 0;
}

class B extends A {}

void f (B b) {
  b._foo.isEven;
}
''');

    await _runChangeScenario(
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
        declaredGetters
          _foo: #M2
        interface: #M3
      B: #M4
        interface: #M5
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        int: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        int: #M7
[status] idle
''',
      updateFiles: () {
        modifyFile2(testFile, r'''
class A {
  String get _foo => '';
}

class B extends A {}

void f (B b) {
  b._foo.isEven;
}
''');
        return [testFile];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M8
        declaredGetters
          _foo: #M9
        interface: #M3
      B: #M4
        interface: #M5
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        String: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      84 +6 UNDEFINED_GETTER
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        String: #M10
[status] idle
''',
    );
  }

  test_dependency_class_getter_returnType() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int get foo => 0;
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A {
  double get foo => 1.2;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        interface: #M8
          map
            foo: #M7
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M6
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M7
[status] idle
''',
    );
  }

  test_dependency_class_getter_returnType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int get foo => 0;
  int get bar => 0;
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M2
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M4
[status] idle
''',
      updatedA: r'''
class A {
  int get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M2
        declaredGetters
          foo: #M4
        interface: #M8
          map
            foo: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_interface_addMethod() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  void foo() {}
}
''',
      testCode: r'''
import 'a.dart';
class B extends A {}
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    classes
      class B
        supertype: A
        constructors
          synthetic new
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M3
        interface: #M4
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          interfaceId: #M2
[status] idle
''',
      updatedA: r'''
class A {
  void foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
  requirements
[future] getLibraryByUri T2
  library
    classes
      class B
        supertype: A
        constructors
          synthetic new
[operation] cannotReuseLinkedBundle
  interfaceIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    expectedId: #M2
    actualId: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          interfaceId: #M6
[status] idle
''',
    );
  }

  test_dependency_class_it_add() async {
    await _runChangeScenarioTA(
      initialA: '',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] linkLibraryCycle
  package:test/a.dart
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[status] idle
''',
      updatedA: r'''
class A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M1
        interface: #M2
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: <null>
    actualId: #M1
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M3
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M1
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: <null>
    actualId: #M1
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M1
[status] idle
''',
    );
  }

  test_dependency_class_it_add_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {}
''',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
class A {}
class B {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M3
        interface: #M4
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_it_change() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {}
class B {}
''',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M4
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
class A extends B {}
class B {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M5
        interface: #M6
      B: #M2
        interface: #M3
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M7
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M5
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M5
[status] idle
''',
    );
  }

  test_dependency_class_it_change_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {}
class B {}
class C {}
''',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M6
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
class A {}
class B extends C {}
class C {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M7
        interface: #M8
      C: #M4
        interface: #M5
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_it_remove() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {}
''',
      testCode: r'''
import 'a.dart';
A foo() => throw 0;
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: '',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: <null>
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M3
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[status] idle
''',
    );
  }

  test_dependency_class_it_remove_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {}
class B {}
''',
      testCode: r'''
import 'a.dart';
A foo() => throw 0;
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M4
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
class A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_method_add() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_METHOD
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
      updatedA: r'''
class A {
  int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
  requirements
    topLevels
      dart:core
        int: #M5
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: <null>
    actualId: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M3
[status] idle
''',
    );
  }

  test_dependency_class_method_inherited_fromGeneric_extends2_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  T foo() {}
}

class B extends A<int> {}

class C extends B {}
''',
      testCode: r'''
import 'a.dart';
void f(C c) {
  c.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
      C: #M5
        interface: #M6
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M8
  requirements
    topLevels
      dart:core
        C: <null>
      package:test/a.dart
        C: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        C: <null>
      package:test/a.dart
        C: #M5
    interfaces
      package:test/a.dart
        C
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A<T> {
  T foo() {}
}

class B extends A<double> {}

class C extends B {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M9
        interface: #M10
          map
            foo: #M1
      C: #M11
        interface: #M12
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        double: #M13
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: C
    expectedId: #M5
    actualId: #M11
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M14
  requirements
    topLevels
      dart:core
        C: <null>
      package:test/a.dart
        C: #M11
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: C
    expectedId: #M5
    actualId: #M11
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        C: <null>
      package:test/a.dart
        C: #M11
    interfaces
      package:test/a.dart
        C
          methods
            foo: #M1
[status] idle
''',
    );
  }

  test_dependency_class_method_inherited_fromGeneric_extends_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  T foo() {}
}

class B extends A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A<T> {
  T foo() {}
}

class B extends A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M7
        interface: #M8
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M10
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
    );
  }

  test_dependency_class_method_inherited_fromGeneric_implements_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  T foo() {}
}

class B implements A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A<T> {
  T foo() {}
}

class B implements A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M7
        interface: #M8
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M10
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
    );
  }

  test_dependency_class_method_inherited_fromGeneric_with_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  T foo() {}
}

class B with A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A<T> {
  T foo() {}
}

class B with A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M7
        interface: #M8
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M10
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
    );
  }

  test_dependency_class_method_inherited_private() async {
    // Test that there is a dependency between `f()` and `A._foo`.
    // So, that we re-analyze `f()` body when `A._foo` changes.
    // Currently this dependency is implicit: we analyze the whole library
    // when any of its files changes.
    configuration.withStreamResolvedUnitResults = false;

    newFile(testFile.path, r'''
class A {
  int _foo() => 0;
}

class B extends A {}

void f (B b) {
  b._foo().isEven;
}
''');

    await _runChangeScenario(
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
      B: #M3
        interface: #M4
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        int: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        int: #M6
[status] idle
''',
      updateFiles: () {
        modifyFile2(testFile, r'''
class A {
  String _foo() => '';
}

class B extends A {}

void f (B b) {
  b._foo().isEven;
}
''');
        return [testFile];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M7
        interface: #M2
      B: #M3
        interface: #M4
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        String: #M8
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      84 +6 UNDEFINED_GETTER
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        String: #M8
[status] idle
''',
    );
  }

  test_dependency_class_method_private() async {
    configuration.withStreamResolvedUnitResults = false;

    newFile(testFile.path, r'''
class A {
  int _foo() => 0;
}

class B extends A {}

void f(B b) {
  b._foo();
}
''');

    // Note:
    // 1. No `_foo` in `B`, even though it is in the same library.
    // 2. No dependency of `test.dart` on `_foo` through `B`.
    // However: we reanalyze `test.dart` when we change it, because we
    // always analyze the whole library when one of its files changes.
    // So, we don't need a separate dependency on `_foo`.
    await _runChangeScenario(
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
      B: #M3
        interface: #M4
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        int: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        int: #M6
[status] idle
''',
      updateFiles: () {
        modifyFile2(testFile, r'''
class A {
  double _foo() => 0;
}

class B extends A {}

void f(B b) {
  b._foo();
}
''');
        return [testFile];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M7
        interface: #M2
      B: #M3
        interface: #M4
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        double: #M8
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        double: #M8
[status] idle
''',
    );
  }

  test_dependency_class_method_private2() async {
    configuration.withStreamResolvedUnitResults = false;

    newFile('$testPackageLibPath/a.dart', r'''
import 'test.dart';

class B extends A {}
''');

    newFile(testFile.path, r'''
import 'a.dart';

class A {
  void _foo() {}
}

void f(B b) {
  b._foo();
}
''');

    // Note:
    // 1. No `_foo` in `B`.
    // 2. No dependency of `test.dart` on `_foo` through `B`.
    // However: we reanalyze `test.dart` when we change it, because we
    // always analyze the whole library when one of its files changes.
    // So, we don't need a separate dependency on `_foo`.
    await _runChangeScenario(
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      B: #M0
        interface: #M1
  package:test/test.dart
    declaredClasses
      A: #M2
        declaredMethods
          _foo: #M3
        interface: #M4
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
        B: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(testFile, r'''
import 'a.dart';

class A {
  void _bar() {}
}

void f(B b) {
  b._foo();
}
''');
        return [testFile];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      B: #M0
        interface: #M1
  package:test/test.dart
    declaredClasses
      A: #M2
        declaredMethods
          _bar: #M6
        interface: #M4
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
        B: <null>
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      66 +4 UNDEFINED_METHOD
      35 +4 UNUSED_ELEMENT
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M0
    instances
      package:test/a.dart
        B
          requestedGetters
            _foo: <null>
          requestedMethods
            _foo: <null>
[status] idle
''',
    );
  }

  test_dependency_class_method_remove() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  void foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M3
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M4
  requirements
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_METHOD
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
    );
  }

  test_dependency_class_method_returnType() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M4
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
class A {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo: #M5
  requirements
    topLevels
      dart:core
        double: #M7
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M5
[status] idle
''',
    );
  }

  test_dependency_class_method_returnType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int foo() {}
  int bar() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
          map
            bar: #M1
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
class A {
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M6
          foo: #M2
        interface: #M7
          map
            bar: #M6
            foo: #M2
  requirements
    topLevels
      dart:core
        double: #M8
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_setter_add() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedSetters
            foo=: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
      updatedA: r'''
class A {
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M3
        declaredSetters
          foo=: #M4
        interface: #M5
          map
            foo=: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo=
    expectedId: <null>
    actualId: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M3
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M4
[status] idle
''',
    );
  }

  test_dependency_class_setter_inherited_fromGeneric_extends_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  set foo(T _) {}
}

class B extends A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
class A<T> {
  set foo(T _) {}
}

class B extends A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M8
        interface: #M9
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
    );
  }

  test_dependency_class_setter_inherited_fromGeneric_implements_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  set foo(T _) {}
}

class B implements A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
class A<T> {
  set foo(T _) {}
}

class B implements A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M8
        interface: #M9
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
    );
  }

  test_dependency_class_setter_inherited_fromGeneric_with_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A<T> {
  set foo(T _) {}
}

class B with A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
class A<T> {
  set foo(T _) {}
}

class B with A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M8
        interface: #M9
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
    );
  }

  test_dependency_class_setter_inherited_private() async {
    // Test that there is a dependency between `f()` and `A._foo`.
    // So, that we re-analyze `f()` body when `A._foo` changes.
    // Currently this dependency is implicit: we analyze the whole library
    // when any of its files changes.
    configuration.withStreamResolvedUnitResults = false;

    newFile(testFile.path, r'''
class A {
  set _foo(int _) {}
}

class B extends A {}

void f (B b) {
  b._foo = 0;
}
''');

    await _runChangeScenario(
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
        declaredSetters
          _foo=: #M2
        interface: #M3
      B: #M4
        interface: #M5
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        int: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        int: #M7
[status] idle
''',
      updateFiles: () {
        modifyFile2(testFile, r'''
class A {
  set _foo(String _) {}
}

class B extends A {}

void f (B b) {
  b._foo = 0;
}
''');
        return [testFile];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M8
        declaredSetters
          _foo=: #M9
        interface: #M3
      B: #M4
        interface: #M5
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        String: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      85 +1 INVALID_ASSIGNMENT
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        String: #M10
[status] idle
''',
    );
  }

  test_dependency_class_setter_remove() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
class A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M6
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedSetters
            foo=: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
    );
  }

  test_dependency_class_setter_valueType() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
class A {
  set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo=: #M7
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M6
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M7
[status] idle
''',
    );
  }

  test_dependency_class_static_getter() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  static int get foo {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
          requestedGetters
            foo: #M2
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
      updatedA: r'''
class A {
  static double get foo {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        interface: #M3
  requirements
    topLevels
      dart:core
        double: #M8
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M6
          requestedGetters
            foo: #M7
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
    );
  }

  test_dependency_class_static_getter_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  static int get foo {}
  static int get bar {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
        interface: #M5
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M2
          requestedGetters
            foo: #M4
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
      updatedA: r'''
class A {
  static int get foo {}
  static double get bar {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M8
          foo: #M2
        declaredGetters
          bar: #M9
          foo: #M4
        interface: #M5
  requirements
    topLevels
      dart:core
        double: #M10
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_static_method() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  static int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M4
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: #M1
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
      updatedA: r'''
class A {
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M5
        interface: #M2
  requirements
    topLevels
      dart:core
        double: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: #M5
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
    );
  }

  test_dependency_class_static_method_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  static int foo() {}
  static int bar() {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: #M2
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
      updatedA: r'''
class A {
  static int foo() {}
  static double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M6
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        double: #M7
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_class_static_setter() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  static set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
          requestedSetters
            foo=: #M2
[status] idle
''',
      updatedA: r'''
class A {
  static set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M3
  requirements
    topLevels
      dart:core
        double: #M8
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M6
          requestedSetters
            foo=: #M7
[status] idle
''',
    );
  }

  test_dependency_class_static_setter_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  static set foo(int _) {}
  static set bar(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredSetters
          bar=: #M3
          foo=: #M4
        interface: #M5
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M2
          requestedSetters
            foo=: #M4
[status] idle
''',
      updatedA: r'''
class A {
  static set foo(int _) {}
  static set bar(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M8
          foo: #M2
        declaredSetters
          bar=: #M9
          foo=: #M4
        interface: #M5
  requirements
    topLevels
      dart:core
        double: #M10
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_classTypaAlias_constructor_named() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.named(int _);
}
mixin M {}
class B = A with M;
''',
      testCode: r'''
import 'a.dart';
void f() {
  B.named(0);
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
      B: #M3
        inheritedConstructors
          named: #M1
        interface: #M4
    declaredMixins
      M: #M5
        interface: #M6
  requirements
    topLevels
      dart:core
        int: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M8
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        B
          constructors
            named: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.named(double _);
}
mixin M {}
class B = A with M;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M9
        interface: #M2
      B: #M3
        inheritedConstructors
          named: #M9
        interface: #M4
    declaredMixins
      M: #M5
        interface: #M6
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: B
    constructorName: named
    expectedId: #M1
    actualId: #M9
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        B
          constructors
            named: #M9
[status] idle
''',
    );
  }

  test_dependency_enum_constant_argument() async {
    await _runChangeScenarioTA(
      initialA: r'''
enum A {
  foo(0);
  const A(int _)
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredEnums
      A: #M0
        declaredFields
          foo: #M1
          values: #M2
        declaredGetters
          foo: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
  requirements
    topLevels
      dart:core
        int: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M8
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
          requestedGetters
            foo: #M3
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
      updatedA: r'''
enum A {
  foo(1);
  const A(int _)
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredEnums
      A: #M0
        declaredFields
          foo: #M9
          values: #M10
        declaredGetters
          foo: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
  requirements
    topLevels
      dart:core
        int: #M7
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M9
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M9
          requestedGetters
            foo: #M3
    interfaces
      package:test/a.dart
        A
          constructors
            foo: <null>
[status] idle
''',
    );
  }

  test_dependency_enum_method_returnType() async {
    await _runChangeScenarioTA(
      initialA: r'''
enum A {
  v;
  int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo: #M5
            index: #M7
  requirements
    topLevels
      dart:core
        int: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M9
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M5
[status] idle
''',
      updatedA: r'''
enum A {
  v;
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          foo: #M10
        interface: #M11
          map
            foo: #M10
            index: #M7
  requirements
    topLevels
      dart:core
        double: #M12
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M5
    actualId: #M10
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M10
[status] idle
''',
    );
  }

  test_dependency_enum_method_returnType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
enum A {
  v;
  int foo() {}
  int bar() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          bar: #M5
          foo: #M6
        interface: #M7
          map
            bar: #M5
            foo: #M6
            index: #M8
  requirements
    topLevels
      dart:core
        int: #M9
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M10
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M6
[status] idle
''',
      updatedA: r'''
enum A {
  v;
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          bar: #M11
          foo: #M6
        interface: #M12
          map
            bar: #M11
            foo: #M6
            index: #M8
  requirements
    topLevels
      dart:core
        double: #M13
        int: #M9
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_class_excludePrivate() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
class _B {}
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
    exportNamespace
      A: package:test/a.dart::@class::A
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      _B: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      A: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            A: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
class A {}
class _B2 {}
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      _B2: #M4
        interface: #M5
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
    exportNamespace
      A: package:test/a.dart::@class::A
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_class_localHidesExport_addHidden() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
class B {}
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
class B {}
class C {}
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    classes
      class B
        constructors
          synthetic new
      class C
        constructors
          synthetic new
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
      declared <testLibrary>::@class::B
      declared <testLibrary>::@class::C
    exportNamespace
      A: package:test/a.dart::@class::A
      B: <testLibrary>::@class::B
      C: <testLibrary>::@class::C
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M4
        interface: #M5
      C: #M6
        interface: #M7
    reExportMap
      A: #M0
  requirements
    exportRequirements
      package:test/test.dart
        declaredTopNames: B C
        exports
          package:test/a.dart
            A: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
class A {}
class B {}
class C {}
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M8
        interface: #M9
  requirements
[future] getLibraryByUri T2
  library
    classes
      class B
        constructors
          synthetic new
      class C
        constructors
          synthetic new
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
      declared <testLibrary>::@class::B
      declared <testLibrary>::@class::C
    exportNamespace
      A: package:test/a.dart::@class::A
      B: <testLibrary>::@class::B
      C: <testLibrary>::@class::C
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_class_localHidesExport_addNotHidden() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
class B {}
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
class B {}
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    classes
      class B
        constructors
          synthetic new
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
      declared <testLibrary>::@class::B
    exportNamespace
      A: package:test/a.dart::@class::A
      B: <testLibrary>::@class::B
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M4
        interface: #M5
    reExportMap
      A: #M0
  requirements
    exportRequirements
      package:test/test.dart
        declaredTopNames: B
        exports
          package:test/a.dart
            A: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
class A {}
class B {}
class C {}
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M6
        interface: #M7
  requirements
[future] getLibraryByUri T2
  library
    classes
      class B
        constructors
          synthetic new
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
      exported[(0, 0)] package:test/a.dart::@class::C
      declared <testLibrary>::@class::B
    exportNamespace
      A: package:test/a.dart::@class::A
      B: <testLibrary>::@class::B
      C: package:test/a.dart::@class::C
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/test.dart
    exportedUri: package:test/a.dart
    name: C
    expectedId: <null>
    actualId: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M4
        interface: #M5
    reExportMap
      A: #M0
      C: #M6
  requirements
    exportRequirements
      package:test/test.dart
        declaredTopNames: B
        exports
          package:test/a.dart
            A: #M0
            C: #M6
[status] idle
''',
    );
  }

  test_dependency_export_class_reExport_combinatorShow() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
export 'a.dart' show A;
class B {}
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'b.dart';
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
      exported[(0, 0)] package:test/b.dart::@class::B
    exportNamespace
      A: package:test/a.dart::@class::A
      B: package:test/b.dart::@class::B
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/b.dart
    declaredClasses
      B: #M2
        interface: #M3
    reExportMap
      A: #M0
  requirements
    exportRequirements
      package:test/b.dart
        declaredTopNames: B
        exports
          package:test/a.dart
            combinators
              show A
            A: #M0
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      A: #M0
      B: #M2
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/b.dart
            A: #M0
            B: #M2
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
class A {}
class A2 {}
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
      A2: #M4
        interface: #M5
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@class::A
      exported[(0, 0)] package:test/b.dart::@class::B
    exportNamespace
      A: package:test/a.dart::@class::A
      B: package:test/b.dart::@class::B
[operation] readLibraryCycleBundle
  package:test/b.dart
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_noLibrary() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
export ':';
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 1;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_add() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final b = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
      exported[(0, 0)] package:test/a.dart::@getter::b
    exportNamespace
      a: package:test/a.dart::@getter::a
      b: package:test/a.dart::@getter::b
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/test.dart
    exportedUri: package:test/a.dart
    name: b
    expectedId: <null>
    actualId: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
      b: #M2
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
            b: #M2
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_add_combinators_hide_false() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart' hide b;
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              hide b
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final b = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_add_combinators_hide_true() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart' hide c;
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              hide c
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final b = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
      exported[(0, 0)] package:test/a.dart::@getter::b
    exportNamespace
      a: package:test/a.dart::@getter::a
      b: package:test/a.dart::@getter::b
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/test.dart
    exportedUri: package:test/a.dart
    name: b
    expectedId: <null>
    actualId: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
      b: #M2
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              hide c
            a: #M0
            b: #M2
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_add_combinators_show_false() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart' show a;
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              show a
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final b = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_add_combinators_show_true() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart' show a, b;
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              show a, b
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final b = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
      exported[(0, 0)] package:test/a.dart::@getter::b
    exportNamespace
      a: package:test/a.dart::@getter::a
      b: package:test/a.dart::@getter::b
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/test.dart
    exportedUri: package:test/a.dart
    name: b
    expectedId: <null>
    actualId: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
      b: #M2
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              show a, b
            a: #M0
            b: #M2
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_add_combinators_showHide_true() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart' show a, b hide c;
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              show a, b
              hide c
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final b = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
      exported[(0, 0)] package:test/a.dart::@getter::b
    exportNamespace
      a: package:test/a.dart::@getter::a
      b: package:test/a.dart::@getter::b
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/test.dart
    exportedUri: package:test/a.dart
    name: b
    expectedId: <null>
    actualId: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
      b: #M2
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              show a, b
              hide c
            a: #M0
            b: #M2
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_add_private() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final _b = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      _b: #M2
      a: #M0
    declaredVariables
      _b: #M3
      a: #M1
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_remove() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
final b = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
      exported[(0, 0)] package:test/a.dart::@getter::b
    exportNamespace
      a: package:test/a.dart::@getter::a
      b: package:test/a.dart::@getter::b
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
      b: #M1
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
            b: #M1
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M2
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] cannotReuseLinkedBundle
  exportCountMismatch
    fragmentUri: package:test/test.dart
    exportedUri: package:test/a.dart
    actual: 1
    required: 2
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_remove_show_false() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
final b = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart' show a;
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            combinators
              show a
            a: #M0
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M2
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
    exportNamespace
      a: package:test/a.dart::@getter::a
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_replace() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
final b = 0;
''');

    newFile('$testPackageLibPath/test.dart', r'''
export 'a.dart';
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
      exported[(0, 0)] package:test/a.dart::@getter::b
    exportNamespace
      a: package:test/a.dart::@getter::a
      b: package:test/a.dart::@getter::b
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
      b: #M1
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
            b: #M1
[status] idle
''',
      updateFiles: () {
        modifyFile2(a, r'''
final a = 0;
final c = 0;
''');
        return [a];
      },
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      c: #M4
    declaredVariables
      a: #M2
      c: #M5
  requirements
[future] getLibraryByUri T2
  library
    exportedReferences
      exported[(0, 0)] package:test/a.dart::@getter::a
      exported[(0, 0)] package:test/a.dart::@getter::c
    exportNamespace
      a: package:test/a.dart::@getter::a
      c: package:test/a.dart::@getter::c
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/test.dart
    exportedUri: package:test/a.dart
    name: c
    expectedId: <null>
    actualId: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    reExportMap
      a: #M0
      c: #M4
  requirements
    exportRequirements
      package:test/test.dart
        exports
          package:test/a.dart
            a: #M0
            c: #M4
[status] idle
''',
    );
  }

  test_dependency_export_topLevelVariable_type() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/b.dart', r'''
export 'a.dart';
''');

    // Uses exported `a`.
    newFile('$testPackageLibPath/test.dart', r'''
import 'b.dart';
final x = a;
''');

    configuration.elementTextConfiguration.withExportScope = true;
    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
    exportedReferences
      declared <testLibrary>::@getter::x
    exportNamespace
      x: <testLibrary>::@getter::x
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/b.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/b.dart
        exports
          package:test/a.dart
            a: #M0
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M2
    declaredVariables
      x: #M3
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/b.dart
        a: #M0
[status] idle
''',
      // Change the initializer, now `double`.
      updateFiles: () {
        modifyFile2(a, r'''
final a = 1.2;
''');
        return [a];
      },
      // Linked, `x` has type `double`.
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M4
    declaredVariables
      a: #M5
  requirements
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: double
    exportedReferences
      declared <testLibrary>::@getter::x
    exportNamespace
      x: <testLibrary>::@getter::x
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/b.dart
    exportedUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M4
[operation] linkLibraryCycle
  package:test/b.dart
    reExportMap
      a: #M4
  requirements
    exportRequirements
      package:test/b.dart
        exports
          package:test/a.dart
            a: #M4
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/b.dart
    name: a
    expectedId: #M0
    actualId: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M6
    declaredVariables
      x: #M7
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/b.dart
        a: #M4
[status] idle
''',
    );
  }

  test_dependency_extension_static_method_returnType() async {
    await _runChangeScenarioTA(
      initialA: r'''
extension A on int {
  static int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensions
      A: #M0
        declaredMethods
          foo: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M3
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: #M1
[status] idle
''',
      updatedA: r'''
extension A on int {
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensions
      A: #M0
        declaredMethods
          foo: #M4
  requirements
    topLevels
      dart:core
        double: #M5
        int: #M2
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: #M4
[status] idle
''',
    );
  }

  test_dependency_extension_static_method_returnType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
extension A on int {
  static int foo() {}
  static int bar() {}
}
''',
      testCode: r'''
import 'a.dart';
void f() {
  A.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensions
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M4
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: #M2
[status] idle
''',
      updatedA: r'''
extension A on int {
  static int foo() {}
  static double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensions
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M2
  requirements
    topLevels
      dart:core
        double: #M6
        int: #M3
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_extensionType_method_returnType() async {
    await _runChangeScenarioTA(
      initialA: r'''
extension type A(int it) {
  int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
            it: #M2
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M3
[status] idle
''',
      updatedA: r'''
extension type A(int it) {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          foo: #M7
        interface: #M8
          map
            foo: #M7
            it: #M2
  requirements
    topLevels
      dart:core
        double: #M9
        int: #M5
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M3
    actualId: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M7
[status] idle
''',
    );
  }

  test_dependency_extensionType_method_returnType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
extension type A(int it) {
  int foo() {}
  int bar() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
            it: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M4
[status] idle
''',
      updatedA: r'''
extension type A(int it) {
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          bar: #M8
          foo: #M4
        interface: #M9
          map
            bar: #M8
            foo: #M4
            it: #M2
  requirements
    topLevels
      dart:core
        double: #M10
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_instanceElement_fields_add() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.fields;
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  static final int foo = 0;
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredFields: #M1
[status] idle
''',
      updatedA: r'''
class A {
  static final int foo = 0;
  static final int bar = 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M5
          foo: #M1
        declaredGetters
          bar: #M6
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceChildrenIdsMismatch
    libraryUri: package:test/a.dart
    instanceName: A
    childrenPropertyName: fields
    expectedIds: #M1
    actualIds: #M1 #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredFields: #M1 #M5
[status] idle
''',
    );
  }

  test_dependency_instanceElement_getters_add() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getters;
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  int get foo => 0;
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredGetters: #M2
[status] idle
''',
      updatedA: r'''
class A {
  int get foo => 0;
  int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M5
          foo: #M1
        declaredGetters
          bar: #M6
          foo: #M2
        interface: #M7
          map
            bar: #M6
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceChildrenIdsMismatch
    libraryUri: package:test/a.dart
    instanceName: A
    childrenPropertyName: getters
    expectedIds: #M2
    actualIds: #M2 #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredGetters: #M2 #M6
[status] idle
''',
    );
  }

  test_dependency_instanceElement_methods_add() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.methods;
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  void foo() {}
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredMethods: #M1
[status] idle
''',
      updatedA: r'''
class A {
  void foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceChildrenIdsMismatch
    libraryUri: package:test/a.dart
    instanceName: A
    childrenPropertyName: methods
    expectedIds: #M1
    actualIds: #M1 #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredMethods: #M1 #M3
[status] idle
''',
    );
  }

  test_dependency_instanceElement_setters_add() async {
    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.setters;
    });

    await _runChangeScenarioTA(
      initialA: r'''
class A {
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredSetters: #M2
[status] idle
''',
      updatedA: r'''
class A {
  set foo(int _) {}
  set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M5
          foo: #M1
        declaredSetters
          bar=: #M6
          foo=: #M2
        interface: #M7
          map
            bar=: #M6
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceChildrenIdsMismatch
    libraryUri: package:test/a.dart
    instanceName: A
    childrenPropertyName: setters
    expectedIds: #M2
    actualIds: #M2 #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      7 +8 UNUSED_IMPORT
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredSetters: #M2 #M6
[status] idle
''',
    );
  }

  test_dependency_mixin_getter_inherited_fromGeneric_on_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
mixin A<T> {
  T get foo {}
}

mixin B on A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
mixin A<T> {
  T get foo {}
}

mixin B on A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M8
        interface: #M9
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M2
[status] idle
''',
    );
  }

  test_dependency_mixin_getter_returnType() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {
  int get foo => 0;
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
mixin A {
  double get foo => 1.2;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        interface: #M8
          map
            foo: #M7
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M6
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M7
[status] idle
''',
    );
  }

  test_dependency_mixin_getter_returnType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {
  int get foo => 0;
  int get bar => 0;
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M2
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M4
[status] idle
''',
      updatedA: r'''
mixin A {
  int get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M2
        declaredGetters
          foo: #M4
        interface: #M8
          map
            foo: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_mixin_it_add() async {
    await _runChangeScenarioTA(
      initialA: '',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] linkLibraryCycle
  package:test/a.dart
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[status] idle
''',
      updatedA: r'''
mixin A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M1
        interface: #M2
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: <null>
    actualId: #M1
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M3
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M1
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: <null>
    actualId: #M1
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M1
[status] idle
''',
    );
  }

  test_dependency_mixin_it_add_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {}
''',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
mixin A {}
mixin B {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M3
        interface: #M4
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_mixin_it_change() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {}
mixin B {}
''',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M4
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
mixin A on B {}
mixin B {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M5
        interface: #M6
      B: #M2
        interface: #M3
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M7
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M5
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M5
[status] idle
''',
    );
  }

  test_dependency_mixin_it_change_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {}
mixin B {}
mixin C {}
''',
      testCode: r'''
import 'a.dart';
A foo() {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M6
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
mixin A {}
mixin B on C {}
mixin C {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M7
        interface: #M8
      C: #M4
        interface: #M5
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      19 +3 BODY_MIGHT_COMPLETE_NORMALLY
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_mixin_it_remove() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {}
''',
      testCode: r'''
import 'a.dart';
A foo() => throw 0;
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: '',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: <null>
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M3
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      17 +1 UNDEFINED_CLASS
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: <null>
[status] idle
''',
    );
  }

  test_dependency_mixin_it_remove_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {}
mixin B {}
''',
      testCode: r'''
import 'a.dart';
A foo() => throw 0;
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M4
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
mixin A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_mixin_method_add() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_METHOD
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
      updatedA: r'''
mixin A {
  int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
  requirements
    topLevels
      dart:core
        int: #M5
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: <null>
    actualId: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M3
[status] idle
''',
    );
  }

  test_dependency_mixin_method_inherited_fromGeneric_implements_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
mixin A<T> {
  T foo() {}
}

mixin B implements A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
mixin A<T> {
  T foo() {}
}

mixin B implements A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M7
        interface: #M8
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M10
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
    );
  }

  test_dependency_mixin_method_inherited_fromGeneric_on_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
mixin A<T> {
  T foo() {}
}

mixin B on A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M6
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
mixin A<T> {
  T foo() {}
}

mixin B on A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M7
        interface: #M8
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M10
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M3
    actualId: #M7
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M7
    interfaces
      package:test/a.dart
        B
          methods
            foo: #M1
[status] idle
''',
    );
  }

  test_dependency_mixin_method_remove() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {
  void foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M3
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
mixin A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M4
  requirements
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_METHOD
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
    );
  }

  test_dependency_mixin_method_returnType() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {
  int foo() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M4
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M1
[status] idle
''',
      updatedA: r'''
mixin A {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo: #M5
  requirements
    topLevels
      dart:core
        double: #M7
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo
    expectedId: #M1
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M5
[status] idle
''',
    );
  }

  test_dependency_mixin_method_returnType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {
  int foo() {}
  int bar() {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo();
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
          map
            bar: #M1
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          methods
            foo: #M2
[status] idle
''',
      updatedA: r'''
mixin A {
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M6
          foo: #M2
        interface: #M7
          map
            bar: #M6
            foo: #M2
  requirements
    topLevels
      dart:core
        double: #M8
        int: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_mixin_setter_add() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedSetters
            foo=: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
      updatedA: r'''
mixin A {
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M3
        declaredSetters
          foo=: #M4
        interface: #M5
          map
            foo=: #M4
  requirements
    topLevels
      dart:core
        int: #M6
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceMethodIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    methodName: foo=
    expectedId: <null>
    actualId: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M3
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M4
[status] idle
''',
    );
  }

  test_dependency_mixin_setter_inherited_fromGeneric_on_changeTypeArgument() async {
    configuration.withStreamResolvedUnitResults = false;
    await _runChangeScenarioTA(
      initialA: r'''
mixin A<T> {
  set foo(T _) {}
}

mixin B on A<int> {}
''',
      testCode: r'''
import 'a.dart';
void f(B b) {
  b.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M6
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M7
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M4
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
mixin A<T> {
  set foo(T _) {}
}

mixin B on A<double> {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M8
        interface: #M9
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        double: #M10
[future] getErrors T2
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M11
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: B
    expectedId: #M4
    actualId: #M8
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M8
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        B
          methods
            foo=: #M2
[status] idle
''',
    );
  }

  test_dependency_mixin_setter_remove() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
mixin A {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        interface: #M6
  requirements
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: <null>
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
    errors
      35 +3 UNDEFINED_SETTER
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: <null>
          requestedSetters
            foo=: <null>
          requestedMethods
            foo: <null>
    interfaces
      package:test/a.dart
        A
          methods
            foo: <null>
            foo=: <null>
[status] idle
''',
    );
  }

  test_dependency_mixin_setter_valueType() async {
    await _runChangeScenarioTA(
      initialA: r'''
mixin A {
  set foo(int _) {}
}
''',
      testCode: r'''
import 'a.dart';
void f(A a) {
  a.foo = 0;
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      f: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M2
[status] idle
''',
      updatedA: r'''
mixin A {
  set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo=: #M7
  requirements
    topLevels
      dart:core
        double: #M9
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  instanceFieldIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    fieldName: foo
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M6
    interfaces
      package:test/a.dart
        A
          methods
            foo=: #M7
[status] idle
''',
    );
  }

  test_dependency_topLevelFunction() async {
    await _runChangeScenarioTA(
      initialA: r'''
int foo() {}
''',
      testCode: r'''
import 'a.dart';
final x = foo();
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredFunctions
      foo: #M0
  requirements
    topLevels
      dart:core
        int: #M1
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M2
    declaredVariables
      x: #M3
  requirements
    topLevels
      dart:core
        foo: <null>
      package:test/a.dart
        foo: #M0
[status] idle
''',
      updatedA: r'''
double foo() {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredFunctions
      foo: #M4
  requirements
    topLevels
      dart:core
        double: #M5
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: double
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: foo
    expectedId: #M0
    actualId: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M6
    declaredVariables
      x: #M7
  requirements
    topLevels
      dart:core
        foo: <null>
      package:test/a.dart
        foo: #M4
[status] idle
''',
    );
  }

  test_dependency_topLevelFunction_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
int foo() {}
int bar() {}
''',
      testCode: r'''
import 'a.dart';
final x = foo();
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredFunctions
      bar: #M0
      foo: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        foo: <null>
      package:test/a.dart
        foo: #M1
[status] idle
''',
      updatedA: r'''
int foo() {}
double bar() {}
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredFunctions
      bar: #M5
      foo: #M1
  requirements
    topLevels
      dart:core
        double: #M6
        int: #M2
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_topLevelGetter() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
double get a => 1.2;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M5
    declaredVariables
      a: #M6
  requirements
    topLevels
      dart:core
        double: #M7
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: double
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M8
    declaredVariables
      x: #M9
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M5
[status] idle
''',
    );
  }

  test_dependency_topLevelGetter_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
int get b => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M5
    declaredVariables
      x: #M6
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
int get a => 0;
double get b => 1.2;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M7
    declaredVariables
      a: #M2
      b: #M8
  requirements
    topLevels
      dart:core
        double: #M9
        int: #M4
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_dependency_topLevelVariable() async {
    await _runChangeScenarioTA(
      initialA: r'''
final a = 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M2
    declaredVariables
      x: #M3
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      // Change the initializer, now `double`.
      updatedA: r'''
final a = 1.2;
''',
      // Linked, `x` has type `double`.
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M4
    declaredVariables
      a: #M5
  requirements
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: double
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M6
    declaredVariables
      x: #M7
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M4
[status] idle
''',
    );
  }

  test_dependency_topLevelVariable_exported() async {
    var a = newFile('$testPackageLibPath/a.dart', r'''
final a = 0;
''');

    newFile('$testPackageLibPath/b.dart', r'''
export 'a.dart';
''');

    // Uses exported `a`.
    newFile('$testPackageLibPath/test.dart', r'''
import 'b.dart';
final x = a;
''');

    await _runChangeScenario(
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
[operation] linkLibraryCycle
  package:test/b.dart
    reExportMap
      a: #M0
  requirements
    exportRequirements
      package:test/b.dart
        exports
          package:test/a.dart
            a: #M0
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M2
    declaredVariables
      x: #M3
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/b.dart
        a: #M0
[status] idle
''',
      // Change the initializer, now `double`.
      updateFiles: () {
        modifyFile2(a, r'''
final a = 1.2;
''');
        return [a];
      },
      // Linked, `x` has type `double`.
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M4
    declaredVariables
      a: #M5
  requirements
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: double
[operation] cannotReuseLinkedBundle
  exportIdMismatch
    fragmentUri: package:test/b.dart
    exportedUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M4
[operation] linkLibraryCycle
  package:test/b.dart
    reExportMap
      a: #M4
  requirements
    exportRequirements
      package:test/b.dart
        exports
          package:test/a.dart
            a: #M4
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/b.dart
    name: a
    expectedId: #M0
    actualId: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M6
    declaredVariables
      x: #M7
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/b.dart
        a: #M4
[status] idle
''',
    );
  }

  test_dependency_typeAlias_aliasedType() async {
    await _runChangeScenarioTA(
      initialA: r'''
typedef A = int;
''',
      testCode: r'''
import 'a.dart';
void foo(A _) {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredTypeAliases
      A: #M0
  requirements
    topLevels
      dart:core
        int: #M1
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M2
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
typedef A = double;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredTypeAliases
      A: #M3
  requirements
    topLevels
      dart:core
        double: #M4
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: #M3
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M5
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M3
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: A
    expectedId: #M0
    actualId: #M3
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M3
[status] idle
''',
    );
  }

  test_dependency_typeAlias_aliasedType_notUsed() async {
    await _runChangeScenarioTA(
      initialA: r'''
typedef A = int;
typedef B = int;
''',
      testCode: r'''
import 'a.dart';
void foo(A _) {}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredTypeAliases
      A: #M0
      B: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M3
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
[status] idle
''',
      updatedA: r'''
typedef A = int;
typedef B = double;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredTypeAliases
      A: #M0
      B: #M4
  requirements
    topLevels
      dart:core
        double: #M5
        int: #M2
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_dependency_typeAlias_class_constructor() async {
    await _runChangeScenarioTA(
      initialA: r'''
class A {
  A.named(int _);
}
typedef B = A;
''',
      testCode: r'''
import 'a.dart';
void foo() {
  B.named(0);
}
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
    declaredTypeAliases
      B: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M5
  requirements
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        A
          constructors
            named: #M1
[status] idle
''',
      updatedA: r'''
class A {
  A.named(double _);
}
typedef B = A;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M6
        interface: #M2
    declaredTypeAliases
      B: #M3
  requirements
    topLevels
      dart:core
        double: #M7
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsCannotReuse
  interfaceConstructorIdMismatch
    libraryUri: package:test/a.dart
    interfaceName: A
    constructorName: named
    expectedId: #M1
    actualId: #M6
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        B: <null>
      package:test/a.dart
        B: #M3
    interfaces
      package:test/a.dart
        A
          constructors
            named: #M6
[status] idle
''',
    );
  }

  test_linkedBundleProvider_newBundleKey() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      // Here `k02` is for `dart:core`.
      expectedInitialDriverState: r'''
files
  /home/test/lib/test.dart
    uri: package:test/test.dart
    current
      id: file_0
      kind: library_0
        libraryImports
          library_1 dart:core synthetic
        fileKinds: library_0
        cycle_0
          dependencies: dart:core
          libraries: library_0
          apiSignature_0
      unlinkedKey: k00
libraryCycles
  /home/test/lib/test.dart
    current: cycle_0
      key: k01
    get: []
    put: [k01]
linkedBundleProvider: [k01, k02]
elementFactory
  hasElement
    package:test/test.dart
''',
      // Add a part, this changes the linked bundle key.
      updateFiles: () {
        var a = newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
final b = 0;
''');
        return [a];
      },
      updatedCode: r'''
part 'a.dart';
final a = 0;
''',
      // So, we cannot find the existing library manifest.
      // So, we relink the library, and give new IDs.
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
      b: #M3
    declaredVariables
      a: #M4
      b: #M5
''',
      // Note a new bundle key is generated: k05
      // TODO(scheglov): Here is a memory leak: k01 is still present.
      expectedUpdatedDriverState: r'''
files
  /home/test/lib/a.dart
    uri: package:test/a.dart
    current
      id: file_6
      kind: partOfUriKnown_6
        uriFile: file_0
        library: library_7
      referencingFiles: file_0
      unlinkedKey: k03
  /home/test/lib/test.dart
    uri: package:test/test.dart
    current
      id: file_0
      kind: library_7
        libraryImports
          library_1 dart:core synthetic
        partIncludes
          partOfUriKnown_6
        fileKinds: library_7 partOfUriKnown_6
        cycle_2
          dependencies: dart:core
          libraries: library_7
          apiSignature_1
      unlinkedKey: k04
libraryCycles
  /home/test/lib/test.dart
    current: cycle_2
      key: k05
    get: []
    put: [k01, k05]
linkedBundleProvider: [k01, k02, k05]
elementFactory
  hasElement
    package:test/test.dart
''',
    );
  }

  test_linkedBundleProvider_sameBundleKey() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      expectedInitialDriverState: r'''
files
  /home/test/lib/test.dart
    uri: package:test/test.dart
    current
      id: file_0
      kind: library_0
        libraryImports
          library_1 dart:core synthetic
        fileKinds: library_0
        cycle_0
          dependencies: dart:core
          libraries: library_0
          apiSignature_0
      unlinkedKey: k00
libraryCycles
  /home/test/lib/test.dart
    current: cycle_0
      key: k01
    get: []
    put: [k01]
linkedBundleProvider: [k01, k02]
elementFactory
  hasElement
    package:test/test.dart
''',
      updatedCode: r'''
final a = 0;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
      expectedUpdatedDriverState: r'''
files
  /home/test/lib/test.dart
    uri: package:test/test.dart
    current
      id: file_0
      kind: library_6
        libraryImports
          library_1 dart:core synthetic
        fileKinds: library_6
        cycle_2
          dependencies: dart:core
          libraries: library_6
          apiSignature_1
      unlinkedKey: k03
libraryCycles
  /home/test/lib/test.dart
    current: cycle_2
      key: k01
    get: []
    put: [k01, k01]
linkedBundleProvider: [k01, k02]
elementFactory
  hasElement
    package:test/test.dart
''',
    );
  }

  test_manifest_baseName2_private2() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  void _foo() {}
}
''');

    await _runLibraryManifestScenario(
      initialCode: r'''
import 'a.dart';

class B extends A {
  int get _foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M3
        declaredFields
          _foo: #M4
        declaredGetters
          _foo: #M5
        interface: #M6
''',
      updatedCode: r'''
import 'a.dart';

class B extends A {
  int get _foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M3
        declaredFields
          _foo: #M4
        declaredGetters
          _foo: #M5
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            zzz: #M7
''',
    );
  }

  test_manifest_baseName2_private3() async {
    newFile('$testPackageLibPath/a.dart', r'''
import 'test.dart';

class B extends A {
  void _foo() {}
}
''');

    await _runLibraryManifestScenario(
      initialCode: r'''
import 'a.dart';

class A {
  int get _foo {}
}

class C extends B {
  set _foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      B: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
  package:test/test.dart
    declaredClasses
      A: #M3
        declaredFields
          _foo: #M4
        declaredGetters
          _foo: #M5
        interface: #M6
      C: #M7
        declaredFields
          _foo: #M8
        declaredSetters
          _foo=: #M9
        interface: #M10
''',
      updatedCode: r'''
import 'a.dart';

class A {
  int get _foo {}
}

class C extends B {
  set _foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      B: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
  package:test/test.dart
    declaredClasses
      A: #M3
        declaredFields
          _foo: #M4
        declaredGetters
          _foo: #M5
        interface: #M6
      C: #M7
        declaredFields
          _foo: #M8
        declaredSetters
          _foo=: #M9
        declaredMethods
          zzz: #M11
        interface: #M12
          map
            zzz: #M11
''',
    );
  }

  test_manifest_baseName_declaredConstructor() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          zzz: #M3
        declaredConstructors
          foo: #M1
        interface: #M4
          map
            zzz: #M3
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredConstructor() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  A.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  A.foo();
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          foo: #M3
        interface: #M4
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredMethods
          zzz: #M5
        declaredConstructors
          foo: #M3
        interface: #M6
          map
            foo: #M2
            zzz: #M5
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  int get foo {}
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  int get foo {}
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  A.foo();
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredMethods
          zzz: #M6
        declaredConstructors
          foo: #M4
        interface: #M7
          map
            foo: #M2
            foo=: #M3
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredInstanceSetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  int get foo {}
  set foo(int _) {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  int get foo {}
  set foo(int _) {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredConstructors
          foo: #M8
        interface: #M9
          map
            foo: #M6
            foo=: #M7
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M10
        declaredConstructors
          foo: #M8
        interface: #M11
          map
            foo: #M6
            foo=: #M7
            zzz: #M10
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredSetters
          foo=: #M8
        declaredConstructors
          foo: #M9
        interface: #M10
          map
            foo: #M7
            foo=: #M8
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredSetters
          foo=: #M8
        declaredMethods
          zzz: #M11
        declaredConstructors
          foo: #M9
        interface: #M12
          map
            foo: #M7
            foo=: #M8
            zzz: #M11
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredConstructors
          foo: #M7
        interface: #M8
          map
            foo: #M5
            foo=: #M6
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M9
        declaredConstructors
          foo: #M7
        interface: #M10
          map
            foo: #M5
            foo=: #M6
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredConstructors
          foo: #M8
        interface: #M9
          map
            foo: #M6
            foo=: #M7
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M10
        declaredConstructors
          foo: #M8
        interface: #M11
          map
            foo: #M6
            foo=: #M7
            zzz: #M10
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredStaticSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M5
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M7
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M6
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M8
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M4
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M6
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M5
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M7
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredConstructors
          foo: #M7
        interface: #M8
          map
            foo: #M6
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredMethods
          zzz: #M9
        declaredConstructors
          foo: #M7
        interface: #M10
          map
            foo: #M6
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredConstructors
          foo: #M8
        interface: #M9
          map
            foo: #M7
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredMethods
          zzz: #M10
        declaredConstructors
          foo: #M8
        interface: #M11
          map
            foo: #M7
            foo=: #M3
            zzz: #M10
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredConstructors
          foo: #M6
        interface: #M7
          map
            foo: #M5
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredMethods
          zzz: #M8
        declaredConstructors
          foo: #M6
        interface: #M9
          map
            foo: #M5
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredConstructors
          foo: #M7
        interface: #M8
          map
            foo: #M6
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredMethods
          zzz: #M9
        declaredConstructors
          foo: #M7
        interface: #M10
          map
            foo: #M6
            foo=: #M2
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        declaredConstructors
          foo: #M2
        interface: #M3
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
          zzz: #M4
        declaredConstructors
          foo: #M2
        interface: #M5
          map
            foo: #M1
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  void foo() {}
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  void foo() {}
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_declaredInstanceGetter_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  void foo() {}
  int get foo {}
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  void foo() {}
  int get foo {}
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_declaredInstanceGetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  void foo() {}
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  void foo() {}
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_declaredInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  void foo() {}
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  void foo() {}
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  void foo() {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  void foo() {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_declaredInstanceSetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  void foo() {}
  set foo(int _) {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  void foo() {}
  set foo(int _) {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          foo: #M5
        declaredConstructors
          foo: #M6
        interface: #M7
          map
            foo: #M5
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          foo: #M5
          zzz: #M8
        declaredConstructors
          foo: #M6
        interface: #M9
          map
            foo: #M5
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          foo: #M6
        declaredConstructors
          foo: #M7
        interface: #M8
          map
            foo: #M6
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          foo: #M6
          zzz: #M9
        declaredConstructors
          foo: #M7
        interface: #M10
          map
            foo: #M6
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        declaredConstructors
          foo: #M5
        interface: #M6
          map
            foo: #M4
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
          zzz: #M7
        declaredConstructors
          foo: #M5
        interface: #M8
          map
            foo: #M4
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceMethod_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          foo: #M5
        declaredConstructors
          foo: #M6
        interface: #M7
          map
            foo: #M5
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          foo: #M5
          zzz: #M8
        declaredConstructors
          foo: #M6
        interface: #M9
          map
            foo: #M5
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        declaredConstructors
          foo: #M3
        interface: #M4
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        declaredMethods
          zzz: #M5
        declaredConstructors
          foo: #M3
        interface: #M6
          map
            foo=: #M2
            zzz: #M5
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceSetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  set foo(int _) {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo=: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  set foo(int _) {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredConstructors
          foo: #M7
        interface: #M8
          map
            foo: #M2
            foo=: #M6
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M9
        declaredConstructors
          foo: #M7
        interface: #M10
          map
            foo: #M2
            foo=: #M6
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredConstructors
          foo: #M8
        interface: #M9
          map
            foo: #M2
            foo=: #M7
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M10
        declaredConstructors
          foo: #M8
        interface: #M11
          map
            foo: #M2
            foo=: #M7
            zzz: #M10
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        declaredConstructors
          foo: #M6
        interface: #M7
          map
            foo: #M1
            foo=: #M5
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        declaredMethods
          zzz: #M8
        declaredConstructors
          foo: #M6
        interface: #M9
          map
            foo: #M1
            foo=: #M5
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredInstanceSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredConstructors
          foo: #M7
        interface: #M8
          map
            foo=: #M6
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M9
        declaredConstructors
          foo: #M7
        interface: #M10
          map
            foo=: #M6
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo=: #M1
''',
      updatedCode: r'''
class A {
  A.foo();
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M2
            foo=: #M5
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            foo=: #M7
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M6
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M8
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M1
            foo=: #M4
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            foo=: #M6
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo=: #M5
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M7
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredStaticSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredStaticSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredStaticSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredStaticSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_declaredStaticSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticMethod_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticMethod_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticMethod_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticMethod_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_declaredStaticSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConstructors
          foo: #M5
        interface: #M6
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  B.foo();
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          zzz: #M7
        declaredConstructors
          foo: #M5
        interface: #M8
          map
            foo: #M2
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredConstructor_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConstructors
          foo: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  B.foo();
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          zzz: #M8
        declaredConstructors
          foo: #M6
        interface: #M9
          map
            foo: #M2
            foo=: #M3
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredConstructor_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  B.foo();
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          zzz: #M6
        declaredConstructors
          foo: #M4
        interface: #M7
          map
            foo: #M1
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredConstructor_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConstructors
          foo: #M5
        interface: #M6
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  B.foo();
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          zzz: #M7
        declaredConstructors
          foo: #M5
        interface: #M8
          map
            foo=: #M2
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
          zzz: #M3
        interface: #M4
          map
            []: #M1
            zzz: #M3
''',
    );
  }

  test_manifest_baseName_declaredIndex_declaredIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
  int operator[](_) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          []: #M1
          []=: #M1
        interface: #M2
          map
            []: #M1
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
  int operator[](_) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          []: #M3
          []=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            []: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredIndex_declaredIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
          []=: #M2
        interface: #M3
          map
            []: #M1
            []=: #M2
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
          []=: #M2
          zzz: #M4
        interface: #M5
          map
            []: #M1
            []=: #M2
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredIndex_declaredIndexEq_declaredIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
  operator[]=(_, _) {}
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          []: #M1
          []=: #M1
        interface: #M2
          map
            []: #M1
            []=: #M1
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
  operator[]=(_, _) {}
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          []: #M3
          []=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            []: #M3
            []=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredIndex_declaredIndexEq_inheritedIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
  int operator[](_) {}
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        declaredMethods
          []: #M4
          []=: #M5
        interface: #M6
          map
            []: #M4
            []=: #M5
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
  int operator[](_) {}
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        declaredMethods
          []: #M4
          []=: #M5
          zzz: #M7
        interface: #M8
          map
            []: #M4
            []=: #M5
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredIndex_declaredIndexEq_inheritedIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
  int operator[](_) {}
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        declaredMethods
          []: #M4
          []=: #M5
        interface: #M6
          map
            []: #M4
            []=: #M5
''',
      updatedCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
  int operator[](_) {}
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        declaredMethods
          []: #M4
          []=: #M5
          zzz: #M7
        interface: #M8
          map
            []: #M4
            []=: #M5
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredIndex_inheritedIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
  int operator[](_) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        declaredMethods
          []: #M4
        interface: #M5
          map
            []: #M4
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
  int operator[](_) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        declaredMethods
          []: #M4
          zzz: #M6
        interface: #M7
          map
            []: #M4
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredIndex_inheritedIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
  int operator[](_) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        declaredMethods
          []: #M4
        interface: #M5
          map
            []: #M4
            []=: #M1
''',
      updatedCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
  int operator[](_) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        declaredMethods
          []: #M4
          zzz: #M6
        interface: #M7
          map
            []: #M4
            []=: #M1
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
''',
      updatedCode: r'''
class A {
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
          zzz: #M3
        interface: #M4
          map
            []=: #M1
            zzz: #M3
''',
    );
  }

  test_manifest_baseName_declaredIndexEq_declaredIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
}

class B extends A {
  operator[]=(_, _) {}
  int operator[](_) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        declaredMethods
          []: #M3
          []=: #M4
        interface: #M5
          map
            []: #M3
            []=: #M4
''',
      updatedCode: r'''
class A {
}

class B extends A {
  operator[]=(_, _) {}
  int operator[](_) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        declaredMethods
          []: #M3
          []=: #M4
          zzz: #M6
        interface: #M7
          map
            []: #M3
            []=: #M4
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredIndexEq_declaredIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  operator[]=(_, _) {}
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          []: #M1
          []=: #M1
        interface: #M2
          map
            []=: #M1
''',
      updatedCode: r'''
class A {
  operator[]=(_, _) {}
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          []: #M3
          []=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            []=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredIndexEq_inheritedIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        declaredMethods
          []=: #M4
        interface: #M5
          map
            []: #M1
            []=: #M4
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        declaredMethods
          []=: #M4
          zzz: #M6
        interface: #M7
          map
            []: #M1
            []=: #M4
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredIndexEq_inheritedIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
  operator[]=(_, _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        declaredMethods
          []=: #M4
        interface: #M5
          map
            []=: #M4
''',
      updatedCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
  operator[]=(_, _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        declaredMethods
          []=: #M4
          zzz: #M6
        interface: #M7
          map
            []=: #M4
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M2
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  int get foo {}
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredMethods
          zzz: #M5
        interface: #M6
          map
            foo: #M2
            foo=: #M3
            zzz: #M5
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredInstanceSetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo: #M6
            foo=: #M7
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M6
            foo=: #M7
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredSetters
          foo=: #M8
        interface: #M9
          map
            foo: #M7
            foo=: #M8
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredSetters
          foo=: #M8
        declaredMethods
          zzz: #M10
        interface: #M11
          map
            foo: #M7
            foo=: #M8
            zzz: #M10
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo: #M5
            foo=: #M6
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M5
            foo=: #M6
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredInstanceSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo: #M6
            foo=: #M7
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M6
            foo=: #M7
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredStaticSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M5
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M7
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M6
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M8
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M4
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M6
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_declaredStaticSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M5
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M7
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M6
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        interface: #M8
          map
            foo: #M7
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M7
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M6
          map
            foo: #M5
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M5
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M6
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
          zzz: #M3
        interface: #M4
          map
            foo: #M1
            zzz: #M3
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_declaredInstanceGetter_declaredInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  int get foo {}
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  int get foo {}
  int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_declaredInstanceGetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_declaredInstanceGetter_declaredInstanceSetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  int get foo {}
  set foo(int _) {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  int get foo {}
  set foo(int _) {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_declaredInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_declaredInstanceSetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  set foo(int _) {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
            foo=: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  set foo(int _) {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo: #M3
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo: #M5
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          foo: #M5
          zzz: #M7
        interface: #M8
          map
            foo: #M5
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          foo: #M6
        interface: #M7
          map
            foo: #M6
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          foo: #M6
          zzz: #M8
        interface: #M9
          map
            foo: #M6
            foo=: #M3
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
          zzz: #M6
        interface: #M7
          map
            foo: #M4
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredInstanceMethod_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo: #M5
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          foo: #M5
          zzz: #M7
        interface: #M8
          map
            foo: #M5
            foo=: #M2
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo=: #M2
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceSetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo=: #M1
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredInstanceSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M6
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            foo=: #M6
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredInstanceSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo: #M2
            foo=: #M7
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M7
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredInstanceSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M6
          map
            foo: #M1
            foo=: #M5
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            foo=: #M5
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredInstanceSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo=: #M6
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M6
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo=: #M1
''',
      updatedCode: r'''
class A {
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            foo=: #M3
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo: #M2
            foo=: #M5
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            foo=: #M7
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M6
          foo=: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M6
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredConflicts
          foo: #M8
          foo=: #M8
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M8
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M1
            foo=: #M4
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredConflicts
          foo: #M6
          foo=: #M6
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            foo=: #M6
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredInstanceSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M5
          foo=: #M5
        interface: #M6
          map
            foo=: #M5
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredConflicts
          foo: #M7
          foo=: #M7
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M7
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredStaticSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
''',
      updatedCode: r'''
class A {
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredMethods
          zzz: #M5
        interface: #M6
          map
            zzz: #M5
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredStaticSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredStaticSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredSetters
          foo=: #M8
        interface: #M9
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredSetters
          foo=: #M8
        declaredMethods
          zzz: #M10
        interface: #M11
          map
            foo: #M2
            foo=: #M3
            zzz: #M10
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredStaticSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M1
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_declaredStaticSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo=: #M2
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        interface: #M8
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredGetters
          foo: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M6
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredStaticGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static int get foo {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
          zzz: #M3
        interface: #M4
          map
            zzz: #M3
''',
    );
  }

  test_manifest_baseName_declaredStaticMethod_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          foo: #M5
          zzz: #M7
        interface: #M8
          map
            foo: #M2
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredStaticMethod_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          foo: #M6
        interface: #M7
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          foo: #M6
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            foo=: #M3
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticMethod_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
          zzz: #M6
        interface: #M7
          map
            foo: #M1
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_declaredStaticMethod_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static void foo() {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          foo: #M5
          zzz: #M7
        interface: #M8
          map
            foo=: #M2
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredStaticSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        declaredMethods
          zzz: #M4
        interface: #M5
          map
            zzz: #M4
''',
    );
  }

  test_manifest_baseName_declaredStaticSetter_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_declaredStaticSetter_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredFields
          foo: #M6
        declaredSetters
          foo=: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M2
            foo=: #M3
            zzz: #M9
''',
    );
  }

  test_manifest_baseName_declaredStaticSetter_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M6
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M1
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_declaredStaticSetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  static set foo(int _) {}
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        declaredMethods
          zzz: #M8
        interface: #M9
          map
            foo=: #M2
            zzz: #M8
''',
    );
  }

  test_manifest_baseName_inheritedConstructor() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin M {}

class A {
  A.foo();
}

class B = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
      B: #M3
        inheritedConstructors
          foo: #M1
        interface: #M4
    declaredMixins
      M: #M5
        interface: #M6
''',
      updatedCode: r'''
mixin M {}

class A {
  A.foo();
}

class B = A with M;
class Z {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
      B: #M3
        inheritedConstructors
          foo: #M1
        interface: #M4
      Z: #M7
        interface: #M8
    declaredMixins
      M: #M5
        interface: #M6
''',
    );
  }

  test_manifest_baseName_inheritedConstructor_inheritedConstructor() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin M {}

class A {
  A.foo();
  A.foo();
}

class B = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
      B: #M3
        inheritedConstructors
          foo: #M1
        interface: #M4
    declaredMixins
      M: #M5
        interface: #M6
''',
      updatedCode: r'''
mixin M {}

class A {
  A.foo();
  A.foo();
}

class B = A with M;
class Z {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M7
          foo=: #M7
        interface: #M2
      B: #M3
        inheritedConstructors
          foo: #M7
        interface: #M4
      Z: #M8
        interface: #M9
    declaredMixins
      M: #M5
        interface: #M6
''',
    );
  }

  test_manifest_baseName_inheritedConstructor_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin M {}

class A {
  A.foo();
  int get foo {}
}

class B = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          foo: #M3
        interface: #M4
          map
            foo: #M2
      B: #M5
        inheritedConstructors
          foo: #M3
        interface: #M6
          map
            foo: #M2
    declaredMixins
      M: #M7
        interface: #M8
''',
      updatedCode: r'''
mixin M {}

class A {
  A.foo();
  int get foo {}
}

class B = A with M;
class Z {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          foo: #M3
        interface: #M4
          map
            foo: #M2
      B: #M5
        inheritedConstructors
          foo: #M3
        interface: #M6
          map
            foo: #M2
      Z: #M9
        interface: #M10
    declaredMixins
      M: #M7
        interface: #M8
''',
    );
  }

  test_manifest_baseName_inheritedConstructor_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin M {}

class A {
  A.foo();
  int get foo {}
  set foo(int _) {}
}

class B = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            foo: #M2
            foo=: #M3
      B: #M6
        inheritedConstructors
          foo: #M4
        interface: #M7
          map
            foo: #M2
            foo=: #M3
    declaredMixins
      M: #M8
        interface: #M9
''',
      updatedCode: r'''
mixin M {}

class A {
  A.foo();
  int get foo {}
  set foo(int _) {}
}

class B = A with M;
class Z {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            foo: #M2
            foo=: #M3
      B: #M6
        inheritedConstructors
          foo: #M4
        interface: #M7
          map
            foo: #M2
            foo=: #M3
      Z: #M10
        interface: #M11
    declaredMixins
      M: #M8
        interface: #M9
''',
    );
  }

  test_manifest_baseName_inheritedConstructor_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin M {}

class A {
  A.foo();
  void foo() {}
}

class B = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        declaredConstructors
          foo: #M2
        interface: #M3
          map
            foo: #M1
      B: #M4
        inheritedConstructors
          foo: #M2
        interface: #M5
          map
            foo: #M1
    declaredMixins
      M: #M6
        interface: #M7
''',
      updatedCode: r'''
mixin M {}

class A {
  A.foo();
  void foo() {}
}

class B = A with M;
class Z {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        declaredConstructors
          foo: #M2
        interface: #M3
          map
            foo: #M1
      B: #M4
        inheritedConstructors
          foo: #M2
        interface: #M5
          map
            foo: #M1
      Z: #M8
        interface: #M9
    declaredMixins
      M: #M6
        interface: #M7
''',
    );
  }

  test_manifest_baseName_inheritedConstructor_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin M {}

class A {
  A.foo();
  set foo(int _) {}
}

class B = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        declaredConstructors
          foo: #M3
        interface: #M4
          map
            foo=: #M2
      B: #M5
        inheritedConstructors
          foo: #M3
        interface: #M6
          map
            foo=: #M2
    declaredMixins
      M: #M7
        interface: #M8
''',
      updatedCode: r'''
mixin M {}

class A {
  A.foo();
  set foo(int _) {}
}

class B = A with M;
class Z {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        declaredConstructors
          foo: #M3
        interface: #M4
          map
            foo=: #M2
      B: #M5
        inheritedConstructors
          foo: #M3
        interface: #M6
          map
            foo=: #M2
      Z: #M9
        interface: #M10
    declaredMixins
      M: #M7
        interface: #M8
''',
    );
  }

  test_manifest_baseName_inheritedIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        interface: #M4
          map
            []: #M1
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
        interface: #M2
          map
            []: #M1
      B: #M3
        declaredMethods
          zzz: #M5
        interface: #M6
          map
            []: #M1
            zzz: #M5
''',
    );
  }

  test_manifest_baseName_inheritedIndex_inheritedIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator[](_) {}
  operator[]=(_, _) {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
          []=: #M2
        interface: #M3
          map
            []: #M1
            []=: #M2
      B: #M4
        interface: #M5
          map
            []: #M1
            []=: #M2
''',
      updatedCode: r'''
class A {
  int operator[](_) {}
  operator[]=(_, _) {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
          []=: #M2
        interface: #M3
          map
            []: #M1
            []=: #M2
      B: #M4
        declaredMethods
          zzz: #M6
        interface: #M7
          map
            []: #M1
            []=: #M2
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_inheritedIndexEq() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        interface: #M4
          map
            []=: #M1
''',
      updatedCode: r'''
class A {
  operator[]=(_, _) {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []=: #M1
        interface: #M2
          map
            []=: #M1
      B: #M3
        declaredMethods
          zzz: #M5
        interface: #M6
          map
            []=: #M1
            zzz: #M5
''',
    );
  }

  test_manifest_baseName_inheritedIndexEq_inheritedIndex() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  operator[]=(_, _) {}
  int operator[](_) {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
          []=: #M2
        interface: #M3
          map
            []: #M1
            []=: #M2
      B: #M4
        interface: #M5
          map
            []: #M1
            []=: #M2
''',
      updatedCode: r'''
class A {
  operator[]=(_, _) {}
  int operator[](_) {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          []: #M1
          []=: #M2
        interface: #M3
          map
            []: #M1
            []=: #M2
      B: #M4
        declaredMethods
          zzz: #M6
        interface: #M7
          map
            []: #M1
            []=: #M2
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_inheritedInstanceGetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredMethods
          zzz: #M6
        interface: #M7
          map
            foo: #M2
            zzz: #M6
''',
    );
  }

  test_manifest_baseName_inheritedInstanceGetter_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        interface: #M6
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  int get foo {}
  set foo(int _) {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
      B: #M5
        declaredMethods
          zzz: #M7
        interface: #M8
          map
            foo: #M2
            foo=: #M3
            zzz: #M7
''',
    );
  }

  test_manifest_baseName_inheritedInstanceMethod() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          zzz: #M5
        interface: #M6
          map
            foo: #M1
            zzz: #M5
''',
    );
  }

  test_manifest_baseName_inheritedInstanceSetter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredMethods
          zzz: #M6
        interface: #M7
          map
            foo=: #M2
            zzz: #M6
''',
    );
  }

  test_manifest_class_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
''',
      updatedCode: r'''
class A {}
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_constructor_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
  A.bar();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          bar: #M3
          foo: #M1
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_formalParameter_requiredPositional() async {
    configuration.includeDefaultConstructors();
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo(int a);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo(int a);
  A.bar();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          bar: #M3
          foo: #M1
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_formalParameter_requiredPositional_add() async {
    configuration.includeDefaultConstructors();
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A(int a);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          new: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A(int a, int b);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          new: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A.named(int x);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  const A.named(int x) : assert(x > 0);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_assert() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A.c1(int x) : assert(x > 0);
  const A.c2(int x) : assert(x > 0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  const A.c1(int x) : assert(x > 0);
  const A.c2(int x) : assert(x > 1);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M4
        interface: #M3
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_fieldInitializer_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int foo;
  const A.named() : bar = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          named: #M3
        interface: #M4
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  final int foo;
  const A.named() : foo = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          named: #M5
        interface: #M4
          map
            foo: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_fieldInitializer_value() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int foo;
  const A.named() : foo = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          named: #M3
        interface: #M4
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  final int foo;
  const A.named() : foo = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          named: #M5
        interface: #M4
          map
            foo: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_formalParameter_exchange() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A.named(int x, int y) : assert(x > 0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  const A.named(int y, int x) : assert(x > 0);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_redirect_argument() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int f;
  const A.c1(int a) : f = a;
  const A.c2() : this.c1(0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M4
        interface: #M5
          map
            f: #M2
''',
      updatedCode: r'''
class A {
  final int f;
  const A.c1(int a) : f = a;
  const A.c2() : this.c1(1);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M6
        interface: #M5
          map
            f: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_redirect_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int f;
  const A.c1() : f = 0;
  const A.c2() : f = 1;
  const A.c3() : this.c1();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M4
          c3: #M5
        interface: #M6
          map
            f: #M2
''',
      updatedCode: r'''
class A {
  final int f;
  const A.c1() : f = 0;
  const A.c2() : f = 1;
  const A.c3() : this.c2();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M4
          c3: #M7
        interface: #M6
          map
            f: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A.named(int x) : assert(x > 0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  const A.named(int x);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_super_argument() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A.named(int _);
}

class B extends A {
  const A.named() : super.named(0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
      B: #M3
        declaredConstructors
          named: #M4
        interface: #M5
''',
      updatedCode: r'''
class A {
  const A.named(int _);
}

class B extends A {
  const A.named() : super.named(1);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
      B: #M3
        declaredConstructors
          named: #M6
        interface: #M5
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_super_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int f;
  const A.c1() : f = 0;
  const A.c2() : f = 1;
}

class B extends A {
  const A.named() : super.c1(0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M4
        interface: #M5
          map
            f: #M2
      B: #M6
        declaredConstructors
          named: #M7
        interface: #M8
          map
            f: #M2
''',
      updatedCode: r'''
class A {
  final int f;
  const A.c1() : f = 0;
  const A.c2() : f = 1;
}

class B extends A {
  const A.named() : super.c2(0);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M4
        interface: #M5
          map
            f: #M2
      B: #M6
        declaredConstructors
          named: #M9
        interface: #M8
          map
            f: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_isConst_super_transitive() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int f;
  const A.named() : f = 0;
}

class B extends A {
  const A.named() : super.named();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          named: #M3
        interface: #M4
          map
            f: #M2
      B: #M5
        declaredConstructors
          named: #M6
        interface: #M7
          map
            f: #M2
''',
      updatedCode: r'''
class A {
  final int f;
  const A.named() : f = 1;
}

class B extends A {
  const A.named() : super.named();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          named: #M8
        interface: #M4
          map
            f: #M2
      B: #M5
        declaredConstructors
          named: #M9
        interface: #M7
          map
            f: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_notConst_assert() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.named(int x) : assert(x > 0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.named(int x) : assert(x > 1);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_notConst_fieldInitializer_value() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int foo;
  A.named() : foo = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          named: #M3
        interface: #M4
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  final int foo;
  A.named() : foo = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredConstructors
          named: #M3
        interface: #M4
          map
            foo: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_notConst_redirect_argument() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final int f;
  A.c1(int a) : f = a;
  A.c2() : this.c1(0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M4
        interface: #M5
          map
            f: #M2
''',
      updatedCode: r'''
class A {
  final int f;
  A.c1(int a) : f = a;
  A.c2() : this.c1(1);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          f: #M1
        declaredGetters
          f: #M2
        declaredConstructors
          c1: #M3
          c2: #M4
        interface: #M5
          map
            f: #M2
''',
    );
  }

  test_manifest_class_constructor_initializers_notConst_super_argument() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A.named(int _);
}

class B extends A {
  A.named() : super.named(0);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
      B: #M3
        declaredConstructors
          named: #M4
        interface: #M5
''',
      updatedCode: r'''
class A {
  const A.named(int _);
}

class B extends A {
  A.named() : super.named(1);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
      B: #M3
        declaredConstructors
          named: #M4
        interface: #M5
''',
    );
  }

  test_manifest_class_constructor_isConst_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  const A.foo();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_isConst_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_isFactory_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  factory A.foo();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_isFactory_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  factory A.foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A.foo();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  @Deprected('0')
  A.foo();
  @Deprected('0')
  A.bar();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          bar: #M1
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  @Deprected('1')
  A.foo();
  @Deprected('0')
  A.bar();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          bar: #M1
          foo: #M4
        interface: #M3
''',
    );
  }

  test_manifest_class_constructor_private() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A._foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          _foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  A._foo();
  A.bar();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          _foo: #M1
          bar: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_constructor_private_const() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A._foo();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          _foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  const A._foo();
  A.bar();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          _foo: #M1
          bar: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_extendsAdd_direct() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {}
class B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
class A extends B {}
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M4
        interface: #M5
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_extendsAdd_indirect() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A extends B {}
class B {}
class C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
      updatedCode: r'''
class A extends B {}
class B extends C {}
class C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M6
        interface: #M7
      B: #M8
        interface: #M9
      C: #M4
        interface: #M5
''',
    );
  }

  test_manifest_class_extendsChange() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A extends B {}
class B {}
class C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
      updatedCode: r'''
class A extends C {}
class B {}
class C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M6
        interface: #M7
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
    );
  }

  test_manifest_class_field_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
      updatedCode: r'''
class A {
  final a = 0;
  final b = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M4
        declaredGetters
          a: #M2
          b: #M5
        interface: #M6
          map
            a: #M2
            b: #M5
''',
    );
  }

  test_manifest_class_field_const_initializer() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static const a = 0;
  static const b = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M2
        declaredGetters
          a: #M3
          b: #M4
        interface: #M5
''',
      updatedCode: r'''
class A {
  static const a = 1;
  static const b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M6
          b: #M2
        declaredGetters
          a: #M3
          b: #M4
        interface: #M5
''',
    );
  }

  test_manifest_class_field_initializer_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
      updatedCode: r'''
class A {
  final a = 1.2;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M4
        declaredGetters
          a: #M5
        interface: #M6
          map
            a: #M5
''',
    );
  }

  test_manifest_class_field_initializer_value_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
      updatedCode: r'''
class A {
  final a = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
    );
  }

  test_manifest_class_field_initializer_value_static_const() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static const a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static const a = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M4
        declaredGetters
          a: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_field_initializer_value_static_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static final a = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_field_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  @Deprecated('0')
  var a = 0;
  @Deprecated('0')
  var b = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M2
        declaredGetters
          a: #M3
          b: #M4
        declaredSetters
          a=: #M5
          b=: #M6
        interface: #M7
          map
            a: #M3
            a=: #M5
            b: #M4
            b=: #M6
''',
      updatedCode: r'''
class A {
  @Deprecated('1')
  var a = 0;
  @Deprecated('0')
  var b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M8
          b: #M2
        declaredGetters
          a: #M9
          b: #M4
        declaredSetters
          a=: #M10
          b=: #M6
        interface: #M11
          map
            a: #M9
            a=: #M10
            b: #M4
            b=: #M6
''',
    );
  }

  test_manifest_class_field_private_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  final _a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _a: #M1
        declaredGetters
          _a: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  final _a = 0;
  final b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _a: #M1
          b: #M4
        declaredGetters
          _a: #M2
          b: #M5
        interface: #M6
          map
            b: #M5
''',
    );
  }

  test_manifest_class_field_private_static_const() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static const _a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _a: #M1
        declaredGetters
          _a: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static const _a = 0;
  static const b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _a: #M1
          b: #M4
        declaredGetters
          _a: #M2
          b: #M5
        interface: #M3
''',
    );
  }

  test_manifest_class_field_private_var() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  var _a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _a: #M1
        declaredGetters
          _a: #M2
        declaredSetters
          _a=: #M3
        interface: #M4
''',
      updatedCode: r'''
class A {
  var _a = 0;
  var b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _a: #M1
          b: #M5
        declaredGetters
          _a: #M2
          b: #M6
        declaredSetters
          _a=: #M3
          b=: #M7
        interface: #M8
          map
            b: #M6
            b=: #M7
''',
    );
  }

  test_manifest_class_field_static_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
''',
      updatedCode: r'''
class A {
  static int foo = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
''',
    );
  }

  test_manifest_class_field_static_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
''',
      updatedCode: r'''
class A {
  int foo = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        declaredSetters
          foo=: #M7
        interface: #M8
          map
            foo: #M6
            foo=: #M7
''',
    );
  }

  test_manifest_class_field_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int? a;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        declaredSetters
          a=: #M3
        interface: #M4
          map
            a: #M2
            a=: #M3
''',
      updatedCode: r'''
class A {
  double? a;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M5
        declaredGetters
          a: #M6
        declaredSetters
          a=: #M7
        interface: #M8
          map
            a: #M6
            a=: #M7
''',
    );
  }

  test_manifest_class_getter_add_extends() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo => 0;
}

class B extends A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo => 0;
  int get bar => 0;
}

class B extends A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_class_getter_add_extends_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  T get foo => 0;
}

class B extends A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
class A<T> {
  T get foo => 0;
  T get bar => 0;
}

class B extends A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_class_getter_add_implements() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo => 0;
}

class B implements A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo => 0;
  int get bar => 0;
}

class B implements A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_class_getter_add_implements_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  T get foo => 0;
}

class B implements A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
class A<T> {
  T get foo => 0;
  T get bar => 0;
}

class B implements A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_class_getter_add_with() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo => 0;
}

class B with A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo => 0;
  int get bar => 0;
}

class B with A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_class_getter_add_with_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  T get foo => 0;
}

class B with A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
class A<T> {
  T get foo => 0;
  T get bar => 0;
}

class B with A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_class_getter_combinedSignatures_merged_addUnrelated() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  num get foo;
}

abstract class B {
  int get foo;
}

abstract class C implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
      C: #M8
        interface: #M9
          map
            foo: #M10
          combinedIds
            [#M2, #M6]: #M10
''',
      updatedCode: r'''
abstract class A {
  num get foo;
}

abstract class B {
  int get foo;
}

abstract class C implements A, B {
  void zzz();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
      C: #M8
        declaredMethods
          zzz: #M11
        interface: #M12
          map
            foo: #M10
            zzz: #M11
          combinedIds
            [#M2, #M6]: #M10
''',
    );
  }

  test_manifest_class_getter_combinedSignatures_merged_inherit() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  dynamic get foo;
}

class B {
  void get foo;
}

abstract class C implements A, B {}

abstract class D implements C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
      C: #M8
        interface: #M9
          map
            foo: #M10
          combinedIds
            [#M2, #M6]: #M10
      D: #M11
        interface: #M12
          map
            foo: #M10
''',
      updatedCode: r'''
class A {
  dynamic get foo;
}

class B {
  void get foo;
}

abstract class C implements A, B {
  void xxx() {}
}

abstract class D implements C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredGetters
          foo: #M6
        interface: #M7
          map
            foo: #M6
      C: #M8
        declaredMethods
          xxx: #M13
        interface: #M14
          map
            foo: #M10
            xxx: #M13
          combinedIds
            [#M2, #M6]: #M10
      D: #M11
        interface: #M15
          map
            foo: #M10
            xxx: #M13
''',
    );
  }

  test_manifest_class_getter_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  @Deprecated('0')
  int get foo => 0;
  @Deprecated('0')
  int get bar => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
''',
      updatedCode: r'''
class A {
  @Deprecated('1')
  int get foo => 0;
  @Deprecated('0')
  int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M6
        interface: #M7
          map
            bar: #M3
            foo: #M6
''',
    );
  }

  test_manifest_class_getter_private_instance() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get _foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
        declaredGetters
          _foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  int get _foo => 0;
  int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredGetters
          _foo: #M2
          bar: #M5
        interface: #M6
          map
            bar: #M5
''',
    );
  }

  test_manifest_class_getter_private_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get _foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
        declaredGetters
          _foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static int get _foo => 0;
  int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredGetters
          _foo: #M2
          bar: #M5
        interface: #M6
          map
            bar: #M5
''',
    );
  }

  test_manifest_class_getter_returnType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredFields
          foo: #M1
            type: int @ dart:core
        declaredGetters
          foo: #M2
            returnType: int @ dart:core
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  double get foo => 1.2;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredFields
          foo: #M4
            type: double @ dart:core
        declaredGetters
          foo: #M5
            returnType: double @ dart:core
        interface: #M6
          map
            foo: #M5
''',
    );
  }

  test_manifest_class_getter_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static int get foo => 0;
  static int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M4
          foo: #M1
        declaredGetters
          bar: #M5
          foo: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_getter_static_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  static int get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M6
''',
    );
  }

  test_manifest_class_getter_static_returnType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static double get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M3
''',
    );
  }

  test_manifest_class_getter_static_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  int get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M6
          map
            foo: #M5
''',
    );
  }

  test_manifest_class_getter_toDuplicate_hasInstance_addInstance_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
  double get foo {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M4
''',
    );
  }

  test_manifest_class_getter_toDuplicate_hasInstance_addInstance_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  double get foo {}
  int get foo {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M4
''',
    );
  }

  test_manifest_class_getter_toDuplicate_hasInstance_addStatic_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  int get foo {}
  static double get foo {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M4
''',
    );
  }

  test_manifest_class_getter_toDuplicate_hasInstance_addStatic_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
class A {
  static double get foo {}
  int get foo {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo: #M4
''',
    );
  }

  test_manifest_class_getter_toDuplicate_hasStatic_addStatic_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static int get foo {}
  static double get foo {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M3
''',
    );
  }

  test_manifest_class_getter_toDuplicate_hasStatic_addStatic_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int get foo {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static double get foo {}
  static int get foo {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M3
''',
    );
  }

  test_manifest_class_interfacesAdd() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {}
class B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
class A implements B {}
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M4
        interface: #M5
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_interfacesRemove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A implements B {}
class B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {}
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M4
        interface: #M5
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_interfacesReplace() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A implements B {}
class B {}
class C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
      updatedCode: r'''
class A implements C {}
class B {}
class C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M6
        interface: #M7
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
    );
  }

  test_manifest_class_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
class A {}
@Deprecated('0')
class B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
@Deprecated('0')
class A {}
@Deprecated('1')
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M4
        interface: #M5
''',
    );
  }

  test_manifest_class_method_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_class_method_add_extends() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B extends A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  void bar() {}
}

class B extends A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_class_method_add_extends_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  T foo() {}
}

class B extends A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
class A<T> {
  T foo() {}
  void bar() {}
}

class B extends A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_class_method_add_extends_generic2() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  T foo() {}
}

class B extends A<int> {}

class C extends B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
      C: #M5
        interface: #M6
          map
            foo: #M1
''',
      updatedCode: r'''
class A<T> {
  T foo() {}
  void bar() {}
}

class B extends A<int> {}

class C extends B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M7
          foo: #M1
        interface: #M8
          map
            bar: #M7
            foo: #M1
      B: #M3
        interface: #M9
          map
            bar: #M7
            foo: #M1
      C: #M5
        interface: #M10
          map
            bar: #M7
            foo: #M1
''',
    );
  }

  test_manifest_class_method_add_implements() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B implements A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  void bar() {}
}

class B implements A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_class_method_add_implements_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  T foo() {}
}

class B implements A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
class A<T> {
  T foo() {}
  void bar() {}
}

class B implements A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_class_method_add_with() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}

class B with A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo() {}
  void bar() {}
}

class B with A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_class_method_add_with_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  T foo() {}
}

class B with A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
class A<T> {
  T foo() {}
  void bar() {}
}

class B with A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_class_method_combinedSignatures_conflict_removeOne() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  int foo();
}

abstract class B {
  double foo();
}

abstract class C implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M7
''',
      updatedCode: r'''
abstract class A {
  int foo();
}

abstract class B {}

abstract class C implements A, B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M8
      C: #M6
        interface: #M9
          map
            foo: #M1
''',
    );
  }

  test_manifest_class_method_combinedSignatures_merged_addUnrelated() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  dynamic foo();
}

abstract class B {
  void foo();
}

abstract class C implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M7
          map
            foo: #M8
          combinedIds
            [#M1, #M4]: #M8
''',
      updatedCode: r'''
abstract class A {
  dynamic foo();
}

abstract class B {
  void foo();
  void zzz();
}

abstract class C implements A, B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
          zzz: #M9
        interface: #M10
          map
            foo: #M4
            zzz: #M9
      C: #M6
        interface: #M11
          map
            foo: #M8
            zzz: #M9
          combinedIds
            [#M1, #M4]: #M8
''',
    );
  }

  test_manifest_class_method_combinedSignatures_merged_inherit_backward() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  dynamic foo();
}

class B {
  void foo();
}

abstract class C implements D {}

abstract class D implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M7
          map
            foo: #M8
      D: #M9
        interface: #M10
          map
            foo: #M8
          combinedIds
            [#M1, #M4]: #M8
''',
      updatedCode: r'''
class A {
  dynamic foo();
}

class B {
  void foo();
}

abstract class C implements D {}

abstract class D implements A, B {
  void xxx() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M11
          map
            foo: #M8
            xxx: #M12
      D: #M9
        declaredMethods
          xxx: #M12
        interface: #M13
          map
            foo: #M8
            xxx: #M12
          combinedIds
            [#M1, #M4]: #M8
''',
    );
  }

  test_manifest_class_method_combinedSignatures_merged_inherit_forward() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  dynamic foo();
}

class B {
  void foo();
}

abstract class C implements A, B {}

abstract class D implements C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M7
          map
            foo: #M8
          combinedIds
            [#M1, #M4]: #M8
      D: #M9
        interface: #M10
          map
            foo: #M8
''',
      updatedCode: r'''
class A {
  dynamic foo();
}

class B {
  void foo();
}

abstract class C implements A, B {
  void xxx() {}
}

abstract class D implements C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        declaredMethods
          xxx: #M11
        interface: #M12
          map
            foo: #M8
            xxx: #M11
          combinedIds
            [#M1, #M4]: #M8
      D: #M9
        interface: #M13
          map
            foo: #M8
            xxx: #M11
''',
    );
  }

  test_manifest_class_method_combinedSignatures_merged_removeOne() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  dynamic foo();
}

abstract class B {
  void foo();
}

abstract class C implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M7
          map
            foo: #M8
          combinedIds
            [#M1, #M4]: #M8
''',
      updatedCode: r'''
abstract class A {}

abstract class B {
  void foo();
}

abstract class C implements A, B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M9
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M10
          map
            foo: #M4
''',
    );
  }

  test_manifest_class_method_combinedSignatures_merged_sameBase() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A<T> {
  T foo();
}

abstract class B implements A<dynamic> {}

abstract class C implements A<void> {}

abstract class D implements B, C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
      C: #M5
        interface: #M6
          map
            foo: #M1
      D: #M7
        interface: #M8
          map
            foo: #M1
''',
      updatedCode: r'''
abstract class A<T> {
  T foo();
}

abstract class B implements A<dynamic> {}

abstract class C implements A<void> {}

abstract class D implements B, C {
  void zzz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
      C: #M5
        interface: #M6
          map
            foo: #M1
      D: #M7
        declaredMethods
          zzz: #M9
        interface: #M10
          map
            foo: #M1
            zzz: #M9
''',
    );
  }

  test_manifest_class_method_combinedSignatures_merged_updateOne() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  dynamic foo();
}

abstract class B {
  void foo();
}

abstract class C implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M4
        interface: #M5
          map
            foo: #M4
      C: #M6
        interface: #M7
          map
            foo: #M8
          combinedIds
            [#M1, #M4]: #M8
''',
      updatedCode: r'''
abstract class A {
  dynamic foo();
}

abstract class B {
  int foo();
}

abstract class C implements A, B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        declaredMethods
          foo: #M9
        interface: #M10
          map
            foo: #M9
      C: #M6
        interface: #M11
          map
            foo: #M12
          combinedIds
            [#M1, #M9]: #M12
''',
    );
  }

  test_manifest_class_method_formalParameter_optionalNamed() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo({int a}) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo({int a}) {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_class_method_formalParameter_optionalPositional() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo([int a]) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo([int a]) {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_class_method_formalParameter_requiredNamed() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo({required int a}) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo({required int a}) {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_class_method_formalParameter_requiredNamed_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo({required int a}) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo({required int b}) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_formalParameter_requiredNamed_type() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo({required int a}) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredMethods
          foo: #M1
            functionType: FunctionType
              named
                a: required int @ dart:core
              returnType: void
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo({required double a}) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredMethods
          foo: #M3
            functionType: FunctionType
              named
                a: required double @ dart:core
              returnType: void
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_formalParameter_requiredPositional() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo(int a) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo(int a) {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_class_method_formalParameter_requiredPositional_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo(int a) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo(int b) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
    );
  }

  test_manifest_class_method_formalParameter_requiredPositional_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo(int a) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo(double a) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasInstanceInstance_removeFirst() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
  double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasInstanceInstance_removeSecond() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
  double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasInstanceStatic_removeFirst() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
  static double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasInstanceStatic_removeSecond() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
  static double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasStaticInstance_removeFirst() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
  double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasStaticInstance_removeSecond() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
  double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  static int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasStaticStatic_removeFirst() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
  static double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_method_fromDuplicate_hasStaticStatic_removeSecond() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
  static double foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M1
          foo=: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_method_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  @Deprecated('0')
  void foo() {}
  @Deprecated('0')
  void bar() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
          map
            bar: #M1
            foo: #M2
''',
      updatedCode: r'''
class A {
  @Deprecated('1')
  void foo() {}
  @Deprecated('0')
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M4
        interface: #M5
          map
            bar: #M1
            foo: #M4
''',
    );
  }

  test_manifest_class_method_private_instance() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void _foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  void _foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M1
          bar: #M3
        interface: #M4
          map
            bar: #M3
''',
    );
  }

  test_manifest_class_method_private_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static void _foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static void _foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          _foo: #M1
          bar: #M3
        interface: #M4
          map
            bar: #M3
''',
    );
  }

  test_manifest_class_method_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
  void bar() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
          map
            bar: #M1
            foo: #M2
''',
      updatedCode: r'''
class A {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M2
        interface: #M4
          map
            foo: #M2
''',
    );
  }

  test_manifest_class_method_returnType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredMethods
          foo: #M1
            functionType: FunctionType
              returnType: int @ dart:core
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredMethods
          foo: #M3
            functionType: FunctionType
              returnType: double @ dart:core
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_static_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  static void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
''',
    );
  }

  test_manifest_class_method_static_returnType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_method_static_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasInstance_addInstance_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  int foo() {}
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasInstance_addInstance_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  double foo() {}
  int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasInstance_addStatic_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  int foo() {}
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasInstance_addStatic_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  static double foo() {}
  int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasStatic_addInstance_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static int foo() {}
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasStatic_addInstance_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  double foo() {}
  static int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasStatic_addStatic_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static int foo() {}
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_method_toDuplicate_hasStatic_addStatic_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
class A {
  static double foo() {}
  static int foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M3
          foo=: #M3
        interface: #M2
''',
    );
  }

  test_manifest_class_method_typeParameter() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  Map<T, U> foo<U>() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        typeParameters
          bound: <null>
        supertype: Object @ dart:core
        declaredMethods
          foo: #M1
            functionType: FunctionType
              typeParameters
                bound: <null>
              returnType: Map @ dart:core
                typeParameter#1
                typeParameter#0
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A<T> {
  Map<T, U> foo<U>() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        typeParameters
          bound: <null>
        supertype: Object @ dart:core
        declaredMethods
          bar: #M3
            functionType: FunctionType
              returnType: void
          foo: #M1
            functionType: FunctionType
              typeParameters
                bound: <null>
              returnType: Map @ dart:core
                typeParameter#1
                typeParameter#0
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_class_method_typeParameter_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo<T>() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo<T, U>() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_method_typeParameter_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo<T, U>() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A {
  void foo<T>() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_class_private() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class _A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      _A: #M0
        interface: #M1
''',
      updatedCode: r'''
class _A {}
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M2
        interface: #M3
      _A: #M0
        interface: #M1
''',
    );
  }

  test_manifest_class_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
''',
      updatedCode: '',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
''',
    );
  }

  test_manifest_class_setter_add_extends() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B extends A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
  set bar(int _) {}
}

class B extends A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_class_setter_add_extends_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  set foo(T _) {}
}

class B extends A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
class A<T> {
  set foo(T _) {}
  set bar(T _) {}
}

class B extends A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_class_setter_add_implements() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B implements A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
  set bar(int _) {}
}

class B implements A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_class_setter_add_implements_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  set foo(T _) {}
}

class B implements A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
class A<T> {
  set foo(T _) {}
  set bar(T _) {}
}

class B implements A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_class_setter_add_with() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}

class B with A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
  set bar(int _) {}
}

class B with A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_class_setter_add_with_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  set foo(T _) {}
}

class B with A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
class A<T> {
  set foo(T _) {}
  set bar(T _) {}
}

class B with A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_class_setter_combinedSignatures_merged_addUnrelated() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  set foo(num _);
}

abstract class B {
  set foo(int _);
}

abstract class C implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo=: #M6
      C: #M8
        interface: #M9
          map
            foo=: #M10
          combinedIds
            [#M2, #M6]: #M10
''',
      updatedCode: r'''
abstract class A {
  set foo(num _);
}

abstract class B {
  set foo(int _);
}

abstract class C implements A, B {
  void zzz();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo=: #M6
      C: #M8
        declaredMethods
          zzz: #M11
        interface: #M12
          map
            foo=: #M10
            zzz: #M11
          combinedIds
            [#M2, #M6]: #M10
''',
    );
  }

  test_manifest_class_setter_combinedSignatures_merged_inherit() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  set foo(dynamic _);
}

abstract class B {
  set foo(void _);
}

abstract class C implements A, B {}

abstract class D implements C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo=: #M6
      C: #M8
        interface: #M9
          map
            foo=: #M10
          combinedIds
            [#M2, #M6]: #M10
      D: #M11
        interface: #M12
          map
            foo=: #M10
''',
      updatedCode: r'''
abstract class A {
  set foo(dynamic _);
}

abstract class B {
  set foo(void _);
}

abstract class C implements A, B {
  void xxx() {}
}

abstract class D implements C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        declaredFields
          foo: #M5
        declaredSetters
          foo=: #M6
        interface: #M7
          map
            foo=: #M6
      C: #M8
        declaredMethods
          xxx: #M13
        interface: #M14
          map
            foo=: #M10
            xxx: #M13
          combinedIds
            [#M2, #M6]: #M10
      D: #M11
        interface: #M15
          map
            foo=: #M10
            xxx: #M13
''',
    );
  }

  test_manifest_class_setter_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  @Deprecated('0')
  set foo(int _) {}
  @Deprecated('0')
  set bar(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredSetters
          bar=: #M3
          foo=: #M4
        interface: #M5
          map
            bar=: #M3
            foo=: #M4
''',
      updatedCode: r'''
class A {
  @Deprecated('1')
  set foo(int _) {}
  @Deprecated('0')
  set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredSetters
          bar=: #M3
          foo=: #M6
        interface: #M7
          map
            bar=: #M3
            foo=: #M6
''',
    );
  }

  test_manifest_class_setter_private_instance() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set _foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
        declaredSetters
          _foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  set _foo(int _) {}
  set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredSetters
          _foo=: #M2
          bar=: #M5
        interface: #M6
          map
            bar=: #M5
''',
    );
  }

  test_manifest_class_setter_private_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static set _foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
        declaredSetters
          _foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static set _foo(int _) {}
  set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredSetters
          _foo=: #M2
          bar=: #M5
        interface: #M6
          map
            bar=: #M5
''',
    );
  }

  test_manifest_class_setter_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static set foo(int _) {}
  static set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          bar: #M4
          foo: #M1
        declaredSetters
          bar=: #M5
          foo=: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_setter_static_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  static set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M6
''',
    );
  }

  test_manifest_class_setter_static_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M6
          map
            foo=: #M5
''',
    );
  }

  test_manifest_class_setter_static_valueType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M3
''',
    );
  }

  test_manifest_class_setter_toDuplicate_hasInstance_addInstance_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
  set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo=: #M4
''',
    );
  }

  test_manifest_class_setter_toDuplicate_hasInstance_addInstance_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(double _) {}
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo=: #M4
''',
    );
  }

  test_manifest_class_setter_toDuplicate_hasInstance_addStatic_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(int _) {}
  static set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo=: #M4
''',
    );
  }

  test_manifest_class_setter_toDuplicate_hasInstance_addStatic_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  static set foo(double _) {}
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M5
          map
            foo=: #M4
''',
    );
  }

  test_manifest_class_setter_toDuplicate_hasStatic_addStatic_after() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static set foo(int _) {}
  static set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M3
''',
    );
  }

  test_manifest_class_setter_toDuplicate_hasStatic_addStatic_before() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
class A {
  static set foo(double _) {}
  static set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConflicts
          foo: #M4
          foo=: #M4
        interface: #M3
''',
    );
  }

  test_manifest_class_setter_topMerge() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
abstract class A {
  set foo(List _);
}

abstract class B {
  set foo(List<void> _);
}

abstract class C implements A, B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredFields
          foo: #M1
            type: List @ dart:core
              dynamic
        declaredSetters
          foo=: #M2
            valueType: List @ dart:core
              dynamic
        interface: #M3
          map
            foo=: #M2
      B: #M4
        supertype: Object @ dart:core
        declaredFields
          foo: #M5
            type: List @ dart:core
              void
        declaredSetters
          foo=: #M6
            valueType: List @ dart:core
              void
        interface: #M7
          map
            foo=: #M6
      C: #M8
        supertype: Object @ dart:core
        interfaces
          A @ package:test/test.dart
          B @ package:test/test.dart
        interface: #M9
          map
            foo=: #M10
          combinedIds
            [#M2, #M6]: #M10
''',
      updatedCode: r'''
abstract class A {
  set foo(List _);
}

abstract class B {
  set foo(List<int> _);
}

abstract class C implements A, B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredFields
          foo: #M1
            type: List @ dart:core
              dynamic
        declaredSetters
          foo=: #M2
            valueType: List @ dart:core
              dynamic
        interface: #M3
          map
            foo=: #M2
      B: #M4
        supertype: Object @ dart:core
        declaredFields
          foo: #M11
            type: List @ dart:core
              int @ dart:core
        declaredSetters
          foo=: #M12
            valueType: List @ dart:core
              int @ dart:core
        interface: #M13
          map
            foo=: #M12
      C: #M8
        supertype: Object @ dart:core
        interfaces
          A @ package:test/test.dart
          B @ package:test/test.dart
        interface: #M14
          map
            foo=: #M15
          combinedIds
            [#M2, #M12]: #M15
''',
    );
  }

  test_manifest_class_setter_valueType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredFields
          foo: #M1
            type: int @ dart:core
        declaredSetters
          foo=: #M2
            valueType: int @ dart:core
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
class A {
  set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        supertype: Object @ dart:core
        declaredFields
          foo: #M4
            type: double @ dart:core
        declaredSetters
          foo=: #M5
            valueType: double @ dart:core
        interface: #M6
          map
            foo=: #M5
''',
    );
  }

  test_manifest_class_typeParameters() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {
  void foo(T _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
class A<T> {
  void foo(T _) {}
  void bar(T _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_class_typeParameters_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
''',
      updatedCode: r'''
class A<T, U> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_typeParameters_bound() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T extends num> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
''',
      updatedCode: r'''
class A<T extends int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M2
        interface: #M3
''',
    );
  }

  test_manifest_class_typeParameters_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A<T, U> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
''',
      updatedCode: r'''
class A<T> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M2
        interface: #M3
''',
    );
  }

  test_manifest_classTypeAlias_constructors_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.c1();
}
mixin M {}
class X = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
        interface: #M2
      X: #M3
        inheritedConstructors
          c1: #M1
        interface: #M4
    declaredMixins
      M: #M5
        interface: #M6
''',
      updatedCode: r'''
class A {
  A.c1();
  A.c2();
}
mixin M {}
class X = A with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M7
        interface: #M2
      X: #M3
        inheritedConstructors
          c1: #M1
          c2: #M7
        interface: #M4
    declaredMixins
      M: #M5
        interface: #M6
''',
    );
  }

  test_manifest_classTypeAlias_constructors_add_chain_backward() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.c1();
}
mixin M {}
class X1 = X2 with M;
class X2 = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
        interface: #M2
      X1: #M3
        inheritedConstructors
          c1: #M1
        interface: #M4
      X2: #M5
        inheritedConstructors
          c1: #M1
        interface: #M6
    declaredMixins
      M: #M7
        interface: #M8
''',
      updatedCode: r'''
class A {
  A.c1();
  A.c2();
}
mixin M {}
class X1 = X2 with M;
class X2 = A with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M9
        interface: #M2
      X1: #M3
        inheritedConstructors
          c1: #M1
          c2: #M9
        interface: #M4
      X2: #M5
        inheritedConstructors
          c1: #M1
          c2: #M9
        interface: #M6
    declaredMixins
      M: #M7
        interface: #M8
''',
    );
  }

  test_manifest_classTypeAlias_constructors_add_chain_forward() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.c1();
}
mixin M {}
class X1 = A with M;
class X2 = X1 with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
        interface: #M2
      X1: #M3
        inheritedConstructors
          c1: #M1
        interface: #M4
      X2: #M5
        inheritedConstructors
          c1: #M1
        interface: #M6
    declaredMixins
      M: #M7
        interface: #M8
''',
      updatedCode: r'''
class A {
  A.c1();
  A.c2();
}
mixin M {}
class X1 = A with M;
class X2 = X1 with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M9
        interface: #M2
      X1: #M3
        inheritedConstructors
          c1: #M1
          c2: #M9
        interface: #M4
      X2: #M5
        inheritedConstructors
          c1: #M1
          c2: #M9
        interface: #M6
    declaredMixins
      M: #M7
        interface: #M8
''',
    );
  }

  test_manifest_classTypeAlias_constructors_change() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.c1();
  A.c2(int _);
}
mixin M {}
class X = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M2
        interface: #M3
      X: #M4
        inheritedConstructors
          c1: #M1
          c2: #M2
        interface: #M5
    declaredMixins
      M: #M6
        interface: #M7
''',
      updatedCode: r'''
class A {
  A.c1();
  A.c2(double _);
}
mixin M {}
class X = A with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M8
        interface: #M3
      X: #M4
        inheritedConstructors
          c1: #M1
          c2: #M8
        interface: #M5
    declaredMixins
      M: #M6
        interface: #M7
''',
    );
  }

  test_manifest_classTypeAlias_constructors_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.c1();
  A.c2();
}
mixin M {}
class X = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
          c2: #M2
        interface: #M3
      X: #M4
        inheritedConstructors
          c1: #M1
          c2: #M2
        interface: #M5
    declaredMixins
      M: #M6
        interface: #M7
''',
      updatedCode: r'''
class A {
  A.c1();
}
mixin M {}
class X = A with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          c1: #M1
        interface: #M3
      X: #M4
        inheritedConstructors
          c1: #M1
        interface: #M5
    declaredMixins
      M: #M6
        interface: #M7
''',
    );
  }

  test_manifest_classTypeAlias_extends() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {}
class B {}
mixin M {}
class X = A with M;
class Y = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      X: #M4
        interface: #M5
      Y: #M6
        interface: #M7
    declaredMixins
      M: #M8
        interface: #M9
''',
      updatedCode: r'''
class A {}
class B {}
mixin M {}
class X = A with M;
class Y = B with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      X: #M4
        interface: #M5
      Y: #M10
        interface: #M11
    declaredMixins
      M: #M8
        interface: #M9
''',
    );
  }

  test_manifest_classTypeAlias_getter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int get foo1 => 0;
  int get foo2 => 0;
}

mixin M {
  int get foo3 => 0;
  int get foo4 => 0;
}

class X = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo1: #M1
          foo2: #M2
        declaredGetters
          foo1: #M3
          foo2: #M4
        interface: #M5
          map
            foo1: #M3
            foo2: #M4
      X: #M6
        interface: #M7
          map
            foo1: #M3
            foo2: #M4
            foo3: #M8
            foo4: #M9
    declaredMixins
      M: #M10
        declaredFields
          foo3: #M11
          foo4: #M12
        declaredGetters
          foo3: #M8
          foo4: #M9
        interface: #M13
          map
            foo3: #M8
            foo4: #M9
''',
      updatedCode: r'''
class A {
  int get foo1 => 0;
  double get foo2 => 0;
}

mixin M {
  int get foo3 => 0;
  double get foo4 => 0;
}

class X = A with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo1: #M1
          foo2: #M14
        declaredGetters
          foo1: #M3
          foo2: #M15
        interface: #M16
          map
            foo1: #M3
            foo2: #M15
      X: #M6
        interface: #M17
          map
            foo1: #M3
            foo2: #M15
            foo3: #M8
            foo4: #M18
    declaredMixins
      M: #M10
        declaredFields
          foo3: #M11
          foo4: #M19
        declaredGetters
          foo3: #M8
          foo4: #M18
        interface: #M20
          map
            foo3: #M8
            foo4: #M18
''',
    );
  }

  test_manifest_classTypeAlias_interfaces() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {}
mixin M {}
class X1 = Object with M;
class X2 = Object with M implements A;
class X3 = Object with M;
class X4 = Object with M implements A;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      X1: #M2
        interface: #M3
      X2: #M4
        interface: #M5
      X3: #M6
        interface: #M7
      X4: #M8
        interface: #M9
    declaredMixins
      M: #M10
        interface: #M11
''',
      updatedCode: r'''
class A {}
mixin M {}
class X1 = Object with M;
class X2 = Object with M implements A;
class X3 = Object with M implements A;
class X4 = Object with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      X1: #M2
        interface: #M3
      X2: #M4
        interface: #M5
      X3: #M12
        interface: #M13
      X4: #M14
        interface: #M15
    declaredMixins
      M: #M10
        interface: #M11
''',
    );
  }

  test_manifest_classTypeAlias_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin M {}
@Deprecated('0')
class X = Object with M;
@Deprecated('0')
class Y = Object with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      X: #M0
        interface: #M1
      Y: #M2
        interface: #M3
    declaredMixins
      M: #M4
        interface: #M5
''',
      updatedCode: r'''
mixin M {}
@Deprecated('0')
class X = Object with M;
@Deprecated('1')
class Y = Object with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      X: #M0
        interface: #M1
      Y: #M6
        interface: #M7
    declaredMixins
      M: #M4
        interface: #M5
''',
    );
  }

  test_manifest_classTypeAlias_method() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  void foo1(int _) {}
  void foo2(int _) {}
}

mixin M {
  void foo3(int _) {}
  void foo4(int _) {}
}

class X = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo1: #M1
          foo2: #M2
        interface: #M3
          map
            foo1: #M1
            foo2: #M2
      X: #M4
        interface: #M5
          map
            foo1: #M1
            foo2: #M2
            foo3: #M6
            foo4: #M7
    declaredMixins
      M: #M8
        declaredMethods
          foo3: #M6
          foo4: #M7
        interface: #M9
          map
            foo3: #M6
            foo4: #M7
''',
      updatedCode: r'''
class A {
  void foo1(int _) {}
  void foo2(double _) {}
}

mixin M {
  void foo3(int _) {}
  void foo4(double _) {}
}

class X = A with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo1: #M1
          foo2: #M10
        interface: #M11
          map
            foo1: #M1
            foo2: #M10
      X: #M4
        interface: #M12
          map
            foo1: #M1
            foo2: #M10
            foo3: #M6
            foo4: #M13
    declaredMixins
      M: #M8
        declaredMethods
          foo3: #M6
          foo4: #M13
        interface: #M14
          map
            foo3: #M6
            foo4: #M13
''',
    );
  }

  test_manifest_classTypeAlias_setter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  set foo1(int _) {}
  set foo2(int _) {}
}

mixin M {
  set foo3(int _) {}
  set foo4(int _) {}
}

class X = A with M;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo1: #M1
          foo2: #M2
        declaredSetters
          foo1=: #M3
          foo2=: #M4
        interface: #M5
          map
            foo1=: #M3
            foo2=: #M4
      X: #M6
        interface: #M7
          map
            foo1=: #M3
            foo2=: #M4
            foo3=: #M8
            foo4=: #M9
    declaredMixins
      M: #M10
        declaredFields
          foo3: #M11
          foo4: #M12
        declaredSetters
          foo3=: #M8
          foo4=: #M9
        interface: #M13
          map
            foo3=: #M8
            foo4=: #M9
''',
      updatedCode: r'''
class A {
  set foo1(int _) {}
  set foo2(double _) {}
}

mixin M {
  set foo3(int _) {}
  set foo4(double _) {}
}

class X = A with M;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          foo1: #M1
          foo2: #M14
        declaredSetters
          foo1=: #M3
          foo2=: #M15
        interface: #M16
          map
            foo1=: #M3
            foo2=: #M15
      X: #M6
        interface: #M17
          map
            foo1=: #M3
            foo2=: #M15
            foo3=: #M8
            foo4=: #M18
    declaredMixins
      M: #M10
        declaredFields
          foo3: #M11
          foo4: #M19
        declaredSetters
          foo3=: #M8
          foo4=: #M18
        interface: #M20
          map
            foo3=: #M8
            foo4=: #M18
''',
    );
  }

  test_manifest_constInitializer_adjacentStrings() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 0;
const c = '$a' 'x';
const d = 'x' '$a';
const e = '$b' 'x';
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
      e: #M4
    declaredVariables
      a: #M5
      b: #M6
      c: #M7
      d: #M8
      e: #M9
''',
      updatedCode: r'''
const a = 1;
const b = 0;
const c = '$a' 'x';
const d = 'x' '$a';
const e = '$b' 'x';
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
      e: #M4
    declaredVariables
      a: #M10
      b: #M6
      c: #M11
      d: #M12
      e: #M9
''',
    );
  }

  test_manifest_constInitializer_asExpression() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 0;
const c = a as int;
const d = b as int;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = 0;
const b = 1;
const c = a as int;
const d = b as int;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M8
      c: #M6
      d: #M9
''',
    );
  }

  test_manifest_constInitializer_binaryExpression() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0 + 1;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = 0 + 1;
const b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_constInitializer_binaryExpression_left_change() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = a + 2;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
''',
      updatedCode: r'''
const a = 1;
const b = a + 2;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M4
      b: #M5
''',
    );
  }

  test_manifest_constInitializer_binaryExpression_left_token() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0 + 1;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = 2 + 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M2
''',
    );
  }

  test_manifest_constInitializer_binaryExpression_operator() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  const A();
  int operator+(_) {}
}
const a = A();
const x = a + 1;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          +: #M1
        interface: #M2
          map
            +: #M1
    declaredGetters
      a: #M3
      x: #M4
    declaredVariables
      a: #M5
      x: #M6
''',
      updatedCode: r'''
class A {
  const A();
  double operator+(_) {}
}
const a = A();
const x = a + 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          +: #M7
        interface: #M8
          map
            +: #M7
    declaredGetters
      a: #M3
      x: #M9
    declaredVariables
      a: #M5
      x: #M10
''',
    );
  }

  test_manifest_constInitializer_binaryExpression_operator_token() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0 + 1;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = 0 - 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M2
''',
    );
  }

  test_manifest_constInitializer_binaryExpression_right() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 2 + a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
''',
      updatedCode: r'''
const a = 1;
const b = 2 + a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M4
      b: #M5
''',
    );
  }

  test_manifest_constInitializer_binaryExpression_right_add() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
const b = 0 + a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      b: #M0
        returnType: double @ dart:core
    declaredVariables
      b: #M1
        type: double @ dart:core
        constInitializer
          tokenBuffer: 0+a
          tokenLengthList: [1, 1, 1]
          elements
            [0] (dart:core, instanceMethod, num, +) #M2
          elementIndexList
            0 = null
            5 = element 0
''',
      updatedCode: r'''
const a = 1;
const b = 0 + a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M3
        returnType: int @ dart:core
      b: #M4
        returnType: int @ dart:core
    declaredVariables
      a: #M5
        type: int @ dart:core
        constInitializer
          tokenBuffer: 1
          tokenLengthList: [1]
      b: #M6
        type: int @ dart:core
        constInitializer
          tokenBuffer: 0+a
          tokenLengthList: [1, 1, 1]
          elements
            [0] (package:test/test.dart, topLevelGetter, a) <null>
            [1] (package:test/test.dart, topLevelVariable, a) <null>
            [2] (dart:core, instanceMethod, num, +) #M2
          elementIndexList
            5 = element 0
            13 = element 1
            21 = element 2
''',
    );
  }

  test_manifest_constInitializer_binaryExpression_right_remove() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 1 + a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
        returnType: int @ dart:core
      b: #M1
        returnType: int @ dart:core
    declaredVariables
      a: #M2
        type: int @ dart:core
        constInitializer
          tokenBuffer: 0
          tokenLengthList: [1]
      b: #M3
        type: int @ dart:core
        constInitializer
          tokenBuffer: 1+a
          tokenLengthList: [1, 1, 1]
          elements
            [0] (package:test/test.dart, topLevelGetter, a) <null>
            [1] (package:test/test.dart, topLevelVariable, a) <null>
            [2] (dart:core, instanceMethod, num, +) #M4
          elementIndexList
            5 = element 0
            13 = element 1
            21 = element 2
''',
      updatedCode: r'''
const b = 1 + a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      b: #M5
        returnType: double @ dart:core
    declaredVariables
      b: #M6
        type: double @ dart:core
        constInitializer
          tokenBuffer: 1+a
          tokenLengthList: [1, 1, 1]
          elements
            [0] (dart:core, instanceMethod, num, +) #M4
          elementIndexList
            0 = null
            5 = element 0
''',
    );
  }

  test_manifest_constInitializer_boolLiteral() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = true;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = true;
const b = false;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_constInitializer_conditionalExpression() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = true;
const b = true;
const c = a ? 0 : 1;
const d = b ? 0 : 1;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = true;
const b = false;
const c = a ? 0 : 1;
const d = b ? 0 : 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M8
      c: #M6
      d: #M9
''',
    );
  }

  test_manifest_constInitializer_constructorName_named() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A.named();
}
const a = A.named();
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
    declaredGetters
      a: #M3
    declaredVariables
      a: #M4
''',
      updatedCode: r'''
class A {
  A.named(int _);
}
const a = A.named();
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M5
        interface: #M2
    declaredGetters
      a: #M3
    declaredVariables
      a: #M6
''',
    );
  }

  test_manifest_constInitializer_constructorName_unnamed() async {
    configuration.ignoredManifestInstanceMemberNames.remove('new');
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A();
}
const a = A();
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          new: #M1
        interface: #M2
    declaredGetters
      a: #M3
    declaredVariables
      a: #M4
''',
      updatedCode: r'''
class A {
  A(int _);
}
const a = A();
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          new: #M5
        interface: #M2
    declaredGetters
      a: #M3
    declaredVariables
      a: #M6
''',
    );
  }

  test_manifest_constInitializer_constructorName_unnamed_notAffected() async {
    configuration.ignoredManifestInstanceMemberNames.remove('new');
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A();
}
const a = A();
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredConstructors
          new: #M1
        interface: #M2
    declaredGetters
      a: #M3
    declaredVariables
      a: #M4
''',
      updatedCode: r'''
class A {
  A();
  void foo() {}
}
const a = A();
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M5
        declaredConstructors
          new: #M1
        interface: #M6
          map
            foo: #M5
    declaredGetters
      a: #M3
    declaredVariables
      a: #M4
''',
    );
  }

  test_manifest_constInitializer_dynamicElement() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0 as dynamic;
const b = 0 as dynamic;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
''',
      updatedCode: r'''
const a = 0 as dynamic;
const b = 0 as int;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M4
    declaredVariables
      a: #M2
      b: #M5
''',
    );
  }

  test_manifest_constInitializer_instanceCreation_argument() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  A(_);
}
const a = 0;
const b = 0;
const c = A(a);
const d = A(b);
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
    declaredGetters
      a: #M2
      b: #M3
      c: #M4
      d: #M5
    declaredVariables
      a: #M6
      b: #M7
      c: #M8
      d: #M9
''',
      updatedCode: r'''
class A {
  A(_);
}
const a = 1;
const b = 0;
const c = A(a);
const d = A(b);
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
    declaredGetters
      a: #M2
      b: #M3
      c: #M4
      d: #M5
    declaredVariables
      a: #M10
      b: #M7
      c: #M11
      d: #M9
''',
    );
  }

  test_manifest_constInitializer_integerLiteral() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = 0;
const b = 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_constInitializer_integerLiteral_value() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M2
''',
    );
  }

  test_manifest_constInitializer_listLiteral() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 0;
const c = [a];
const d = [b];
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = 1;
const b = 0;
const c = [a];
const d = [b];
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M8
      b: #M5
      c: #M9
      d: #M7
''',
    );
  }

  test_manifest_constInitializer_mapLiteral_key() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 0;
const c = {a: 0};
const d = {b: 0};
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = 1;
const b = 0;
const c = {a: 0};
const d = {b: 0};
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M8
      b: #M5
      c: #M9
      d: #M7
''',
    );
  }

  test_manifest_constInitializer_mapLiteral_value() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 0;
const c = {0: a};
const d = {0: b};
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = 1;
const b = 0;
const c = {0: a};
const d = {0: b};
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M8
      b: #M5
      c: #M9
      d: #M7
''',
    );
  }

  test_manifest_constInitializer_namedType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {}
class B {}
const a = A;
const b = B;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
    declaredGetters
      a: #M4
      b: #M5
    declaredVariables
      a: #M6
      b: #M7
''',
      updatedCode: r'''
class A {}
class B extends A {}
const a = A;
const b = B;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        interface: #M1
      B: #M8
        interface: #M9
    declaredGetters
      a: #M4
      b: #M5
    declaredVariables
      a: #M6
      b: #M10
''',
    );
  }

  test_manifest_constInitializer_prefixedIdentifier_className_fieldName() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static const a = 0;
  static const b = 0;
}

const c = A.a;
const d = A.b;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M2
        declaredGetters
          a: #M3
          b: #M4
        interface: #M5
    declaredGetters
      c: #M6
      d: #M7
    declaredVariables
      c: #M8
      d: #M9
''',
      updatedCode: r'''
class A {
  static const a = 0;
  static const b = 1;
}

const c = A.a;
const d = A.b;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M10
        declaredGetters
          a: #M3
          b: #M4
        interface: #M5
    declaredGetters
      c: #M6
      d: #M7
    declaredVariables
      c: #M8
      d: #M11
''',
    );
  }

  test_manifest_constInitializer_prefixedIdentifier_importPrefix_className_fieldName() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
import '' as self;

class A {
  static const a = 0;
  static const b = 0;
}

const c = self.A.a;
const d = self.A.b;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M2
        declaredGetters
          a: #M3
          b: #M4
        interface: #M5
    declaredGetters
      c: #M6
      d: #M7
    declaredVariables
      c: #M8
      d: #M9
''',
      updatedCode: r'''
import '' as self;

class A {
  static const a = 0;
  static const b = 1;
}

const c = self.A.a;
const d = self.A.b;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M10
        declaredGetters
          a: #M3
          b: #M4
        interface: #M5
    declaredGetters
      c: #M6
      d: #M7
    declaredVariables
      c: #M8
      d: #M11
''',
    );
  }

  test_manifest_constInitializer_prefixedIdentifier_importPrefix_topVariable() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
import '' as self;
const a = 0;
const b = 0;
const c = self.a;
const d = self.b;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
import '' as self;
const a = 0;
const b = 1;
const c = self.a;
const d = self.b;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M8
      c: #M6
      d: #M9
''',
    );
  }

  test_manifest_constInitializer_prefixedIdentifier_importPrefix_topVariable_changePrefix() async {
    newFile('$testPackageLibPath/a.dart', '');

    await _runLibraryManifestScenario(
      initialCode: r'''
import 'a.dart' as x;
const z = x.x + y.y;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      z: #M0
    declaredVariables
      z: #M1
''',
      updatedCode: r'''
import 'a.dart' as y;
const z = x.x + y.y;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      z: #M0
    declaredVariables
      z: #M2
''',
    );
  }

  test_manifest_constInitializer_prefixedIdentifier_importPrefix_topVariable_changeUri() async {
    newFile('$testPackageLibPath/a.dart', r'''
const x = 0;
''');

    newFile('$testPackageLibPath/b.dart', r'''
const x = 0;
''');

    await _runLibraryManifestScenario(
      initialCode: r'''
import 'a.dart' as p;
const z = p.x;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      x: #M0
    declaredVariables
      x: #M1
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      z: #M2
    declaredVariables
      z: #M3
''',
      updatedCode: r'''
import 'b.dart' as p;
const z = p.x;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/b.dart
    declaredGetters
      x: #M4
    declaredVariables
      x: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      z: #M2
    declaredVariables
      z: #M6
''',
    );
  }

  test_manifest_constInitializer_prefixExpression() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator-() {}
}
const a = A();
const b = -a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          unary-: #M1
        interface: #M2
          map
            unary-: #M1
    declaredGetters
      a: #M3
      b: #M4
    declaredVariables
      a: #M5
      b: #M6
''',
      updatedCode: r'''
class A {
  double operator-() {}
}
const a = A();
const b = -a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          unary-: #M7
        interface: #M8
          map
            unary-: #M7
    declaredGetters
      a: #M3
      b: #M9
    declaredVariables
      a: #M5
      b: #M10
''',
    );
  }

  test_manifest_constInitializer_prefixExpression_notAffected() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  int operator-() {}
}
const a = A();
const b = -a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          unary-: #M1
        interface: #M2
          map
            unary-: #M1
    declaredGetters
      a: #M3
      b: #M4
    declaredVariables
      a: #M5
      b: #M6
''',
      updatedCode: r'''
class A {
  int operator-() {}
  void foo() {}
}
const a = A();
const b = -a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M7
          unary-: #M1
        interface: #M8
          map
            foo: #M7
            unary-: #M1
    declaredGetters
      a: #M3
      b: #M4
    declaredVariables
      a: #M5
      b: #M6
''',
    );
  }

  test_manifest_constInitializer_propertyAccess_stringLength() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = '0'.length;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = '1'.length;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M2
''',
    );
  }

  test_manifest_constInitializer_setLiteral() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 0;
const c = {a};
const d = {b};
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = 1;
const b = 0;
const c = {a};
const d = {b};
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M8
      b: #M5
      c: #M9
      d: #M7
''',
    );
  }

  test_manifest_constInitializer_simpleIdentifier_field() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
class A {
  static const a = 0;
  static const b = 0;
  static const c = a;
  static const d = b;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M2
          c: #M3
          d: #M4
        declaredGetters
          a: #M5
          b: #M6
          c: #M7
          d: #M8
        interface: #M9
''',
      updatedCode: r'''
class A {
  static const a = 0;
  static const b = 1;
  static const c = a;
  static const d = b;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      A: #M0
        declaredFields
          a: #M1
          b: #M10
          c: #M3
          d: #M11
        declaredGetters
          a: #M5
          b: #M6
          c: #M7
          d: #M8
        interface: #M9
''',
    );
  }

  test_manifest_constInitializer_simpleIdentifier_topVariable() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
const b = 0;
const c = a;
const d = b;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = 0;
const b = 1;
const c = a;
const d = b;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M8
      c: #M6
      d: #M9
''',
    );
  }

  test_manifest_constInitializer_typeLiteral() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = List<int>;
const b = List<int>;
const c = a;
const d = b;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M5
      c: #M6
      d: #M7
''',
      updatedCode: r'''
const a = List<int>;
const b = List<double>;
const c = a;
const d = b;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
      c: #M2
      d: #M3
    declaredVariables
      a: #M4
      b: #M8
      c: #M6
      d: #M9
''',
    );
  }

  test_manifest_enum_constants_replace() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A {
  c1, c2
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          c1: #M1
          c2: #M2
          values: #M3
        declaredGetters
          c1: #M4
          c2: #M5
          values: #M6
        interface: #M7
          map
            index: #M8
''',
      updatedCode: r'''
enum A {
  c1, c3
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          c1: #M1
          c3: #M9
          values: #M10
        declaredGetters
          c1: #M4
          c3: #M11
          values: #M6
        interface: #M7
          map
            index: #M8
''',
    );
  }

  test_manifest_enum_constants_update_argument() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A {
  c1(1),
  c2(2),
  c3(3);
  const A(int _);
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          c1: #M1
          c2: #M2
          c3: #M3
          values: #M4
        declaredGetters
          c1: #M5
          c2: #M6
          c3: #M7
          values: #M8
        interface: #M9
          map
            index: #M10
''',
      updatedCode: r'''
enum A {
  c1(1),
  c2(20),
  c3(3);
  const A(int _);
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          c1: #M1
          c2: #M11
          c3: #M3
          values: #M12
        declaredGetters
          c1: #M5
          c2: #M6
          c3: #M7
          values: #M8
        interface: #M9
          map
            index: #M10
''',
    );
  }

  test_manifest_enum_constants_update_typeArgument() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A<T> {
  c1<int>(),
  c2<int>(),
  c3<int>();
  const A();
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          c1: #M1
          c2: #M2
          c3: #M3
          values: #M4
        declaredGetters
          c1: #M5
          c2: #M6
          c3: #M7
          values: #M8
        interface: #M9
          map
            index: #M10
''',
      updatedCode: r'''
enum A<T> {
  c1<int>(),
  c2<double>(),
  c3<int>();
  const A();
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          c1: #M1
          c2: #M11
          c3: #M3
          values: #M12
        declaredGetters
          c1: #M5
          c2: #M13
          c3: #M7
          values: #M8
        interface: #M9
          map
            index: #M10
''',
    );
  }

  test_manifest_enum_field_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A {
  v;
  final int foo = 0;
  final int bar = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
          v: #M3
          values: #M4
        declaredGetters
          bar: #M5
          foo: #M6
          v: #M7
          values: #M8
        interface: #M9
          map
            bar: #M5
            foo: #M6
            index: #M10
''',
      updatedCode: r'''
enum A {
  v;
  final int foo = 0;
  final double bar = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          bar: #M11
          foo: #M2
          v: #M3
          values: #M4
        declaredGetters
          bar: #M12
          foo: #M6
          v: #M7
          values: #M8
        interface: #M13
          map
            bar: #M12
            foo: #M6
            index: #M10
''',
    );
  }

  test_manifest_enum_getter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A {
  v;
  int get foo {}
  int get bar {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
          v: #M3
          values: #M4
        declaredGetters
          bar: #M5
          foo: #M6
          v: #M7
          values: #M8
        interface: #M9
          map
            bar: #M5
            foo: #M6
            index: #M10
''',
      updatedCode: r'''
enum A {
  v;
  int get foo {}
  double get bar {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          bar: #M11
          foo: #M2
          v: #M3
          values: #M4
        declaredGetters
          bar: #M12
          foo: #M6
          v: #M7
          values: #M8
        interface: #M13
          map
            bar: #M12
            foo: #M6
            index: #M10
''',
    );
  }

  test_manifest_enum_implements_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A { v }
class B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M0
        interface: #M1
    declaredEnums
      A: #M2
        declaredFields
          v: #M3
          values: #M4
        declaredGetters
          v: #M5
          values: #M6
        interface: #M7
          map
            index: #M8
''',
      updatedCode: r'''
enum A implements B { v }
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M0
        interface: #M1
    declaredEnums
      A: #M9
        declaredFields
          v: #M10
          values: #M11
        declaredGetters
          v: #M12
          values: #M13
        interface: #M14
          map
            index: #M8
''',
    );
  }

  test_manifest_enum_implements_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A implements B { v }
class B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M0
        interface: #M1
    declaredEnums
      A: #M2
        declaredFields
          v: #M3
          values: #M4
        declaredGetters
          v: #M5
          values: #M6
        interface: #M7
          map
            index: #M8
''',
      updatedCode: r'''
enum A { v }
class B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredClasses
      B: #M0
        interface: #M1
    declaredEnums
      A: #M9
        declaredFields
          v: #M10
          values: #M11
        declaredGetters
          v: #M12
          values: #M13
        interface: #M14
          map
            index: #M8
''',
    );
  }

  test_manifest_enum_it_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A { v }
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
''',
      updatedCode: r'''
enum A { v }
enum B { v }
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
      B: #M7
        declaredFields
          v: #M8
          values: #M9
        declaredGetters
          v: #M10
          values: #M11
        interface: #M12
          map
            index: #M6
''',
    );
  }

  test_manifest_enum_it_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A { v }
enum B { v }
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
      B: #M7
        declaredFields
          v: #M8
          values: #M9
        declaredGetters
          v: #M10
          values: #M11
        interface: #M12
          map
            index: #M6
''',
      updatedCode: r'''
enum A { v }
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
''',
    );
  }

  test_manifest_enum_method() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A {
  v;
  int foo() {}
  int bar() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          bar: #M5
          foo: #M6
        interface: #M7
          map
            bar: #M5
            foo: #M6
            index: #M8
''',
      updatedCode: r'''
enum A {
  v;
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          bar: #M9
          foo: #M6
        interface: #M10
          map
            bar: #M9
            foo: #M6
            index: #M8
''',
    );
  }

  test_manifest_enum_setter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A {
  v;
  set foo(int _) {}
  set bar(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
          v: #M3
          values: #M4
        declaredGetters
          v: #M5
          values: #M6
        declaredSetters
          bar=: #M7
          foo=: #M8
        interface: #M9
          map
            bar=: #M7
            foo=: #M8
            index: #M10
''',
      updatedCode: r'''
enum A {
  v;
  set foo(int _) {}
  set bar(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          bar: #M11
          foo: #M2
          v: #M3
          values: #M4
        declaredGetters
          v: #M5
          values: #M6
        declaredSetters
          bar=: #M12
          foo=: #M8
        interface: #M13
          map
            bar=: #M12
            foo=: #M8
            index: #M10
''',
    );
  }

  test_manifest_enum_typeParameters() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A<T> {
  v;
  void foo(T _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          foo: #M5
        interface: #M6
          map
            foo: #M5
            index: #M7
''',
      updatedCode: r'''
enum A<T> {
  v;
  void foo(T _) {}
  void bar(T _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        declaredMethods
          bar: #M8
          foo: #M5
        interface: #M9
          map
            bar: #M8
            foo: #M5
            index: #M7
''',
    );
  }

  test_manifest_enum_typeParameters_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A<T> { v }
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
''',
      updatedCode: r'''
enum A<T, U> { v }
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M7
        declaredFields
          v: #M8
          values: #M9
        declaredGetters
          v: #M10
          values: #M11
        interface: #M12
          map
            index: #M6
''',
    );
  }

  test_manifest_enum_with_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A { v }

mixin M {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        interface: #M5
          map
            index: #M6
    declaredMixins
      M: #M7
        declaredMethods
          foo: #M8
        interface: #M9
          map
            foo: #M8
''',
      updatedCode: r'''
enum A with M { v }

mixin M {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M10
        declaredFields
          v: #M11
          values: #M12
        declaredGetters
          v: #M13
          values: #M14
        interface: #M15
          map
            foo: #M8
            index: #M6
    declaredMixins
      M: #M7
        declaredMethods
          foo: #M8
        interface: #M9
          map
            foo: #M8
''',
    );
  }

  test_manifest_enum_with_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
enum A with M { v }

mixin M {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M0
        declaredFields
          v: #M1
          values: #M2
        declaredGetters
          v: #M3
          values: #M4
        interface: #M5
          map
            foo: #M6
            index: #M7
    declaredMixins
      M: #M8
        declaredMethods
          foo: #M6
        interface: #M9
          map
            foo: #M6
''',
      updatedCode: r'''
enum A { v }

mixin M {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredEnums
      A: #M10
        declaredFields
          v: #M11
          values: #M12
        declaredGetters
          v: #M13
          values: #M14
        interface: #M15
          map
            index: #M7
    declaredMixins
      M: #M8
        declaredMethods
          foo: #M6
        interface: #M9
          map
            foo: #M6
''',
    );
  }

  test_manifest_extension_extendedType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
extension A on int {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        extendedType: int @ dart:core
        declaredMethods
          foo: #M1
            functionType: FunctionType
              returnType: void
''',
      updatedCode: r'''
extension A on double {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M2
        extendedType: double @ dart:core
        declaredMethods
          foo: #M3
            functionType: FunctionType
              returnType: void
''',
    );
  }

  test_manifest_extension_getter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension A on int {
  int get foo {}
  int get bar {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
''',
      updatedCode: r'''
extension A on int {
  int get foo {}
  double get bar {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredFields
          bar: #M5
          foo: #M2
        declaredGetters
          bar: #M6
          foo: #M4
''',
    );
  }

  test_manifest_extension_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
extension A on int {}

@Deprecated('0')
extension B on int {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
      B: #M1
''',
      updatedCode: r'''
@Deprecated('0')
extension A on int {}

@Deprecated('1')
extension B on int {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
      B: #M2
''',
    );
  }

  test_manifest_extension_method() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension A on int {
  int foo() {}
  int bar() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
''',
      updatedCode: r'''
extension A on int {
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M2
''',
    );
  }

  test_manifest_extension_noName() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension on int {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
''',
      updatedCode: r'''
extension on int {
  void foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
''',
    );
  }

  test_manifest_extension_setter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension A on int {
  set foo(int _) {}
  set bar(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredSetters
          bar=: #M3
          foo=: #M4
''',
      updatedCode: r'''
extension A on int {
  set foo(int _) {}
  set bar(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredFields
          bar: #M5
          foo: #M2
        declaredSetters
          bar=: #M6
          foo=: #M4
''',
    );
  }

  test_manifest_extension_typeParameters() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension A<T> on int {
  void foo(T _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredMethods
          foo: #M1
''',
      updatedCode: r'''
extension A<T> on int {
  void foo(T _) {}
  void bar(T _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
        declaredMethods
          bar: #M2
          foo: #M1
''',
    );
  }

  test_manifest_extension_typeParameters_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension A<T> on int {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M0
''',
      updatedCode: r'''
extension A<T, U> on int {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensions
      A: #M1
''',
    );
  }

  test_manifest_extensionType_getter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A(int it) {
  int get foo {}
  int get bar {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
          it: #M3
        declaredGetters
          bar: #M4
          foo: #M5
          it: #M6
        interface: #M7
          map
            bar: #M4
            foo: #M5
            it: #M6
''',
      updatedCode: r'''
extension type A(int it) {
  int get foo {}
  double get bar {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          bar: #M8
          foo: #M2
          it: #M3
        declaredGetters
          bar: #M9
          foo: #M5
          it: #M6
        interface: #M10
          map
            bar: #M9
            foo: #M5
            it: #M6
''',
    );
  }

  test_manifest_extensionType_implements_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A(int it) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        interface: #M3
          map
            it: #M2
''',
      updatedCode: r'''
extension type A(int it) implements Object {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M4
        declaredFields
          it: #M5
        declaredGetters
          it: #M6
        interface: #M7
          map
            it: #M6
''',
    );
  }

  test_manifest_extensionType_implements_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A(int it) implements Object {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        interface: #M3
          map
            it: #M2
''',
      updatedCode: r'''
extension type A(int it) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M4
        declaredFields
          it: #M5
        declaredGetters
          it: #M6
        interface: #M7
          map
            it: #M6
''',
    );
  }

  test_manifest_extensionType_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
extension type A(int it) {}

@Deprecated('0')
extension type B(int it) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        interface: #M3
          map
            it: #M2
      B: #M4
        declaredFields
          it: #M5
        declaredGetters
          it: #M6
        interface: #M7
          map
            it: #M6
''',
      updatedCode: r'''
@Deprecated('0')
extension type A(int it) {}

@Deprecated('1')
extension type B(int it) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        interface: #M3
          map
            it: #M2
      B: #M8
        declaredFields
          it: #M9
        declaredGetters
          it: #M10
        interface: #M11
          map
            it: #M10
''',
    );
  }

  test_manifest_extensionType_method() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A(int it) {
  int foo() {}
  int bar() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
            it: #M2
''',
      updatedCode: r'''
extension type A(int it) {
  int foo() {}
  double bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          bar: #M6
          foo: #M4
        interface: #M7
          map
            bar: #M6
            foo: #M4
            it: #M2
''',
    );
  }

  test_manifest_extensionType_representation_constructorName() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A.foo(int it) {
  void baz() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          baz: #M3
        declaredConstructors
          foo: #M4
        interface: #M5
          map
            baz: #M3
            it: #M2
''',
      updatedCode: r'''
extension type A.bar(int it) {
  void baz() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          baz: #M3
        declaredConstructors
          bar: #M6
        interface: #M5
          map
            baz: #M3
            it: #M2
''',
    );
  }

  test_manifest_extensionType_representation_field_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A(int it) {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
            it: #M2
''',
      updatedCode: r'''
extension type A(int _it) {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          _it: #M5
        declaredGetters
          _it: #M6
        declaredMethods
          foo: #M3
        interface: #M7
          map
            foo: #M3
''',
    );
  }

  test_manifest_extensionType_representation_field_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A(int it) {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
            it: #M2
''',
      updatedCode: r'''
extension type A(double it) {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M5
        declaredGetters
          it: #M6
        declaredMethods
          foo: #M3
        interface: #M7
          map
            foo: #M3
            it: #M6
''',
    );
  }

  test_manifest_extensionType_setter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A(int it) {
  set foo(int _) {}
  set bar(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
          it: #M3
        declaredGetters
          it: #M4
        declaredSetters
          bar=: #M5
          foo=: #M6
        interface: #M7
          map
            bar=: #M5
            foo=: #M6
            it: #M4
''',
      updatedCode: r'''
extension type A(int it) {
  set foo(int _) {}
  set bar(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          bar: #M8
          foo: #M2
          it: #M3
        declaredGetters
          it: #M4
        declaredSetters
          bar=: #M9
          foo=: #M6
        interface: #M10
          map
            bar=: #M9
            foo=: #M6
            it: #M4
''',
    );
  }

  test_manifest_extensionType_typeParameters() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A<T>(int it) {
  void foo(T _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
            it: #M2
''',
      updatedCode: r'''
extension type A<T>(int it) {
  void foo(T _) {}
  void bar(T _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        declaredMethods
          bar: #M5
          foo: #M3
        interface: #M6
          map
            bar: #M5
            foo: #M3
            it: #M2
''',
    );
  }

  test_manifest_extensionType_typeParameters_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
extension type A<T>(int it) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M0
        declaredFields
          it: #M1
        declaredGetters
          it: #M2
        interface: #M3
          map
            it: #M2
''',
      updatedCode: r'''
extension type A<T, U>(int it) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredExtensionTypes
      A: #M4
        declaredFields
          it: #M5
        declaredGetters
          it: #M6
        interface: #M7
          map
            it: #M6
''',
    );
  }

  test_manifest_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@deprecated
int get a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
@deprecated
int get a => 0;
int get b => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_metadata_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
int get a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
@deprecated
int get a => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M1
''',
    );
  }

  test_manifest_metadata_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@deprecated
int get a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
int get a => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M1
''',
    );
  }

  test_manifest_metadata_simpleIdentifier_change() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
@a
int get foo => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      foo: #M1
    declaredVariables
      a: #M2
      foo: #M3
''',
      updatedCode: r'''
const a = 1;
@a
int get foo => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      foo: #M4
    declaredVariables
      a: #M5
      foo: #M3
''',
    );
  }

  test_manifest_metadata_simpleIdentifier_replace() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@deprecated
int get a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
@override
int get a => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M1
''',
    );
  }

  test_manifest_mixin_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
''',
      updatedCode: r'''
mixin A {}
mixin B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_field_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
      updatedCode: r'''
mixin A {
  final a = 0;
  final b = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
          b: #M4
        declaredGetters
          a: #M2
          b: #M5
        interface: #M6
          map
            a: #M2
            b: #M5
''',
    );
  }

  test_manifest_mixin_field_initializer_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
      updatedCode: r'''
mixin A {
  final a = 1.2;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M4
        declaredGetters
          a: #M5
        interface: #M6
          map
            a: #M5
''',
    );
  }

  test_manifest_mixin_field_initializer_value_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
      updatedCode: r'''
mixin A {
  final a = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
          map
            a: #M2
''',
    );
  }

  test_manifest_mixin_field_initializer_value_static_const() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static const a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static const a = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M4
        declaredGetters
          a: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_field_initializer_value_static_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static final a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static final a = 1;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_field_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  @Deprecated('0')
  var a = 0;
  @Deprecated('0')
  var b = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
          b: #M2
        declaredGetters
          a: #M3
          b: #M4
        declaredSetters
          a=: #M5
          b=: #M6
        interface: #M7
          map
            a: #M3
            a=: #M5
            b: #M4
            b=: #M6
''',
      updatedCode: r'''
mixin A {
  @Deprecated('0')
  var a = 0;
  @Deprecated('1')
  var b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
          b: #M8
        declaredGetters
          a: #M3
          b: #M9
        declaredSetters
          a=: #M5
          b=: #M10
        interface: #M11
          map
            a: #M3
            a=: #M5
            b: #M9
            b=: #M10
''',
    );
  }

  test_manifest_mixin_field_private_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  final _a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _a: #M1
        declaredGetters
          _a: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  final _a = 0;
  final b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _a: #M1
          b: #M4
        declaredGetters
          _a: #M2
          b: #M5
        interface: #M6
          map
            b: #M5
''',
    );
  }

  test_manifest_mixin_field_private_static_const() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static const _a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _a: #M1
        declaredGetters
          _a: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static const _a = 0;
  static const b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _a: #M1
          b: #M4
        declaredGetters
          _a: #M2
          b: #M5
        interface: #M3
''',
    );
  }

  test_manifest_mixin_field_private_var() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  var _a = 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _a: #M1
        declaredGetters
          _a: #M2
        declaredSetters
          _a=: #M3
        interface: #M4
''',
      updatedCode: r'''
mixin A {
  var _a = 0;
  var b = 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _a: #M1
          b: #M5
        declaredGetters
          _a: #M2
          b: #M6
        declaredSetters
          _a=: #M3
          b=: #M7
        interface: #M8
          map
            b: #M6
            b=: #M7
''',
    );
  }

  test_manifest_mixin_field_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  int? a;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M1
        declaredGetters
          a: #M2
        declaredSetters
          a=: #M3
        interface: #M4
          map
            a: #M2
            a=: #M3
''',
      updatedCode: r'''
mixin A {
  double? a;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          a: #M5
        declaredGetters
          a: #M6
        declaredSetters
          a=: #M7
        interface: #M8
          map
            a: #M6
            a=: #M7
''',
    );
  }

  test_manifest_mixin_getter_add_implements() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  int get foo => 0;
}

mixin B implements A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
mixin A {
  int get foo => 0;
  int get bar => 0;
}

mixin B implements A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_mixin_getter_add_implements_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  T get foo => 0;
}

mixin B implements A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
mixin A<T> {
  T get foo => 0;
  T get bar => 0;
}

mixin B implements A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_mixin_getter_add_on() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  int get foo => 0;
}

mixin B on A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
mixin A {
  int get foo => 0;
  int get bar => 0;
}

mixin B on A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_mixin_getter_add_on_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  T get foo => 0;
}

mixin B on A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
      B: #M4
        interface: #M5
          map
            foo: #M2
''',
      updatedCode: r'''
mixin A<T> {
  T get foo => 0;
  T get bar => 0;
}

mixin B on A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredGetters
          bar: #M7
          foo: #M2
        interface: #M8
          map
            bar: #M7
            foo: #M2
      B: #M4
        interface: #M9
          map
            bar: #M7
            foo: #M2
''',
    );
  }

  test_manifest_mixin_getter_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  @Deprecated('0')
  int get foo => 0;
  @Deprecated('0')
  int get bar => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M4
        interface: #M5
          map
            bar: #M3
            foo: #M4
''',
      updatedCode: r'''
mixin A {
  @Deprecated('1')
  int get foo => 0;
  @Deprecated('0')
  int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredGetters
          bar: #M3
          foo: #M6
        interface: #M7
          map
            bar: #M3
            foo: #M6
''',
    );
  }

  test_manifest_mixin_getter_private_instance() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  int get _foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
        declaredGetters
          _foo: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  int get _foo => 0;
  int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredGetters
          _foo: #M2
          bar: #M5
        interface: #M6
          map
            bar: #M5
''',
    );
  }

  test_manifest_mixin_getter_private_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static int get _foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
        declaredGetters
          _foo: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static int get _foo => 0;
  int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredGetters
          _foo: #M2
          bar: #M5
        interface: #M6
          map
            bar: #M5
''',
    );
  }

  test_manifest_mixin_getter_returnType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        superclassConstraints
          Object @ dart:core
        declaredFields
          foo: #M1
            type: int @ dart:core
        declaredGetters
          foo: #M2
            returnType: int @ dart:core
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
mixin A {
  double get foo => 1.2;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        superclassConstraints
          Object @ dart:core
        declaredFields
          foo: #M4
            type: double @ dart:core
        declaredGetters
          foo: #M5
            returnType: double @ dart:core
        interface: #M6
          map
            foo: #M5
''',
    );
  }

  test_manifest_mixin_getter_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static int get foo => 0;
  static int get bar => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M4
          foo: #M1
        declaredGetters
          bar: #M5
          foo: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_getter_static_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
''',
      updatedCode: r'''
mixin A {
  static int get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M6
''',
    );
  }

  test_manifest_mixin_getter_static_returnType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static double get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M3
''',
    );
  }

  test_manifest_mixin_getter_static_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static int get foo => 0;
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  int get foo => 0;
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M4
        declaredGetters
          foo: #M5
        interface: #M6
          map
            foo: #M5
''',
    );
  }

  test_manifest_mixin_interfacesAdd() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {}
mixin B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A implements B {}
mixin B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M4
        interface: #M5
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_interfacesRemove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A implements B {}
mixin B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {}
mixin B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M4
        interface: #M5
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_interfacesReplace() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A implements B {}
mixin B {}
mixin C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
      updatedCode: r'''
mixin A implements C {}
mixin B {}
mixin C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M6
        interface: #M7
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
    );
  }

  test_manifest_mixin_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
mixin A {}
@Deprecated('0')
mixin B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
@Deprecated('0')
mixin A {}
@Deprecated('1')
mixin B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M4
        interface: #M5
''',
    );
  }

  test_manifest_mixin_method_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A {
  void foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_mixin_method_add_implements() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void foo() {}
}

mixin B implements A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A {
  void foo() {}
  void bar() {}
}

mixin B implements A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_mixin_method_add_implements_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  T foo() {}
}

mixin B implements A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A<T> {
  T foo() {}
  void bar() {}
}

mixin B implements A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_mixin_method_add_on() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void foo() {}
}

mixin B on A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A {
  void foo() {}
  void bar() {}
}

mixin B extends A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_mixin_method_add_on_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  T foo() {}
}

mixin B extends A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
      B: #M3
        interface: #M4
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A<T> {
  T foo() {}
  void bar() {}
}

mixin B extends A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M5
          foo: #M1
        interface: #M6
          map
            bar: #M5
            foo: #M1
      B: #M3
        interface: #M7
          map
            bar: #M5
            foo: #M1
''',
    );
  }

  test_manifest_mixin_method_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  @Deprecated('0')
  void foo() {}
  @Deprecated('0')
  void bar() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
          map
            bar: #M1
            foo: #M2
''',
      updatedCode: r'''
mixin A {
  @Deprecated('1')
  void foo() {}
  @Deprecated('0')
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M4
        interface: #M5
          map
            bar: #M1
            foo: #M4
''',
    );
  }

  test_manifest_mixin_method_private_instance() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void _foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
''',
      updatedCode: r'''
mixin A {
  void _foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          _foo: #M1
          bar: #M3
        interface: #M4
          map
            bar: #M3
''',
    );
  }

  test_manifest_mixin_method_private_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static void _foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          _foo: #M1
        interface: #M2
''',
      updatedCode: r'''
mixin A {
  static void _foo() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          _foo: #M1
          bar: #M3
        interface: #M4
          map
            bar: #M3
''',
    );
  }

  test_manifest_mixin_method_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void foo() {}
  void bar() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M1
          foo: #M2
        interface: #M3
          map
            bar: #M1
            foo: #M2
''',
      updatedCode: r'''
mixin A {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M2
        interface: #M4
          map
            foo: #M2
''',
    );
  }

  test_manifest_mixin_method_returnType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        superclassConstraints
          Object @ dart:core
        declaredMethods
          foo: #M1
            functionType: FunctionType
              returnType: int @ dart:core
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A {
  double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        superclassConstraints
          Object @ dart:core
        declaredMethods
          foo: #M3
            functionType: FunctionType
              returnType: double @ dart:core
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_mixin_method_static_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A {
  static void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
''',
    );
  }

  test_manifest_mixin_method_static_returnType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static int foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
mixin A {
  static double foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M2
''',
    );
  }

  test_manifest_mixin_method_static_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static void foo() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
''',
      updatedCode: r'''
mixin A {
  void foo() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_mixin_method_typeParameter() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  Map<T, U> foo<U>() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        typeParameters
          bound: <null>
        superclassConstraints
          Object @ dart:core
        declaredMethods
          foo: #M1
            functionType: FunctionType
              typeParameters
                bound: <null>
              returnType: Map @ dart:core
                typeParameter#1
                typeParameter#0
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A<T> {
  Map<T, U> foo<U>() {}
  void bar() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        typeParameters
          bound: <null>
        superclassConstraints
          Object @ dart:core
        declaredMethods
          bar: #M3
            functionType: FunctionType
              returnType: void
          foo: #M1
            functionType: FunctionType
              typeParameters
                bound: <null>
              returnType: Map @ dart:core
                typeParameter#1
                typeParameter#0
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_mixin_method_typeParameter_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void foo<T>() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A {
  void foo<T, U>() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_mixin_method_typeParameter_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  void foo<T, U>() {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A {
  void foo<T>() {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M3
        interface: #M4
          map
            foo: #M3
''',
    );
  }

  test_manifest_mixin_onAdd_direct() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {}
mixin B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A on B {}
mixin B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M4
        interface: #M5
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_onAdd_indirect() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A on B {}
mixin B {}
mixin C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
      updatedCode: r'''
mixin A on B {}
mixin B on C {}
mixin C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M6
        interface: #M7
      B: #M8
        interface: #M9
      C: #M4
        interface: #M5
''',
    );
  }

  test_manifest_mixin_onChange() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A on B {}
mixin B {}
mixin C {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
      updatedCode: r'''
mixin A on C {}
mixin B {}
mixin C {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M6
        interface: #M7
      B: #M2
        interface: #M3
      C: #M4
        interface: #M5
''',
    );
  }

  test_manifest_mixin_private() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin _A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      _A: #M0
        interface: #M1
''',
      updatedCode: r'''
mixin _A {}
mixin B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      B: #M2
        interface: #M3
      _A: #M0
        interface: #M1
''',
    );
  }

  test_manifest_mixin_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {}
mixin B {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
      B: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin B {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      B: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_setter_add_implements() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  set foo(int _) {}
}

mixin B implements A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
mixin A {
  set foo(int _) {}
  set bar(int _) {}
}

mixin B implements A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_mixin_setter_add_implements_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  set foo(T _) {}
}

mixin B implements A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
mixin A<T> {
  set foo(T _) {}
  set bar(T _) {}
}

mixin B implements A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_mixin_setter_add_on() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  set foo(int _) {}
}

mixin B on A {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
mixin A {
  set foo(int _) {}
  set bar(int _) {}
}

mixin B on A {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_mixin_setter_add_on_generic() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  set foo(T _) {}
}

mixin B on A<int> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
      B: #M4
        interface: #M5
          map
            foo=: #M2
''',
      updatedCode: r'''
mixin A<T> {
  set foo(T _) {}
  set bar(T _) {}
}

mixin B on A<int> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M6
          foo: #M1
        declaredSetters
          bar=: #M7
          foo=: #M2
        interface: #M8
          map
            bar=: #M7
            foo=: #M2
      B: #M4
        interface: #M9
          map
            bar=: #M7
            foo=: #M2
''',
    );
  }

  test_manifest_mixin_setter_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  @Deprecated('0')
  set foo(int _) {}
  @Deprecated('0')
  set bar(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredSetters
          bar=: #M3
          foo=: #M4
        interface: #M5
          map
            bar=: #M3
            foo=: #M4
''',
      updatedCode: r'''
mixin A {
  @Deprecated('1')
  set foo(int _) {}
  @Deprecated('0')
  set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M1
          foo: #M2
        declaredSetters
          bar=: #M3
          foo=: #M6
        interface: #M7
          map
            bar=: #M3
            foo=: #M6
''',
    );
  }

  test_manifest_mixin_setter_private_instance() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  set _foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
        declaredSetters
          _foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  set _foo(int _) {}
  set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredSetters
          _foo=: #M2
          bar=: #M5
        interface: #M6
          map
            bar=: #M5
''',
    );
  }

  test_manifest_mixin_setter_private_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static set _foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
        declaredSetters
          _foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static set _foo(int _) {}
  set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          _foo: #M1
          bar: #M4
        declaredSetters
          _foo=: #M2
          bar=: #M5
        interface: #M6
          map
            bar=: #M5
''',
    );
  }

  test_manifest_mixin_setter_static() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static set foo(int _) {}
  static set bar(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          bar: #M4
          foo: #M1
        declaredSetters
          bar=: #M5
          foo=: #M2
        interface: #M3
''',
    );
  }

  test_manifest_mixin_setter_static_falseToTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
mixin A {
  static set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M6
''',
    );
  }

  test_manifest_mixin_setter_static_trueToFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  set foo(int _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M6
          map
            foo=: #M5
''',
    );
  }

  test_manifest_mixin_setter_static_valueType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  static set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
''',
      updatedCode: r'''
mixin A {
  static set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredFields
          foo: #M4
        declaredSetters
          foo=: #M5
        interface: #M3
''',
    );
  }

  test_manifest_mixin_setter_valueType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A {
  set foo(int _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        superclassConstraints
          Object @ dart:core
        declaredFields
          foo: #M1
            type: int @ dart:core
        declaredSetters
          foo=: #M2
            valueType: int @ dart:core
        interface: #M3
          map
            foo=: #M2
''',
      updatedCode: r'''
mixin A {
  set foo(double _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        superclassConstraints
          Object @ dart:core
        declaredFields
          foo: #M4
            type: double @ dart:core
        declaredSetters
          foo=: #M5
            valueType: double @ dart:core
        interface: #M6
          map
            foo=: #M5
''',
    );
  }

  test_manifest_mixin_typeParameters() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {
  void foo(T _) {}
}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
          map
            foo: #M1
''',
      updatedCode: r'''
mixin A<T> {
  void foo(T _) {}
  void bar(T _) {}
}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        declaredMethods
          bar: #M3
          foo: #M1
        interface: #M4
          map
            bar: #M3
            foo: #M1
''',
    );
  }

  test_manifest_mixin_typeParameters_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
mixin A<T> {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M0
        interface: #M1
''',
      updatedCode: r'''
mixin A<T, U> {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredMixins
      A: #M2
        interface: #M3
''',
    );
  }

  test_manifest_topLevelFunction_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo() {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M0
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_optionalNamed() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo({int a}) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo({int a}) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M0
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_optionalNamed_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo({int a}) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo({int b}) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M2
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_optionalNamed_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo({int a}) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo({double a}) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M2
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_optionalPositional() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo([int a]) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo([int a]) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M0
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_optionalPositional_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo([int a]) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo([int b]) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M0
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_optionalPositional_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo([int a]) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo([double a]) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M2
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredNamed() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo({required int a}) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo({required int a}) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M0
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredNamed_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo({required int a}) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo({required int b}) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M2
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredNamed_toRequiredPositional() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo({required int a}) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo(int a) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M1
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredNamed_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo({required int a}) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo({required double a}) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M2
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredPositional() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo(int a) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo(int a) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M0
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredPositional_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo(int a) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo(int b) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M0
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredPositional_toRequiredNamed() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo(int a) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo({required int a}) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M1
''',
    );
  }

  test_manifest_topLevelFunction_formalParameter_requiredPositional_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo(int a) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo(double a) {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M2
''',
    );
  }

  test_manifest_topLevelFunction_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprected('0')
void a() {}
@Deprected('0')
void b() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      a: #M0
      b: #M1
''',
      updatedCode: r'''
@Deprected('0')
void a() {}
@Deprected('1')
void b() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      a: #M0
      b: #M2
''',
    );
  }

  test_manifest_topLevelFunction_private() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void _foo() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      _foo: #M0
''',
      updatedCode: r'''
void _foo() {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      _foo: #M0
      bar: #M1
''',
    );
  }

  test_manifest_topLevelFunction_returnType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
int foo() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
double foo() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M1
''',
    );
  }

  test_manifest_topLevelFunction_typeParameter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
Map<T, U> foo<T extends num, U>() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
Map<T, U> foo<T, U>() {}
void bar() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      bar: #M1
      foo: #M2
''',
    );
  }

  test_manifest_topLevelFunction_typeParameter_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo<T>() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo<T, U>() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M1
''',
    );
  }

  test_manifest_topLevelFunction_typeParameter_bound() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo<T extends num>() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo<T extends int>() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M1
''',
    );
  }

  test_manifest_topLevelFunction_typeParameter_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
void foo<T, U>() {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M0
''',
      updatedCode: r'''
void foo<T>() {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredFunctions
      foo: #M1
''',
    );
  }

  test_manifest_topLevelGetter_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
int get a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
int get a => 0;
int get b => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_topLevelGetter_body() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
int get a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
int get a => 1;
''',
      expectedUpdatedEvents: r'''
[operation] readLibraryCycleBundle
  package:test/test.dart
''',
    );
  }

  test_manifest_topLevelGetter_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
int get a => 0;
@Deprecated('0')
int get b => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredVariables
      a: #M2
      b: #M3
''',
      updatedCode: r'''
@Deprecated('0')
int get a => 0;
@Deprecated('1')
int get b => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M4
    declaredVariables
      a: #M2
      b: #M3
''',
    );
  }

  test_manifest_topLevelGetter_private() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
int get _a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
    declaredVariables
      _a: #M1
''',
      updatedCode: r'''
int get _a => 0;
int get b => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
      b: #M2
    declaredVariables
      _a: #M1
      b: #M3
''',
    );
  }

  test_manifest_topLevelGetter_returnType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
int get a => 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
double get a => 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_topLevelSetter_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
set a(int _) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredSetters
      a=: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
set a(int _) {}
set b(int _) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredSetters
      a=: #M0
      b=: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_topLevelSetter_body() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
set a(int _) { 0; }
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredSetters
      a=: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
set a(int _) { 1; }
''',
      expectedUpdatedEvents: r'''
[operation] readLibraryCycleBundle
  package:test/test.dart
''',
    );
  }

  test_manifest_topLevelSetter_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
set a(int _) {}
@Deprecated('0')
set b(int _) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredSetters
      a=: #M0
      b=: #M1
    declaredVariables
      a: #M2
      b: #M3
''',
      updatedCode: r'''
@Deprecated('0')
set a(int _) {}
@Deprecated('1')
set b(int _) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredSetters
      a=: #M0
      b=: #M4
    declaredVariables
      a: #M2
      b: #M3
''',
    );
  }

  test_manifest_topLevelSetter_valueType() async {
    configuration.withElementManifests = true;
    await _runLibraryManifestScenario(
      initialCode: r'''
set a(int _) {}
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredSetters
      a=: #M0
        valueType: int @ dart:core
    declaredVariables
      a: #M1
        type: int @ dart:core
''',
      updatedCode: r'''
set a(double _) {}
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredSetters
      a=: #M2
        valueType: double @ dart:core
    declaredVariables
      a: #M3
        type: double @ dart:core
''',
    );
  }

  test_manifest_topLevelVariable_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final a = 0;
final b = 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_topLevelVariable_initializer_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final a = 1.2;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_topLevelVariable_initializer_value_const() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
const a = 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M2
''',
    );
  }

  test_manifest_topLevelVariable_initializer_value_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final a = 1;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
    );
  }

  test_manifest_topLevelVariable_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
var a = 0;
@Deprecated('0')
var b = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M1
    declaredSetters
      a=: #M2
      b=: #M3
    declaredVariables
      a: #M4
      b: #M5
''',
      updatedCode: r'''
@Deprecated('0')
var a = 0;
@Deprecated('1')
var b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M6
    declaredSetters
      a=: #M2
      b=: #M7
    declaredVariables
      a: #M4
      b: #M8
''',
    );
  }

  test_manifest_topLevelVariable_private_const() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
const _a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
    declaredVariables
      _a: #M1
''',
      updatedCode: r'''
const _a = 0;
const b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
      b: #M2
    declaredVariables
      _a: #M1
      b: #M3
''',
    );
  }

  test_manifest_topLevelVariable_private_final() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final _a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
    declaredVariables
      _a: #M1
''',
      updatedCode: r'''
final _a = 0;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
      b: #M2
    declaredVariables
      _a: #M1
      b: #M3
''',
    );
  }

  test_manifest_topLevelVariable_private_var() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
var _a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
    declaredSetters
      _a=: #M1
    declaredVariables
      _a: #M2
''',
      updatedCode: r'''
var _a = 0;
var b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      _a: #M0
      b: #M3
    declaredSetters
      _a=: #M1
      b=: #M4
    declaredVariables
      _a: #M2
      b: #M5
''',
    );
  }

  test_manifest_topLevelVariable_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
int? a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredSetters
      a=: #M1
    declaredVariables
      a: #M2
''',
      updatedCode: r'''
double? a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M3
    declaredSetters
      a=: #M4
    declaredVariables
      a: #M5
''',
    );
  }

  test_manifest_type_dynamicType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final dynamic a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final dynamic a = 0;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_dynamicType_to_interfaceType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final dynamic a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final int a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final int Function() a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final int Function() a;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_functionType_named() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function({int p1}) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function({int p1}) a;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_functionType_named_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function({int p1}) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function({int p1, double p2}) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_named_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function({int p1, double p2}) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function({int p1}) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_named_toPositional() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function({int p}) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function(int p) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_named_toRequiredFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function({required int p1}) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function({int p1}) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_named_toRequiredTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function({int p1}) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function({required int p1}) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_named_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function({int p1}) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function({double p1}) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_nullabilitySuffix() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final int Function() a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final int Function()? a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_positional() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function(int p1) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function(int p1) a;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_functionType_positional_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function(int p1) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function(int p1, double p2) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_positional_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function(int p1, double p2) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function(int p1) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_positional_toNamed() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function(int p) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function({int p}) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_positional_toRequiredFalse() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function(int p1) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function([int p1]) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_positional_toRequiredTrue() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function([int p1]) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function(int p1) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_positional_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function(int p1) a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function(double p1) a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_returnType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final int Function() a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final double Function() a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_typeParameter() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final T Function<T>() a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final T Function<T>() a;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_functionType_typeParameter_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function<E1>() a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function<E1, E2>() a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_typeParameter_bound() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final T Function<T extends int>() a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final T Function<T extends double>() a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_functionType_typeParameter_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void Function<E1, E2>() a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void Function<E1>() a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_interfaceType_element() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final int a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final double a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_interfaceType_nullabilitySuffix() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final int a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final int? a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_interfaceType_typeArguments() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final List<int> a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final List<double> a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_invalidType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final NotType a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final NotType a = 0;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_neverType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final Never a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final Never a;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_neverType_nullabilitySuffix() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final Never a;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final Never? a;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_namedFields() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final ({int f1}) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final ({int f1}) a = 0;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_recordType_namedFields_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final ({int f1}) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final ({int f1, double f2}) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_namedFields_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final ({int f1}) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final ({int f2}) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_namedFields_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final ({int f1, double f2}) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final ({int f1}) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_namedFields_reorder() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final ({int f1, double f2}) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final ({double f2, int f1}) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
    );
  }

  test_manifest_type_recordType_namedFields_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final ({int f1}) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final ({double f1}) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_nullabilitySuffix() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final (int,) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final (int,)? a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_positionalFields() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final (int,) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final (int,) a = 0;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_type_recordType_positionalFields_add() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final (int,) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final (int, double) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_positionalFields_name() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final (int x,) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final (int y,) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
    );
  }

  test_manifest_type_recordType_positionalFields_remove() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final (int, double) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final (int,) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_recordType_positionalFields_type() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final (int,) a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final (double,) a = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M2
    declaredVariables
      a: #M3
''',
    );
  }

  test_manifest_type_voidType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
final void a = 0;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
''',
      updatedCode: r'''
final void a = 0;
final b = 0;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      a: #M0
      b: #M2
    declaredVariables
      a: #M1
      b: #M3
''',
    );
  }

  test_manifest_typeAlias_aliasedType_functionType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
typedef A = int Function();
typedef B = int Function();
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredTypeAliases
      A: #M0
      B: #M1
''',
      updatedCode: r'''
typedef A = int Function();
typedef B = double Function();
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredTypeAliases
      A: #M0
      B: #M2
''',
    );
  }

  test_manifest_typeAlias_aliasedType_interfaceType() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
typedef A = int;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredTypeAliases
      A: #M0
''',
      updatedCode: r'''
typedef A = double;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredTypeAliases
      A: #M1
''',
    );
  }

  test_manifest_typeAlias_aliasedType_metadata() async {
    await _runLibraryManifestScenario(
      initialCode: r'''
@Deprecated('0')
typedef A = int;

@Deprecated('0')
typedef B = int;
''',
      expectedInitialEvents: r'''
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
    declaredTypeAliases
      A: #M0
      B: #M1
''',
      updatedCode: r'''
@Deprecated('0')
typedef A = int;

@Deprecated('1')
typedef B = int;
''',
      expectedUpdatedEvents: r'''
[operation] linkLibraryCycle
  package:test/test.dart
    declaredTypeAliases
      A: #M0
      B: #M2
''',
    );
  }

  test_operation_addFile_affected() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationAddTestFile(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
double get a => 0;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M5
    declaredVariables
      a: #M6
  requirements
    topLevels
      dart:core
        double: #M7
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M8
    declaredVariables
      x: #M9
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M5
[operation] produceErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M5
[status] idle
''',
    );
  }

  test_operation_addFile_notAffected() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationAddTestFile(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
int get a => 0;
int get b => 0;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M5
    declaredVariables
      a: #M1
      b: #M6
  requirements
    topLevels
      dart:core
        int: #M2
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ErrorsResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[status] idle
''',
    );
  }

  test_operation_getErrors_affected() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
double get a => 0;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M5
    declaredVariables
      a: #M6
  requirements
    topLevels
      dart:core
        double: #M7
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M8
    declaredVariables
      x: #M9
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M5
[operation] getErrorsCannotReuse
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M5
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #3
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M5
[status] idle
''',
    );
  }

  test_operation_getErrors_notAffected() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationTestFileGetErrors(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getErrors T1
  ErrorsResult #0
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[operation] analyzeFile
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[stream]
  ResolvedUnitResult #1
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: exists isLibrary
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
int get a => 0;
int get b => 0;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M5
    declaredVariables
      a: #M1
      b: #M6
  requirements
    topLevels
      dart:core
        int: #M2
[future] getErrors T2
  ErrorsResult #2
    path: /home/test/lib/test.dart
    uri: package:test/test.dart
    flags: isLibrary
[operation] readLibraryCycleBundle
  package:test/test.dart
[operation] getErrorsFromBytes
  file: /home/test/lib/test.dart
  library: /home/test/lib/test.dart
[status] idle
''',
    );
  }

  test_operation_getLibraryByUri_affected() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
double get a => 1.2;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M5
    declaredVariables
      a: #M6
  requirements
    topLevels
      dart:core
        double: #M7
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: double
[operation] cannotReuseLinkedBundle
  topLevelIdMismatch
    libraryUri: package:test/a.dart
    name: a
    expectedId: #M0
    actualId: #M5
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M8
    declaredVariables
      x: #M9
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M5
[status] idle
''',
    );
  }

  test_operation_getLibraryByUri_notAffected() async {
    await _runChangeScenarioTA(
      initialA: r'''
int get a => 0;
''',
      testCode: r'''
import 'a.dart';
final x = a;
''',
      operation: _FineOperationGetTestLibrary(),
      expectedInitialEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[future] getLibraryByUri T1
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
    declaredVariables
      a: #M1
  requirements
    topLevels
      dart:core
        int: #M2
[operation] linkLibraryCycle
  package:test/test.dart
    declaredGetters
      x: #M3
    declaredVariables
      x: #M4
  requirements
    topLevels
      dart:core
        a: <null>
      package:test/a.dart
        a: #M0
[status] idle
''',
      updatedA: r'''
int get a => 0;
int get b => 0;
''',
      expectedUpdatedEvents: r'''
[status] working
[operation] linkLibraryCycle
  package:test/a.dart
    declaredGetters
      a: #M0
      b: #M5
    declaredVariables
      a: #M1
      b: #M6
  requirements
    topLevels
      dart:core
        int: #M2
[future] getLibraryByUri T2
  library
    topLevelVariables
      final hasInitializer x
        type: int
[operation] readLibraryCycleBundle
  package:test/test.dart
[status] idle
''',
    );
  }

  test_req_classElement_noName() async {
    newFile(testFile.path, r'''
class {}
''');

    _ManualRequirements.install((state) {
      var e = state.singleUnit.libraryElement.classes.single;
      e.getNamedConstructor('foo');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
[status] idle
''',
    );
  }

  test_req_extensionElement_noName() async {
    newFile(testFile.path, r'''
extension on int {
  void foo() {}
}
''');

    _ManualRequirements.install((state) {
      var e = state.singleUnit.libraryElement.extensions.single;
      e.getMethod('foo');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
    topLevels
      dart:core
        int: #M0
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        int: #M0
[status] idle
''',
    );
  }

  test_req_instanceElement_fields() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  static final int foo = 0;
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.fields;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredFields: #M1
[status] idle
''',
    );
  }

  test_req_instanceElement_getField() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  final int foo = 0;
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getField('foo');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
[status] idle
''',
    );
  }

  test_req_instanceElement_getGetter() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  static int get foo {}
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getGetter('foo');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedGetters
            foo: #M2
[status] idle
''',
    );
  }

  test_req_instanceElement_getMethod() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  static int foo() {}
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getMethod('foo');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedMethods
            foo: #M1
[status] idle
''',
    );
  }

  test_req_instanceElement_getMethod_doesNotExist() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getMethod('foo');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        interface: #M1
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedMethods
            foo: <null>
[status] idle
''',
    );
  }

  test_req_instanceElement_getSetter() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  static set foo(int _) {}
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getSetter('foo');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedSetters
            foo=: #M2
[status] idle
''',
    );
  }

  test_req_instanceElement_getterElement_variable() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  int foo = 0;
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getGetter('foo')!.variable;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
          requestedGetters
            foo: #M2
[status] idle
''',
    );
  }

  test_req_instanceElement_getterElement_variable_synthetic() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  int get foo => 0;
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getGetter('foo')!.variable;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
          requestedGetters
            foo: #M2
[status] idle
''',
    );
  }

  test_req_instanceElement_getters() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  int get foo => 0;
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getters;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        interface: #M3
          map
            foo: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredGetters: #M2
[status] idle
''',
    );
  }

  test_req_instanceElement_methods() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  static int foo() {}
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.methods;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredMethods
          foo: #M1
        interface: #M2
  requirements
    topLevels
      dart:core
        int: #M3
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredMethods: #M1
[status] idle
''',
    );
  }

  test_req_instanceElement_setterElement_variable() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  int foo = 0;
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getSetter('foo')!.variable;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredGetters
          foo: #M2
        declaredSetters
          foo=: #M3
        interface: #M4
          map
            foo: #M2
            foo=: #M3
  requirements
    topLevels
      dart:core
        int: #M5
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
          requestedSetters
            foo=: #M3
[status] idle
''',
    );
  }

  test_req_instanceElement_setterElement_variable_synthetic() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  set foo(int _) {}
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.getSetter('foo')!.variable;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          requestedFields
            foo: #M1
          requestedSetters
            foo=: #M2
[status] idle
''',
    );
  }

  test_req_instanceElement_setters() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  set foo(int _) {}
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInstanceElement('A');
      A.setters;
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredFields
          foo: #M1
        declaredSetters
          foo=: #M2
        interface: #M3
          map
            foo=: #M2
  requirements
    topLevels
      dart:core
        int: #M4
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    instances
      package:test/a.dart
        A
          allDeclaredSetters: #M2
[status] idle
''',
    );
  }

  test_req_interfaceElement_getConstructor_named() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {
  A.named();
}
''');

    newFile(testFile.path, r'''
import 'a.dart';
''');

    _ManualRequirements.install((state) {
      var A = state.singleUnit.scopeInterfaceElement('A');
      A.getNamedConstructor('named');
    });

    await _runManualRequirementsRecording(
      expectedEvents: r'''
[status] working
[operation] linkLibraryCycle SDK
[operation] linkLibraryCycle
  package:test/a.dart
    declaredClasses
      A: #M0
        declaredConstructors
          named: #M1
        interface: #M2
  requirements
[operation] linkLibraryCycle
  package:test/test.dart
  requirements
[operation] analyzedLibrary
  file: /home/test/lib/test.dart
  requirements
    topLevels
      dart:core
        A: <null>
      package:test/a.dart
        A: #M0
    interfaces
      package:test/a.dart
        A
          constructors
            named: #M1
[status] idle
''',
    );
  }

  Future<void> _runChangeScenario({
    required _FineOperation operation,
    String? expectedInitialEvents,
    required List<File> Function() updateFiles,
    required String expectedUpdatedEvents,
  }) async {
    void setId(String id) {
      NodeTextExpectationsCollector.intraInvocationId = id;
    }

    withFineDependencies = true;
    configuration
      ..withResultRequirements = true
      ..withLibraryManifest = true
      ..withLinkBundleEvents = true;

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver, idProvider: idProvider);

    configuration.elementTextConfiguration
      ..withLibraryFragments = false
      ..withReferences = false
      ..withSyntheticGetters = false;

    switch (operation) {
      case _FineOperationAddTestFile():
        driver.addFile2(testFile);
      case _FineOperationTestFileGetErrors():
        collector.getErrors('T1', testFile);
      case _FineOperationGetTestLibrary():
        collector.getLibraryByUri('T1', 'package:test/test.dart');
    }

    if (expectedInitialEvents != null) {
      setId('expectedInitialEvents');
      await assertEventsText(collector, expectedInitialEvents);
    } else {
      await collector.nextStatusIdle();
      collector.take();
    }

    var updatedFiles = updateFiles();
    for (var updatedFile in updatedFiles) {
      driver.changeFile2(updatedFile);
    }

    switch (operation) {
      case _FineOperationAddTestFile():
        // Nothing to do here, wait for analysis of previous added files.
        break;
      case _FineOperationTestFileGetErrors():
        collector.getErrors('T2', testFile);
      case _FineOperationGetTestLibrary():
        collector.getLibraryByUri('T2', 'package:test/test.dart');
    }

    setId('expectedUpdatedEvents');
    await assertEventsText(collector, expectedUpdatedEvents);
  }

  Future<void> _runChangeScenarioTA({
    required String initialA,
    required String testCode,
    required _FineOperation operation,
    String? expectedInitialEvents,
    required String updatedA,
    required String expectedUpdatedEvents,
  }) async {
    var a = newFile('$testPackageLibPath/a.dart', initialA);
    newFile('$testPackageLibPath/test.dart', testCode);

    await _runChangeScenario(
      operation: operation,
      expectedInitialEvents: expectedInitialEvents,
      updateFiles: () {
        modifyFile2(a, updatedA);
        return [a];
      },
      expectedUpdatedEvents: expectedUpdatedEvents,
    );
  }

  Future<void> _runLibraryManifestScenario({
    required String initialCode,
    String? expectedInitialEvents,
    String? expectedInitialDriverState,
    List<File> Function()? updateFiles,
    required String updatedCode,
    required String expectedUpdatedEvents,
    String? expectedUpdatedDriverState,
  }) async {
    void setId(String id) {
      NodeTextExpectationsCollector.intraInvocationId = id;
    }

    newFile(testFile.path, initialCode);

    withFineDependencies = true;
    configuration
      ..withGetLibraryByUri = false
      ..withLibraryManifest = true
      ..withLinkBundleEvents = true
      ..withSchedulerStatus = false;

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver, idProvider: idProvider);

    var libraryUri = Uri.parse('package:test/test.dart');
    collector.getLibraryByUri('T1', '$libraryUri');

    if (expectedInitialEvents != null) {
      setId('expectedInitialEvents');
      await assertEventsText(collector, expectedInitialEvents);
    } else {
      await collector.nextStatusIdle();
      collector.take();
    }

    if (expectedInitialDriverState != null) {
      assertDriverStateString(testFile, expectedInitialDriverState);
    }

    if (updateFiles != null) {
      var updatedFiles = updateFiles();
      for (var updatedFile in updatedFiles) {
        driver.changeFile2(updatedFile);
      }
    }

    modifyFile2(testFile, updatedCode);
    driver.changeFile2(testFile);

    collector.getLibraryByUri('T2', '$libraryUri');

    setId('expectedUpdatedEvents');
    await assertEventsText(collector, expectedUpdatedEvents);

    if (expectedUpdatedDriverState != null) {
      assertDriverStateString(testFile, expectedUpdatedDriverState);
    }
  }

  /// Works together with [_ManualRequirements] to execute manual requests to
  /// the element model, and observe which requirements are recorded.
  Future<void> _runManualRequirementsRecording({
    required String expectedEvents,
  }) async {
    withFineDependencies = true;
    configuration
      ..withAnalyzeFileEvents = false
      ..withLibraryManifest = true
      ..withLinkBundleEvents = true
      ..withGetErrorsEvents = false
      ..withResultRequirements = true
      ..withStreamResolvedUnitResults = false;

    var driver = driverFor(testFile);
    var collector = DriverEventCollector(driver, idProvider: idProvider);

    collector.getErrors('T1', testFile);
    await assertEventsText(collector, expectedEvents);
  }
}

/// A lint that is always reported for all linted files.
class _AlwaysReportedLint extends LintRule {
  static final instance = _AlwaysReportedLint();

  static const LintCode code = LintCode(
    'always_reported_lint',
    'This lint is reported for all files',
  );

  _AlwaysReportedLint() : super(name: 'always_reported_lint', description: '');

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    var visitor = _AlwaysReportedLintVisitor(this);
    registry.addCompilationUnit(this, visitor);
  }
}

/// A visitor for [_AlwaysReportedLint] that reports the lint for all files.
class _AlwaysReportedLintVisitor extends SimpleAstVisitor<void> {
  final LintRule rule;

  _AlwaysReportedLintVisitor(this.rule);

  @override
  void visitCompilationUnit(CompilationUnit node) {
    rule.reportAtOffset(0, 0);
  }
}

mixin _EventsMixin {
  final IdProvider idProvider = IdProvider();
  final DriverEventsPrinterConfiguration configuration =
      DriverEventsPrinterConfiguration();

  Future<void> assertEventsText(
    DriverEventCollector collector,
    String expected,
  ) async {
    await pumpEventQueue(times: 5000);

    var buffer = StringBuffer();
    var sink = TreeStringSink(sink: buffer, indent: '');

    var elementPrinter = ElementPrinter(
      sink: sink,
      configuration: ElementPrinterConfiguration(),
    );

    var events = collector.take();
    DriverEventsPrinter(
      configuration: configuration,
      sink: sink,
      elementPrinter: elementPrinter,
      idProvider: collector.idProvider,
    ).write(events);

    var actual = buffer.toString();
    if (actual != expected) {
      print('-------- Actual --------');
      print('$actual------------------------');
      NodeTextExpectationsCollector.add(actual);
    }
    expect(actual, expected);
  }
}

sealed class _FineOperation {
  const _FineOperation();
}

final class _FineOperationAddTestFile extends _FineOperation {
  const _FineOperationAddTestFile();
}

final class _FineOperationGetTestLibrary extends _FineOperation {
  const _FineOperationGetTestLibrary();
}

final class _FineOperationTestFileGetErrors extends _FineOperation {
  const _FineOperationTestFileGetErrors();
}

/// Helper for triggering requirements manually.
///
/// Some [Element] APIs are not trivial, or maybe even impossible, to
/// trigger. For example because this API is not used during normal resolution
/// of Dart code, but can be used by a linter rule.
class _ManualRequirements {
  final List<CompilationUnitImpl> units;

  _ManualRequirements(this.units);

  _ManualRequirementsUnit get singleUnit {
    var unit = units.single;
    return _ManualRequirementsUnit(unit);
  }

  static void install(void Function(_ManualRequirements) operation) {
    testFineAfterLibraryAnalyzerHook = (units) {
      var self = _ManualRequirements(units);
      operation(self);
    };
  }
}

class _ManualRequirementsUnit {
  final CompilationUnitImpl unit;

  _ManualRequirementsUnit(this.unit);

  LibraryElementImpl get libraryElement {
    return libraryFragment.element;
  }

  LibraryFragmentImpl get libraryFragment {
    return unit.declaredFragment!;
  }

  ClassElementImpl scopeClassElement(String name) {
    return scopeInterfaceElement(name) as ClassElementImpl;
  }

  InstanceElementImpl scopeInstanceElement(String name) {
    var lookupResult = libraryFragment.scope.lookup(name);
    return lookupResult.getter as InstanceElementImpl;
  }

  InterfaceElementImpl scopeInterfaceElement(String name) {
    return scopeInstanceElement(name) as InterfaceElementImpl;
  }
}

extension on AnalysisDriver {
  Future<void> assertFilesDefiningClassMemberName(
    String name,
    List<File?> expected,
  ) async {
    var fileStateList = await getFilesDefiningClassMemberName(name);
    var files = fileStateList.resources;
    expect(files, unorderedEquals(expected));
  }

  Future<void> assertFilesReferencingName(
    String name, {
    required List<File?> includesAll,
    required List<File?> excludesAll,
  }) async {
    var fileStateList = await getFilesReferencingName(name);
    var files = fileStateList.resources;
    for (var expected in includesAll) {
      expect(files, contains(expected));
    }
    for (var expected in excludesAll) {
      expect(files, isNot(contains(expected)));
    }
  }

  void assertLoadedLibraryUriSet({
    Iterable<String>? included,
    Iterable<String>? excluded,
  }) {
    var uriSet = testView!.loadedLibraryUriSet;
    if (included != null) {
      expect(uriSet, containsAll(included));
    }
    if (excluded != null) {
      for (var excludedUri in excluded) {
        expect(uriSet, isNot(contains(excludedUri)));
      }
    }
  }

  FileResult getFileSyncValid(File file) {
    return getFileSync2(file) as FileResult;
  }

  Future<LibraryElementResult> getLibraryByUriValid(String uriStr) async {
    return await getLibraryByUri(uriStr) as LibraryElementResult;
  }
}
