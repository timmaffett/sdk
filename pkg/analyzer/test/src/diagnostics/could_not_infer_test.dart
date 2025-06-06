// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/error/codes.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../dart/resolution/context_collection_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CouldNotInferTest);
  });
}

// TODO(scheglov): Add tests with non-function typedefs.
// https://github.com/dart-lang/sdk/issues/44078)
@reflectiveTest
class CouldNotInferTest extends PubPackageResolutionTest {
  test_constructors_inferenceFBounded() async {
    await assertErrorsInCode(
      '''
class C<T> {}

class P<T extends C<T>, U extends C<U>> {
  T t;
  U u;
  P(this.t, this.u);
  P._();
  P<U, T> get reversed => new P(u, t);
}

main() {
  P._();
}
''',
      [
        error(
          CompileTimeErrorCode
              .NOT_INITIALIZED_NON_NULLABLE_INSTANCE_FIELD_CONSTRUCTOR,
          94,
          1,
        ),
        error(
          CompileTimeErrorCode
              .NOT_INITIALIZED_NON_NULLABLE_INSTANCE_FIELD_CONSTRUCTOR,
          94,
          1,
        ),
        error(CompileTimeErrorCode.COULD_NOT_INFER, 154, 3),
        error(CompileTimeErrorCode.COULD_NOT_INFER, 154, 3),
        error(
          CompileTimeErrorCode.TYPE_ARGUMENT_NOT_MATCHING_BOUNDS,
          154,
          1,
          contextMessages: [message(testFile, 154, 1)],
        ),
        error(
          CompileTimeErrorCode.TYPE_ARGUMENT_NOT_MATCHING_BOUNDS,
          154,
          1,
          contextMessages: [message(testFile, 154, 1)],
        ),
      ],
    );
  }

  test_constructors_inferFromArguments_argumentNotAssignable() async {
    await assertErrorsInCode(
      '''
class A {}

typedef T F<T>();

class C<T extends A> {
  C(F<T> f);
}

class NotA {}
NotA myF() => null;

main() {
  var x = C(myF);
}
''',
      [
        error(CompileTimeErrorCode.RETURN_OF_INVALID_TYPE_FROM_FUNCTION, 98, 4),
        error(WarningCode.UNUSED_LOCAL_VARIABLE, 120, 1),
        error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 126, 3),
      ],
    );
  }

  test_downwardInference_fixes_noUpwardsErrors() async {
    await assertErrorsInCode(
      r'''
import 'dart:math';
// T max<T extends num>(T x, T y);
main() {
  num x;
  dynamic y;

  num a = max(x, y);
  Object b = max(x, y);
  dynamic c = max(x, y);
  var d = max(x, y);
}
''',
      [
        error(WarningCode.UNUSED_LOCAL_VARIABLE, 93, 1),
        error(
          CompileTimeErrorCode
              .NOT_ASSIGNED_POTENTIALLY_NON_NULLABLE_LOCAL_VARIABLE,
          101,
          1,
        ),
        error(WarningCode.UNUSED_LOCAL_VARIABLE, 117, 1),
        error(
          CompileTimeErrorCode
              .NOT_ASSIGNED_POTENTIALLY_NON_NULLABLE_LOCAL_VARIABLE,
          125,
          1,
        ),
        error(WarningCode.UNUSED_LOCAL_VARIABLE, 142, 1),
        error(
          CompileTimeErrorCode
              .NOT_ASSIGNED_POTENTIALLY_NON_NULLABLE_LOCAL_VARIABLE,
          150,
          1,
        ),
        error(WarningCode.UNUSED_LOCAL_VARIABLE, 163, 1),
        error(
          CompileTimeErrorCode
              .NOT_ASSIGNED_POTENTIALLY_NON_NULLABLE_LOCAL_VARIABLE,
          171,
          1,
        ),
      ],
    );
  }

  test_function() async {
    await assertErrorsInCode(
      r'''
T f<T>(T t) => null;
main() { f(<S>(S s) => s); }
''',
      [error(CompileTimeErrorCode.RETURN_OF_INVALID_TYPE_FROM_FUNCTION, 15, 4)],
    );
  }

  test_function_argument_invalidType() async {
    await assertErrorsInCode(
      r'''
void foo<T extends num>(T t) {}

void f(X x) {
  foo(x);
}
''',
      [error(CompileTimeErrorCode.UNDEFINED_CLASS, 40, 1)],
    );
  }

  test_functionType() async {
    await assertNoErrorsInCode('''
void f<X>() {}

main() {
  [f];
}
''');
  }

  test_functionType_allSameSubtype() async {
    await assertNoErrorsInCode(r'''
external T f<T extends num>(T a, T b);
void g(int cb(int a, int b)) {}
void main() {
  g(f);
}
''');
  }

  test_functionType_instantiatedToBounds() async {
    await assertErrorsInCode(
      r'''
class A<X extends A<X>> {}

void foo<X extends Y, Y extends A<X>>() {}

void f() {
  foo();
}
''',
      [error(CompileTimeErrorCode.COULD_NOT_INFER, 85, 3)],
    );
  }

  test_functionType_optOutOfGenericMetadata() async {
    newFile('$testPackageLibPath/a.dart', '''
void f<X>() {}
''');
    await assertErrorsInCode(
      '''
// @dart=2.12
import 'a.dart';
main() {
  [f];
}
''',
      [error(CompileTimeErrorCode.COULD_NOT_INFER, 42, 3)],
    );
  }

  test_functionType_parameterIsBound_returnIsBound() async {
    await assertNoErrorsInCode(r'''
external T f<T extends num>(T a, T b);
void g(num cb(num a, num b)) {}
void main() {
  g(f);
}
''');
  }

  test_functionType_parameterIsObject_returnIsBound() async {
    await assertErrorsInCode(
      '''
external T f<T extends num>(T a, T b);
void g(num cb(Object a, Object b)) {}
void main() {
  g(f);
}
''',
      [error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 95, 1)],
    );
  }

  test_functionType_parameterIsObject_returnIsBound_prefixedFunction() async {
    newFile('$testPackageLibPath/a.dart', '''
external T f<T extends num>(T a, T b);
''');
    await assertErrorsInCode(
      '''
import 'a.dart' as a;
void g(num cb(Object a, Object b)) {}
void main() {
  g(a.f);
}
''',
      [error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 78, 3)],
    );
  }

  test_functionType_parameterIsObject_returnIsSubtype() async {
    await assertErrorsInCode(
      '''
external T f<T extends num>(T a, T b);
void g(int cb(Object a, Object b)) {}
void main() {
  g(f);
}
''',
      [error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 95, 1)],
    );
  }

  test_functionType_parameterIsObject_returnIsSubtype_tearOff() async {
    await assertErrorsInCode(
      '''
class C {
  T m<T extends num>(T x, T y) {
    throw 'error';
  }
}
void g(int cb(Object a, Object b)) {}
void main() {
  g(C().m);
}
''',
      [error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 124, 5)],
    );
  }

  test_functionType_parameterIsSubtype_returnIsBound() async {
    await assertNoErrorsInCode(r'''
external T f<T extends num>(T a, T b);
void g(num cb(int a, int b)) {}
void main() {
  g(f);
}
''');
  }

  test_functionType_parameterIsSubtype_returnIsObject() async {
    await assertNoErrorsInCode('''
external T f<T extends num>(T a, T b);
void g(Object cb(int a, int b)) {}
void main() {
  g(f);
}
''');
  }

  test_functionType_parametersAreSubtypes_returnIsBound() async {
    await assertNoErrorsInCode('''
external T f<T extends num>(T a, T b);
void g(num cb(int a, double b)) {}
void main() {
  g(f);
}
''');
  }

  test_functionType_parametersAreSubtypes_returnIsOne() async {
    await assertErrorsInCode(
      '''
external T f<T extends num>(T a, T b);
void g(int cb(int a, double b)) {}
void main() {
  g(f);
}
''',
      [
        error(CompileTimeErrorCode.COULD_NOT_INFER, 92, 1),
        error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 92, 1),
      ],
    );
  }

  test_genericMethods_correctlyRecognizeGenericUpperBound() async {
    // Regression test for https://github.com/dart-lang/sdk/issues/25740.
    await assertErrorsInCode(
      r'''
class Foo<T extends Pattern> {
  U method<U extends T>(U u) => u;
}
main() {
  new Foo<String>().method(42);
}
''',
      [error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 104, 2)],
    );
  }

  test_instanceCreation_viaTypeAlias_notWellBounded() async {
    await assertErrorsInCode(
      '''
class C<X> {
  C();
  factory C.foo() => C();
  factory C.bar() = C;
}
typedef G<X> = X Function(X);
typedef A<X extends G<C<X>>> = C<X>;

void f() {
  A(); // Error.
  A.foo(); // Error.
  A.bar(); // Error.
}
''',
      [
        error(CompileTimeErrorCode.COULD_NOT_INFER, 152, 1),
        error(CompileTimeErrorCode.COULD_NOT_INFER, 169, 5),
        error(CompileTimeErrorCode.COULD_NOT_INFER, 190, 5),
      ],
    );
  }

  test_method() async {
    await assertErrorsInCode(
      r'''
class C {
  T f<T>(T t) => null;
}
main() { new C().f(<S>(S s) => s); }
''',
      [error(CompileTimeErrorCode.RETURN_OF_INVALID_TYPE_FROM_METHOD, 27, 4)],
    );
  }

  test_topLevel() async {
    await assertErrorsInCode(
      '''
class C<P extends num> {
  factory C(Iterable<P> p) => C._();
  C._();
}

var c = C([]);
''',
      [error(CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE, 84, 2)],
    );
  }
}
