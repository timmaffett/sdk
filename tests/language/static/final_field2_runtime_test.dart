// TODO(multitest): This was automatically migrated from a multitest and may
// contain strange or dead code.

// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// Disallow re-assignment of a final static variable.

class A {
  static const x = 1;
}

class B {
  const B() : n = 5;
  final n;

  static const b = 3 + 5;
}

main() {
  new B();
  print(B.b);
}
