// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../dart/resolution/node_text_expectations.dart';
import '../elements_base.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(LocalDeclarationElementTest_keepLinking);
    defineReflectiveTests(LocalDeclarationElementTest_fromBytes);
    defineReflectiveTests(UpdateNodeTextExpectations);
  });
}

abstract class LocalDeclarationElementTest extends ElementsBaseTest {
  test_localFunctions() async {
    var library = await buildLibrary(r'''
f() {
  f1() {}
  {
    f2() {}
  }
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      functions
        f @0
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      returnType: dynamic
''');
  }

  test_localFunctions_inConstructor() async {
    var library = await buildLibrary(r'''
class C {
  C() {
    f() {}
  }
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @6
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
              typeNameOffset: 12
  classes
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      constructors
        new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
''');
  }

  test_localFunctions_inMethod() async {
    var library = await buildLibrary(r'''
class C {
  m() {
    f() {}
  }
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @6
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
          methods
            m @12
              reference: <testLibraryFragment>::@class::C::@method::m
              element: <testLibrary>::@class::C::@method::m
  classes
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
      methods
        m
          reference: <testLibrary>::@class::C::@method::m
          firstFragment: <testLibraryFragment>::@class::C::@method::m
          returnType: dynamic
''');
  }

  test_localFunctions_inTopLevelGetter() async {
    var library = await buildLibrary(r'''
get g {
  f() {}
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      topLevelVariables
        synthetic g (offset=-1)
          reference: <testLibraryFragment>::@topLevelVariable::g
          element: <testLibrary>::@topLevelVariable::g
          getter2: <testLibraryFragment>::@getter::g
      getters
        get g @4
          reference: <testLibraryFragment>::@getter::g
          element: <testLibraryFragment>::@getter::g#element
  topLevelVariables
    synthetic g
      reference: <testLibrary>::@topLevelVariable::g
      firstFragment: <testLibraryFragment>::@topLevelVariable::g
      type: dynamic
      getter: <testLibraryFragment>::@getter::g#element
  getters
    static get g
      firstFragment: <testLibraryFragment>::@getter::g
      returnType: dynamic
''');
  }

  test_localLabels_inConstructor() async {
    var library = await buildLibrary(r'''
class C {
  C() {
    aaa: while (true) {}
    bbb: switch (42) {
      ccc: case 0:
        break;
    }
  }
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @6
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
              typeNameOffset: 12
  classes
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      constructors
        new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
''');
  }

  test_localLabels_inMethod() async {
    var library = await buildLibrary(r'''
class C {
  m() {
    aaa: while (true) {}
    bbb: switch (42) {
      ccc: case 0:
        break;
    }
  }
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @6
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
          methods
            m @12
              reference: <testLibraryFragment>::@class::C::@method::m
              element: <testLibrary>::@class::C::@method::m
  classes
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
      methods
        m
          reference: <testLibrary>::@class::C::@method::m
          firstFragment: <testLibraryFragment>::@class::C::@method::m
          returnType: dynamic
''');
  }

  test_localLabels_inTopLevelFunction() async {
    var library = await buildLibrary(r'''
main() {
  aaa: while (true) {}
  bbb: switch (42) {
    ccc: case 0:
      break;
  }
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      functions
        main @0
          reference: <testLibraryFragment>::@function::main
          element: <testLibrary>::@function::main
  functions
    main
      reference: <testLibrary>::@function::main
      firstFragment: <testLibraryFragment>::@function::main
      returnType: dynamic
''');
  }
}

@reflectiveTest
class LocalDeclarationElementTest_fromBytes
    extends LocalDeclarationElementTest {
  @override
  bool get keepLinkingLibraries => false;
}

@reflectiveTest
class LocalDeclarationElementTest_keepLinking
    extends LocalDeclarationElementTest {
  @override
  bool get keepLinkingLibraries => true;
}
