// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/fix/data_driven/changes_selector.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/element_descriptor.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/element_kind.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/rename.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/transform.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'data_driven_test_support.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(RenameClassTest);
    defineReflectiveTests(RenameConstructorTest);
    defineReflectiveTests(RenameExtensionTest);
    defineReflectiveTests(RenameExtensionTypeTest);
    defineReflectiveTests(RenameFieldTest);
    defineReflectiveTests(RenameGetterTest);
    defineReflectiveTests(RenameSetterTest);
    defineReflectiveTests(RenameMethodTest);
    defineReflectiveTests(RenameMixinTest);
    defineReflectiveTests(RenameTopLevelFunctionTest);
    defineReflectiveTests(RenameTopLevelVariableTest);
    defineReflectiveTests(RenameTypedefTest);
  });
}

@reflectiveTest
class RenameClassTest extends _AbstractRenameTest {
  @override
  String get _kind => 'class';

  Future<void> test_as_deprecated() async {
    setPackageContent('''
class A {}
@deprecated
class Old extends A {}
class New extends A {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f(A o) {
  print(o as Old);
}
''');
    await assertHasFix('''
import '$importUri';

void f(A o) {
  print(o as New);
}
''');
  }

  Future<void> test_as_removed() async {
    setPackageContent('''
class A {}
class New extends A {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f(A o) {
  print(o as Old);
}
''');
    await assertHasFix('''
import '$importUri';

void f(A o) {
  print(o as New);
}
''');
  }

  Future<void> test_constructor_named_deprecated() async {
    setPackageContent('''
@deprecated
class Old {
  Old.c();
}
class New {
  New.c();
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f() {
  Old.c();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  New.c();
}
''');
  }

  Future<void> test_constructor_named_removed() async {
    setPackageContent('''
class New {
  New.c();
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f() {
  Old.c();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  New.c();
}
''');
  }

  Future<void> test_constructor_unnamed_deprecated() async {
    setPackageContent('''
@deprecated
class Old {
  Old();
}
class New {
  New();
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f() {
  Old();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  New();
}
''');
  }

  Future<void> test_constructor_unnamed_removed() async {
    setPackageContent('''
class New {
  New();
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f() {
  Old();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  New();
}
''');
  }

  Future<void> test_constructor_unnamed_removed_prefixed() async {
    setPackageContent('''
class New {
  New();
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri' as p;

void f() {
  p.Old();
}
''');
    await assertHasFix('''
import '$importUri' as p;

void f() {
  p.New();
}
''');
  }

  Future<void> test_inExtends_deprecated() async {
    setPackageContent('''
@deprecated
class Old {}
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C extends Old {}
''');
    await assertHasFix('''
import '$importUri';

class C extends New {}
''');
  }

  Future<void> test_inExtends_removed() async {
    setPackageContent('''
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C extends Old {}
''');
    await assertHasFix('''
import '$importUri';

class C extends New {}
''');
  }

  Future<void> test_inImplements_deprecated() async {
    setPackageContent('''
@deprecated
class Old {}
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C implements Old {}
''');
    await assertHasFix('''
import '$importUri';

class C implements New {}
''');
  }

  Future<void> test_inImplements_removed() async {
    setPackageContent('''
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C implements Old {}
''');
    await assertHasFix('''
import '$importUri';

class C implements New {}
''');
  }

  Future<void> test_inOn_deprecated() async {
    setPackageContent('''
@deprecated
class Old {}
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

extension E on Old {}
''');
    await assertHasFix('''
import '$importUri';

extension E on New {}
''');
  }

  Future<void> test_inOn_removed() async {
    setPackageContent('''
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

extension E on Old {}
''');
    await assertHasFix('''
import '$importUri';

extension E on New {}
''');
  }

  Future<void> test_inTypeAnnotation_deprecated() async {
    setPackageContent('''
@deprecated
class Old {}
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f(Old o) {}
''');
    await assertHasFix('''
import '$importUri';

void f(New o) {}
''');
  }

  Future<void> test_inTypeAnnotation_removed() async {
    setPackageContent('''
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f(Old o) {}
''');
    await assertHasFix('''
import '$importUri';

void f(New o) {}
''');
  }

  Future<void> test_inTypeArgument_deprecated() async {
    setPackageContent('''
@deprecated
class Old {}
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f() {
 var a = <Old>[];
 print(a);
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
 var a = <New>[];
 print(a);
}
''');
  }

  Future<void> test_inTypeArgument_removed() async {
    setPackageContent('''
class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f() {
  var a = <Old>[];
  var b = New();
  print(a);
  print(b);
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  var a = <New>[];
  var b = New();
  print(a);
  print(b);
}
''');
  }

  Future<void> test_inWith_deprecated() async {
    setPackageContent('''
@deprecated
mixin class Old {}
mixin class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C with Old {}
''');
    await assertHasFix('''
import '$importUri';

class C with New {}
''');
  }

  Future<void> test_inWith_removed() async {
    setPackageContent('''
mixin class New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C with Old {}
''');
    await assertHasFix('''
import '$importUri';

class C with New {}
''');
  }

  Future<void> test_staticField_deprecated() async {
    setPackageContent('''
@deprecated
class Old {
  static String empty = '';
}
class New {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var s = Old.empty;
''');
    await assertHasFix('''
import '$importUri';

var s = New.empty;
''');
  }

  Future<void> test_staticField_removed() async {
    setPackageContent('''
class New {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var s = Old.empty;
''');
    await assertHasFix('''
import '$importUri';

var s = New.empty;
''');
  }
}

@reflectiveTest
class RenameConstructorTest extends _AbstractRenameTest {
  @override
  String get _kind => 'constructor';

  Future<void> test_named_named_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  C.a();
  C.b();
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b();
}
''');
  }

  Future<void> test_named_named_removed() async {
    setPackageContent('''
class C {
  C.b();
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b();
}
''');
  }

  Future<void> test_named_unnamed_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  C.old();
  C();
}
''');
    setPackageData(_rename(['old', 'C'], ''));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.old();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C();
}
''');
  }

  Future<void> test_named_unnamed_removed() async {
    setPackageContent('''
class C {
  C();
}
''');
    setPackageData(_rename(['old', 'C'], ''));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.old();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C();
}
''');
  }

  Future<void> test_unnamed_named_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  C();
  C.a();
}
''');
    setPackageData(_rename(['', 'C'], 'a'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.a();
}
''');
  }

  Future<void> test_unnamed_named_removed() async {
    setPackageContent('''
class C {
  C.a();
}
''');
    setPackageData(_rename(['', 'C'], 'a'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.a();
}
''');
  }

  Future<void> test_unnamed_named_removed_prefixed() async {
    setPackageContent('''
class C {
  C.a();
}
''');
    setPackageData(_rename(['', 'C'], 'a'));
    await resolveTestCode('''
import '$importUri' as p;

void f() {
  p.C();
}
''');
    await assertHasFix('''
import '$importUri' as p;

void f() {
  p.C.a();
}
''');
  }
}

@reflectiveTest
class RenameExtensionTest extends _AbstractRenameTest {
  @override
  String get _kind => 'extension';

  Future<void> test_override_deprecated() async {
    setPackageContent('''
@deprecated
extension Old on String {
  int get double => length * 2;
}
extension New on String {
  int get double => length * 2;
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var l = Old('a').double;
''');
    await assertHasFix('''
import '$importUri';

var l = New('a').double;
''');
  }

  Future<void> test_override_removed() async {
    setPackageContent('''
extension New on String {
  int get double => length * 2;
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var l = Old('a').double;
''');
    await assertHasFix('''
import '$importUri';

var l = New('a').double;
''');
  }

  Future<void> test_staticField_deprecated() async {
    setPackageContent('''
@deprecated
extension Old on String {
  static String empty = '';
}
extension New on String {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var s = Old.empty;
''');
    await assertHasFix('''
import '$importUri';

var s = New.empty;
''');
  }

  Future<void> test_staticField_removed() async {
    setPackageContent('''
extension New on String {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var s = Old.empty;
''');
    await assertHasFix('''
import '$importUri';

var s = New.empty;
''');
  }

  Future<void> test_staticField_removed_prefixed() async {
    setPackageContent('''
extension New on String {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri' as p;

var s = p.Old.empty;
''');
    await assertHasFix('''
import '$importUri' as p;

var s = p.New.empty;
''');
  }
}

@reflectiveTest
class RenameExtensionTypeTest extends _AbstractRenameTest {
  @override
  String get _kind => 'extensionType';

  Future<void> test_override_deprecated() async {
    setPackageContent('''
@deprecated
extension type Old(String _) implements String {
  int get double => length * 2;
}
extension type New(String _) implements String {
  int get double => length * 2;
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var l = Old('a').double;
''');
    await assertHasFix('''
import '$importUri';

var l = New('a').double;
''');
  }

  Future<void> test_override_removed() async {
    setPackageContent('''
extension type New(String _) implements String {
  int get double => length * 2;
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var l = Old('a').double;
''');
    await assertHasFix('''
import '$importUri';

var l = New('a').double;
''');
  }

  Future<void> test_staticField_deprecated() async {
    setPackageContent('''
@deprecated
extension type Old(String _) implements String {
  static String empty = '';
}
extension type New(String _) implements String {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var s = Old.empty;
''');
    await assertHasFix('''
import '$importUri';

var s = New.empty;
''');
  }

  Future<void> test_staticField_removed() async {
    setPackageContent('''
extension type New(String _) implements String {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

var s = Old.empty;
''');
    await assertHasFix('''
import '$importUri';

var s = New.empty;
''');
  }

  Future<void> test_staticField_removed_prefixed() async {
    setPackageContent('''
extension type New(String _) implements String {
  static String empty = '';
}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri' as p;

var s = p.Old.empty;
''');
    await assertHasFix('''
import '$importUri' as p;

var s = p.New.empty;
''');
  }
}

@reflectiveTest
class RenameFieldTest extends _AbstractRenameTest {
  @override
  String get _kind => 'field';

  Future<void> test_instance_reference_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  int a;
  int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(C c) {
  c.a;
}
''');
    await assertHasFix('''
import '$importUri';

void f(C c) {
  c.b;
}
''');
  }

  Future<void> test_instance_reference_inPropertyAccess() async {
    setPackageContent('''
class A {
  static B m() => B();
}
class B {
  @deprecated
  final String f = '';
  final C g = C();
}
class C {
  final String h = '';
}
''');
    setPackageData(_rename(['f', 'B'], 'g.h'));
    await resolveTestCode('''
import '$importUri';

void f() {
  A.m().f;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  A.m().g.h;
}
''');
  }

  Future<void> test_instance_reference_removed() async {
    setPackageContent('''
class C {
  int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(C c) {
  c.a;
}
''');
    await assertHasFix('''
import '$importUri';

void f(C c) {
  c.b;
}
''');
  }

  Future<void> test_static_assignment_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  static int a;
  static int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a = 0;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b = 0;
}
''');
  }

  Future<void> test_static_assignment_removed() async {
    setPackageContent('''
class C {
  static int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a = 0;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b = 0;
}
''');
  }

  Future<void> test_static_reference_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  static int a;
  static int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b;
}
''');
  }

  Future<void> test_static_reference_removed() async {
    setPackageContent('''
class C {
  static int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b;
}
''');
  }

  Future<void> test_static_reference_removed_extension() async {
    setPackageContent('''
extension C {
  static int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b;
}
''');
  }

  Future<void> test_static_reference_removed_prefixed() async {
    setPackageContent('''
class C {
  static int b;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri' as p;

void f() {
  p.C.a;
}
''');
    await assertHasFix('''
import '$importUri' as p;

void f() {
  p.C.b;
}
''');
  }
}

@reflectiveTest
class RenameGetterTest extends _AbstractRenameTest {
  @override
  String get _kind => 'getter';

  Future<void> test_instance_nonReference_method_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  int get a => 0;
  int get b => 1;
}
class D {
  @deprecated
  void a(int b) {}
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(D d) {
  d.a(2);
}
''');
    await assertNoFix();
  }

  Future<void> test_instance_nonReference_parameter_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  int get a => 0;
  int get b => 1;
}
class D {
  D({@deprecated int a; int c});
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

D d = D(a: 2);
''');
    await assertNoFix();
  }

  Future<void> test_instance_reference_direct_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  int get a => 0;
  int get b => 1;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(C c) {
  c.a;
}
''');
    await assertHasFix('''
import '$importUri';

void f(C c) {
  c.b;
}
''');
  }

  Future<void> test_instance_reference_direct_deprecated_viaSubclass() async {
    setPackageContent('''
class A {
  @deprecated
  int get old => 0;
  int get replacement => 1;
}

class B extends A {}
''');
    setPackageData(_rename(['old', 'A'], 'replacement'));
    await resolveTestCode('''
import '$importUri';

void f(B b) {
  b.old;
}
''');
    await assertHasFix('''
import '$importUri';

void f(B b) {
  b.replacement;
}
''');
  }

  Future<void> test_instance_reference_direct_removed() async {
    setPackageContent('''
class C {
  int get b => 1;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(C c) {
  c.a;
}
''');
    await assertHasFix('''
import '$importUri';

void f(C c) {
  c.b;
}
''');
  }

  Future<void> test_instance_reference_indirect_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  int get a => 0;
  int get b => 1;
}
class D {
  C c() => C();
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(D d) {
  print(d.c().a);
}
''');
    await assertHasFix('''
import '$importUri';

void f(D d) {
  print(d.c().b);
}
''');
  }

  Future<void> test_instance_reference_indirect_removed() async {
    setPackageContent('''
class C {
  int get b => 1;
}
class D {
  C c() => C();
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(D d) {
  print(d.c().a);
}
''');
    await assertHasFix('''
import '$importUri';

void f(D d) {
  print(d.c().b);
}
''');
  }

  Future<void> test_topLevel_reference_deprecated() async {
    setPackageContent('''
@deprecated
int get a => 0;
int get b => 1;
''');
    setPackageData(_rename(['a'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  a;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  b;
}
''');
  }

  Future<void> test_topLevel_reference_removed() async {
    setPackageContent('''
int get b => 1;
''');
    setPackageData(_rename(['a'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  a;
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  b;
}
''');
  }

  Future<void> test_topLevel_reference_removed_prefixed() async {
    setPackageContent('''
int get b => 1;
''');
    setPackageData(_rename(['a'], 'b'));
    await resolveTestCode('''
import '$importUri' as p;

void f() {
  p.a;
}
''');
    await assertHasFix('''
import '$importUri' as p;

void f() {
  p.b;
}
''');
  }
}

@reflectiveTest
class RenameMethodTest extends _AbstractRenameTest {
  @override
  String get _kind => 'method';

  @failingTest
  Future<void> test_instance_override_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  int a() => 0;
  int b() => 0;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

class D extends C {
  @override
  int a() => 0;
}
''');
    await assertHasFix('''
import '$importUri';

class D extends C {
  @override
  int b() => 0;
}
''');
  }

  Future<void> test_instance_override_removed() async {
    setPackageContent('''
class C {
  int b() => 0;
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

class D extends C {
  @override
  int a() => 0;
}
''');
    await assertHasFix('''
import '$importUri';

class D extends C {
  @override
  int b() => 0;
}
''');
  }

  Future<void> test_instance_reference_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  int a() {}
  int b() {}
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(C c) {
  c.a();
}
''');
    await assertHasFix('''
import '$importUri';

void f(C c) {
  c.b();
}
''');
  }

  Future<void> test_instance_reference_direct_deprecated_viaSubclass() async {
    setPackageContent('''
class A {
  @deprecated
  void old() {}
  void replacement() {}
}

class B extends A {}
''');
    setPackageData(_rename(['old', 'A'], 'replacement'));
    await resolveTestCode('''
import '$importUri';

void f(B b) {
  b.old();
}
''');
    await assertHasFix('''
import '$importUri';

void f(B b) {
  b.replacement();
}
''');
  }

  Future<void> test_instance_reference_removed() async {
    setPackageContent('''
class C {
  int b() {}
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f(C c) {
  c.a();
}
''');
    await assertHasFix('''
import '$importUri';

void f(C c) {
  c.b();
}
''');
  }

  Future<void> test_static_reference_deprecated() async {
    setPackageContent('''
class C {
  @deprecated
  static int a() {}
  static int b() {}
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b();
}
''');
  }

  Future<void> test_static_reference_removed() async {
    setPackageContent('''
class C {
  static int b() {}
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  C.a();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  C.b();
}
''');
  }

  Future<void> test_static_reference_removed_prefixed() async {
    setPackageContent('''
class C {
  static int b() {}
}
''');
    setPackageData(_rename(['a', 'C'], 'b'));
    await resolveTestCode('''
import '$importUri' as p;

void f() {
  p.C.a();
}
''');
    await assertHasFix('''
import '$importUri' as p;

void f() {
  p.C.b();
}
''');
  }
}

@reflectiveTest
class RenameMixinTest extends _AbstractRenameTest {
  @override
  String get _kind => 'mixin';

  Future<void> test_inWith_deprecated() async {
    setPackageContent('''
@deprecated
mixin Old {}
mixin New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C with Old {}
''');
    await assertHasFix('''
import '$importUri';

class C with New {}
''');
  }

  Future<void> test_inWith_removed() async {
    setPackageContent('''
mixin New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

class C with Old {}
''');
    await assertHasFix('''
import '$importUri';

class C with New {}
''');
  }

  Future<void> test_inWith_removed_prefixed() async {
    setPackageContent('''
mixin New {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri' as p;

class C with p.Old {}
''');
    await assertHasFix('''
import '$importUri' as p;

class C with p.New {}
''');
  }
}

@reflectiveTest
class RenameSetterTest extends _AbstractRenameTest {
  @override
  // TODO(asashour): consider changing the kind to `setter`,
  // and matching it as `method`
  String get _kind => 'method';

  Future<void> test_invalidOverride() async {
    setPackageContent('''
class A {
  set x(int i) {}
}
''');
    setPackageData(_rename(['x', 'B'], 'y'));
    await resolveTestCode('''
import '$importUri';

class B extends A {
  set x(String s) {}
}
''');
    await assertHasFix('''
import '$importUri';

class B extends A {
  set y(String s) {}
}
''');
  }
}

@reflectiveTest
class RenameTopLevelFunctionTest extends _AbstractRenameTest {
  @override
  String get _kind => 'function';

  Future<void> test_deprecated() async {
    setPackageContent('''
@deprecated
int a() {}
int b() {}
''');
    setPackageData(_rename(['a'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  a();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  b();
}
''');
  }

  Future<void> test_removed() async {
    setPackageContent('''
int b() {}
''');
    setPackageData(_rename(['a'], 'b'));
    await resolveTestCode('''
import '$importUri';

void f() {
  a();
}
''');
    await assertHasFix('''
import '$importUri';

void f() {
  b();
}
''');
  }

  Future<void> test_removed_prefixed() async {
    setPackageContent('''
int b() {}
''');
    setPackageData(_rename(['a'], 'b'));
    await resolveTestCode('''
import '$importUri' as p;

void f() {
  p.a();
}
''');
    await assertHasFix('''
import '$importUri' as p;

void f() {
  p.b();
}
''');
  }
}

@reflectiveTest
class RenameTopLevelVariableTest extends _AbstractRenameTest {
  @override
  String get _kind => 'variable';

  Future<void> test_toStaticField_noPrefix_deprecated() async {
    setPackageContent('''
@deprecated
int Old = 0;
class C {
  int New = 1;
}
''');
    setPackageData(_rename(['Old'], 'C.New'));
    await resolveTestCode('''
import '$importUri';

int f() => Old;
''');
    await assertHasFix('''
import '$importUri';

int f() => C.New;
''');
  }

  Future<void> test_toTopLevel_withoutPrefix_deprecated() async {
    setPackageContent('''
@deprecated
int Old = 0;
int New = 1;
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

int f() => Old;
''');
    await assertHasFix('''
import '$importUri';

int f() => New;
''');
  }

  Future<void> test_toTopLevel_withoutPrefix_removed() async {
    setPackageContent('''
C New = C();
class C {}
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

C f() => Old;
''');
    await assertHasFix('''
import '$importUri';

C f() => New;
''');
  }

  Future<void> test_toTopLevel_withPrefix_deprecated() async {
    setPackageContent('''
@deprecated
int Old = 0;
int New = 1;
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri' as p;

int f() => p.Old;
''');
    await assertHasFix('''
import '$importUri' as p;

int f() => p.New;
''');
  }
}

@reflectiveTest
class RenameTypedefTest extends _AbstractRenameTest {
  @override
  String get _kind => 'typedef';

  Future<void> test_deprecated() async {
    setPackageContent('''
@deprecated
typedef Old = int Function(int);
typedef New = int Function(int);
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f(Old o) {}
''');
    await assertHasFix('''
import '$importUri';

void f(New o) {}
''');
  }

  Future<void> test_removed() async {
    setPackageContent('''
typedef New = int Function(int);
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri';

void f(Old o) {}
''');
    await assertHasFix('''
import '$importUri';

void f(New o) {}
''');
  }

  Future<void> test_removed_prefixed() async {
    setPackageContent('''
typedef New = int Function(int);
''');
    setPackageData(_rename(['Old'], 'New'));
    await resolveTestCode('''
import '$importUri' as p;

void f(p.Old o) {}
''');
    await assertHasFix('''
import '$importUri' as p;

void f(p.New o) {}
''');
  }
}

abstract class _AbstractRenameTest extends DataDrivenFixProcessorTest {
  /// Return the kind of element being renamed.
  String get _kind;

  Transform _rename(
    List<String> components,
    String newName, {
    bool isStatic = false,
  }) => Transform(
    title: 'title',
    date: DateTime.now(),
    element: ElementDescriptor(
      libraryUris: [Uri.parse(importUri)],
      kind: ElementKind.fromName(_kind)!,
      isStatic: isStatic,
      components: components,
    ),
    bulkApply: false,
    changesSelector: UnconditionalChangesSelector([Rename(newName: newName)]),
  );
}
