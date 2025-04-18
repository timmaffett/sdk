// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library WebSocketTest;

import 'dart:html';

import 'package:expect/legacy/async_minitest.dart'; // ignore: deprecated_member_use

main() {
  group('supported', () {
    test('supported', () {
      expect(WebSocket.supported, true);
    });
  });

  group('websocket', () {
    var expectation = WebSocket.supported ? returnsNormally : throws;

    test('constructorTest', () {
      expect(() {
        var socket = new WebSocket('ws://localhost/ws', 'chat');
        expect(socket, isNotNull);
        expect(socket, isInstanceOf<WebSocket>());
      }, expectation);
    });

    if (WebSocket.supported) {
      test('echo', () {
        var socket = new WebSocket('ws://${window.location.host}/ws');

        socket.onOpen.first.then((_) {
          socket.send('hello!');
        });

        return socket.onMessage.first.then((MessageEvent e) {
          expect(e.data, 'hello!');
          socket.close();
        });
      });

      test('error handling', () {
        var socket = new WebSocket('ws://${window.location.host}/ws');
        socket.onOpen.first.then((_) => socket.send('close-with-error'));
        return socket.onError.first.then((e) {
          print('$e was caught, yay!');
          socket.close();
        });
      });
    }
  });
}
