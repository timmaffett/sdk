// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.typedef_unalias_test;

import 'package:kernel/ast.dart';
import 'package:test/test.dart';
import 'verify_test.dart' show TestHarness;

void harnessTest(String name, void doTest(TestHarness harness)) {
  test(name, () {
    doTest(new TestHarness());
  });
}

void main() {
  harnessTest('`Foo` where typedef Foo = C', (TestHarness harness) {
    var foo = new Typedef('Foo', harness.otherRawType, fileUri: dummyUri);
    harness.enclosingLibrary.addTypedef(foo);
    var type = new TypedefType(foo, Nullability.nonNullable);
    expect(type.unalias, equals(harness.otherRawType));
  });
  harnessTest('`Foo<Obj>` where typedef Foo<T> = C<T>', (TestHarness harness) {
    var param = harness.makeTypeParameter('T');
    var foo = new Typedef(
        'Foo',
        new InterfaceType(harness.otherClass, Nullability.nonNullable,
            [new TypeParameterType(param, Nullability.nonNullable)]),
        typeParameters: [param],
        fileUri: dummyUri);
    harness.enclosingLibrary.addTypedef(foo);
    var input =
        new TypedefType(foo, Nullability.nonNullable, [harness.objectRawType]);
    var expected = new InterfaceType(
        harness.otherClass, Nullability.nonNullable, [harness.objectRawType]);
    expect(input.unalias, equals(expected));
  });
  harnessTest('`Bar<Obj>` where typedef Bar<T> = Foo<T>, Foo<T> = C<T>',
      (TestHarness harness) {
    var fooParam = harness.makeTypeParameter('T');
    var foo = new Typedef(
        'Foo',
        new InterfaceType(harness.otherClass, Nullability.nonNullable,
            [new TypeParameterType(fooParam, Nullability.nonNullable)]),
        typeParameters: [fooParam],
        fileUri: dummyUri);
    var barParam = harness.makeTypeParameter('T');
    var bar = new Typedef(
        'Bar',
        new TypedefType(foo, Nullability.nonNullable,
            [new TypeParameterType(barParam, Nullability.nonNullable)]),
        typeParameters: [barParam],
        fileUri: dummyUri);
    harness.enclosingLibrary.addTypedef(foo);
    harness.enclosingLibrary.addTypedef(bar);
    var input =
        new TypedefType(bar, Nullability.nonNullable, [harness.objectRawType]);
    var expected = new InterfaceType(
        harness.otherClass, Nullability.nonNullable, [harness.objectRawType]);
    expect(input.unalias, equals(expected));
  });
  harnessTest('`Foo<Foo<C>>` where typedef Foo<T> = C<T>',
      (TestHarness harness) {
    var param = harness.makeTypeParameter('T');
    var foo = new Typedef(
        'Foo',
        new InterfaceType(harness.otherClass, Nullability.nonNullable,
            [new TypeParameterType(param, Nullability.nonNullable)]),
        typeParameters: [param],
        fileUri: dummyUri);
    harness.enclosingLibrary.addTypedef(foo);
    var input = new TypedefType(foo, Nullability.nonNullable, [
      new TypedefType(foo, Nullability.nonNullable, [harness.objectRawType])
    ]);
    var expected =
        new InterfaceType(harness.otherClass, Nullability.nonNullable, [
      new TypedefType(foo, Nullability.nonNullable, [harness.objectRawType])
    ]);
    expect(input.unalias, equals(expected));
  });
}
