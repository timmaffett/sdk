// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/assist.dart';
import 'package:analyzer_plugin/utilities/assist/assist.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'assist_processor.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ConvertPartOfToUriTest);
  });
}

@reflectiveTest
class ConvertPartOfToUriTest extends AssistProcessorTest {
  @override
  AssistKind get kind => DartAssistKind.convertPartOfToUri;

  Future<void> test_nonSibling() async {
    newFile('$testPackageLibPath/foo.dart', '''
// @dart = 3.4
// preEnhancedParts
library foo;
part 'src/bar.dart';
''');

    testFilePath = convertPath('$testPackageLibPath/src/bar.dart');
    addTestSource('''
// @dart = 3.4
// preEnhancedParts
part of f^oo;
''');

    await analyzeTestPackageFiles();
    await resolveTestFile();
    await assertHasAssist('''
// @dart = 3.4
// preEnhancedParts
part of '../foo.dart';
''');
  }

  Future<void> test_sibling() async {
    newFile('$testPackageLibPath/foo.dart', '''
// @dart = 3.4
// preEnhancedParts
library foo;
part 'bar.dart';
''');

    testFilePath = convertPath('$testPackageLibPath/bar.dart');
    addTestSource('''
// @dart = 3.4
// preEnhancedParts
part of f^oo;
''');

    await analyzeTestPackageFiles();
    await resolveTestFile();
    await assertHasAssist('''
// @dart = 3.4
// preEnhancedParts
part of 'foo.dart';
''');
  }
}
