// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analyzer_cli/src/driver.dart' show Driver, outSink, errorSink;
import 'package:analyzer_cli/src/options.dart' show ExitHandler, exitHandler;
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'utils.dart' show recursiveCopy, testDirectory, withTempDirAsync;

void main() {
  defineReflectiveTests(OptionsTest);
}

@reflectiveTest
class OptionsTest {
  final _Runner _runner = _Runner.setUp();

  void tearDown() {
    _runner.tearDown();
  }

  Future<void> test_options() async {
    // Copy to the temp directory so that existing analysis options in the test
    // directory hierarchy do not interfere.
    var projDir = path.join(testDirectory, 'data', 'flutter_analysis_options');
    await withTempDirAsync((String tempDirPath) async {
      await recursiveCopy(Directory(projDir), tempDirPath);
      var expectedPath = path.join(
        tempDirPath,
        'somepkgs',
        'flutter',
        'lib',
        'analysis_options.yaml',
      );
      expect(FileSystemEntity.isFileSync(expectedPath), isTrue);
      await _runner.run2([
        '--packages',
        path.join(tempDirPath, 'packagelist'),
        path.join(tempDirPath, 'lib', 'main.dart'),
      ]);
      expect(_runner.stdout, contains('The parameter \'child\' is required'));
      // Should be a warning as specified in 'analysis_options.yaml'.
      expect(_runner.stdout, contains('1 warning found'));
    });
  }
}

class _Runner {
  final _stdout = StringBuffer();
  final _stderr = StringBuffer();

  final StringSink _savedOutSink;
  final StringSink _savedErrorSink;
  final int _savedExitCode;
  final ExitHandler _savedExitHandler;

  _Runner.setUp()
    : _savedOutSink = outSink,
      _savedErrorSink = errorSink,
      _savedExitHandler = exitHandler,
      _savedExitCode = exitCode {
    outSink = _stdout;
    errorSink = _stderr;
    exitHandler = (_) {};
  }

  String get stderr => _stderr.toString();

  String get stdout => _stdout.toString();

  Future<void> run2(List<String> args) async {
    await Driver().start(args);
    if (stderr.isNotEmpty) {
      fail('Unexpected output to stderr:\n$stderr');
    }
  }

  void tearDown() {
    outSink = _savedOutSink;
    errorSink = _savedErrorSink;
    exitCode = _savedExitCode;
    exitHandler = _savedExitHandler;
  }
}
