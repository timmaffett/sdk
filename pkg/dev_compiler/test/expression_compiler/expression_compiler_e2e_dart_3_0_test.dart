// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dev_compiler/src/compiler/module_builder.dart'
    show ModuleFormat;
import 'package:test/test.dart';

import '../shared_test_options.dart';
import 'expression_compiler_e2e_suite.dart';

void main(List<String> args) async {
  var driver = await ExpressionEvaluationTestDriver.init();

  group('Dart 3.0 language features', () {
    tearDownAll(() async {
      await driver.finish();
    });

    group('(AMD module system)', () {
      var setup = SetupCompilerOptions(
        moduleFormat: ModuleFormat.amd,
        args: args,
      );
      runSharedTests(setup, driver);
    });

    group('(DDC module system)', () {
      var setup = SetupCompilerOptions(
        moduleFormat: ModuleFormat.ddc,
        args: args,
      );
      runSharedTests(setup, driver);
    });
  });
}

/// Shared tests for language features introduced in version 3.0.0.
void runSharedTests(
  SetupCompilerOptions setup,
  ExpressionEvaluationTestDriver driver,
) {
  group('Records', () {
    const recordsSource = '''
    void main() {
      var r = (true, 3);
      var cr = (true, {'a':1, 'b': 2});
      var nr = (true, (false, 3));

      // Breakpoint: bp
      print('hello world');
    }
    ''';

    setUpAll(() async {
      await driver.initSource(setup, recordsSource);
    });

    tearDownAll(() async {
      await driver.cleanupTest();
    });

    test('simple record', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'r.toString()',
        expectedResult: '(true, 3)',
      );
    });

    test('simple record type', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'r.runtimeType.toString()',
        expectedResult: '(bool, int)',
      );
    });

    test('simple record field one', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'r.\$1.toString()',
        expectedResult: 'true',
      );
    });

    test('simple record field two', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'r.\$2.toString()',
        expectedResult: '3',
      );
    });

    test('complex record', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'cr.toString()',
        expectedResult: '(true, {a: 1, b: 2})',
      );
    });

    test('complex record type', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'cr.runtimeType.toString()',
        expectedResult: '(bool, IdentityMap<String, int>)',
      );
    });

    test('complex record field one', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'cr.\$1.toString()',
        expectedResult: 'true',
      );
    });

    test('complex record field two', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'cr.\$2.toString()',
        expectedResult: '{a: 1, b: 2}',
      );
    });

    test('nested record', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'nr.toString()',
        expectedResult: '(true, (false, 3))',
      );
    });

    test('nested record type', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'nr.runtimeType.toString()',
        expectedResult: '(bool, (bool, int))',
      );
    });

    test('nested record field one', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'nr.\$1.toString()',
        expectedResult: 'true',
      );
    });

    test('nested record field two', () async {
      await driver.checkInFrame(
        breakpointId: 'bp',
        expression: 'nr.\$2.toString()',
        expectedResult: '(false, 3)',
      );
    });
  });

  group('Patterns', () {
    const patternsSource = r'''
    void main() {
      int foo(Object? obj) {
        switch (obj) {
          case [int a, double b] || [double b, int a]:
            // Breakpoint: bp1
            return a;
          case [int a, String b] || [String b, int a]:
            // Breakpoint: bp2
            return a;
          default:
            // Breakpoint: bp3
           return 0;
        }
      }

      final one = foo([1,2]);
      final ten = foo([10,'20']);
      final zero = foo(0);

      // Breakpoint: bp4
      print('$one, $ten, $zero');
    }
    ''';

    setUpAll(() async {
      await driver.initSource(setup, patternsSource);
    });

    tearDownAll(() async {
      await driver.cleanupTest();
    });

    test('first case match', () async {
      await driver.checkInFrame(
        breakpointId: 'bp1',
        expression: 'a.toString()',
        expectedResult: '1',
      );
    });

    test('second case match', () async {
      await driver.checkInFrame(
        breakpointId: 'bp2',
        expression: 'a.toString()',
        expectedResult: '10',
      );
    });

    test('default case match', () async {
      await driver.checkInFrame(
        breakpointId: 'bp3',
        expression: 'obj.toString()',
        expectedResult: '0',
      );
    });

    test('first case match result', () async {
      await driver.checkInFrame(
        breakpointId: 'bp4',
        expression: 'one.toString()',
        expectedResult: '1',
      );
    });

    test('second case match result', () async {
      await driver.checkInFrame(
        breakpointId: 'bp4',
        expression: 'ten.toString()',
        expectedResult: '10',
      );
    });

    test('default match result', () async {
      await driver.checkInFrame(
        breakpointId: 'bp4',
        expression: 'zero.toString()',
        expectedResult: '0',
      );
    });

    test('first case scope', () async {
      await driver.checkScope(
        breakpointId: 'bp1',
        expectedScope: {'a': '1', 'b': '2', 'obj': 'obj'},
      );
    });

    test('second case scope', () async {
      await driver.checkScope(
        breakpointId: 'bp2',
        expectedScope: {'a\$': '10', 'b\$': '\'20\'', 'obj': 'obj'},
      );
    });

    test('default case scope', () async {
      await driver.checkScope(breakpointId: 'bp3', expectedScope: {'obj': '0'});
    });

    test('result scope', () async {
      await driver.checkScope(
        breakpointId: 'bp4',
        expectedScope: {'foo': 'foo', 'one': '1', 'ten': '10', 'zero': '0'},
      );
    });
  });

  group('Shadowing', () {
    // Includes similar names that could collide due to renaming scheme.
    const shadowingSource = r'''
    void main() {
      String a = '1';
      String a$ = '2';
      String a$0 = '3';
      String a$360 = '4';
      if (a case Object a) {
        a = '5$a';
        // Breakpoint: bp1
        print(a);
      }
      if (a$ case Object a$) {
        a$ = '10${a$}';
        print(a$);
      }
      if (a$ case Object a$) {
        a$ = '6${a$}';
        // Breakpoint: bp2
        print(a$);
      }
      if (a$0 case Object a$0) {
        a$0 = '7${a$0}';
        // Breakpoint: bp3
        print(a$0);
      }
      if (a$360 case Object a$360) {
        a$360 = '8${a$360}';
        // Breakpoint: bp4
        print(a$360);
      }
      // Breakpoint: bp5
      print('$a, ${a$}, ${a$0}, ${a$360}');
    }
    ''';

    setUpAll(() async {
      await driver.initSource(setup, shadowingSource);
    });

    tearDownAll(() async {
      await driver.cleanupTest();
    });

    group('bp1', () {
      test('a', () async {
        await driver.checkInFrame(
          breakpointId: 'bp1',
          expression: 'a.toString()',
          expectedResult: '51',
        );
      });

      test('a\$', () async {
        await driver.checkInFrame(
          breakpointId: 'bp1',
          expression: 'a\$.toString()',
          expectedResult: '2',
        );
      });

      test('a\$0', () async {
        await driver.checkInFrame(
          breakpointId: 'bp1',
          expression: 'a\$0.toString()',
          expectedResult: '3',
        );
      });

      test('a\$360', () async {
        await driver.checkInFrame(
          breakpointId: 'bp1',
          expression: 'a\$360.toString()',
          expectedResult: '4',
        );
      });
    });

    group('bp2', () {
      test('a', () async {
        await driver.checkInFrame(
          breakpointId: 'bp2',
          expression: 'a.toString()',
          expectedResult: '1',
        );
      });

      test('a\$', () async {
        await driver.checkInFrame(
          breakpointId: 'bp2',
          expression: 'a\$.toString()',
          expectedResult: '62',
        );
      });

      test('a\$0', () async {
        await driver.checkInFrame(
          breakpointId: 'bp2',
          expression: 'a\$0.toString()',
          expectedResult: '3',
        );
      });

      test('a\$360', () async {
        await driver.checkInFrame(
          breakpointId: 'bp2',
          expression: 'a\$360.toString()',
          expectedResult: '4',
        );
      });
    });

    group('bp3', () {
      test('a', () async {
        await driver.checkInFrame(
          breakpointId: 'bp3',
          expression: 'a.toString()',
          expectedResult: '1',
        );
      });

      test('a\$', () async {
        await driver.checkInFrame(
          breakpointId: 'bp3',
          expression: 'a\$.toString()',
          expectedResult: '2',
        );
      });

      test('a\$0', () async {
        await driver.checkInFrame(
          breakpointId: 'bp3',
          expression: 'a\$0.toString()',
          expectedResult: '73',
        );
      });

      test('a\$360', () async {
        await driver.checkInFrame(
          breakpointId: 'bp3',
          expression: 'a\$360.toString()',
          expectedResult: '4',
        );
      });
    });

    group('bp4', () {
      test('a', () async {
        await driver.checkInFrame(
          breakpointId: 'bp4',
          expression: 'a.toString()',
          expectedResult: '1',
        );
      });

      test('a\$', () async {
        await driver.checkInFrame(
          breakpointId: 'bp4',
          expression: 'a\$.toString()',
          expectedResult: '2',
        );
      });

      test('a\$0', () async {
        await driver.checkInFrame(
          breakpointId: 'bp4',
          expression: 'a\$0.toString()',
          expectedResult: '3',
        );
      });

      test('a\$360', () async {
        await driver.checkInFrame(
          breakpointId: 'bp4',
          expression: 'a\$360.toString()',
          expectedResult: '84',
        );
      });
    });

    group('bp5', () {
      test('a', () async {
        await driver.checkInFrame(
          breakpointId: 'bp5',
          expression: 'a.toString()',
          expectedResult: '1',
        );
      });

      test('a\$', () async {
        await driver.checkInFrame(
          breakpointId: 'bp5',
          expression: 'a\$.toString()',
          expectedResult: '2',
        );
      });

      test('a\$0', () async {
        await driver.checkInFrame(
          breakpointId: 'bp5',
          expression: 'a\$0.toString()',
          expectedResult: '3',
        );
      });

      test('a\$360', () async {
        await driver.checkInFrame(
          breakpointId: 'bp5',
          expression: 'a\$360.toString()',
          expectedResult: '4',
        );
      });
    });
  });
}
