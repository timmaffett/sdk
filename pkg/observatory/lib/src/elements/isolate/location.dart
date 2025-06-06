// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:web/web.dart';

import '../../../models.dart' as M;
import '../function_ref.dart';
import '../helpers/custom_element.dart';
import '../helpers/rendering_scheduler.dart';
import '../source_link.dart';

class IsolateLocationElement extends CustomElement implements Renderable {
  late RenderingScheduler<IsolateLocationElement> _r;

  Stream<RenderedEvent<IsolateLocationElement>> get onRendered => _r.onRendered;

  late M.Isolate _isolate;
  late M.EventRepository _events;
  late M.ScriptRepository _scripts;
  late StreamSubscription _debugSubscription;
  late StreamSubscription _isolateSubscription;

  factory IsolateLocationElement(
    M.Isolate isolate,
    M.EventRepository events,
    M.ScriptRepository scripts, {
    RenderingQueue? queue,
  }) {
    IsolateLocationElement e = new IsolateLocationElement.created();
    e._r = new RenderingScheduler<IsolateLocationElement>(e, queue: queue);
    e._isolate = isolate;
    e._events = events;
    e._scripts = scripts;
    return e;
  }

  IsolateLocationElement.created() : super.created('isolate-location');

  @override
  void attached() {
    super.attached();
    _r.enable();
    _debugSubscription = _events.onDebugEvent.listen(_eventListener);
    _isolateSubscription = _events.onIsolateEvent.listen(_eventListener);
  }

  @override
  void detached() {
    super.detached();
    removeChildren();
    _r.disable(notify: true);
    _debugSubscription.cancel();
    _isolateSubscription.cancel();
  }

  void render() {
    switch (_isolate.status) {
      case M.IsolateStatus.loading:
        children = <HTMLElement>[
          new HTMLSpanElement()..textContent = 'not yet runnable',
        ];
        break;
      case M.IsolateStatus.running:
        children = <HTMLElement>[
          new HTMLSpanElement()..textContent = 'at ',
          new FunctionRefElement(
            _isolate,
            M.topFrame(_isolate.pauseEvent)!.function!,
            queue: _r.queue,
          ).element,
          new HTMLSpanElement()..textContent = ' (',
          new SourceLinkElement(
            _isolate,
            M.topFrame(_isolate.pauseEvent)!.location!,
            _scripts,
            queue: _r.queue,
          ).element,
          new HTMLSpanElement()..textContent = ') ',
        ];
        break;
      case M.IsolateStatus.paused:
        if (_isolate.pauseEvent is M.PauseStartEvent) {
          children = <HTMLElement>[
            new HTMLSpanElement()..textContent = 'at isolate start',
          ];
        } else if (_isolate.pauseEvent is M.PauseExitEvent) {
          children = <HTMLElement>[
            new HTMLSpanElement()..textContent = 'at isolate exit',
          ];
        } else if (_isolate.pauseEvent is M.NoneEvent) {
          children = <HTMLElement>[
            new HTMLSpanElement()..textContent = 'not yet runnable',
          ];
        } else {
          final content = <HTMLElement>[];
          if (_isolate.pauseEvent is M.PauseBreakpointEvent) {
            content.add(new HTMLSpanElement()..textContent = 'by breakpoint');
          } else if (_isolate.pauseEvent is M.PauseExceptionEvent) {
            content.add(new HTMLSpanElement()..textContent = 'by exception');
          }
          if (M.topFrame(_isolate.pauseEvent) != null) {
            content.addAll([
              new HTMLSpanElement()..textContent = ' at ',
              new FunctionRefElement(
                _isolate,
                M.topFrame(_isolate.pauseEvent)!.function!,
                queue: _r.queue,
              ).element,
              new HTMLSpanElement()..textContent = ' (',
              new SourceLinkElement(
                _isolate,
                M.topFrame(_isolate.pauseEvent)!.location!,
                _scripts,
                queue: _r.queue,
              ).element,
              new HTMLSpanElement()..textContent = ') ',
            ]);
          }
          children = content;
        }
        break;
      default:
        children = const [];
    }
  }

  void _eventListener(e) {
    if (e.isolate.id == _isolate.id) {
      // This view doesn't display registered service extensions.
      if (e is! M.ServiceRegisteredEvent && e is! M.ServiceUnregisteredEvent) {
        _r.dirty();
      }
    }
  }
}
