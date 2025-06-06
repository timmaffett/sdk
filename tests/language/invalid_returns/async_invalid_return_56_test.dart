// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

/* `return exp;` where `exp` has static type `S` is an error if the future
 * value type of the function is `void` and `flatten(S)` is not
 * `void`, `dynamic`, `Null`, `void*`, `dynamic*`, or `Null*`.
 */

int v = 0;

FutureOr<void> test1() async {
  return v;
  //     ^
  // [analyzer] COMPILE_TIME_ERROR.RETURN_OF_INVALID_TYPE
  // [cfe] A value of type 'int' can't be returned from an async function with return type 'FutureOr<void>'.
}

// Inferred return type of function literal is `Future<void>`.
FutureOr<void> Function() test2 = () async {
  return v;
  //     ^
  // [analyzer] COMPILE_TIME_ERROR.RETURN_OF_INVALID_TYPE_FROM_CLOSURE
  // [cfe] A value of type 'int' can't be returned from an async function with return type 'Future<void>'.
};

void main() {
  test1();
  test2();
}
