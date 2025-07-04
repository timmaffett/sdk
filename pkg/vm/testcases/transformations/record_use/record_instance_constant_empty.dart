// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:meta/meta.dart' show RecordUse;

void main() {
  doSomething();
}

@MyClass(const A())
void doSomething() {
  print('a');
}

@RecordUse()
class MyClass {
  final A a;

  const MyClass(this.a);
}

class A {
  const A();
}
