#!/usr/bin/env dart

import 'dart:io';
import 'package:args/args.dart';
import 'package:string_extractor_intl/string_extractor_intl.dart';


void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('input', abbr: 'i', defaultsTo: 'lib', help: 'Input directory to scan')
    ..addOption('output', abbr: 'o', defaultsTo: 'lib/l10n', help: 'Output directory for localization files')
    ..addOption('template-arb', defaultsTo: 'app_en.arb', help: 'Template ARB file name')
    ..addOption('class-name', abbr: 'c', defaultsTo: 'AppLocalizations', help: 'Name of the localization class')
    ..addFlag('help', abbr: 'h', help: 'Show usage information', negatable: false)
    ..addFlag('replace', abbr: 'r', help: 'Replace hardcoded strings with localization calls', negatable: false)
    ..addFlag('check-deps', defaultsTo: true, help: 'Check for required dependencies', negatable: false);

  try {
    final results = parser.parse(arguments);

    if (results['help']) {
      print('Flutter String Extractor for Localization\n');
      print('Usage: extract_strings [options]\n');
      print(parser.usage);
      return;
    }

    final inputDir = results['input'] as String;
    final outputDir = results['output'] as String;
    final templateArb = results['template-arb'] as String;
    final className = results['class-name'] as String;
    final shouldReplace = results['replace'] as bool;
    final checkDeps = results['check-deps'] as bool;

    print('🌍 Flutter Localization String Extractor');
    print('Scanning directory: $inputDir');
    print('Output directory: $outputDir');
    print('Template ARB file: $templateArb');
    print('Localization class: $className');

    final extractor = LocalizationStringExtractor();
    await extractor.extractStrings(
      inputDirectory: inputDir,
      outputDirectory: outputDir,
      templateArbFile: templateArb,
      className: className,
      replaceInFiles: shouldReplace,
      checkDependencies: checkDeps,
    );

    print('✅ Localization extraction completed!');
    print('');
    print('📋 Next steps:');
    print('1. Add other language ARB files (e.g., app_es.arb, app_fr.arb)');
    print('2. Run: flutter gen-l10n');
    print('3. Import AppLocalizations in your app and wrap with MaterialApp');
  } catch (e) {
    print('❌ Error: $e');
    exit(1);
  }
}