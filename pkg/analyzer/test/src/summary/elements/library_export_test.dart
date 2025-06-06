// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../dart/resolution/node_text_expectations.dart';
import '../elements_base.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(LibraryExportElementTest_keepLinking);
    defineReflectiveTests(LibraryExportElementTest_fromBytes);
    defineReflectiveTests(UpdateNodeTextExpectations);
  });
}

abstract class LibraryExportElementTest extends ElementsBaseTest {
  test_export_class() async {
    newFile('$testPackageLibPath/a.dart', 'class C {}');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::C
  exportNamespace
    C: package:test/a.dart::@class::C
''');
  }

  test_export_class_type_alias() async {
    newFile('$testPackageLibPath/a.dart', r'''
class C = _D with _E;
class _D {}
class _E {}
''');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::C
  exportNamespace
    C: package:test/a.dart::@class::C
''');
  }

  test_export_configurations_useDefault() async {
    declaredVariables = {'dart.library.io': 'false'};
    newFile('$testPackageLibPath/foo.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_io.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_html.dart', 'class A {}');
    var library = await buildLibrary(r'''
export 'foo.dart'
  if (dart.library.io) 'foo_io.dart'
  if (dart.library.html) 'foo_html.dart';
''');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/foo.dart
  exportedReferences
    exported[(0, 0)] package:test/foo.dart::<fragment>::@class::A
  exportNamespace
    A: package:test/foo.dart::@class::A
''');
  }

  test_export_configurations_useFirst() async {
    declaredVariables = {
      'dart.library.io': 'true',
      'dart.library.html': 'true',
    };
    newFile('$testPackageLibPath/foo.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_io.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_html.dart', 'class A {}');
    var library = await buildLibrary(r'''
export 'foo.dart'
  if (dart.library.io) 'foo_io.dart'
  if (dart.library.html) 'foo_html.dart';
''');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/foo_io.dart
  exportedReferences
    exported[(0, 0)] package:test/foo_io.dart::<fragment>::@class::A
  exportNamespace
    A: package:test/foo_io.dart::@class::A
''');
  }

  test_export_configurations_useSecond() async {
    declaredVariables = {
      'dart.library.io': 'false',
      'dart.library.html': 'true',
    };
    newFile('$testPackageLibPath/foo.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_io.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_html.dart', 'class A {}');
    var library = await buildLibrary(r'''
export 'foo.dart'
  if (dart.library.io) 'foo_io.dart'
  if (dart.library.html) 'foo_html.dart';
''');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/foo_html.dart
  exportedReferences
    exported[(0, 0)] package:test/foo_html.dart::<fragment>::@class::A
  exportNamespace
    A: package:test/foo_html.dart::@class::A
''');
  }

  test_export_cycle() async {
    newFile('$testPackageLibPath/a.dart', r'''
export 'test.dart';
class A {}
''');

    var library = await buildLibrary(r'''
export 'a.dart';
class X {}
''');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
      classes
        class X @23
          reference: <testLibraryFragment>::@class::X
          element: <testLibrary>::@class::X
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::X::@constructor::new
              element: <testLibrary>::@class::X::@constructor::new
              typeName: X
  classes
    class X
      reference: <testLibrary>::@class::X
      firstFragment: <testLibraryFragment>::@class::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::X::@constructor::new
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::A
    declared <testLibraryFragment>::@class::X
  exportNamespace
    A: package:test/a.dart::@class::A
    X: <testLibrary>::@class::X
''');
  }

  test_export_function() async {
    newFile('$testPackageLibPath/a.dart', 'f() {}');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@function::f
  exportNamespace
    f: package:test/a.dart::@function::f
''');
  }

  test_export_getter() async {
    newFile('$testPackageLibPath/a.dart', 'get f() => null;');
    var library = await buildLibrary('export "a.dart";');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
''');
  }

  test_export_hide() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {}
class B {}
class C {}
class D {}
''');
    var library = await buildLibrary(r'''
export 'a.dart' hide A, C;
''');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
          combinators
            hide: A, C
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::B
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::D
  exportNamespace
    B: package:test/a.dart::@class::B
    D: package:test/a.dart::@class::D
''');
  }

  test_export_multiple_combinators() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {}
class B {}
class C {}
class D {}
''');
    var library = await buildLibrary(r'''
export 'a.dart' hide A show C;
''');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
          combinators
            hide: A
            show: C
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::C
  exportNamespace
    C: package:test/a.dart::@class::C
''');
  }

  test_export_reexport() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
export 'a.dart';
class B {}
''');

    newFile('$testPackageLibPath/c.dart', r'''
export 'a.dart';
class C {}
''');

    var library = await buildLibrary(r'''
export 'b.dart';
export 'c.dart';
class X {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/b.dart
        package:test/c.dart
      classes
        class X @40
          reference: <testLibraryFragment>::@class::X
          element: <testLibrary>::@class::X
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::X::@constructor::new
              element: <testLibrary>::@class::X::@constructor::new
              typeName: X
  classes
    class X
      reference: <testLibrary>::@class::X
      firstFragment: <testLibraryFragment>::@class::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::X::@constructor::new
  exportedReferences
    exported[(0, 0), (0, 1)] package:test/a.dart::<fragment>::@class::A
    exported[(0, 0)] package:test/b.dart::<fragment>::@class::B
    exported[(0, 1)] package:test/c.dart::<fragment>::@class::C
    declared <testLibraryFragment>::@class::X
  exportNamespace
    A: package:test/a.dart::@class::A
    B: package:test/b.dart::@class::B
    C: package:test/c.dart::@class::C
    X: <testLibrary>::@class::X
''');
  }

  test_export_setter() async {
    newFile('$testPackageLibPath/a.dart', 'void set f(value) {}');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@setter::f
  exportNamespace
    f=: package:test/a.dart::<fragment>::@setter::f#element
''');
  }

  test_export_show() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {}
class B {}
class C {}
class D {}
''');
    var library = await buildLibrary(r'''
export 'a.dart' show A, C;
''');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
          combinators
            show: A, C
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::A
    exported[(0, 0)] package:test/a.dart::<fragment>::@class::C
  exportNamespace
    A: package:test/a.dart::@class::A
    C: package:test/a.dart::@class::C
''');
  }

  test_export_show_getter_setter() async {
    newFile('$testPackageLibPath/a.dart', '''
get f => null;
void set f(value) {}
''');
    var library = await buildLibrary('export "a.dart" show f;');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
          combinators
            show: f
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@getter::f
    exported[(0, 0)] package:test/a.dart::<fragment>::@setter::f
  exportNamespace
    f: package:test/a.dart::<fragment>::@getter::f#element
    f=: package:test/a.dart::<fragment>::@setter::f#element
''');
  }

  test_export_typedef() async {
    newFile('$testPackageLibPath/a.dart', 'typedef F();');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@typeAlias::F
  exportNamespace
    F: package:test/a.dart::@typeAlias::F
''');
  }

  test_export_uri() async {
    var library = await buildLibrary('''
export 'foo.dart';
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/foo.dart
''');
  }

  test_export_variable() async {
    newFile('$testPackageLibPath/a.dart', 'var x;');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@getter::x
    exported[(0, 0)] package:test/a.dart::<fragment>::@setter::x
  exportNamespace
    x: package:test/a.dart::<fragment>::@getter::x#element
    x=: package:test/a.dart::<fragment>::@setter::x#element
''');
  }

  test_export_variable_const() async {
    newFile('$testPackageLibPath/a.dart', 'const x = 0;');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@getter::x
  exportNamespace
    x: package:test/a.dart::<fragment>::@getter::x#element
''');
  }

  test_export_variable_final() async {
    newFile('$testPackageLibPath/a.dart', 'final x = 0;');
    var library = await buildLibrary('export "a.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
  exportedReferences
    exported[(0, 0)] package:test/a.dart::<fragment>::@getter::x
  exportNamespace
    x: package:test/a.dart::<fragment>::@getter::x#element
''');
  }

  test_exportImport_configurations_useDefault() async {
    declaredVariables = {'dart.library.io': 'false'};
    newFile('$testPackageLibPath/foo.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_io.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_html.dart', 'class A {}');
    newFile('$testPackageLibPath/bar.dart', r'''
export 'foo.dart'
  if (dart.library.io) 'foo_io.dart'
  if (dart.library.html) 'foo_html.dart';
''');
    var library = await buildLibrary(r'''
import 'bar.dart';
class B extends A {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryImports
        package:test/bar.dart
      classes
        class B @25
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
  classes
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
          superConstructor: package:test/foo.dart::@class::A::@constructor::new
''');

    var typeA = library.getClass2('B')!.supertype!;
    var fragmentA = typeA.element3.firstFragment;
    var sourceA = fragmentA.libraryFragment.source;
    expect(sourceA.shortName, 'foo.dart');
  }

  test_exportImport_configurations_useFirst() async {
    declaredVariables = {
      'dart.library.io': 'true',
      'dart.library.html': 'false',
    };
    newFile('$testPackageLibPath/foo.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_io.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_html.dart', 'class A {}');
    newFile('$testPackageLibPath/bar.dart', r'''
export 'foo.dart'
  if (dart.library.io) 'foo_io.dart'
  if (dart.library.html) 'foo_html.dart';
''');
    var library = await buildLibrary(r'''
import 'bar.dart';
class B extends A {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryImports
        package:test/bar.dart
      classes
        class B @25
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
  classes
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
          superConstructor: package:test/foo_io.dart::@class::A::@constructor::new
''');

    var typeA = library.getClass2('B')!.supertype!;
    var fragmentA = typeA.element3.firstFragment;
    var sourceA = fragmentA.libraryFragment.source;
    expect(sourceA.shortName, 'foo_io.dart');
  }

  test_exportImport_configurations_useSecond() async {
    declaredVariables = {
      'dart.library.io': 'false',
      'dart.library.html': 'true',
    };
    newFile('$testPackageLibPath/foo.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_io.dart', 'class A {}');
    newFile('$testPackageLibPath/foo_html.dart', 'class A {}');
    newFile('$testPackageLibPath/bar.dart', r'''
export 'foo.dart'
  if (dart.library.io) 'foo_io.dart'
  if (dart.library.html) 'foo_html.dart';
''');
    var library = await buildLibrary(r'''
import 'bar.dart';
class B extends A {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryImports
        package:test/bar.dart
      classes
        class B @25
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
  classes
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
          superConstructor: package:test/foo_html.dart::@class::A::@constructor::new
''');

    var typeA = library.getClass2('B')!.supertype!;
    var fragmentA = typeA.element3.firstFragment;
    var sourceA = fragmentA.libraryFragment.source;
    expect(sourceA.shortName, 'foo_html.dart');
  }

  test_exports() async {
    newFile('$testPackageLibPath/a.dart', 'library a;');
    newFile('$testPackageLibPath/b.dart', 'library b;');
    var library = await buildLibrary('export "a.dart"; export "b.dart";');
    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
        package:test/b.dart
  exportedReferences
  exportNamespace
''');
  }

  @SkippedTest() // TODO(scheglov): implement augmentation
  test_exportScope_part_class() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment class A {}
class B {}
''');

    var library = await buildLibrary(r'''
part 'a.dart';
class A {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
      classes
        class A @21
          reference: <testLibraryFragment>::@class::A
          enclosingElement3: <testLibraryFragment>
          augmentation: <testLibrary>::@fragment::package:test/a.dart::@classAugmentation::A
          constructors
            synthetic @-1
              reference: <testLibraryFragment>::@class::A::@constructor::new
              enclosingElement3: <testLibraryFragment>::@class::A
          augmented
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      classes
        augment class A @35
          reference: <testLibrary>::@fragment::package:test/a.dart::@classAugmentation::A
          enclosingElement3: <testLibrary>::@fragment::package:test/a.dart
          augmentationTarget: <testLibraryFragment>::@class::A
        class B @46
          reference: <testLibrary>::@fragment::package:test/a.dart::@class::B
          enclosingElement3: <testLibrary>::@fragment::package:test/a.dart
          constructors
            synthetic @-1
              reference: <testLibrary>::@fragment::package:test/a.dart::@class::B::@constructor::new
              enclosingElement3: <testLibrary>::@fragment::package:test/a.dart::@class::B
  exportedReferences
    declared <testLibrary>::@fragment::package:test/a.dart::@class::B
    declared <testLibraryFragment>::@class::A
  exportNamespace
    A: <testLibraryFragment>::@class::A
    B: <testLibrary>::@fragment::package:test/a.dart::@class::B
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      classes
        class A @21
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          nextFragment: <testLibrary>::@fragment::package:test/a.dart::@classAugmentation::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibraryFragment>::@class::A::@constructor::new#element
              typeName: A
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      classes
        class A @35
          reference: <testLibrary>::@fragment::package:test/a.dart::@classAugmentation::A
          element: <testLibrary>::@class::A
          previousFragment: <testLibraryFragment>::@class::A
        class B @46
          reference: <testLibrary>::@fragment::package:test/a.dart::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibrary>::@fragment::package:test/a.dart::@class::B::@constructor::new
              element: <testLibrary>::@fragment::package:test/a.dart::@class::B::@constructor::new#element
              typeName: B
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@class::B
      constructors
        synthetic new
          firstFragment: <testLibrary>::@fragment::package:test/a.dart::@class::B::@constructor::new
  exportedReferences
    declared <testLibrary>::@fragment::package:test/a.dart::@class::B
    declared <testLibraryFragment>::@class::A
  exportNamespace
    A: <testLibraryFragment>::@class::A
    B: <testLibrary>::@fragment::package:test/a.dart::@class::B
''');
  }

  test_exportScope_part_export() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
class B1 {}
class B2 {}
''');

    newFile('$testPackageLibPath/c.dart', r'''
class C {}
''');

    newFile('$testPackageLibPath/d.dart', r'''
part of 'test.dart';
export 'a.dart';
''');

    newFile('$testPackageLibPath/e.dart', r'''
part of 'test.dart';
export 'b.dart';
export 'c.dart';
''');

    var library = await buildLibrary(r'''
part 'd.dart';
part 'e.dart';
class X {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/d.dart
      parts
        part_0
          uri: package:test/d.dart
          unit: <testLibrary>::@fragment::package:test/d.dart
        part_1
          uri: package:test/e.dart
          unit: <testLibrary>::@fragment::package:test/e.dart
      classes
        class X @36
          reference: <testLibraryFragment>::@class::X
          element: <testLibrary>::@class::X
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::X::@constructor::new
              element: <testLibrary>::@class::X::@constructor::new
              typeName: X
    <testLibrary>::@fragment::package:test/d.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      nextFragment: <testLibrary>::@fragment::package:test/e.dart
      libraryExports
        package:test/a.dart
    <testLibrary>::@fragment::package:test/e.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibrary>::@fragment::package:test/d.dart
      libraryExports
        package:test/b.dart
        package:test/c.dart
  classes
    class X
      reference: <testLibrary>::@class::X
      firstFragment: <testLibraryFragment>::@class::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::X::@constructor::new
  exportedReferences
    exported[(1, 0)] package:test/a.dart::<fragment>::@class::A
    exported[(2, 0)] package:test/b.dart::<fragment>::@class::B1
    exported[(2, 0)] package:test/b.dart::<fragment>::@class::B2
    exported[(2, 1)] package:test/c.dart::<fragment>::@class::C
    declared <testLibraryFragment>::@class::X
  exportNamespace
    A: package:test/a.dart::@class::A
    B1: package:test/b.dart::@class::B1
    B2: package:test/b.dart::@class::B2
    C: package:test/c.dart::@class::C
    X: <testLibrary>::@class::X
''');
  }

  test_exportScope_part_export_hide() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A1 {}
class A2 {}
class A3 {}
class A4 {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
part of 'test.dart';
export 'a.dart' hide A2, A4;
''');

    var library = await buildLibrary(r'''
part 'b.dart';
class X {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/b.dart
      parts
        part_0
          uri: package:test/b.dart
          unit: <testLibrary>::@fragment::package:test/b.dart
      classes
        class X @21
          reference: <testLibraryFragment>::@class::X
          element: <testLibrary>::@class::X
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::X::@constructor::new
              element: <testLibrary>::@class::X::@constructor::new
              typeName: X
    <testLibrary>::@fragment::package:test/b.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      libraryExports
        package:test/a.dart
          combinators
            hide: A2, A4
  classes
    class X
      reference: <testLibrary>::@class::X
      firstFragment: <testLibraryFragment>::@class::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::X::@constructor::new
  exportedReferences
    exported[(1, 0)] package:test/a.dart::<fragment>::@class::A1
    exported[(1, 0)] package:test/a.dart::<fragment>::@class::A3
    declared <testLibraryFragment>::@class::X
  exportNamespace
    A1: package:test/a.dart::@class::A1
    A3: package:test/a.dart::@class::A3
    X: <testLibrary>::@class::X
''');
  }

  test_exportScope_part_export_show() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A1 {}
class A2 {}
class A3 {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
part of 'test.dart';
export 'a.dart' show A1, A3;
''');

    var library = await buildLibrary(r'''
part 'b.dart';
class X {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/b.dart
      parts
        part_0
          uri: package:test/b.dart
          unit: <testLibrary>::@fragment::package:test/b.dart
      classes
        class X @21
          reference: <testLibraryFragment>::@class::X
          element: <testLibrary>::@class::X
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::X::@constructor::new
              element: <testLibrary>::@class::X::@constructor::new
              typeName: X
    <testLibrary>::@fragment::package:test/b.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      libraryExports
        package:test/a.dart
          combinators
            show: A1, A3
  classes
    class X
      reference: <testLibrary>::@class::X
      firstFragment: <testLibraryFragment>::@class::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::X::@constructor::new
  exportedReferences
    exported[(1, 0)] package:test/a.dart::<fragment>::@class::A1
    exported[(1, 0)] package:test/a.dart::<fragment>::@class::A3
    declared <testLibraryFragment>::@class::X
  exportNamespace
    A1: package:test/a.dart::@class::A1
    A3: package:test/a.dart::@class::A3
    X: <testLibrary>::@class::X
''');
  }

  @SkippedTest() // TODO(scheglov): implement augmentation
  test_exportScope_part_mixin() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment mixin A {}
mixin B {}
''');

    var library = await buildLibrary(r'''
part 'a.dart';
mixin A {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
      mixins
        mixin A @21
          reference: <testLibraryFragment>::@mixin::A
          enclosingElement3: <testLibraryFragment>
          augmentation: <testLibrary>::@fragment::package:test/a.dart::@mixinAugmentation::A
          superclassConstraints
            Object
          augmented
            superclassConstraints
              Object
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      mixins
        augment mixin A @35
          reference: <testLibrary>::@fragment::package:test/a.dart::@mixinAugmentation::A
          enclosingElement3: <testLibrary>::@fragment::package:test/a.dart
          augmentationTarget: <testLibraryFragment>::@mixin::A
        mixin B @46
          reference: <testLibrary>::@fragment::package:test/a.dart::@mixin::B
          enclosingElement3: <testLibrary>::@fragment::package:test/a.dart
          superclassConstraints
            Object
  exportedReferences
    declared <testLibrary>::@fragment::package:test/a.dart::@mixin::B
    declared <testLibraryFragment>::@mixin::A
  exportNamespace
    A: <testLibraryFragment>::@mixin::A
    B: <testLibrary>::@fragment::package:test/a.dart::@mixin::B
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      mixins
        mixin A @21
          reference: <testLibraryFragment>::@mixin::A
          element: <testLibrary>::@mixin::A
          nextFragment: <testLibrary>::@fragment::package:test/a.dart::@mixinAugmentation::A
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      mixins
        mixin A @35
          reference: <testLibrary>::@fragment::package:test/a.dart::@mixinAugmentation::A
          element: <testLibrary>::@mixin::A
          previousFragment: <testLibraryFragment>::@mixin::A
        mixin B @46
          reference: <testLibrary>::@fragment::package:test/a.dart::@mixin::B
          element: <testLibrary>::@mixin::B
  mixins
    mixin A
      reference: <testLibrary>::@mixin::A
      firstFragment: <testLibraryFragment>::@mixin::A
      superclassConstraints
        Object
    mixin B
      reference: <testLibrary>::@mixin::B
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@mixin::B
      superclassConstraints
        Object
  exportedReferences
    declared <testLibrary>::@fragment::package:test/a.dart::@mixin::B
    declared <testLibraryFragment>::@mixin::A
  exportNamespace
    A: <testLibraryFragment>::@mixin::A
    B: <testLibrary>::@fragment::package:test/a.dart::@mixin::B
''');
  }

  test_exportScope_part_nested_class() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
part 'b.dart';
class A {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
part of 'a.dart';
class B {}
''');

    var library = await buildLibrary(r'''
part 'a.dart';
class C {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      parts
        part_0
          uri: package:test/a.dart
          unit: <testLibrary>::@fragment::package:test/a.dart
      classes
        class C @21
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      nextFragment: <testLibrary>::@fragment::package:test/b.dart
      parts
        part_1
          uri: package:test/b.dart
          unit: <testLibrary>::@fragment::package:test/b.dart
      classes
        class A @42
          reference: <testLibrary>::@fragment::package:test/a.dart::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibrary>::@fragment::package:test/a.dart::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
    <testLibrary>::@fragment::package:test/b.dart
      element: <testLibrary>
      enclosingFragment: <testLibrary>::@fragment::package:test/a.dart
      previousFragment: <testLibrary>::@fragment::package:test/a.dart
      classes
        class B @24
          reference: <testLibrary>::@fragment::package:test/b.dart::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibrary>::@fragment::package:test/b.dart::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
  classes
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@class::A
      constructors
        synthetic new
          firstFragment: <testLibrary>::@fragment::package:test/a.dart::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibrary>::@fragment::package:test/b.dart::@class::B
      constructors
        synthetic new
          firstFragment: <testLibrary>::@fragment::package:test/b.dart::@class::B::@constructor::new
  exportedReferences
    declared <testLibrary>::@fragment::package:test/a.dart::@class::A
    declared <testLibrary>::@fragment::package:test/b.dart::@class::B
    declared <testLibraryFragment>::@class::C
  exportNamespace
    A: <testLibrary>::@class::A
    B: <testLibrary>::@class::B
    C: <testLibrary>::@class::C
''');
  }

  test_exportScope_part_nested_export() async {
    newFile('$testPackageLibPath/a.dart', r'''
class A {}
''');

    newFile('$testPackageLibPath/b.dart', r'''
class B {}
''');

    newFile('$testPackageLibPath/c.dart', r'''
part of 'test.dart';
part 'd.dart';
export 'a.dart';
''');

    newFile('$testPackageLibPath/d.dart', r'''
part of 'c.dart';
export 'b.dart';
''');

    var library = await buildLibrary(r'''
part 'c.dart';
class X {}
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/c.dart
      parts
        part_0
          uri: package:test/c.dart
          unit: <testLibrary>::@fragment::package:test/c.dart
      classes
        class X @21
          reference: <testLibraryFragment>::@class::X
          element: <testLibrary>::@class::X
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::X::@constructor::new
              element: <testLibrary>::@class::X::@constructor::new
              typeName: X
    <testLibrary>::@fragment::package:test/c.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      nextFragment: <testLibrary>::@fragment::package:test/d.dart
      libraryExports
        package:test/a.dart
      parts
        part_1
          uri: package:test/d.dart
          unit: <testLibrary>::@fragment::package:test/d.dart
    <testLibrary>::@fragment::package:test/d.dart
      element: <testLibrary>
      enclosingFragment: <testLibrary>::@fragment::package:test/c.dart
      previousFragment: <testLibrary>::@fragment::package:test/c.dart
      libraryExports
        package:test/b.dart
  classes
    class X
      reference: <testLibrary>::@class::X
      firstFragment: <testLibraryFragment>::@class::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::X::@constructor::new
  exportedReferences
    exported[(1, 0)] package:test/a.dart::<fragment>::@class::A
    exported[(2, 0)] package:test/b.dart::<fragment>::@class::B
    declared <testLibraryFragment>::@class::X
  exportNamespace
    A: package:test/a.dart::@class::A
    B: package:test/b.dart::@class::B
    X: <testLibrary>::@class::X
''');
  }

  test_exportScope_part_variable() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
int a = 0;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      parts
        part_0
          uri: package:test/a.dart
          unit: <testLibrary>::@fragment::package:test/a.dart
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      topLevelVariables
        hasInitializer a @25
          reference: <testLibrary>::@fragment::package:test/a.dart::@topLevelVariable::a
          element: <testLibrary>::@topLevelVariable::a
          getter2: <testLibrary>::@fragment::package:test/a.dart::@getter::a
          setter2: <testLibrary>::@fragment::package:test/a.dart::@setter::a
      getters
        synthetic get a
          reference: <testLibrary>::@fragment::package:test/a.dart::@getter::a
          element: <testLibrary>::@fragment::package:test/a.dart::@getter::a#element
      setters
        synthetic set a
          reference: <testLibrary>::@fragment::package:test/a.dart::@setter::a
          element: <testLibrary>::@fragment::package:test/a.dart::@setter::a#element
          formalParameters
            _a
              element: <testLibrary>::@fragment::package:test/a.dart::@setter::a::@parameter::_a#element
  topLevelVariables
    hasInitializer a
      reference: <testLibrary>::@topLevelVariable::a
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@topLevelVariable::a
      type: int
      getter: <testLibrary>::@fragment::package:test/a.dart::@getter::a#element
      setter: <testLibrary>::@fragment::package:test/a.dart::@setter::a#element
  getters
    synthetic static get a
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@getter::a
      returnType: int
  setters
    synthetic static set a
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@setter::a
      formalParameters
        requiredPositional _a
          type: int
      returnType: void
  exportedReferences
    declared <testLibrary>::@fragment::package:test/a.dart::@getter::a
    declared <testLibrary>::@fragment::package:test/a.dart::@setter::a
  exportNamespace
    a: <testLibrary>::@fragment::package:test/a.dart::@getter::a#element
    a=: <testLibrary>::@fragment::package:test/a.dart::@setter::a#element
''');
  }

  test_exportScope_part_variable_const() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
const a = 0;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      parts
        part_0
          uri: package:test/a.dart
          unit: <testLibrary>::@fragment::package:test/a.dart
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      topLevelVariables
        hasInitializer a @27
          reference: <testLibrary>::@fragment::package:test/a.dart::@topLevelVariable::a
          element: <testLibrary>::@topLevelVariable::a
          initializer: expression_0
            IntegerLiteral
              literal: 0 @31
              staticType: int
          getter2: <testLibrary>::@fragment::package:test/a.dart::@getter::a
      getters
        synthetic get a
          reference: <testLibrary>::@fragment::package:test/a.dart::@getter::a
          element: <testLibrary>::@fragment::package:test/a.dart::@getter::a#element
  topLevelVariables
    const hasInitializer a
      reference: <testLibrary>::@topLevelVariable::a
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@topLevelVariable::a
      type: int
      constantInitializer
        fragment: <testLibrary>::@fragment::package:test/a.dart::@topLevelVariable::a
        expression: expression_0
      getter: <testLibrary>::@fragment::package:test/a.dart::@getter::a#element
  getters
    synthetic static get a
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@getter::a
      returnType: int
  exportedReferences
    declared <testLibrary>::@fragment::package:test/a.dart::@getter::a
  exportNamespace
    a: <testLibrary>::@fragment::package:test/a.dart::@getter::a#element
''');
  }

  test_library_exports_noRelativeUriStr() async {
    var library = await buildLibrary(r'''
export '${'foo'}.dart';
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        noRelativeUriString
''');
  }

  test_library_exports_withRelativeUri_emptyUriSelf() async {
    var library = await buildLibrary(r'''
export '';
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/test.dart
''');
  }

  test_library_exports_withRelativeUri_noSource() async {
    var library = await buildLibrary(r'''
export 'foo:bar';
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        relativeUri 'foo:bar'
''');
  }

  test_library_exports_withRelativeUri_notExists() async {
    var library = await buildLibrary(r'''
export 'a.dart';
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/a.dart
''');
  }

  test_library_exports_withRelativeUri_notLibrary_part() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
''');
    var library = await buildLibrary(r'''
export 'a.dart';
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        source 'package:test/a.dart'
''');
  }

  test_library_exports_withRelativeUriString() async {
    var library = await buildLibrary(r'''
export ':';
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        relativeUriString ':'
''');
  }

  test_unresolved_export() async {
    var library = await buildLibrary("export 'foo.dart';");
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      libraryExports
        package:test/foo.dart
''');
  }
}

@reflectiveTest
class LibraryExportElementTest_fromBytes extends LibraryExportElementTest {
  @override
  bool get keepLinkingLibraries => false;
}

@reflectiveTest
class LibraryExportElementTest_keepLinking extends LibraryExportElementTest {
  @override
  bool get keepLinkingLibraries => true;
}
