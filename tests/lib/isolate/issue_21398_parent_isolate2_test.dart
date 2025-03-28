// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:isolate';
import 'package:expect/async_helper.dart';
import "package:expect/expect.dart";

import "deferred_loaded_lib.dart" deferred as lib;

// Sends an object created from a deferred library that is loaded in the child
// isolate but not the parent isolate.
// The parent isolate successfully receives the object.

void funcChild(SendPort replyPort) {
  // Deferred load a library, create an object from that library and send
  // it over to the parent isolate which has not yet loaded that library.
  lib.loadLibrary().then((_) {
    replyPort.send(new lib.FromChildIsolate());
  });
}

void main() {
  var receivePort = new ReceivePort();
  asyncStart();

  // Spawn an isolate using spawnFunction.
  Isolate.spawn(funcChild, receivePort.sendPort).then((isolate) {
    receivePort.listen(
      (dynamic msg) {
        Expect.equals(10, msg.fld);
        receivePort.close();
        asyncEnd();
      },
      onError: (e, s) {
        // We don't expect to receive any error messages, per spec listen
        // does not receive an error object.
        Expect.fail("We don't expect to receive any error messages");
        receivePort.close();
        asyncEnd();
      },
    );
  });
}
