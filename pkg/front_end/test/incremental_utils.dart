// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import "package:front_end/src/api_prototype/file_system.dart" show FileSystem;
import 'package:front_end/src/kernel/utils.dart' show serializeComponent;
import 'package:kernel/kernel.dart'
    show
        Class,
        Component,
        EmptyStatement,
        FileUriNode,
        Library,
        Node,
        Procedure,
        RecursiveVisitor;

Uint8List postProcess(Component c, {bool clearMetadata = true}) {
  postProcessComponent(c, clearMetadata: clearMetadata);
  return serializeComponent(c);
}

void postProcessComponent(Component c, {bool clearMetadata = true}) {
  if (clearMetadata) {
    // For now metadata isn't great for recompiles because it will only contain
    // what was just compiled. To avoid failures caused by this we for now just
    // clear the metadata.
    c.metadata.clear();
  }
  c.libraries.sort((l1, l2) {
    return "${l1.fileUri}".compareTo("${l2.fileUri}");
  });

  c.problemsAsJson?.sort();

  c.computeCanonicalNames();
  for (Library library in c.libraries) {
    library.additionalExports.sort();
    library.problemsAsJson?.sort();
  }
}

void throwOnEmptyMixinBodies(Component component) {
  int empty = countEmptyMixinBodies(component);
  if (empty != 0) {
    throw "Expected 0 empty bodies in mixins, but found $empty";
  }
}

int countEmptyMixinBodies(Component component) {
  int empty = 0;
  for (Library lib in component.libraries) {
    for (Class c in lib.classes) {
      if (c.isAnonymousMixin) {
        for (Procedure p in c.procedures) {
          if (p.function.body is EmptyStatement) {
            empty++;
          }
        }
      }
    }
  }
  return empty;
}

Future<void> throwOnInsufficientUriToSource(Component component,
    {FileSystem? fileSystem}) async {
  UriFinder uriFinder = new UriFinder();
  component.accept(uriFinder);
  Set<Uri> uris = uriFinder.seenUris.toSet();
  uris.removeAll(component.uriToSource.keys);
  uris.remove(null);
  if (uris.length != 0) {
    throw "Expected 0 uris with no source, but found ${uris.length} ($uris)";
  }

  if (fileSystem != null) {
    uris = uriFinder.seenUris.toSet();
    for (Uri uri in uris) {
      if (!uri.isScheme("org-dartlang-test")) continue;
      // The file system doesn't have the sources for any modules.
      // For now assume that that is always what's going on.
      if (!await fileSystem.entityForUri(uri).exists()) continue;
      List<int> expected = await fileSystem.entityForUri(uri).readAsBytes();
      List<int> actual = component.uriToSource[uri]!.source;
      bool fail = false;
      if (expected.length != actual.length) {
        fail = true;
      }
      if (!fail) {
        for (int i = 0; i < expected.length; i++) {
          if (expected[i] != actual[i]) {
            fail = true;
            break;
          }
        }
      }
      if (fail) {
        String expectedString = utf8.decode(expected);
        String actualString = utf8.decode(actual);
        throw "Not expected source for $uri:\n\n"
            "$expectedString\n\n"
            "vs\n\n"
            "$actualString";
      }
    }
  }
}

class UriFinder extends RecursiveVisitor {
  Set<Uri> seenUris = new Set<Uri>();
  @override
  void defaultNode(Node node) {
    super.defaultNode(node);
    if (node is FileUriNode) {
      seenUris.add(node.fileUri);
    }
  }
}
