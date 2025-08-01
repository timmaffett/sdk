// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// dart2jsOptions=-O1

// Formatting can break multitests, so don't format them.
// dart format off

import 'package:expect/expect.dart';

class A {
  String? field;
}

class B {
  int? field;
}

@pragma('dart2js:noInline')
assign(d) {
  d.field = 0;
}

main() {
  Expect.throws(() => assign(new A()));
  assign(new B()); //# 01: ok
}
