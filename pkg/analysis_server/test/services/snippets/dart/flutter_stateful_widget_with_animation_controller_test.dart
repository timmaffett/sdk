// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/snippets/dart/flutter_stateful_widget_with_animation.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'test_support.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(FlutterStatefulWidgetWithAnimationControllerTest);
  });
}

@reflectiveTest
class FlutterStatefulWidgetWithAnimationControllerTest
    extends FlutterSnippetProducerTest {
  @override
  final generator = FlutterStatefulWidgetWithAnimationController.new;

  @override
  String get label => FlutterStatefulWidgetWithAnimationController.label;

  @override
  String get prefix => FlutterStatefulWidgetWithAnimationController.prefix;

  Future<void> test_noSuperParams() async {
    writeTestPackageConfig(flutter: true, languageVersion: '2.16');

    var code = '^';
    var expectedCode = r'''
import 'package:flutter/widgets.dart';

class /*0*/MyWidget extends StatefulWidget {
  const /*1*/MyWidget({Key? key}) : super(key: key);

  @override
  State</*2*/MyWidget> createState() => _/*3*/MyWidgetState();
}

class _/*4*/MyWidgetState extends State</*5*/MyWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return [!const Placeholder()!];
  }
}''';
    await assertFlutterSnippetResult(code, expectedCode, 'MyWidget');
  }

  Future<void> test_notValid_notFlutterProject() async {
    writeTestPackageConfig();

    await expectNotValidSnippet('^');
  }

  Future<void> test_valid() async {
    writeTestPackageConfig(flutter: true);

    var code = '^';
    var expectedCode = r'''
import 'package:flutter/widgets.dart';

class /*0*/MyWidget extends StatefulWidget {
  const /*1*/MyWidget({super.key});

  @override
  State</*2*/MyWidget> createState() => _/*3*/MyWidgetState();
}

class _/*4*/MyWidgetState extends State</*5*/MyWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return /*[0*/const Placeholder()/*0]*/;
  }
}''';
    await assertFlutterSnippetResult(code, expectedCode, 'MyWidget');
  }
}
