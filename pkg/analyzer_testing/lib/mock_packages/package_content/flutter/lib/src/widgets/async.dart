// Copyright 2015 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'framework.dart';

typedef AsyncWidgetBuilder<T> =
    Widget Function(BuildContext context, AsyncSnapshot<T> snapshot);

class AsyncSnapshot<T> {}

class StreamBuilder<T> extends StatefulWidget {
  final T? initialData;
  final AsyncWidgetBuilder<T> builder;

  const StreamBuilder({
    Key? key,
    this.initialData,
    required Stream<T>? stream,
    required this.builder,
  });
}

class FutureBuilder<T> extends StatefulWidget {
  final T? initialData;
  final AsyncWidgetBuilder<T> builder;

  const FutureBuilder({
    Key? key,
    this.initialData,
    required Future<T>? future,
    required this.builder,
  });
}
