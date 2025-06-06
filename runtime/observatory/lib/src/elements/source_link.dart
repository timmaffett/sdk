// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library source_link_element;

import 'dart:async';

import 'package:web/web.dart';

import 'package:observatory/service.dart' as S;
import 'package:observatory/src/elements/helpers/custom_element.dart';
import 'package:observatory/src/elements/helpers/rendering_scheduler.dart';
import 'package:observatory/src/elements/helpers/uris.dart';

import 'package:observatory/models.dart'
    show IsolateRef, SourceLocation, Script, ScriptRepository;

class SourceLinkElement extends CustomElement implements Renderable {
  late RenderingScheduler<SourceLinkElement> _r;

  Stream<RenderedEvent<SourceLinkElement>> get onRendered => _r.onRendered;

  late IsolateRef _isolate;
  late SourceLocation _location;
  Script? _script;
  late ScriptRepository _repository;

  IsolateRef get isolate => _isolate;
  SourceLocation get location => _location;

  factory SourceLinkElement(
      IsolateRef isolate, SourceLocation location, ScriptRepository repository,
      {RenderingQueue? queue}) {
    SourceLinkElement e = new SourceLinkElement.created();
    e._r = new RenderingScheduler<SourceLinkElement>(e, queue: queue);
    e._isolate = isolate;
    e._location = location;
    e._repository = repository;
    return e;
  }

  SourceLinkElement.created() : super.created('source-link');

  @override
  void attached() {
    super.attached();
    _repository.get(_isolate, _location.script!.id!).then((script) {
      _script = script;
      _r.dirty();
    }, onError: (e) {
      // The script object has expired, likely due to a hot reload.
      (_isolate as S.Isolate).getScripts().then((scripts) {
        var uri = _location.script!.uri;
        for (final script in scripts) {
          if (script.uri == uri) {
            _script = script;
            _r.dirty();
            return;
          }
        }
        // Rethrow the original exception if we can't find a match.
        throw e;
      });
    });
    _r.enable();
  }

  @override
  void detached() {
    super.detached();
    removeChildren();
    _r.disable(notify: true);
  }

  Future render() async {
    if (_script == null) {
      children = <HTMLElement>[
        new HTMLSpanElement()..textContent = '<LOADING>'
      ];
    } else {
      String label = _script!.uri!.split('/').last;
      int? token = _location.tokenPos;
      int? line = _script!.tokenToLine(token);
      int? column = _script!.tokenToCol(token);
      children = <HTMLElement>[
        new HTMLAnchorElement()
          ..href = Uris.inspect(isolate, object: _script!, pos: token)
          ..title = _script!.uri!
          ..text = '${label}:${line}:${column}'
      ];
    }
  }
}
