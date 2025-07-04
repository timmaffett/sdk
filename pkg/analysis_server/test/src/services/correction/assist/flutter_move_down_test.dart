// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/assist.dart';
import 'package:analyzer_plugin/utilities/assist/assist.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'assist_processor.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(FlutterMoveDownTest);
  });
}

@reflectiveTest
class FlutterMoveDownTest extends AssistProcessorTest {
  @override
  AssistKind get kind => DartAssistKind.flutterMoveDown;

  @override
  void setUp() {
    super.setUp();
    writeTestPackageConfig(flutter: true);
  }

  Future<void> test_first() async {
    await resolveTestCode('''
import 'package:flutter/material.dart';
void f() {
  Column(
    children: <Widget>[
      Text('aaa'),
      ^Text('bbbbbb'),
      Text('ccccccccc'),
    ],
  );
}
''');
    await assertHasAssist('''
import 'package:flutter/material.dart';
void f() {
  Column(
    children: <Widget>[
      Text('aaa'),
      Text('ccccccccc'),
      Text('bbbbbb'),
    ],
  );
}
''');
    assertExitPosition(before: "Text('bbbbbb')");
  }

  Future<void> test_last() async {
    await resolveTestCode('''
import 'package:flutter/material.dart';
void f() {
  Column(
    children: <Widget>[
      Text('aaa'),
      Text('bbb'),
      ^Text('ccc'),
    ],
  );
}
''');
    await assertNoAssist();
  }

  Future<void> test_notInList() async {
    await resolveTestCode('''
import 'package:flutter/material.dart';
void f() {
  Center(
    child: ^Text('aaa'),
  );
}
''');
    await assertNoAssist();
  }
}
