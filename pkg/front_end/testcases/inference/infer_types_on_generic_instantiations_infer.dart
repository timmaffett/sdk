// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*@testedFeatures=inference*/
library test;

class A<T> {
  final T x = throw '';
}

class B implements A<int> {
  /*error:INVALID_METHOD_OVERRIDE*/ dynamic get x => 3;
}

foo() {
  String y = /*info:DYNAMIC_CAST*/ new B(). /*@target=B.x*/ x; // TypeError.
  int z = /*info:DYNAMIC_CAST*/ new B(). /*@target=B.x*/ x;
}

main() {
  try {
    foo();
  } on TypeError {}
}
