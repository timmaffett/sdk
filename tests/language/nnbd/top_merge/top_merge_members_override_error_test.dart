// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

// Tests several aspects of the TOP_MERGE algorithm for merging super-interfaces.
// This tests that TOP_MERGE is not applied when a class directly overrides a
// method. Instead, the signature of the overriding method should apply.

class A<T> {
  T member() {
    throw "Unreachable";
  }
}

void takesObject(Object x) {}

class D0 extends A<dynamic> {
  Object? member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'Object?'.
    x.toString; // Check that member does not return `void`
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'Object?' can't be assigned to the parameter type 'Object'.
  }
}

class D1 extends A<Object?> {
  dynamic member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member returns `dynamic`
  }
}

class D2 extends A<void> {
  Object? member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'Object?'.
    x.toString; // Check that member does not return `void`
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'Object?' can't be assigned to the parameter type 'Object'.
  }
}

class D3 extends A<Object?> {
  void member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object?`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class D4 extends A<void> {
  dynamic member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member returns `dynamic`
  }
}

class D5 extends A<dynamic> {
  void member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object?`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class D6 extends A<void> {
  void member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object?`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class D7 extends A<dynamic> {
  dynamic member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member returns `dynamic`
  }
}

// Test the same examples with top level normalization

class ND0 extends A<FutureOr<dynamic>> {
  Object? member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();

    x.foo; // Check that member does not return `dynamic`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'Object?'.
    x.toString; // Check that member does not return `void`
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'Object?' can't be assigned to the parameter type 'Object'.
  }
}

class ND1 extends A<FutureOr<Object?>> {
  dynamic member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member returns `dynamic`
  }
}

class ND2 extends A<FutureOr<void>> {
  Object? member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'Object?'.
    x.toString; // Check that member does not return `void`
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'Object?' can't be assigned to the parameter type 'Object'.
  }
}

class ND3 extends A<FutureOr<Object?>> {
  void member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object?`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class ND4 extends A<FutureOr<void>> {
  dynamic member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member returns `dynamic`
  }
}

class ND5 extends A<FutureOr<dynamic>> {
  void member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object?`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class ND6 extends A<FutureOr<void>> {
  void member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member does not return `dynamic`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object?`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class ND7 extends A<FutureOr<dynamic>> {
  dynamic member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member();
    x.foo; // Check that member returns `dynamic`
  }
}

// Test the same examples with deep normalization

class DND0 extends A<FutureOr<dynamic> Function()> {
  Object? Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'Object?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'Object?' can't be assigned to the parameter type 'Object'.
  }
}

class DND1 extends A<FutureOr<Object?> Function()> {
  dynamic Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member returns `dynamic Function()`
  }
}

class DND2 extends A<FutureOr<void> Function()> {
  Object? Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'Object?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'Object?' can't be assigned to the parameter type 'Object'.
  }
}

class DND3 extends A<FutureOr<Object?> Function()> {
  void Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object? Function()`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class DND4 extends A<FutureOr<void> Function()> {
  dynamic Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member returns `dynamic Function()`
  }
}

class DND5 extends A<FutureOr<dynamic> Function()> {
  void Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object? Function()`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class DND6 extends A<FutureOr<void> Function()> {
  void Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] The getter 'foo' isn't defined for the type 'void'.
    x.toString; // Check that member does not return `Object? Function()`
    // [error column 5]
    // [cfe] This expression has type 'void' and can't be used.
    //^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.USE_OF_VOID_RESULT
    // [cfe] This expression has type 'void' and can't be used.
  }
}

class DND7 extends A<FutureOr<dynamic> Function()> {
  dynamic Function() member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member returns `dynamic Function()`
  }
}

// Test the same examples with deep normalization + typedefs

// With all override examples, no normalization is specified, and so
// all errors and warnings should look like the `Object?` errors and
// warnings (we don't distinguish between the method sets on `Object?`
// and `FutureOr<T>` for any `T`).

typedef Wrap<T> = FutureOr<T>? Function();

class WND0 extends A<Wrap<FutureOr<dynamic>>> {
  Wrap<FutureOr<Object?>> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<FutureOr<Object?>>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<FutureOr<Object?>>?' can't be assigned to the parameter type 'Object'.
  }
}

class WND1 extends A<Wrap<FutureOr<Object?>>> {
  Wrap<dynamic> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<dynamic>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<dynamic>?' can't be assigned to the parameter type 'Object'.
  }
}

class WND2 extends A<Wrap<FutureOr<void>>> {
  Wrap<Object?> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<Object?>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<Object?>?' can't be assigned to the parameter type 'Object'.
  }
}

class WND3 extends A<Wrap<FutureOr<Object?>>> {
  Wrap<void> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<void>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<void>?' can't be assigned to the parameter type 'Object'.
  }
}

class WND4 extends A<Wrap<FutureOr<void>>> {
  Wrap<dynamic> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<dynamic>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<dynamic>?' can't be assigned to the parameter type 'Object'.
  }
}

class WND5 extends A<Wrap<FutureOr<dynamic>>> {
  Wrap<void> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<void>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<void>?' can't be assigned to the parameter type 'Object'.
  }
}

class WND6 extends A<Wrap<FutureOr<void>>> {
  Wrap<void> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<void>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<void>?' can't be assigned to the parameter type 'Object'.
  }
}

class WND7 extends A<Wrap<FutureOr<dynamic>>> {
  Wrap<dynamic> member() {
    throw "Unreachable";
  }

  void test() {
    var self = this;
    var x = self.member()();
    x.foo; // Check that member does not return `dynamic Function()`
    //^^^
    // [analyzer] COMPILE_TIME_ERROR.UNCHECKED_USE_OF_NULLABLE_VALUE
    // [cfe] The getter 'foo' isn't defined for the type 'FutureOr<dynamic>?'.
    x.toString; // Check that member does not return `void Function()`
    takesObject(x); // Check that member does not return `Object Function()`
    //          ^
    // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
    // [cfe] The argument type 'FutureOr<dynamic>?' can't be assigned to the parameter type 'Object'.
  }
}
