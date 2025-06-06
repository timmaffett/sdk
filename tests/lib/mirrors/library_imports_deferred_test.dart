// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.library_imports_deferred;

import 'dart:mirrors';
import 'package:expect/expect.dart';
import 'stringify.dart';

import 'dart:math' as eagermath;
import 'dart:math' deferred as lazymath;

test(MirrorSystem mirrors) {
  LibraryMirror thisLibrary = mirrors.findLibrary(
    #test.library_imports_deferred,
  );
  LibraryMirror math = mirrors.findLibrary(#dart.math);

  var importsOfCollection = thisLibrary.libraryDependencies
      .where((dep) => dep.targetLibrary == math)
      .toList();
  Expect.equals(2, importsOfCollection.length);
  Expect.notEquals(
    importsOfCollection[0].isDeferred,
    importsOfCollection[1].isDeferred,
  ); // One deferred, one not.

  // Only math is defer-imported.
  LibraryDependencyMirror dep = thisLibrary.libraryDependencies.singleWhere(
    (dep) => dep.isDeferred,
  );
  Expect.equals(math, dep.targetLibrary);

  Expect.stringEquals(
    'import dart.math as eagermath\n'
    'import dart.math deferred as lazymath\n'
    'import dart.mirrors\n'
    'import expect\n'
    'import test.stringify\n',
    stringifyDependencies(thisLibrary),
  );
}

main() {
  test(currentMirrorSystem());
}
