// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Formatting can break multitests, so don't format them.
// dart format off

// Regression test for Issue 15744
// Also, tests that syntax errors in reflected classes are reported correctly.

library lib;

import 'dart:mirrors';

class MD {
  final String name;
  const MD({required this.name});
}

@MD(name: 'A')
class A {}

@MD(name: 'B')
class B {
  static x = { 0: 0; }; // //# 01: compile-time error
}

main() {
  reflectClass(A).metadata;
  reflectClass(B).newInstance(Symbol.empty, []);
}
