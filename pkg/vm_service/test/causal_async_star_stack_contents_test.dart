// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// VMOptions=--verbose_debug

import 'dart:developer';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'common/service_test_common.dart';
import 'common/test_helper.dart';

// AUTOGENERATED START
//
// Update these constants by running:
//
// dart pkg/vm_service/test/update_line_numbers.dart pkg/vm_service/test/causal_async_star_stack_contents_test.dart
//
const LINE_0 = 32;
const LINE_B = 33;
const LINE_1 = 34;
const LINE_C = 35;
const LINE_2 = 41;
const LINE_A = 42;
const LINE_D = 43;
// AUTOGENERATED END

Stream<int> foobar() async* {
  // ignore: await_only_futures
  await 0; // force async gap
  debugger(); // LINE_0
  yield 1; // LINE_B
  debugger(); // LINE_1
  yield 2; // LINE_C
}

Future<void> helper() async {
  // ignore: await_only_futures
  await 0; // force async gap
  debugger(); // LINE_2
  print('helper'); // LINE_A
  await for (var i in foobar()) /* LINE_D */ {
    print('helper $i');
  }
}

void testMain() {
  helper();
}

final tests = <IsolateTest>[
  hasStoppedAtBreakpoint,
  stoppedAtLine(LINE_2),
  stepOver,
  hasStoppedAtBreakpoint,
  stoppedAtLine(LINE_A),
  (VmService service, IsolateRef isolateRef) async {
    final Stack stack = await service.getStack(isolateRef.id!);
    // No causal frames because we are in a completely synchronous stack.
    expect(stack.asyncCausalFrames, isNotNull);
    final asyncStack = stack.asyncCausalFrames!;
    expect(asyncStack.length, greaterThanOrEqualTo(1));
    expect(asyncStack[0].function!.name, contains('helper'));
    // helper isn't awaited.
  },
  resumeIsolate,
  hasStoppedAtBreakpoint,
  stoppedAtLine(LINE_0),
  stepOver,
  hasStoppedAtBreakpoint,
  stoppedAtLine(LINE_B),
  (VmService service, IsolateRef isolateRef) async {
    final Stack stack = await service.getStack(isolateRef.id!);
    // Has causal frames (we are inside an async function)
    expect(stack.asyncCausalFrames, isNotNull);
    final asyncStack = stack.asyncCausalFrames!;
    expect(asyncStack.length, greaterThanOrEqualTo(3));
    expect(asyncStack[0].function!.name, contains('foobar'));
    expect(asyncStack[1].kind, equals(FrameKind.kAsyncSuspensionMarker));
    expect(asyncStack[2].function!.name, contains('helper'));
    expect(asyncStack[3].kind, equals(FrameKind.kAsyncSuspensionMarker));
  },
  resumeIsolate,
  hasStoppedAtBreakpoint,
  stoppedAtLine(LINE_1),
  stepOver,
  hasStoppedAtBreakpoint,
  stoppedAtLine(LINE_C),
  (VmService service, IsolateRef isolateRef) async {
    final Stack stack = await service.getStack(isolateRef.id!);
    // Has causal frames (we are inside a function called by an async function)
    expect(stack.asyncCausalFrames, isNotNull);
    final asyncStack = stack.asyncCausalFrames!;
    expect(asyncStack.length, greaterThanOrEqualTo(4));
    final script = await service.getObject(
      isolateRef.id!,
      asyncStack[0].location!.script!.id!,
    ) as Script;
    expect(asyncStack[0].function!.name, contains('foobar'));
    expect(
      script.getLineNumberFromTokenPos(asyncStack[0].location!.tokenPos!),
      LINE_C,
    );
    expect(asyncStack[1].kind, equals(FrameKind.kAsyncSuspensionMarker));
    expect(asyncStack[2].function!.name, contains('helper'));
    expect(
      script.getLineNumberFromTokenPos(asyncStack[2].location!.tokenPos!),
      LINE_D,
    );
    expect(asyncStack[3].kind, equals(FrameKind.kAsyncSuspensionMarker));
  },
];

void main([args = const <String>[]]) => runIsolateTests(
      args,
      tests,
      'causal_async_star_stack_contents_test.dart',
      testeeConcurrent: testMain,
      extraArgs: extraDebuggingArgs,
    );
