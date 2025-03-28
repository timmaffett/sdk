// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Fails because this.x parameter is used in a setter.

class Foo {
  var x;
  set y(this.x) {}
  //    ^^^^
  // [analyzer] SYNTACTIC_ERROR.FIELD_INITIALIZER_OUTSIDE_CONSTRUCTOR
  //    ^^^^^^
  // [analyzer] COMPILE_TIME_ERROR.FIELD_INITIALIZER_OUTSIDE_CONSTRUCTOR
  // [cfe] Field formal parameters can only be used in a constructor.
}

main() {
  Foo().y = 2;
}
