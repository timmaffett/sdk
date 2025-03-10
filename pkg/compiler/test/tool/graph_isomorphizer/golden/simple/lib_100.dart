// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// This file was autogenerated by the pkg/compiler/tool/graph_isomorphizer.dart.
import "package:expect/expect.dart";

import 'libImport.dart';

@pragma('dart2js:noInline')
typeTest(dynamic t) {
  if (t is T_100) {
    return true;
  }
  if (t is T_101) {
    return true;
  }
  if (t is T_111) {
    return true;
  }
  if (t is T_101_type__1) {
    return true;
  }
  if (t is T_101_type__2) {
    return true;
  }
  if (t is T_101_type__3) {
    return true;
  }
  if (t is T_101_type__4) {
    return true;
  }
  if (t is T_111_type__1) {
    return true;
  }
  if (t is T_111_type__2) {
    return true;
  }
  if (t is T_111_type__3) {
    return true;
  }
  if (t is T_111_type__4) {
    return true;
  }
  if (t is T_111_type__5) {
    return true;
  }
  if (t is T_111_type__6) {
    return true;
  }
  return false;
}

@pragma('dart2js:noInline')
g_100() {
  // C_1**;
  Expect.isFalse(typeTest(C_100()));
  Expect.isFalse(typeTest(C_101()));
  Expect.isFalse(typeTest(C_111()));
  Expect.isFalse(typeTest(C_101_class_1()));
  Expect.isFalse(typeTest(C_101_class_2()));
  Expect.isFalse(typeTest(C_101_class_3()));
  Expect.isFalse(typeTest(C_101_class_4()));
  Expect.isFalse(typeTest(C_111_class_1()));
  Expect.isFalse(typeTest(C_111_class_2()));
  Expect.isFalse(typeTest(C_111_class_3()));
  Expect.isFalse(typeTest(C_111_class_4()));
  Expect.isFalse(typeTest(C_111_class_5()));
  Expect.isFalse(typeTest(C_111_class_6()));

  Expect.isTrue(closureC_100(C_100())(C_100()));
  Expect.isTrue(closureC_101(C_101())(C_101()));
  Expect.isTrue(closureC_111(C_111())(C_111()));
  Expect.isTrue(closureC_101_class_1(C_101_class_1())(C_101_class_1()));
  Expect.isTrue(closureC_101_class_2(C_101_class_2())(C_101_class_2()));
  Expect.isTrue(closureC_101_class_3(C_101_class_3())(C_101_class_3()));
  Expect.isTrue(closureC_101_class_4(C_101_class_4())(C_101_class_4()));
  Expect.isTrue(closureC_111_class_1(C_111_class_1())(C_111_class_1()));
  Expect.isTrue(closureC_111_class_2(C_111_class_2())(C_111_class_2()));
  Expect.isTrue(closureC_111_class_3(C_111_class_3())(C_111_class_3()));
  Expect.isTrue(closureC_111_class_4(C_111_class_4())(C_111_class_4()));
  Expect.isTrue(closureC_111_class_5(C_111_class_5())(C_111_class_5()));
  Expect.isTrue(closureC_111_class_6(C_111_class_6())(C_111_class_6()));

  Expect.equals(
    closureC_100(C_100()).runtimeType.toString(),
    '(C_100) => bool',
  );
  Expect.equals(
    closureC_101(C_101()).runtimeType.toString(),
    '(C_101) => bool',
  );
  Expect.equals(
    closureC_111(C_111()).runtimeType.toString(),
    '(C_111) => bool',
  );
  Expect.equals(
    closureC_101_class_1(C_101_class_1()).runtimeType.toString(),
    '(C_101_class_1) => bool',
  );
  Expect.equals(
    closureC_101_class_2(C_101_class_2()).runtimeType.toString(),
    '(C_101_class_2) => bool',
  );
  Expect.equals(
    closureC_101_class_3(C_101_class_3()).runtimeType.toString(),
    '(C_101_class_3) => bool',
  );
  Expect.equals(
    closureC_101_class_4(C_101_class_4()).runtimeType.toString(),
    '(C_101_class_4) => bool',
  );
  Expect.equals(
    closureC_111_class_1(C_111_class_1()).runtimeType.toString(),
    '(C_111_class_1) => bool',
  );
  Expect.equals(
    closureC_111_class_2(C_111_class_2()).runtimeType.toString(),
    '(C_111_class_2) => bool',
  );
  Expect.equals(
    closureC_111_class_3(C_111_class_3()).runtimeType.toString(),
    '(C_111_class_3) => bool',
  );
  Expect.equals(
    closureC_111_class_4(C_111_class_4()).runtimeType.toString(),
    '(C_111_class_4) => bool',
  );
  Expect.equals(
    closureC_111_class_5(C_111_class_5()).runtimeType.toString(),
    '(C_111_class_5) => bool',
  );
  Expect.equals(
    closureC_111_class_6(C_111_class_6()).runtimeType.toString(),
    '(C_111_class_6) => bool',
  );

  Set<String> uniques = {};

  // f_1**;
  f_100(uniques, 0);
  f_101(uniques, 0);
  f_111(uniques, 0);
  Expect.equals(3, uniques.length);
}
