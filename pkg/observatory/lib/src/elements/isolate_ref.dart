// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library isolate_ref_element;

import 'dart:async';

import 'package:web/web.dart';

import '../../models.dart' as M show IsolateRef, EventRepository;
import 'helpers/custom_element.dart';
import 'helpers/rendering_scheduler.dart';
import 'helpers/uris.dart';

class IsolateRefElement extends CustomElement implements Renderable {
  late RenderingScheduler<IsolateRefElement> _r;

  Stream<RenderedEvent<IsolateRefElement>> get onRendered => _r.onRendered;

  late M.IsolateRef _isolate;
  late M.EventRepository _events;
  late StreamSubscription _updatesSubscription;

  M.IsolateRef get isolate => _isolate;

  factory IsolateRefElement(
    M.IsolateRef isolate,
    M.EventRepository events, {
    RenderingQueue? queue,
  }) {
    IsolateRefElement e = new IsolateRefElement.created();
    e._r = new RenderingScheduler<IsolateRefElement>(e, queue: queue);
    e._isolate = isolate;
    e._events = events;
    return e;
  }

  IsolateRefElement.created() : super.created('isolate-ref');

  @override
  void attached() {
    super.attached();
    _updatesSubscription = _events.onIsolateUpdate
        .where((e) => e.isolate.id == isolate.id)
        .listen((e) {
          _isolate = e.isolate;
          _r.dirty();
        });
    _r.enable();
  }

  @override
  void detached() {
    super.detached();
    removeChildren();
    _r.disable(notify: true);
    _updatesSubscription.cancel();
  }

  void render() {
    final isolateType = isolate.isSystemIsolate! ? 'System Isolate' : 'Isolate';
    children = <HTMLElement>[
      new HTMLAnchorElement()
        ..href = Uris.inspect(isolate)
        ..text = '$isolateType ${isolate.number} (${isolate.name})'
        ..className = 'isolate-ref',
    ];
  }
}
