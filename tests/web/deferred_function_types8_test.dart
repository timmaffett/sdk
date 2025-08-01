// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:expect/async_helper.dart';
import 'package:expect/expect.dart';
import 'deferred_function_types_lib1.dart' deferred as lib1;
import 'deferred_function_types_lib2.dart' deferred as lib2;

@pragma('dart2js:never-inline')
confuse(f) => f;

main() {
  asyncTest(() async {
    await lib2.loadLibrary();
    Expect.isFalse(lib2.method2() is int Function(int));
    Expect.isTrue(lib2.method2() is String Function(String));
    Expect.isFalse(lib2.method6 is Object? Function(Null, String, int));
    Expect.isTrue(confuse(lib2.method6) is Object? Function(Null, int, String));
    Expect.isTrue(lib2.test6(lib2.method6));
    await lib1.loadLibrary();
    Expect.isTrue(lib1.method1() is int Function(int));
    Expect.isFalse(lib1.method1() is String Function(String));
    Expect.isTrue(confuse(lib1.method5) is Object? Function(Null, String, int));
    Expect.isFalse(lib1.method5 is Object? Function(Null, int, String));
    Expect.isTrue(lib1.test5(lib1.method5));
  });
}
