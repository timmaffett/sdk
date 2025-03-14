// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'package:args/command_runner.dart';

mixin PrintUsageException implements Command<void> {
  @override
  Never usageException(String message) {
    print(message);
    printUsage();
    exit(1);
  }
}
