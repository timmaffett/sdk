// Copyright (c) 2015, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:linter/src/test_utilities/analysis_error_info.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import '../tool/util/formatter.dart';
import 'mocks.dart';

void main() {
  defineTests();
}

void defineTests() {
  group('formatter', () {
    test('pluralize', () {
      expect(pluralize('issue', 0), '0 issues');
      expect(pluralize('issue', 1), '1 issue');
      expect(pluralize('issue', 2), '2 issues');
    });

    group('reporter', () {
      late DiagnosticInfo info;
      late StringBuffer out;
      late String sourcePath;
      late ReportFormatter reporter;

      setUp(() async {
        var lineInfo = LineInfo([3, 6, 9]);

        var type = MockDiagnosticType()..displayName = 'test';

        var code = TestDiagnosticCode('mock_code', 'MSG')..type = type;

        await d.dir('project', [
          d.file('foo.dart', '''
var x = 11;
var y = 22;
var z = 33;
'''),
        ]).create();
        sourcePath = '${d.sandbox}/project/foo.dart';
        var source = MockSource(sourcePath);

        var error = Diagnostic.tmp(
          source: source,
          offset: 10,
          length: 3,
          diagnosticCode: code,
        );

        info = DiagnosticInfo([error], lineInfo);
        out = StringBuffer();
        reporter = ReportFormatter([info], out)..write();
      });

      test('count', () {
        expect(reporter.errorCount, 1);
      });

      test('write', () {
        expect(out.toString().trim(), '''$sourcePath 3:2 [test] MSG
var z = 33;
 ^^^

files analyzed, 1 issue found.''');
      });

      test('stats', () {
        out.clear();
        ReportFormatter([info], out).write();
        expect(
          out.toString(),
          startsWith('''$sourcePath 3:2 [test] MSG
var z = 33;
 ^^^

files analyzed, 1 issue found.
'''),
        );
      });
    });
  });
}
