// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Defines the VM-specific translation of Dart source code to kernel binaries.
library;

import 'dart:async';
import 'dart:convert' as convert show json;
import 'dart:io' show File, IOSink;
import 'dart:typed_data';

import 'package:args/args.dart' show ArgParser, ArgResults;
import 'package:build_integration/file_system/multi_root.dart'
    show MultiRootFileSystem, MultiRootFileSystemEntity;
import 'package:crypto/crypto.dart';
import 'package:front_end/src/api_unstable/vm.dart'
    show
        CompilerContext,
        CompilerOptions,
        CompilerResult,
        InvocationMode,
        DiagnosticMessage,
        DiagnosticMessageHandler,
        FileSystem,
        FileSystemEntity,
        ProcessedOptions,
        Severity,
        StandardFileSystem,
        Verbosity,
        getMessageUri,
        kernelForModule,
        kernelForProgram,
        parseExperimentalArguments,
        parseExperimentalFlags,
        printDiagnosticMessage,
        resolveInputUri;
import 'package:kernel/ast.dart' show Component, Library;
import 'package:kernel/binary/ast_to_binary.dart' show BinaryPrinter;
import 'package:kernel/class_hierarchy.dart' show ClassHierarchy;
import 'package:kernel/core_types.dart' show CoreTypes;
import 'package:kernel/kernel.dart' show loadComponentFromBinary;
import 'package:kernel/target/targets.dart' show Target, TargetFlags, getTarget;
import 'package:package_config/package_config.dart' show loadPackageConfigUri;

import 'http_filesystem.dart' show HttpAwareFileSystem;
import 'modular/target/install.dart' show installAdditionalTargets;
import 'modular/transformations/call_site_annotator.dart'
    as call_site_annotator;
import 'native_assets/synthesizer.dart';
import 'target_os.dart';
import 'transformations/deferred_loading.dart' as deferred_loading;
import 'transformations/devirtualization.dart'
    as devirtualization
    show transformComponent;
import 'transformations/dynamic_interface_annotator.dart'
    as dynamic_interface_annotator
    show annotateComponent;
import 'transformations/mixin_deduplication.dart'
    as mixin_deduplication
    show transformComponent;
import 'transformations/no_dynamic_invocations_annotator.dart'
    as no_dynamic_invocations_annotator
    show transformComponent;
import 'transformations/obfuscation_prohibitions_annotator.dart'
    as obfuscationProhibitions;
import 'transformations/record_use/record_use.dart' as record_use;
import 'transformations/to_string_transformer.dart' as to_string_transformer;
import 'transformations/type_flow/transformer.dart'
    as globalTypeFlow
    show transformComponent;
import 'transformations/unreachable_code_elimination.dart'
    as unreachable_code_elimination;
import 'transformations/vm_constant_evaluator.dart' as vm_constant_evaluator;

/// Declare options consumed by [runCompiler].
void declareCompilerOptions(ArgParser args) {
  args.addOption(
    'platform',
    help: 'Path to vm_platform.dill file',
    defaultsTo: null,
  );
  args.addOption(
    'packages',
    help: 'Path to .dart_tool/package_config.json file',
    defaultsTo: null,
  );
  args.addOption(
    'output',
    abbr: 'o',
    help: 'Path to resulting dill file',
    defaultsTo: null,
  );
  args.addFlag(
    'aot',
    help:
        'Produce kernel file for AOT compilation (enables global transformations).',
    defaultsTo: false,
  );
  args.addFlag(
    'support-mirrors',
    help:
        'Whether dart:mirrors is supported. By default dart:mirrors is '
        'supported when --aot and --minimal-kernel are not used.',
    defaultsTo: null,
  );
  args.addFlag('compact-async', help: 'Obsolete, ignored.', hide: true);
  args.addOption('depfile', help: 'Path to output Ninja depfile');
  args.addOption(
    'depfile-target',
    help: 'Override the target in the generated depfile',
    hide: true,
  );
  args.addOption(
    'from-dill',
    help: 'Read existing dill file instead of compiling from sources',
    defaultsTo: null,
  );
  args.addFlag(
    'link-platform',
    help: 'Include platform into resulting kernel file.',
    defaultsTo: true,
  );
  args.addFlag(
    'minimal-kernel',
    help: 'Produce minimal tree-shaken kernel file.',
    defaultsTo: false,
  );
  args.addFlag(
    'embed-sources',
    help: 'Embed source files in the generated kernel component',
    defaultsTo: true,
  );
  args.addMultiOption(
    'filesystem-root',
    help:
        'A base path for the multi-root virtual file system.'
        ' If multi-root file system is used, the input script and .dart_tool/package_config.json file should be specified using URI.',
  );
  args.addOption(
    'filesystem-scheme',
    help: 'The URI scheme for the multi-root virtual filesystem.',
  );
  args.addMultiOption(
    'source',
    help: 'List additional source files to include into compilation.',
    defaultsTo: const <String>[],
  );
  args.addOption(
    'native-assets',
    help: 'Provide the native-assets mapping for @Native external functions.',
  );
  args.addOption(
    'recorded-usages-file',
    help: 'The path to store the recorded usages.',
  );
  args.addOption(
    'target',
    help: 'Target model that determines what core libraries are available',
    allowed: <String>['vm', 'flutter', 'flutter_runner', 'dart_runner'],
    defaultsTo: 'vm',
  );
  args.addFlag(
    'tfa',
    help:
        'Enable global type flow analysis and related transformations in AOT mode.',
    defaultsTo: true,
  );
  args.addOption(
    'target-os',
    help: 'Compile for a specific target operating system when in AOT mode.',
    allowed: TargetOS.names,
  );
  args.addFlag(
    'rta',
    help: 'Use rapid type analysis for faster compilation in AOT mode.',
    defaultsTo: true,
  );
  args.addFlag(
    'tree-shake-write-only-fields',
    help: 'Enable tree shaking of fields which are only written in AOT mode.',
    defaultsTo: true,
  );
  args.addFlag(
    'protobuf-tree-shaker-v2',
    help: 'Enable protobuf tree shaker v2 in AOT mode.',
    defaultsTo: false,
  );
  args.addMultiOption(
    'define',
    abbr: 'D',
    help: 'The values for the environment constants (e.g. -Dkey=value).',
  );
  args.addFlag(
    'enable-asserts',
    help: 'Whether asserts will be enabled.',
    defaultsTo: false,
  );
  args.addFlag(
    'sound-null-safety',
    help: 'Respect the nullability of types at runtime.',
    defaultsTo: true,
    hide: true,
  );
  args.addFlag(
    'split-output-by-packages',
    help: 'Split resulting kernel file into multiple files (one per package).',
    defaultsTo: false,
  );
  args.addOption(
    'component-name',
    help: 'Name of the Fuchsia component',
    defaultsTo: null,
  );
  args.addOption(
    'data-dir',
    help: 'Name of the subdirectory of //data for output files',
  );
  args.addOption(
    'dynamic-interface',
    help: 'Path to dynamic module interface yaml file.',
  );
  args.addOption(
    'dump-detailed-dynamic-interface',
    help: 'Path to output detailed dynamic interface.',
  );
  args.addOption('manifest', help: 'Path to output Fuchsia package manifest');
  args.addMultiOption(
    'enable-experiment',
    help: 'Comma separated list of experimental features to enable.',
  );
  args.addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this help message.',
  );
  args.addFlag(
    'track-widget-creation',
    help: 'Run a kernel transformer to track creation locations for widgets.',
    defaultsTo: false,
  );
  args.addMultiOption(
    'delete-tostring-package-uri',
    help:
        'Replaces implementations of `toString` with `super.toString()` for '
        'specified package',
    valueHelp: 'dart:ui',
    defaultsTo: const <String>[],
  );
  args.addMultiOption(
    'keep-class-names-implementing',
    help:
        'Prevents obfuscation of the class names of any class implementing '
        'the given class.',
    defaultsTo: const <String>[],
  );
  args.addOption(
    'invocation-modes',
    help: 'Provides information to the front end about how it is invoked.',
    defaultsTo: '',
  );
  args.addOption(
    'verbosity',
    help:
        'Sets the verbosity level used for filtering messages during '
        'compilation.',
    defaultsTo: Verbosity.defaultValue,
  );
}

/// Create ArgParser and populate it with options consumed by [runCompiler].
ArgParser createCompilerArgParser() {
  final ArgParser argParser = new ArgParser(allowTrailingOptions: true);
  declareCompilerOptions(argParser);
  return argParser;
}

const int successExitCode = 0;
const int badUsageExitCode = 1;
const int compileTimeErrorExitCode = 254;

/// Run kernel compiler tool with given [options] and [usage]
/// and return exit code.
Future<int> runCompiler(ArgResults options, String usage) async {
  final String? platformKernel = options['platform'];

  if (options['help']) {
    print(usage);
    return successExitCode;
  }

  final String? nativeAssetsPath = options['native-assets'];
  final String? recordedUsagesFile = options['recorded-usages-file'];
  final bool splitOutputByPackages = options['split-output-by-packages'];
  final String? input = options.rest.singleOrNull;
  if ((input == null && (nativeAssetsPath == null || splitOutputByPackages)) ||
      (platformKernel == null)) {
    print(usage);
    return badUsageExitCode;
  }

  final String outputFileName = options['output'] ?? "$input.dill";
  final String? packages = options['packages'];
  final String targetName = options['target'];
  final String? fileSystemScheme = options['filesystem-scheme'];
  final String? depfile = options['depfile'];
  final String? depfileTarget = options['depfile-target'];
  final String? fromDillFile = options['from-dill'];
  final List<String>? fileSystemRoots = options['filesystem-root'];
  final String? targetOS = options['target-os'];
  final bool aot = options['aot'];
  final bool tfa = options['tfa'];
  final bool rta = options['rta'];
  final bool linkPlatform = options['link-platform'];
  final bool embedSources = options['embed-sources'];
  final bool enableAsserts = options['enable-asserts'];
  final bool useProtobufTreeShakerV2 = options['protobuf-tree-shaker-v2'];
  final String? manifestFilename = options['manifest'];
  final String? dataDir = options['component-name'] ?? options['data-dir'];
  final bool? supportMirrors = options['support-mirrors'];

  final bool minimalKernel = options['minimal-kernel'];
  final bool treeShakeWriteOnlyFields = options['tree-shake-write-only-fields'];
  final List<String>? experimentalFlags = options['enable-experiment'];
  final Map<String, String> environmentDefines = {};
  final List<String> sources = options['source'];

  if (!parseCommandLineDefines(options['define'], environmentDefines, usage)) {
    return badUsageExitCode;
  }

  final bool soundNullSafety = options['sound-null-safety'];
  if (!soundNullSafety) {
    print('Error: --no-sound-null-safety is not supported.');
    return badUsageExitCode;
  }

  if (aot) {
    if (!linkPlatform) {
      print('Error: --no-link-platform option cannot be used with --aot');
      return badUsageExitCode;
    }
    if (splitOutputByPackages) {
      print(
        'Error: --split-output-by-packages option cannot be used with --aot',
      );
      return badUsageExitCode;
    }
  }

  if (supportMirrors == true) {
    if (aot) {
      print('Error: --support-mirrors option cannot be used with --aot');
      return badUsageExitCode;
    }
    if (minimalKernel) {
      print(
        'Error: --support-mirrors option cannot be used with '
        '--minimal-kernel',
      );
      return badUsageExitCode;
    }
  }

  final fileSystem = createFrontEndFileSystem(
    fileSystemScheme,
    fileSystemRoots,
  );

  final Uri? packagesUri = packages != null ? resolveInputUri(packages) : null;

  final platformKernelUri = Uri.base.resolveUri(new Uri.file(platformKernel));
  final List<Uri> additionalDills = <Uri>[];
  if (aot || linkPlatform) {
    additionalDills.add(platformKernelUri);
  }

  final verbosity = Verbosity.parseArgument(options['verbosity']);
  final errorPrinter = new ErrorPrinter(verbosity);
  final errorDetector = new ErrorDetector(
    previousErrorHandler: errorPrinter.call,
  );

  final Uri? nativeAssetsUri =
      nativeAssetsPath == null ? null : resolveInputUri(nativeAssetsPath);

  final Uri? recordedUsagesUri =
      recordedUsagesFile == null ? null : resolveInputUri(recordedUsagesFile);

  final String? dynamicInterfaceFilePath = options['dynamic-interface'];
  final Uri? dynamicInterfaceUri =
      dynamicInterfaceFilePath == null
          ? null
          : resolveInputUri(dynamicInterfaceFilePath);
  final String? dumpDetailedDynamicInterface =
      options['dump-detailed-dynamic-interface'];

  Uri? mainUri;
  if (input != null) {
    mainUri = resolveInputUri(input);
    if (packagesUri != null) {
      mainUri = await convertToPackageUri(fileSystem, mainUri, packagesUri);
    }
  }

  final List<Uri> additionalSources = sources.map(resolveInputUri).toList();

  final CompilerOptions compilerOptions =
      new CompilerOptions()
        ..sdkSummary = platformKernelUri
        ..fileSystem = fileSystem
        ..additionalDills = additionalDills
        ..packagesFileUri = packagesUri
        ..explicitExperimentalFlags = parseExperimentalFlags(
          parseExperimentalArguments(experimentalFlags),
          onError: print,
        )
        ..onDiagnostic = (DiagnosticMessage m) {
          errorDetector(m);
        }
        ..embedSourceText = embedSources
        ..invocationModes = InvocationMode.parseArguments(
          options['invocation-modes'],
        )
        ..verbosity = verbosity;

  compilerOptions.target = createFrontEndTarget(
    targetName,
    trackWidgetCreation: options['track-widget-creation'],
    supportMirrors: supportMirrors ?? !(aot || minimalKernel),
  );
  if (compilerOptions.target == null) {
    print('Failed to create front-end target $targetName.');
    return badUsageExitCode;
  }

  final results = await compileToKernel(
    KernelCompilationArguments(
      source: mainUri,
      options: compilerOptions,
      additionalSources: additionalSources,
      nativeAssets: nativeAssetsUri,
      recordedUsages: recordedUsagesUri,
      includePlatform: additionalDills.isNotEmpty,
      deleteToStringPackageUris: options['delete-tostring-package-uri'],
      keepClassNamesImplementing: options['keep-class-names-implementing'],
      dynamicInterface: dynamicInterfaceUri,
      dumpDetailedDynamicInterface: dumpDetailedDynamicInterface,
      aot: aot,
      useGlobalTypeFlowAnalysis: tfa,
      useRapidTypeAnalysis: rta,
      environmentDefines: environmentDefines,
      enableAsserts: enableAsserts,
      useProtobufTreeShakerV2: useProtobufTreeShakerV2,
      minimalKernel: minimalKernel,
      treeShakeWriteOnlyFields: treeShakeWriteOnlyFields,
      targetOS: targetOS,
      fromDillFile: fromDillFile,
    ),
  );

  errorPrinter.printCompilationMessages();

  final Component? component = results.component;
  final Library? nativeAssetsLibrary = results.nativeAssetsLibrary;
  if (errorDetector.hasCompilationErrors ||
      (component == null && nativeAssetsLibrary == null)) {
    return compileTimeErrorExitCode;
  }

  final IOSink sink = new File(outputFileName).openWrite();
  if (component != null) {
    final BinaryPrinter printer = new BinaryPrinter(
      sink,
      libraryFilter: (lib) => !results.loadedLibraries.contains(lib),
    );
    if (aot && nativeAssetsLibrary != null) {
      // If Dart component in AOT, write the vm:native-assets library _inside_
      // the Dart component.
      // TODO(https://dartbug.com/50152): Support AOT dill concatenation.
      component.libraries.add(nativeAssetsLibrary);
      nativeAssetsLibrary.parent = component;
    }
    printer.writeComponentFile(component);
  }
  if ((nativeAssetsLibrary != null && (!aot || component == null))) {
    // If no Dart component, write as separate dill.
    // If Dart component in JIT, write as concatenated dill, to not mess with
    // the incremental compiler.
    final BinaryPrinter printer = new BinaryPrinter(sink);
    printer.writeComponentFile(Component(libraries: [nativeAssetsLibrary]));
  }
  await sink.close();

  if (depfile != null) {
    final usedPackageConfig = results.usedPackageConfig;
    await writeDepfile(
      fileSystem,
      [
        if (usedPackageConfig != null) usedPackageConfig,
        ...results.compiledSources!,
      ],
      depfileTarget ?? outputFileName,
      depfile,
    );
  }

  if (splitOutputByPackages) {
    await writeOutputSplitByPackages(
      mainUri!,
      compilerOptions,
      results,
      outputFileName,
    );
  }

  if (manifestFilename != null) {
    await createFarManifest(outputFileName, dataDir, manifestFilename);
  }

  return successExitCode;
}

/// Results of [compileToKernel]: generated kernel [Component] and
/// collection of compiled sources.
class KernelCompilationResults {
  final Component? component;

  final Library? nativeAssetsLibrary;

  /// Set of libraries loaded from .dill, with or without the SDK depending on
  /// the compilation settings.
  final Set<Library> loadedLibraries;
  final ClassHierarchy? classHierarchy;
  final CoreTypes? coreTypes;
  final Iterable<Uri>? compiledSources;
  final Uri? usedPackageConfig;

  KernelCompilationResults(
    this.component,
    this.loadedLibraries,
    this.classHierarchy,
    this.coreTypes,
    this.compiledSources,
  ) : nativeAssetsLibrary = null,
      usedPackageConfig = null;

  KernelCompilationResults.named({
    this.component,
    this.loadedLibraries = const {},
    this.classHierarchy,
    this.coreTypes,
    this.compiledSources,
    this.nativeAssetsLibrary,
    this.usedPackageConfig,
  });
}

// Arguments for [compileToKernel].
class KernelCompilationArguments {
  final Uri? source;
  final CompilerOptions? options;
  final List<Uri> additionalSources;
  final Uri? nativeAssets;
  final Uri? recordedUsages;
  final bool requireMain;
  final bool includePlatform;
  final List<String> deleteToStringPackageUris;
  final List<String> keepClassNamesImplementing;
  final bool aot;
  final Uri? dynamicInterface;
  final String? dumpDetailedDynamicInterface;
  final Map<String, String> environmentDefines; // Should be mutable.
  final bool enableAsserts;
  final bool useGlobalTypeFlowAnalysis;
  final bool useRapidTypeAnalysis;
  final bool treeShakeWriteOnlyFields;
  final bool useProtobufTreeShakerV2;
  final bool minimalKernel;
  final String? targetOS;
  final String? fromDillFile;

  KernelCompilationArguments({
    this.source,
    this.options,
    this.additionalSources = const <Uri>[],
    this.nativeAssets,
    this.recordedUsages,
    this.requireMain = true,
    this.includePlatform = false,
    this.deleteToStringPackageUris = const <String>[],
    this.keepClassNamesImplementing = const <String>[],
    this.aot = false,
    this.dynamicInterface,
    this.dumpDetailedDynamicInterface,
    Map<String, String>? environmentDefines,
    this.enableAsserts = true,
    this.useGlobalTypeFlowAnalysis = false,
    this.useRapidTypeAnalysis = true,
    this.treeShakeWriteOnlyFields = false,
    this.useProtobufTreeShakerV2 = false,
    this.minimalKernel = false,
    this.targetOS,
    this.fromDillFile,
  }) : environmentDefines = environmentDefines ?? {};
}

/// Generates a kernel representation of the program whose main library is in
/// the given [args.source]. Intended for whole program (non-modular) compilation.
///
/// VM-specific replacement of [kernelForProgram].
///
/// Either [arg.source], or [args.nativeAssets], or both must be non-null.
Future<KernelCompilationResults> compileToKernel(
  KernelCompilationArguments args,
) async {
  final options = args.options!;

  // Replace error handler to detect if there are compilation errors.
  final errorDetector = new ErrorDetector(
    previousErrorHandler: options.onDiagnostic,
  );
  options.onDiagnostic = errorDetector.call;

  final nativeAssetsLibrary =
      await NativeAssetsSynthesizer.synthesizeLibraryFromYamlFile(
        args.nativeAssets,
        errorDetector,
      );
  if (args.source == null) {
    return KernelCompilationResults.named(
      nativeAssetsLibrary: nativeAssetsLibrary,
    );
  }

  final target = options.target!;
  options.environmentDefines = target.updateEnvironmentDefines(
    args.environmentDefines,
  );

  CompilerResult? compilerResult;
  final fromDillFile = args.fromDillFile;
  Uri? usedPackageConfig;
  if (fromDillFile != null) {
    compilerResult = await loadKernel(
      options.fileSystem,
      resolveInputUri(fromDillFile),
    );
  } else {
    final processedOptions = new ProcessedOptions(
      options: options,
      inputs: [args.source!, ...args.additionalSources],
    );
    compilerResult = await CompilerContext.runWithOptions(processedOptions, (
      CompilerContext context,
    ) async {
      return args.requireMain
          ? await kernelForProgram(
            args.source!,
            options,
            additionalSources: args.additionalSources,
          )
          : await kernelForModule([
            args.source!,
            ...args.additionalSources,
          ], options);
    });
    usedPackageConfig = await processedOptions.resolvePackagesFileUri();
  }
  final Component? component = compilerResult?.component;

  Iterable<Uri>? compiledSources = component?.uriToSource.keys;

  Set<Library> loadedLibraries = createLoadedLibrariesSet(
    compilerResult?.loadedComponents,
    compilerResult?.sdkComponent,
    includePlatform: args.includePlatform,
  );

  if (args.deleteToStringPackageUris.isNotEmpty && component != null) {
    to_string_transformer.transformComponent(
      component,
      args.deleteToStringPackageUris,
    );
  }

  // Run global transformations only if component is correct.
  if ((args.aot || args.minimalKernel) && component != null) {
    await runGlobalTransformations(target, component, errorDetector, args);

    if (args.minimalKernel) {
      // compiledSources is component.uriToSource.keys.
      // Make a copy of compiledSources to detach it from
      // component.uriToSource which is cleared below.
      compiledSources = compiledSources!.toList();

      component.metadata.clear();
      component.uriToSource.clear();
    }
  }

  // Restore error handler (in case 'options' are reused).
  options.onDiagnostic = errorDetector.previousErrorHandler;

  return KernelCompilationResults.named(
    component: component,
    nativeAssetsLibrary: nativeAssetsLibrary,
    loadedLibraries: loadedLibraries,
    classHierarchy: compilerResult?.classHierarchy,
    coreTypes: compilerResult?.coreTypes,
    compiledSources: compiledSources,
    usedPackageConfig: usedPackageConfig,
  );
}

Set<Library> createLoadedLibrariesSet(
  List<Component>? loadedComponents,
  Component? sdkComponent, {
  bool includePlatform = false,
}) {
  final Set<Library> loadedLibraries = {};
  if (loadedComponents != null) {
    for (Component c in loadedComponents) {
      for (Library lib in c.libraries) {
        loadedLibraries.add(lib);
      }
    }
  }
  if (sdkComponent != null) {
    if (includePlatform) {
      for (Library lib in sdkComponent.libraries) {
        loadedLibraries.remove(lib);
      }
    } else {
      for (Library lib in sdkComponent.libraries) {
        loadedLibraries.add(lib);
      }
    }
  }
  return loadedLibraries;
}

Future runGlobalTransformations(
  Target target,
  Component component,
  ErrorDetector errorDetector,
  KernelCompilationArguments args,
) async {
  assert(!target.flags.supportMirrors);
  if (errorDetector.hasCompilationErrors) return;

  final coreTypes = new CoreTypes(component);

  final dynamicInterface = args.dynamicInterface;
  if (dynamicInterface != null) {
    final fileUri = await asFileUri(args.options!.fileSystem, dynamicInterface);
    final dumpDetailedDynamicInterface = args.dumpDetailedDynamicInterface;
    Map<String, List<Map<String, String>>>? detailedDynamicInterfaceJson =
        (dumpDetailedDynamicInterface != null) ? {} : null;
    dynamic_interface_annotator.annotateComponent(
      File(fileUri.toFilePath()).readAsStringSync(),
      dynamicInterface,
      component,
      coreTypes,
      detailedDynamicInterfaceJson: detailedDynamicInterfaceJson,
    );
    if (dumpDetailedDynamicInterface != null) {
      File(
        dumpDetailedDynamicInterface,
      ).writeAsStringSync(convert.json.encode(detailedDynamicInterfaceJson));
    }
  }

  // TODO(alexmarkov,cstefantsova): Consider doing canonicalization of
  // identical mixin applications when creating mixin applications in frontend,
  // so all backends (and all transformation passes from the very beginning)
  // can benefit from mixin de-duplication.
  // At least, in addition to VM/AOT case we should run this transformation
  // when building a platform dill file for VM/JIT case.
  mixin_deduplication.transformComponent(component);

  // Perform unreachable code elimination, which should be performed before
  // type flow analysis so TFA won't take unreachable code into account.
  final targetOS = args.targetOS;
  final os = targetOS != null ? TargetOS.fromString(targetOS)! : null;
  final evaluator = vm_constant_evaluator.VMConstantEvaluator.create(
    target,
    component,
    os,
    enableAsserts: args.enableAsserts,
    environmentDefines: args.environmentDefines,
    coreTypes: coreTypes,
  );
  unreachable_code_elimination.transformComponent(
    target,
    component,
    evaluator,
    args.enableAsserts,
  );

  if (args.useGlobalTypeFlowAnalysis) {
    globalTypeFlow.transformComponent(
      target,
      coreTypes,
      component,
      treeShakeSignatures: !args.minimalKernel,
      treeShakeWriteOnlyFields: args.treeShakeWriteOnlyFields,
      treeShakeProtobufs: args.useProtobufTreeShakerV2,
      useRapidTypeAnalysis: args.useRapidTypeAnalysis,
    );
  } else {
    devirtualization.transformComponent(coreTypes, component);
    no_dynamic_invocations_annotator.transformComponent(component);
  }

  // TODO(35069): avoid recomputing CSA by reading it from the platform files.
  void ignoreAmbiguousSupertypes(cls, a, b) {}
  final hierarchy = new ClassHierarchy(
    component,
    coreTypes,
    onAmbiguousSupertypes: ignoreAmbiguousSupertypes,
  );
  call_site_annotator.transformLibraries(
    component,
    component.libraries,
    coreTypes,
    hierarchy,
  );

  // We don't know yet whether gen_snapshot will want to do obfuscation, but if
  // it does it will need the obfuscation prohibitions.
  obfuscationProhibitions.transformComponent(
    component,
    coreTypes,
    target,
    hierarchy,
    args.keepClassNamesImplementing,
  );

  deferred_loading.transformComponent(component, coreTypes, target);

  final recordedUsagesFile = args.recordedUsages;
  if (recordedUsagesFile != null) {
    assert(args.source != null);
    record_use.transformComponent(component, recordedUsagesFile, args.source!);
  }
}

/// Runs given [action] with [CompilerContext]. This is needed to
/// be able to report compile-time errors.
Future<T> runWithFrontEndCompilerContext<T>(
  Uri source,
  CompilerOptions compilerOptions,
  Component component,
  Future<T> action(),
) async {
  final processedOptions = new ProcessedOptions(
    options: compilerOptions,
    inputs: [source],
  );

  // Run within the context, so we have uri source tokens...
  return await CompilerContext.runWithOptions(processedOptions, (
    CompilerContext context,
  ) async {
    // To make the fileUri/fileOffset -> line/column mapping, we need to
    // pre-fill the map.
    context.uriToSource.addAll(component.uriToSource);

    return action();
  });
}

class ErrorDetector {
  final DiagnosticMessageHandler? previousErrorHandler;
  bool hasCompilationErrors = false;

  ErrorDetector({this.previousErrorHandler});

  void call(DiagnosticMessage message) {
    if (message.severity == Severity.error) {
      hasCompilationErrors = true;
    }

    previousErrorHandler?.call(message);
  }
}

class ErrorPrinter {
  final Verbosity verbosity;
  final DiagnosticMessageHandler? previousErrorHandler;
  final Map<Uri?, List<DiagnosticMessage>> compilationMessages =
      <Uri?, List<DiagnosticMessage>>{};
  final void Function(String) println;

  ErrorPrinter(
    this.verbosity, {
    this.previousErrorHandler,
    this.println = print,
  });

  void call(DiagnosticMessage message) {
    final sourceUri = getMessageUri(message);
    (compilationMessages[sourceUri] ??= <DiagnosticMessage>[]).add(message);
    previousErrorHandler?.call(message);
  }

  void printCompilationMessages() {
    final sortedUris =
        compilationMessages.keys.toList()..sort((a, b) {
          // Sort messages without a corresponding uri before the location based
          // messages, since these related to the whole compilation.
          if (a != null && b != null) {
            return '$a'.compareTo('$b');
          } else if (a != null) {
            return 1;
          } else if (b != null) {
            return -1;
          }
          return 0;
        });
    for (final Uri? sourceUri in sortedUris) {
      for (final DiagnosticMessage message in compilationMessages[sourceUri]!) {
        if (Verbosity.shouldPrint(verbosity, message)) {
          printDiagnosticMessage(message, println);
        }
      }
    }
  }
}

bool parseCommandLineDefines(
  List<String> dFlags,
  Map<String, String> environmentDefines,
  String usage,
) {
  for (final String dflag in dFlags) {
    final equalsSignIndex = dflag.indexOf('=');
    if (equalsSignIndex < 0) {
      // Ignored.
    } else if (equalsSignIndex > 0) {
      final key = dflag.substring(0, equalsSignIndex);
      final value = dflag.substring(equalsSignIndex + 1);
      environmentDefines[key] = value;
    } else {
      print('The environment constant options must have a key (was: "$dflag")');
      print(usage);
      return false;
    }
  }
  return true;
}

/// Create front-end target with given name.
Target? createFrontEndTarget(
  String targetName, {
  bool trackWidgetCreation = false,
  bool supportMirrors = true,
}) {
  // Make sure VM-specific targets are available.
  installAdditionalTargets();

  final TargetFlags targetFlags = new TargetFlags(
    trackWidgetCreation: trackWidgetCreation,
    supportMirrors: supportMirrors,
  );
  return getTarget(targetName, targetFlags);
}

/// Create a front-end file system.
///
/// If requested, create a virtual multi-root file system and/or an http aware
/// file system.
FileSystem createFrontEndFileSystem(
  String? multiRootFileSystemScheme,
  List<String>? multiRootFileSystemRoots, {
  bool allowHttp = false,
}) {
  FileSystem fileSystem = StandardFileSystem.instance;
  if (allowHttp) {
    fileSystem = HttpAwareFileSystem(fileSystem);
  }
  if (multiRootFileSystemRoots != null &&
      multiRootFileSystemRoots.isNotEmpty &&
      multiRootFileSystemScheme != null) {
    final rootUris = <Uri>[];
    for (String root in multiRootFileSystemRoots) {
      rootUris.add(resolveInputUri(root));
    }
    fileSystem = new MultiRootFileSystem(
      multiRootFileSystemScheme,
      rootUris,
      fileSystem,
    );
  }
  return fileSystem;
}

/// Convert a URI which may use virtual file system schema to a real file URI.
Future<Uri> asFileUri(FileSystem fileSystem, Uri uri) async {
  FileSystemEntity fse = fileSystem.entityForUri(uri);
  if (fse is MultiRootFileSystemEntity) {
    fse = await fse.delegate;
  }
  return fse.uri;
}

/// Convert URI to a package URI if it is inside one of the packages.
/// TODO(alexmarkov) Remove this conversion after Fuchsia build rules are fixed.
Future<Uri> convertToPackageUri(
  FileSystem fileSystem,
  Uri uri,
  Uri packagesUri,
) async {
  if (uri.scheme == 'package') {
    return uri;
  }
  // Convert virtual URI to a real file URI.
  final Uri fileUri = await asFileUri(fileSystem, uri);
  try {
    final packageConfig = await loadPackageConfigUri(
      await asFileUri(fileSystem, packagesUri),
    );
    return packageConfig.toPackageUri(fileUri) ?? uri;
  } catch (_) {
    // Can't read packages file - silently give up.
    return uri;
  }
}

/// Write a separate kernel binary for each package. The name of the
/// output kernel binary is '[outputFileName]-$package.dilp'.
/// The list of package names is written into a file '[outputFileName]-packages'.
Future writeOutputSplitByPackages(
  Uri source,
  CompilerOptions compilerOptions,
  KernelCompilationResults compilationResults,
  String outputFileName,
) async {
  final packages = <String>[];
  final Component component = compilationResults.component!;
  await runWithFrontEndCompilerContext(
    source,
    compilerOptions,
    component,
    () async {
      // When loading a kernel file list, flutter_runner and dart_runner expect
      // 'main' to be last.
      await forEachPackage(compilationResults, (
        String package,
        List<Library> libraries,
      ) async {
        packages.add(package);
        final String filename = '$outputFileName-$package.dilp';
        final IOSink sink = new File(filename).openWrite();

        final BinaryPrinter printer = new BinaryPrinter(
          sink,
          libraryFilter:
              (lib) =>
                  packageFor(lib, compilationResults.loadedLibraries) ==
                  package,
        );
        printer.writeComponentFile(component);

        await sink.close();
      }, mainFirst: false);
    },
  );

  final IOSink packagesList = new File('$outputFileName-packages').openWrite();
  for (String package in packages) {
    packagesList.writeln(package);
  }
  await packagesList.close();
}

String? packageFor(Library lib, Set<Library> loadedLibraries) {
  // Core libraries are not written into any package kernel binaries.
  if (loadedLibraries.contains(lib)) return null;

  // Packages are written into their own kernel binaries.
  Uri uri = lib.importUri;
  if (uri.scheme == 'package') return uri.pathSegments.first;

  // Everything else (e.g., file: or data: imports) is lumped into the main
  // kernel binary.
  return 'main';
}

/// Sort the libraries etc in the component. Helps packages to produce identical
/// output when their parts are imported in different orders in different
/// contexts.
void sortComponent(Component component) {
  component.libraries.sort((Library a, Library b) {
    return a.importUri.toString().compareTo(b.importUri.toString());
  });
  component.computeCanonicalNames();
  for (Library lib in component.libraries) {
    lib.additionalExports.sort();
  }
}

Future<void> forEachPackage(
  KernelCompilationResults results,
  Future<void> action(String package, List<Library> libraries), {
  required bool mainFirst,
}) async {
  final Component component = results.component!;
  final Set<Library> loadedLibraries = results.loadedLibraries;
  sortComponent(component);

  final Map<String, List<Library>> packages = <String, List<Library>>{};
  packages['main'] = <Library>[]; // Always create 'main'.
  for (Library lib in component.libraries) {
    final String? package = packageFor(lib, loadedLibraries);
    // Ignore external libraries.
    if (package == null) {
      continue;
    }
    packages.putIfAbsent(package, () => <Library>[]).add(lib);
  }

  final mainLibraries = packages.remove('main')!;
  if (mainFirst) {
    await action('main', mainLibraries);
  }

  final mainMethod = component.mainMethod;
  final problemsAsJson = component.problemsAsJson;
  component.setMainMethodAndMode(null, true);
  component.problemsAsJson = null;
  for (String package in packages.keys) {
    await action(package, packages[package]!);
  }
  component.setMainMethodAndMode(mainMethod?.reference, true);
  component.problemsAsJson = problemsAsJson;

  if (!mainFirst) {
    await action('main', mainLibraries);
  }
}

String _escapePath(String path) {
  return path.replaceAll('\\', '\\\\').replaceAll(' ', '\\ ');
}

/// Create ninja dependencies file, as described in
/// https://ninja-build.org/manual.html#_depfile
Future<void> writeDepfile(
  FileSystem fileSystem,
  Iterable<Uri> compiledSources,
  String output,
  String depfile,
) async {
  final IOSink file = new File(depfile).openWrite();
  file.write(_escapePath(output));
  file.write(':');

  // TODO(https://dartbug.com/55246): track macro deps when available.
  for (Uri dep in compiledSources) {
    // Skip corelib dependencies.
    if (dep.scheme == 'org-dartlang-sdk') continue;
    Uri uri = await asFileUri(fileSystem, dep);
    file.write(' ');
    file.write(_escapePath(uri.toFilePath()));
  }
  file.write('\n');
  await file.close();
}

Future<void> createFarManifest(
  String output,
  String? dataDir,
  String packageManifestFilename,
) async {
  List<String> packages = await File('$output-packages').readAsLines();

  // Make sure the 'main' package is the last (convention with package loader).
  packages.remove('main');
  packages.add('main');

  final IOSink packageManifest = File(packageManifestFilename).openWrite();

  final String kernelListFilename = '$packageManifestFilename.dilplist';
  final IOSink kernelList = File(kernelListFilename).openWrite();
  for (String package in packages) {
    final String filenameInPackage = '$package.dilp';
    final String filenameInBuild = '$output-$package.dilp';
    packageManifest.write(
      'data/$dataDir/$filenameInPackage=$filenameInBuild\n',
    );
    kernelList.write('$filenameInPackage\n');
  }
  await kernelList.close();

  final String frameworkVersionFilename =
      '$packageManifestFilename.frameworkversion';
  final IOSink frameworkVersion = File(frameworkVersionFilename).openWrite();
  for (String package in [
    'collection',
    'flutter',
    'meta',
    'typed_data',
    'vector_math',
  ]) {
    Digest? digest;
    if (packages.contains(package)) {
      final filenameInBuild = '$output-$package.dilp';
      final bytes = await File(filenameInBuild).readAsBytes();
      digest = sha256.convert(bytes);
    }
    frameworkVersion.write('$package=$digest\n');
  }
  await frameworkVersion.close();

  packageManifest.write('data/$dataDir/app.dilplist=$kernelListFilename\n');
  packageManifest.write(
    'data/$dataDir/app.frameworkversion=$frameworkVersionFilename\n',
  );
  await packageManifest.close();
}

class CompilerResultLoadedFromKernel implements CompilerResult {
  final Component component;
  final Component sdkComponent = Component();

  CompilerResultLoadedFromKernel(this.component);

  @override
  Uint8List? get summary => null;

  @override
  List<Component> get loadedComponents => const <Component>[];

  @override
  CoreTypes? get coreTypes => null;

  @override
  ClassHierarchy? get classHierarchy => null;
}

Future<CompilerResult> loadKernel(
  FileSystem fileSystem,
  Uri dillFileUri,
) async {
  final component = loadComponentFromBinary(
    (await asFileUri(fileSystem, dillFileUri)).toFilePath(),
  );
  return CompilerResultLoadedFromKernel(component);
}

// Used by kernel_front_end_test.dart
main() {}
