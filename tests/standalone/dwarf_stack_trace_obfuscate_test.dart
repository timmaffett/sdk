// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// VMOptions=--dwarf-stack-traces --save-debugging-info=$TEST_COMPILATION_DIR/dwarf_obfuscate.so --obfuscate

import 'dart:io';

import 'package:expect/config.dart';
import 'package:native_stack_traces/native_stack_traces.dart';
import 'package:path/path.dart' as path;

import 'dwarf_stack_trace_test.dart' as base;

@pragma("vm:prefer-inline")
bar() {
  // Keep the 'throw' and its argument on separate lines.
  throw // force linebreak with dart format
  "Hello, Dwarf!";
}

@pragma("vm:never-inline")
foo() {
  bar();
}

Future<void> main() async {
  String rawStack = "";
  try {
    foo();
  } catch (e, st) {
    rawStack = st.toString();
  }

  if (!isVmAotConfiguration) {
    return; // Not running from an AOT compiled snapshot.
  }

  if (Platform.isAndroid) {
    return; // Generated dwarf.so not available on the test device.
  }

  if (Platform.script.toString().endsWith(".dll")) {
    return; // DWARF not available in DLLs.
  }

  final dwarf = Dwarf.fromFile(
    path.join(
      Platform.environment['TEST_COMPILATION_DIR']!,
      "dwarf_obfuscate.so",
    ),
  )!;

  await base.checkStackTrace(rawStack, dwarf, expectedCallsInfo);
}

final expectedCallsInfo = <List<DartCallInfo>>[
  // The first frame should correspond to the throw in bar, which was inlined
  // into foo (so we'll get information for two calls for that PC address).
  [
    DartCallInfo(
      function: "bar",
      filename: "dwarf_stack_trace_obfuscate_test.dart",
      line: 18,
      column: 3,
      inlined: true,
    ),
    DartCallInfo(
      function: "foo",
      filename: "dwarf_stack_trace_obfuscate_test.dart",
      line: 24,
      column: 3,
      inlined: false,
    ),
  ],
  // The second frame corresponds to call to foo in main.
  [
    DartCallInfo(
      function: "main",
      filename: "dwarf_stack_trace_obfuscate_test.dart",
      line: 30,
      column: 5,
      inlined: false,
    ),
  ],
  // Don't assume anything about any of the frames below the call to foo
  // in main, as this makes the test too brittle.
];
