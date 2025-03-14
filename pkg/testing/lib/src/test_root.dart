// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library;

import 'dart:async' show Future;

import 'dart:convert' show json;

import 'dart:io' show File;

import '../testing.dart' show Chain;

import 'analyze.dart' show Analyze;

import 'suite.dart' show Suite;

/// Records properties of a test root. The information is read from a JSON file.
///
/// Example with comments:
///     {
///       # Path to the `.packages` file used.
///       "packages": "test/.packages",
///       # A list of test suites (collection of tests).
///       "suites": [
///         # A list of suite objects. See the subclasses of [Suite] below.
///       ],
///       "analyze": {
///         # Uris to analyze.
///         "uris": [
///           "lib/",
///           "bin/dartk.dart",
///           "bin/repl.dart",
///           "test/log_analyzer.dart",
///           "third_party/testing/lib/"
///         ],
///         # Regular expressions of file names to ignore when analyzing.
///         "exclude": [
///           "/third_party/dart-sdk/pkg/compiler/",
///           "/third_party/kernel/"
///         ]
///       }
///     }
class TestRoot {
  final Uri packages;

  final List<Suite> suites;

  TestRoot(this.packages, this.suites);

  Analyze get analyze => suites.last as Analyze;

  List<Uri> get urisToAnalyze => analyze.uris;

  Iterable<Chain> get toolChains {
    return List<Chain>.from(suites.whereType<Chain>());
  }

  @override
  String toString() {
    return "TestRoot($suites, $urisToAnalyze)";
  }

  static Future<TestRoot> fromUri(Uri uri) async {
    String jsonText = await File.fromUri(uri).readAsString();
    Map data = json.decode(jsonText);

    addDefaults(data);

    Uri packages = uri.resolve(data["packages"]);

    List<Suite> suites = data["suites"]
        .map<Suite>((json) => Suite.fromJsonMap(uri, json))
        .toList();

    Analyze analyze = await Analyze.fromJsonMap(uri, data["analyze"], suites);

    suites.add(analyze);

    return TestRoot(packages, suites);
  }

  static void addDefaults(Map data) {
    data.putIfAbsent("packages", () => ".packages");
    data.putIfAbsent("suites", () => []);
    Map analyze = data.putIfAbsent("analyze", () => {});
    analyze.putIfAbsent("uris", () => []);
    analyze.putIfAbsent("exclude", () => []);
  }
}
