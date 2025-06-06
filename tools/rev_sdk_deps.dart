// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Script to automatically update revisions in the DEPS file.
//
// Anyone can run this, and is welcome to.

import 'dart:convert';
import 'dart:io';

import 'package:cli_util/cli_logging.dart';
import 'package:path/path.dart' as path;
import 'package:pool/pool.dart' as pool;

/// The following set of packages should be individually reviewed.
///
/// Generally, they are from repos that are not Dart team owned, and we want to
/// ensure that we consistently review all changes from those repos.
const Set<String> individuallyReviewedPackages = {
  'tar',
};

void main(List<String> args) async {
  // Validate we're running from the repo root.
  if (!File('README.dart-sdk').existsSync() || !File('DEPS').existsSync()) {
    stderr.writeln('Please run this script from the root of the SDK repo.');
    exit(1);
  }

  final gclient = GClientHelper();

  final deps = await gclient.getPackageDependencies();
  print('${deps.length} package dependencies found.');

  // Remove pinned deps.
  final pinnedDeps = calculatePinnedDeps();
  deps.removeWhere((dep) => pinnedDeps.contains(dep.name));

  print('Not attempting to move forward the revisions for: '
      '${pinnedDeps.toList().join(', ')}.');
  print('');

  deps.sort((a, b) => a.name.compareTo(b.name));

  final gitPool = pool.Pool(10);

  final revDepsToCommits = Map.fromEntries(
    (await Future.wait(
      deps.map((dep) {
        return gitPool.withResource(() async {
          final git = GitHelper(dep.relativePath);
          await git.fetch();
          var commit = await git.findLatestUnsyncedCommit();
          return MapEntry(dep, commit);
        });
      }),
    ))
        .where((entry) {
      final commit = entry.value;
      return commit.isNotEmpty;
    }),
  );

  if (revDepsToCommits.isEmpty) {
    print('No new revisions.');
    return;
  }

  final separateReviewDeps = revDepsToCommits.keys
      .where((dep) => individuallyReviewedPackages.contains(dep.name))
      .toList();
  revDepsToCommits
      .removeWhere((dep, _) => individuallyReviewedPackages.contains(dep.name));

  final depsToRevNames = revDepsToCommits.keys.map((e) => e.name).join(', ');

  print('Move moving forward revisions for: $depsToRevNames.');
  if (separateReviewDeps.isNotEmpty) {
    print('(additional, individually reviewed updates are also available for: '
        '${separateReviewDeps.map((dep) => dep.name).join(', ')})');
  }
  print('');
  print('Commit message:');
  print('');
  print('[deps] rev $depsToRevNames');
  print('');
  print('Revisions updated by `dart tools/rev_sdk_deps.dart`.');
  print('');

  for (final MapEntry(key: dep, value: commit) in revDepsToCommits.entries) {
    final git = GitHelper(dep.relativePath);

    final gitLog = await git.calculateUnsyncedCommits();
    final currentHash = await gclient.getHash(dep);

    final gitHubRepo = dep.gitHubRepoIdentifier;

    // Construct and print out the GitHub diff URL.
    print('${dep.name} (${dep.gitHubDiffUrl(currentHash, commit)}):');

    /// Qualify or wrap the GitHub issue references within [commitMessage].
    String replaceHashReferences(String commitMessage) => commitMessage
        .replaceAllMapped(
          _mergeCommitPullRequestReference,
          (m) => '($gitHubRepo#${m[1]})',
        )
        .replaceAllMapped(_issueHashReference, (m) => '`${m[0]}`');

    // Format and print out the message header of each new commit.
    final newCommitHeaders = [
      for (final commitHeader in gitLog.split('\n'))
        '  ${replaceHashReferences(commitHeader)}',
    ];
    print(newCommitHeaders.join('\n').trimRight());

    // Update the DEPS file.
    await gclient.setHash(dep, commit);

    print('');
  }

  if (separateReviewDeps.isNotEmpty) {
    final boldText = Ansi(true)
        .emphasized('Note: updates are also available for additional packages');
    print('$boldText; these require individual review.\nPlease ensure that the '
        'review for these changes is thorough. To roll them:');
    print('');
    for (var dep in separateReviewDeps) {
      print('${dep.name} from ${dep.url}:');
      print('  dart tools/manage_deps.dart bump third_party/pkg/${dep.name}');
      print('');
    }
  }
}

/// A regex that matches the final PR reference of a merge commit header.
///
/// Allows replacing the PR reference with a repository qualified reference,
/// so that GitHub auto links to the correct repository instead of
/// an irrelevant issue or PR on the SDK repository.
final RegExp _mergeCommitPullRequestReference = RegExp(r'\(#?(\d+)\)$');

/// A regex that matches any non-qualified issue or PR references
/// within a commit message, such as `#123`.
///
/// Allows replacing or wrapping the potential issue or PR references so that
/// GitHub doesn't autolink to an irrelevant issue or PR on the SDK repository.
final RegExp _issueHashReference = RegExp(r'\B#\d+');

// By convention, pinned deps are deps with an eol comment.
Set<String> calculatePinnedDeps() {
  final packageRevision = RegExp(r'"(\w+)_rev":');

  // "markdown_rev": "e3f4bd28c9...cfeccd83ee", # b/236358256
  var depsFile = File('DEPS');
  return depsFile
      .readAsLinesSync()
      .where((line) => packageRevision.hasMatch(line) && line.contains('", #'))
      .map((line) => packageRevision.firstMatch(line)!.group(1)!)
      .toSet();
}

class GitHelper {
  final String dir;

  GitHelper(this.dir);

  Future<String> fetch() {
    return exec(['git', 'fetch'], cwd: dir);
  }

  Future<String> findLatestUnsyncedCommit() async {
    // git log ..origin/<default-branch> --format=%H -1

    var result = await exec(
      [
        'git',
        'log',
        '..origin/$defaultBranchName',
        '--format=%H',
        '-1',
      ],
      cwd: dir,
    );
    return result.trim();
  }

  Future<String> calculateUnsyncedCommits() async {
    // git log ..origin/<default-branch> --format="%h  %ad  %aN  %s" -1
    var result = await exec(
      [
        'git',
        'log',
        '..origin/$defaultBranchName',
        '--format=%h  %ad  %aN  %s',
      ],
      cwd: dir,
    );
    return result.trim();
  }

  String get defaultBranchName {
    var branchNames = Directory(path.join(dir, '.git', 'refs', 'heads'))
        .listSync()
        .whereType<File>()
        .map((f) => path.basename(f.path))
        .toSet();

    for (var name in ['main', 'master']) {
      if (branchNames.contains(name)) {
        return name;
      }
    }

    return 'main';
  }
}

class GClientHelper {
  Future<String> execGclient(
    List<String> cmd, {
    String? cwd,
    Map<String, String>? environment,
  }) {
    return exec(
      [Platform.isWindows ? 'gclient.bat' : 'gclient', ...cmd],
      cwd: cwd,
      environment: environment,
    );
  }

  Future<List<PackageDependency>> getPackageDependencies() async {
    // gclient revinfo --output-json=<file> --ignore-dep-type=cipd

    final tempDir = Directory.systemTemp.createTempSync();
    final outFile = File(path.join(tempDir.path, 'deps.json'));

    await execGclient([
      'revinfo',
      '--output-json=${outFile.path}',
      '--ignore-dep-type=cipd',
    ]);
    Map<String, dynamic> m = jsonDecode(outFile.readAsStringSync());
    tempDir.deleteSync(recursive: true);

    return m.entries.map((entry) {
      return PackageDependency(
        entry: entry.key,
        url: (entry.value as Map)['url'],
        rev: (entry.value as Map)['rev'],
      );
    }).where((PackageDependency deps) {
      return deps.entry.startsWith('sdk/third_party/pkg/');
    }).toList();
  }

  Future<String> getHash(PackageDependency dep) async {
    // DEPOT_TOOLS_UPDATE=0 gclient getdep --var=path_rev
    var depName = dep.name;
    var result = await execGclient(
      [
        'getdep',
        '--var=${depName}_rev',
      ],
      environment: {
        'DEPOT_TOOLS_UPDATE': '0',
      },
    );
    return result.trim();
  }

  Future<String> setHash(PackageDependency dep, String hash) async {
    // gclient setdep --var=args_rev=9879dsf7g9d87d9f8g7
    var depName = dep.name;
    return await execGclient(
      [
        'setdep',
        '--var=${depName}_rev=$hash',
      ],
      environment: {
        'DEPOT_TOOLS_UPDATE': '0',
      },
    );
  }
}

class PackageDependency {
  final String entry;
  final String url;
  final String? rev;

  PackageDependency({
    required this.entry,
    required this.url,
    required this.rev,
  });

  String get name => entry.substring(entry.lastIndexOf('/') + 1);

  String get relativePath => entry.substring('sdk/'.length);

  /// The identifier of the GitHub repository this dependency is from.
  ///
  /// For example: `dart-lang/test`.
  String get gitHubRepoIdentifier {
    var repo = url.substring(url.lastIndexOf('/') + 1);
    if (repo.endsWith('git')) {
      repo = repo.substring(0, repo.length - '.git'.length);
    }

    final String org;
    if (url.contains('/external/')) {
      // https://dart.googlesource.com/external/github.com/google/webdriver.dart.git
      final parts = url.split('/');
      org = parts[parts.length - 2];
    } else {
      org = 'dart-lang';
    }

    return '$org/$repo';
  }

  /// The URL of the GitHub comparison view between [fromCommit] and [toCommit].
  Uri gitHubDiffUrl(String fromCommit, String toCommit) {
    // https://github.com/dart-lang/<repo>/compare/<old>..<new>
    final from = fromCommit.substring(0, 7);
    final to = toCommit.substring(0, 7);

    return Uri.https('github.com', '$gitHubRepoIdentifier/compare/$from..$to');
  }

  @override
  String toString() => '${rev?.substring(0, 8)} $relativePath';
}

Future<String> exec(
  List<String> cmd, {
  String? cwd,
  Map<String, String>? environment,
}) async {
  var result = await Process.run(
    cmd.first,
    cmd.sublist(1),
    workingDirectory: cwd,
    environment: environment,
  );
  if (result.exitCode != 0) {
    var cwdLocation = cwd == null ? '' : ' ($cwd)';
    print('${cmd.join(' ')}$cwdLocation');

    if ((result.stdout as String).isNotEmpty) {
      stdout.write(result.stdout);
    }
    if ((result.stderr as String).isNotEmpty) {
      stderr.write(result.stderr);
    }
    exit(1);
  }
  return result.stdout;
}
