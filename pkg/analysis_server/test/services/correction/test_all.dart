// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'change_test.dart' as change_test;
import 'levenshtein_test.dart' as levenshtein_test;
import 'name_suggestion_test.dart' as name_suggestion_test;
import 'organize_directives_test.dart' as organize_directives_test;
import 'sort_members_test.dart' as sort_members_test;
import 'status_test.dart' as status_test;

void main() {
  defineReflectiveSuite(() {
    change_test.main();
    levenshtein_test.main();
    name_suggestion_test.main();
    organize_directives_test.main();
    sort_members_test.main();
    status_test.main();
  }, name: 'correction');
}
