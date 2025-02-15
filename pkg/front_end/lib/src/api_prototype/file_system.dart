// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library front_end.file_system;

import 'dart:typed_data' show Uint8List;

/// Abstract interface to file system operations.
///
/// All front end interaction with the file system goes through this interface;
/// this makes it possible for clients to use the front end in a way that
/// doesn't require file system access (e.g. to run unit tests, or to run
/// inside a browser).
///
/// Not intended to be implemented or extended by clients.
abstract class FileSystem {
  /// Returns a [FileSystemEntity] corresponding to the given [uri].
  ///
  /// Uses of `..` and `.` in the URI are normalized before returning.
  ///
  /// If the URI scheme is not supported by this file system, an [Error] will be
  /// thrown.
  ///
  /// Does not check whether a file or folder exists at the given location.
  FileSystemEntity entityForUri(Uri uri);
}

/// Abstract representation of a file system entity that may or may not exist.
///
/// Instances of this class have suitable implementations of equality tests and
/// hashCode.
///
/// Not intended to be implemented or extended by clients.
abstract class FileSystemEntity {
  /// The absolute normalized URI represented by this file system entity.
  ///
  /// Note: this is not necessarily the same as the URI that was passed to
  /// [FileSystem.entityForUri], since the URI might have been normalized.
  Uri get uri;

  /// Whether this file system entity exists.
  ///
  /// This method cannot be assumed to do any async work, in fact, if possible
  /// it should perform the check sync as that might be faster depending on the
  /// caller. If wanting to check async - for instance if trying to physically
  /// check for existence and read in parallel - use [existsAsyncIfPossible]
  /// instead.
  Future<bool> exists();

  /// Whether this file system entity exists.
  ///
  /// This method cannot be assumed to do any async work, but should - if
  /// possible - in fact do async work as that might be faster depending on the
  /// caller - for instance if trying to physically check for existence (and
  /// read) in parallel.
  /// For sequential checks one should use [exists] instead.
  Future<bool> existsAsyncIfPossible();

  /// Attempts to access this file system entity as a file and read its contents
  /// as raw bytes.
  ///
  /// This method cannot be assumed to do any async work, in fact, if possible
  /// it should the read sync as that might be faster depending on the caller.
  /// If wanting to read async - for instance if trying to physically read in
  /// parallel - use [readAsBytesAsyncIfPossible] instead.
  ///
  /// If an error occurs while attempting to read the file (e.g. because no such
  /// file exists, or the entity is a directory), the future is completed with
  /// [FileSystemException].
  Future<Uint8List> readAsBytes();

  /// Attempts to access this file system entity as a file and read its contents
  /// as raw bytes.
  ///
  /// This method cannot be assumed to do any async work, but should - if
  /// possible - in fact do async work as that might be faster depending on the
  /// caller - for instance if trying to physically read in parallel.
  /// For sequential reads one should use [readAsBytes] instead.
  ///
  /// If an error occurs while attempting to read the file (e.g. because no such
  /// file exists, or the entity is a directory), the future is completed with
  /// [FileSystemException].
  Future<Uint8List> readAsBytesAsyncIfPossible();

  /// Attempts to access this file system entity as a file and read its contents
  /// as a string.
  ///
  /// The file is assumed to be UTF-8 encoded.
  ///
  /// If an error occurs while attempting to read the file (e.g. because no such
  /// file exists, the entity is a directory, or the file is not valid UTF-8),
  /// the future is completed with [FileSystemException].
  Future<String> readAsString();
}

/**
 * Base class for all file system exceptions.
 */
class FileSystemException implements Exception {
  final Uri uri;
  final String message;

  FileSystemException(this.uri, this.message);

  @override
  String toString() => 'FileSystemException(uri=$uri; message=$message)';
}

class NullFileSystem implements FileSystem {
  const NullFileSystem();

  @override
  FileSystemEntity entityForUri(Uri uri) {
    throw new UnsupportedError('$runtimeType.entityForUri');
  }
}
