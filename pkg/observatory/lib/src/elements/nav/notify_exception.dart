// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:web/web.dart';

import '../../../models.dart' show ConnectionException;
import '../helpers/custom_element.dart';
import '../helpers/element_utils.dart';
import '../helpers/rendering_scheduler.dart';
import '../helpers/uris.dart';

class ExceptionDeleteEvent {
  final dynamic exception;
  final StackTrace? stacktrace;

  ExceptionDeleteEvent(this.exception, {this.stacktrace});
}

class NavNotifyExceptionElement extends CustomElement implements Renderable {
  late RenderingScheduler<NavNotifyExceptionElement> _r;

  Stream<RenderedEvent<NavNotifyExceptionElement>> get onRendered =>
      _r.onRendered;

  final StreamController<ExceptionDeleteEvent> _onDelete =
      new StreamController<ExceptionDeleteEvent>.broadcast();
  Stream<ExceptionDeleteEvent> get onDelete => _onDelete.stream;

  late dynamic _exception;
  StackTrace? _stacktrace;

  dynamic get exception => _exception;
  StackTrace? get stacktrace => _stacktrace;

  factory NavNotifyExceptionElement(
    dynamic exception, {
    StackTrace? stacktrace = null,
    RenderingQueue? queue,
  }) {
    assert(exception != null);
    NavNotifyExceptionElement e = new NavNotifyExceptionElement.created();
    e._r = new RenderingScheduler<NavNotifyExceptionElement>(e, queue: queue);
    e._exception = exception;
    e._stacktrace = stacktrace;
    return e;
  }

  NavNotifyExceptionElement.created() : super.created('nav-exception');

  @override
  void attached() {
    super.attached();
    _r.enable();
  }

  @override
  void detached() {
    super.detached();
    removeChildren();
    _r.disable(notify: true);
  }

  void render() {
    if (exception is ConnectionException) {
      renderConnectionException();
    } else {
      renderGenericException();
    }
  }

  void renderConnectionException() {
    children = <HTMLElement>[
      new HTMLDivElement()..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..textContent =
              'The request cannot be completed because the '
              'VM is currently disconnected',
        new HTMLBRElement(),
        new HTMLBRElement(),
        new HTMLSpanElement()..textContent = '[',
        new HTMLAnchorElement()
          ..href = Uris.vmConnect()
          ..text = 'Connect to a different VM',
        new HTMLSpanElement()..textContent = ']',
        new HTMLButtonElement()
          ..textContent = '×'
          ..onClick.map(_toEvent).listen(_delete),
      ]),
    ];
  }

  void renderGenericException() {
    List<HTMLElement> content;
    content = <HTMLElement>[
      new HTMLSpanElement()..textContent = 'Unexpected exception:',
      new HTMLBRElement(),
      new HTMLBRElement(),
      new HTMLDivElement()..textContent = exception.toString(),
      new HTMLBRElement(),
    ];
    if (stacktrace != null) {
      content.addAll(<HTMLElement>[
        new HTMLSpanElement()..textContent = 'StackTrace:',
        new HTMLBRElement(),
        new HTMLBRElement(),
        new HTMLDivElement()..textContent = stacktrace.toString(),
        new HTMLBRElement(),
      ]);
    }
    content.addAll(<HTMLElement>[
      new HTMLSpanElement()..textContent = '[',
      new HTMLAnchorElement()
        ..href = Uris.vmConnect()
        ..text = 'Connect to a different VM',
      new HTMLSpanElement()..textContent = ']',
      new HTMLButtonElement()
        ..textContent = '×'
        ..onClick.map(_toEvent).listen(_delete),
    ]);
    children = <HTMLElement>[new HTMLDivElement()..appendChildren(content)];
  }

  ExceptionDeleteEvent _toEvent(_) {
    return new ExceptionDeleteEvent(exception, stacktrace: stacktrace);
  }

  void _delete(ExceptionDeleteEvent e) {
    _onDelete.add(e);
  }

  void delete() {
    _onDelete.add(new ExceptionDeleteEvent(exception, stacktrace: stacktrace));
  }
}
