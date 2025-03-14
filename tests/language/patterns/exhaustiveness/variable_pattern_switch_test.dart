// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

enum E { a, b }

void exhaustiveSwitch1((E, bool) r) {
  switch (r) /* Ok */ {
    case (E.a, var b):
      print('(a, *)');
      break;
    case (E.b, bool b):
      print('(b, *)');
      break;
  }
}

void exhaustiveSwitch2((E, bool) r) {
  switch (r) /* Ok */ {
    case (E.a, true):
      print('(a, false)');
      break;
    case (E a, bool b):
      print('(*, *)');
      break;
  }
}

void nonExhaustiveSwitch1((E, bool) r) {
  switch (r) /* Error */ {
    // [error column 3, length 6]
    // [analyzer] COMPILE_TIME_ERROR.NON_EXHAUSTIVE_SWITCH_STATEMENT
    //    ^
    // [cfe] The type '(E, bool)' is not exhaustively matched by the switch cases since it doesn't match '(E.b, false)'.
    case (E.a, var b):
      print('(a, *)');
      break;
    case (E.b, true):
      print('(b, true)');
      break;
  }
}

void nonExhaustiveSwitch2((E, bool) r) {
  switch (r) /* Error */ {
    // [error column 3, length 6]
    // [analyzer] COMPILE_TIME_ERROR.NON_EXHAUSTIVE_SWITCH_STATEMENT
    //    ^
    // [cfe] The type '(E, bool)' is not exhaustively matched by the switch cases since it doesn't match '(E.b, true)'.
    case (var a, false):
      print('(*, false)');
      break;
    case (E.a, true):
      print('(a, true)');
      break;
  }
}

void nonExhaustiveSwitch3((E, bool) r) {
  switch (r) /* Error */ {
    // [error column 3, length 6]
    // [analyzer] COMPILE_TIME_ERROR.NON_EXHAUSTIVE_SWITCH_STATEMENT
    //    ^
    // [cfe] The type '(E, bool)' is not exhaustively matched by the switch cases since it doesn't match '(E.b, true)'.
    case (E a, false):
      print('(*, false)');
      break;
    case (E.a, true):
      print('(a, true)');
      break;
  }
}

void nonExhaustiveSwitchWithDefault((E, bool) r) {
  switch (r) /* Ok */ {
    case (E.a, var b):
      print('(a, *)');
      break;
    default:
      print('default');
      break;
  }
}

void exhaustiveNullableSwitch((E, bool)? r) {
  switch (r) /* Ok */ {
    case (E.a, var b):
      print('(a, *)');
      break;
    case (E.b, bool b):
      print('(b, *)');
      break;
    case null:
      print('null');
      break;
  }
}

void nonExhaustiveNullableSwitch1((E, bool)? r) {
  switch (r) /* Error */ {
    // [error column 3, length 6]
    // [analyzer] COMPILE_TIME_ERROR.NON_EXHAUSTIVE_SWITCH_STATEMENT
    //    ^
    // [cfe] The type '(E, bool)?' is not exhaustively matched by the switch cases since it doesn't match 'null'.
    case (E a, bool b):
      print('(*, *)');
      break;
  }
}

void nonExhaustiveNullableSwitch2((E, bool)? r) {
  switch (r) /* Error */ {
    // [error column 3, length 6]
    // [analyzer] COMPILE_TIME_ERROR.NON_EXHAUSTIVE_SWITCH_STATEMENT
    //    ^
    // [cfe] The type '(E, bool)?' is not exhaustively matched by the switch cases since it doesn't match '(E.a, true)'.
    case (E a, false):
      print('(*, false)');
      break;
    case (E.b, true):
      print('(b, true)');
      break;
    case null:
      print('null');
      break;
  }
}

void unreachableCase1((E, bool) r) {
  switch (r) /* Ok */ {
    case (E.a, false):
      print('(a, false)');
      break;
    case (E.b, false):
      print('(b, false)');
      break;
    case (E.a, true):
      print('(a, true)');
      break;
    case (E.b, true):
      print('(b, true)');
      break;
    case (E a, bool b): // Unreachable
      // [error column 5, length 4]
      // [analyzer] STATIC_WARNING.UNREACHABLE_SWITCH_CASE
      print('(*, *)');
      break;
  }
}

void unreachableCase2((E, bool) r) {
  // TODO(johnniwinther): Should we avoid the unreachable error here?
  switch (r) /* Error */ {
    case (E a, bool b):
      print('(*, *)');
      break;
    case null: // Unreachable
      print('null');
      break;
  }
}

void unreachableCase3((E, bool)? r) {
  switch (r) /* Ok */ {
    case (var a, var b):
      print('(*, *)');
      break;
    case null:
      print('null1');
      break;
    case null: // Unreachable
      // [error column 5, length 4]
      // [analyzer] STATIC_WARNING.UNREACHABLE_SWITCH_CASE
      print('null2');
      break;
  }
}
