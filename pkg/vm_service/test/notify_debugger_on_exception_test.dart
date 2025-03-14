// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// VMOptions=--verbose_debug

// See: https://github.com/flutter/flutter/issues/17007

import 'common/service_test_common.dart';
import 'common/test_helper.dart';

// AUTOGENERATED START
//
// Update these constants by running:
//
// dart pkg/vm_service/test/update_line_numbers.dart pkg/vm_service/test/notify_debugger_on_exception_test.dart
//
const LINE_A = 23;
const LINE_B = 39;
// AUTOGENERATED END

Never syncThrow() {
  throw 'Hello from syncThrow!'; // LINE_A
}

@pragma('vm:notify-debugger-on-exception')
void catchNotifyDebugger(Function() code) {
  try {
    code();
  } catch (e) {
    // Ignore. Internals will notify debugger.
  }
}

void catchNotifyDebuggerNested() {
  @pragma('vm:notify-debugger-on-exception')
  void nested() {
    try {
      throw 'Hello from nested!'; // LINE_B
    } catch (e) {
      // Ignore. Internals will notify debugger.
    }
  }

  nested();
}

void testMain() {
  catchNotifyDebugger(syncThrow);
  catchNotifyDebuggerNested();
}

final tests = <IsolateTest>[
  hasStoppedWithUnhandledException,
  stoppedAtLine(LINE_A),
  resumeIsolate,
  hasStoppedWithUnhandledException,
  stoppedAtLine(LINE_B),
];

void main([args = const <String>[]]) => runIsolateTests(
      args,
      tests,
      'notify_debugger_on_exception_test.dart',
      testeeConcurrent: testMain,
      pauseOnUnhandledExceptions: true,
    );
