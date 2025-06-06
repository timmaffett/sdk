// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:compiler/src/util/testing.dart';

/*spec.class: global#JsLinkedHashMap:checkedInstance,checks=[],instance*/

/*prod.class: global#JsLinkedHashMap:checks=[],instance*/

@pragma('dart2js:noInline')
method<T>() {
  return
  /*spec.checks=[$signature],instance*/
  /*prod.checks=[],instance*/
  () => <T, int>{};
}

@pragma('dart2js:noInline')
test(o) => o is Map<int, int>;

main() {
  makeLive(test(method<int>().call()));
  makeLive(test(method<String>().call()));
}
