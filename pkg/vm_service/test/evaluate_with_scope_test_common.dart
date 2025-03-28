// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'common/service_test_common.dart';

int? thing1;
int? thing2;

void testeeMain() {
  thing1 = 3;
  thing2 = 4;
}

Future<InstanceRef> evaluate(VmService service, isolate, target, x, y) async =>
    await service.evaluate(
      isolate!.id!!,
      target.id!,
      'x + y',
      scope: {'x': x.id!, 'y': y.id!},
    ) as InstanceRef;

final evaluteWithScopeTests = <IsolateTest>[
  hasStoppedAtExit,
  (VmService service, IsolateRef isolateRef) async {
    final isolateId = isolateRef.id!;
    final isolate = await service.getIsolate(isolateId);
    // [isolate.rootLib] refers to the test entrypoint library, which is a
    // library that imports this file's library. We want a [Library] object that
    // refers to this file's library itself.
    final libId = isolate.libraries!
        .singleWhere(
          (l) => l.uri!.endsWith('evaluate_with_scope_test_common.dart'),
        )
        .id!;
    final Library lib = (await service.getObject(isolateId, libId)) as Library;

    final Field field1 = (await service.getObject(
      isolateId,
      lib.variables!.singleWhere((v) => v.name == 'thing1').id!,
    )) as Field;
    final thing1 = await service.getObject(isolateId, field1.staticValue!.id!);

    final Field field2 = (await service.getObject(
      isolateId,
      lib.variables!.singleWhere((v) => v.name == 'thing2').id!,
    )) as Field;
    final thing2 = await service.getObject(isolateId, field2.staticValue!.id!);

    var result = await evaluate(service, isolate, lib, thing1, thing2);
    expect(result.valueAsString, equals('7'));

    bool didThrow = false;
    try {
      result = await evaluate(service, isolate, lib, lib, lib);
      print(result);
    } catch (e) {
      didThrow = true;
      expect(
        e.toString(),
        contains('Cannot evaluate against a VM-internal object'),
      );
    }
    expect(didThrow, isTrue);

    didThrow = false;
    try {
      result = await service.evaluate(
        isolateId,
        lib.id!,
        'x + y',
        scope: <String, String>{'not&an&id!entifier': thing1.id!},
      ) as InstanceRef;
      print(result);
    } catch (e) {
      didThrow = true;
      expect(e.toString(), contains("invalid 'scope' parameter"));
    }
    expect(didThrow, isTrue);
  }
];
