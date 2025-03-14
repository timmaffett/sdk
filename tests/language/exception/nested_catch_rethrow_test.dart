// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:expect/expect.dart';

void exception1(String e) {
  throw e;
}

void exception2(String e) {
  throw e;
}

Future<void> doThrow1() async {
  try {
    exception1('outer');
  } on Object {
    try {
      exception2('inner');
    } on Object {
      // ignore
    }
    rethrow;
  }
}

Future<void> doThrow2() async {
  try {
    exception2('outer');
  } on Object {
    try {
      exception1('inner');
    } on Object {
      try {
        exception1('more inner');
      } on Object {
        // ignore
      }
    }
    rethrow;
  }
}

Future<void> doThrow3() async {
  try {
    exception1('outer');
  } on Object {
    try {
      // don't throw
    } on Object {
      try {
        // also don't throw
      } on Object {
        // ignore
      }
    }
    rethrow;
  }
}

Future<void> doThrow4() async {
  try {
    exception1('outer');
  } on Object {
    try {
      exception2('inner');
    } on bool {}
    rethrow;
  }
}

Future<void> doThrow5(int v) async {
  await Future.delayed(Duration(milliseconds: 10));
  throw StateError('error $v');
}

Stream<int> _readLoop() async* {
  try {
    while (true) {
      yield 1;
      await doThrow5(0);
    }
  } catch (e) {
    throw StateError('converted');
  } finally {
    try {
      await doThrow5(1);
    } catch (e) {
      Expect.isTrue('$e'.contains('error 1'));
    }
  }
}

void main() async {
  try {
    await doThrow1();
    Expect.fail('should throw');
  } catch (e, s) {
    Expect.equals(e, 'outer');
    Expect.isTrue('$s'.contains('exception1'));
  }

  try {
    await doThrow2();
    Expect.fail('should throw');
  } catch (e, s) {
    Expect.equals(e, 'outer');
    Expect.isTrue('$s'.contains('exception2'));
  }

  try {
    await doThrow3();
    Expect.fail('should throw');
  } catch (e, s) {
    Expect.equals(e, 'outer');
    Expect.isTrue('$s'.contains('exception1'));
  }

  try {
    await doThrow4();
    Expect.fail('should throw');
  } catch (e, s) {
    Expect.equals(e, 'inner');
    Expect.isTrue('$s'.contains('exception2'));
  }

  try {
    await for (var _ in _readLoop()) {}
  } catch (e) {
    Expect.isTrue('$e'.contains('converted'));
  }
}
