// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Tests pre-pattern legacy behavior.
// @dart=2.19

import 'package:expect/expect.dart';

void main() {
  var a = [1, 2, 3][2];
  switch (a) {
    case 0.0:
      // ^^^
      // [analyzer] COMPILE_TIME_ERROR.CASE_EXPRESSION_TYPE_IMPLEMENTS_EQUALS
      // [analyzer] COMPILE_TIME_ERROR.CASE_EXPRESSION_TYPE_IS_NOT_SWITCH_EXPRESSION_SUBTYPE
      // [cfe] Case expression '0.0' does not have a primitive operator '=='.
      // [cfe] Type 'double' of the case expression is not a subtype of type 'int' of this switch expression.
      print("illegal");
      break;
    case 1:
      print("OK");
  }
}
