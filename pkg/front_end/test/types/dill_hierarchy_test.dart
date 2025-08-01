// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package:expect/async_helper.dart" show asyncTest;
import "package:expect/expect.dart" show Expect;
import "package:front_end/src/api_prototype/compiler_options.dart"
    show CompilerOptions;
import "package:front_end/src/base/compiler_context.dart" show CompilerContext;
import "package:front_end/src/base/processed_options.dart"
    show ProcessedOptions;
import "package:front_end/src/base/ticker.dart" show Ticker;
import "package:front_end/src/builder/declaration_builders.dart";
import "package:front_end/src/dill/dill_loader.dart" show DillLoader;
import "package:front_end/src/dill/dill_target.dart" show DillTarget;
import "package:front_end/src/kernel/hierarchy/hierarchy_builder.dart"
    show ClassHierarchyBuilder;
import "package:kernel/ast.dart" show Class, Component, Library;
import "package:kernel/core_types.dart" show CoreTypes;
import "package:kernel/target/targets.dart" show NoneTarget, TargetFlags;
import 'package:kernel/testing/type_parser_environment.dart'
    show parseComponent;

const String expectedHierarchy = """
Object:
  superclasses:

A:
  superclasses:
    Object!

B:
  Longest path to Object: 2
  superclasses:
    Object!
  interfaces: A!

C:
  Longest path to Object: 2
  superclasses:
    Object!
  interfaces: A!

D:
  Longest path to Object: 3
  superclasses:
    Object!
  interfaces: B<T%>!, A!, C<U%>!

E:
  Longest path to Object: 4
  superclasses:
    Object!
  interfaces: D<int!,double!>!, B<int!>!, A!, C<double!>!

F:
  Longest path to Object: 4
  superclasses:
    Object!
  interfaces: D<int!,bool!>!, B<int!>!, A!, C<bool!>!
""";

void main() {
  final Ticker ticker = new Ticker(isVerbose: false);
  final Component component = parseComponent("""
class A;
class B<T> implements A;
class C<U> implements A;
class D<T, U> implements B<T>, C<U>;
class E implements D<int, double>;
class F implements D<int, bool>;""",
      Uri.parse("org-dartlang-test:///library.dart"));

  final CompilerContext context = new CompilerContext(new ProcessedOptions(
      options: new CompilerOptions()
        ..packagesFileUri =
            Uri.base.resolve(".dart_tool/package_config.json")));

  asyncTest(() => context.runInContext<void>((_) async {
        DillTarget target = new DillTarget(
            context,
            ticker,
            await context.options.getUriTranslator(),
            new NoneTarget(new TargetFlags()));
        final DillLoader loader = target.loader;
        loader.appendLibraries(component);
        target.buildOutlines();
        ClassBuilder objectClass = loader.coreLibrary
            .lookupRequiredLocalMember("Object") as ClassBuilder;
        ClassHierarchyBuilder hierarchy = new ClassHierarchyBuilder(
            objectClass, loader, new CoreTypes(component));
        Library library = component.libraries.last;
        for (Class cls in library.classes) {
          hierarchy.getNodeFromClass(cls);
        }
        Expect.stringEquals(
            expectedHierarchy, hierarchy.classNodes.values.join("\n"));
      }));
}
