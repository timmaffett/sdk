// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

export 'ambiguous_main_a.dart';
export 'ambiguous_main_b.dart';

// [error line 6, column 1]
// [cfe] 'main' is exported from both 'tests/language/export/ambiguous_main_a.dart' and 'tests/language/export/ambiguous_main_b.dart'.
// [error line 6, column 8]
// [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXPORT
