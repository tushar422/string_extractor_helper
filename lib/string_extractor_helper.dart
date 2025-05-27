import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'dart:math' as math;
import 'package:yaml/yaml.dart';

class LocalizationStringExtractor {
  final Map<String, Map<String, dynamic>> _extractedStrings = {};
  final Map<String, Set<String>> _fileImports = {};
  final Set<String> _processedFiles = {};
  int _stringCounter = 0;

  Future<void> extractStrings({
    required String inputDirectory,
    required String outputDirectory,
    required String templateArbFile,
    required String className,
    bool replaceInFiles = false,
    bool checkDependencies = true,
  }) async {
    final inputDir = Directory(inputDirectory);

    if (!inputDir.existsSync()) {
      throw Exception('Input directory does not exist: $inputDirectory');
    }

    if (checkDependencies) {
      await _checkDependencies();
    }

    print('🔍 Scanning for Dart files...');
    await _scanDirectory(inputDir, className, replaceInFiles);

    if (_extractedStrings.isEmpty) {
      print('ℹ️  No hardcoded strings found.');
      return;
    }

    print('📝 Found ${_extractedStrings.length} localizable strings');
    await _generateArbFile(outputDirectory, templateArbFile);
    await _generateL10nYaml(outputDirectory, className);

    if (replaceInFiles) {
      print('🔄 Updated ${_processedFiles.length} files with localization calls');
    }
  }

  Future<void> _checkDependencies() async {
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      throw Exception('pubspec.yaml not found. Make sure you\'re in a Flutter project root.');
    }

    final pubspecContent = await pubspecFile.readAsString();
    final pubspec = loadYaml(pubspecContent);

    final dependencies = pubspec['dependencies'] as Map?;

    bool hasIntl = false;
    bool hasFlutterLocalizations = false;

    if (dependencies != null) {
      hasIntl = dependencies.containsKey('intl');
      hasFlutterLocalizations = dependencies.containsKey('flutter_localizations');
    }

    final List<String> missingDeps = [];

    if (!hasIntl) {
      missingDeps.add('intl: ^0.18.1');
    }

    if (!hasFlutterLocalizations) {
      missingDeps.add('flutter_localizations:\n    sdk: flutter');
    }

    if (missingDeps.isNotEmpty) {
      print('⚠️  Missing required dependencies in pubspec.yaml:');
      print('Add these to your dependencies section:');
      for (final dep in missingDeps) {
        print('  $dep');
      }
      print('');
      print('Run: flutter pub get');
      print('');
    }
  }

  Future<void> _scanDirectory(Directory dir, String className, bool replaceInFiles) async {
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        await _processFile(entity, className, replaceInFiles);
      }
    }
  }

  Future<void> _processFile(File file, String className, bool replaceInFiles) async {
    final content = await file.readAsString();
    final strings = _extractStringsFromContent(content);

    if (strings.isEmpty) return;

    String updatedContent = content;
    bool fileModified = false;
    bool needsImport = false;

    for (final stringData in strings) {
      final originalString = stringData['original'] as String;
      final cleanString = stringData['clean'] as String;
      final context = stringData['context'] as String;

      if (_shouldIgnoreString(cleanString)) continue;

      final keyName = _generateKeyName(cleanString);
      final hasVariables = _detectVariables(cleanString);

      String replacement;
      if (hasVariables['hasVars']) {
        final methodCall = _generateMethodCall(className, keyName, hasVariables['variables'], context);
        replacement = methodCall;
        _extractedStrings[keyName] = {
          'value': hasVariables['template'],
          'description': 'Localized string with parameters: ${hasVariables['variables'].join(', ')}',
          'placeholders': _generatePlaceholders(hasVariables['variables']),
        };
      } else {
        replacement = _generateSimpleCall(className, keyName, context);
        _extractedStrings[keyName] = {
          'value': cleanString,
          'description': 'Localized string',
        };
      }

      if (replaceInFiles) {
        // Replace the hardcoded string with localization call
        updatedContent = updatedContent.replaceAll(originalString, replacement);
        fileModified = true;
        needsImport = true;
      }
    }

    if (replaceInFiles && fileModified) {
      if (needsImport) {
        updatedContent = _addImportIfNeeded(updatedContent, className);
      }
      await file.writeAsString(updatedContent);
      _processedFiles.add(file.path);
    }
  }

  bool _isInMaterialAppTitle(String content, int position) {
    // Look backwards from the string position to see if we're in a MaterialApp title
    int start = math.max(0, position - 200);
    String contextStr = content.substring(start, position);

    // Check if we're within a MaterialApp context and specifically in title property
    if (contextStr.contains('MaterialApp(') || contextStr.contains('CupertinoApp(')) {
      // Look for title: pattern before our string
      final titlePattern = RegExp(r'title\s*:\s*$');
      final lines = contextStr.split('\n');
      final lastLine = lines.isNotEmpty ? lines.last : '';

      return titlePattern.hasMatch(lastLine.trim());
    }

    return false;
  }

  List<Map<String, String>> _extractStringsFromContent(String content) {
    final List<Map<String, String>> strings = [];
    final stringPatterns = [
      RegExp(r'"([^"\\]*(\\.[^"\\]*)*)"'), // Double quotes
      RegExp(r"'([^'\\]*(\\.[^'\\]*)*)'"), // Single quotes
    ];

    for (final pattern in stringPatterns) {
      final matches = pattern.allMatches(content);
      for (final match in matches) {
        final fullMatch = match.group(0)!;
        final innerString = match.group(1)!;

        // Skip if it's likely a import/export statement
        if (_isImportExportStatement(content, match.start)) continue;

        // Skip if it's in MaterialApp title (no context available)
        if (_isInMaterialAppTitle(content, match.start)) continue;

        // Get context (Text widget, etc.)
        final context = _getStringContext(content, match.start);

        strings.add({
          'original': fullMatch,
          'clean': innerString,
          'context': context,
        });
      }
    }

    return strings;
  }

  String _getStringContext(String content, int position) {
    // Look backwards to find the widget context
    int start = math.max(0, position - 100);
    String contextStr = content.substring(start, position);

    if (contextStr.contains('Text(')) return 'text';
    if (contextStr.contains('title:')) return 'title';
    if (contextStr.contains('AppBar(')) return 'appbar';
    if (contextStr.contains('SnackBar(')) return 'snackbar';
    if (contextStr.contains('AlertDialog(')) return 'dialog';

    return 'general';
  }

  Map<String, dynamic> _detectVariables(String str) {
    final Set<String> variables = {};
    String template = str;

    // Check for ${} pattern
    final braceMatches = RegExp(r'\$\{([^}]+)\}').allMatches(str);
    for (final match in braceMatches) {
      final varName = match.group(1)!;
      variables.add(varName);
      template = template.replaceAll(match.group(0)!, '{$varName}');
    }

    // Check for $ pattern
    final dollarMatches = RegExp(r'\$([a-zA-Z_][a-zA-Z0-9_]*)').allMatches(str);
    for (final match in dollarMatches) {
      final varName = match.group(1)!;
      variables.add(varName);
      template = template.replaceAll(match.group(0)!, '{$varName}');
    }

    // If no explicit variables found, check if string seems to have placeholder intent
    if (variables.isEmpty && (str.contains('Name') || str.contains('User') || str.contains('Count'))) {
      // This is a heuristic - you might want to make this more sophisticated
      if (str.toLowerCase().contains('welcome') && str.toLowerCase().contains('user')) {
        variables.add('username');
        template = template.replaceAll(RegExp(r'\b[A-Z][a-z]+\b'), '{username}');
      }
    }

    return {
      'hasVars': variables.isNotEmpty,
      'variables': variables.toList(),
      'template': template,
    };
  }

  String _generateMethodCall(String className, String keyName, List<String> variables, String context) {
    if (context == 'text') {
      final params = variables.map((v) => '\$$v').join(', ');
      return 'Text($className.of(context).$keyName($params))';
    } else {
      final params = variables.map((v) => '\$$v').join(', ');
      return '$className.of(context).$keyName($params)';
    }
  }

  String _generateSimpleCall(String className, String keyName, String context) {
    if (context == 'text') {
      return 'Text($className.of(context).$keyName)';
    } else {
      return '$className.of(context).$keyName';
    }
  }

  Map<String, Map<String, String>> _generatePlaceholders(List<String> variables) {
    final Map<String, Map<String, String>> placeholders = {};
    for (final variable in variables) {
      placeholders[variable] = {
        'type': 'String',
        'example': variable == 'username' ? 'John' : 'value',
      };
    }
    return placeholders;
  }

  bool _isImportExportStatement(String content, int position) {
    int lineStart = content.lastIndexOf('\n', position - 1) + 1;
    String linePrefix = content.substring(lineStart, position).trim();

    return linePrefix.startsWith('import ') ||
        linePrefix.startsWith('export ') ||
        linePrefix.startsWith('part ');
  }

  bool _shouldIgnoreString(String str) {
    if (str.length <= 1) return true;
    if (RegExp(r'^\d+\.?\d*$').hasMatch(str)) return true;
    if (RegExp(r'^[a-zA-Z]$').hasMatch(str)) return true;
    if (str.startsWith('http://') || str.startsWith('https://')) return true;
    if (str.contains('/') && str.split('/').length > 2) return true;

    final ignoredPatterns = [
      'assets/',
      'fonts/',
      'images/',
      '.png',
      '.jpg',
      '.jpeg',
      '.svg',
      '.json',
      '.dart',
      'MaterialApp',
      'StatelessWidget',
      'StatefulWidget',
    ];

    return ignoredPatterns.any((pattern) => str.contains(pattern));
  }

  String _generateKeyName(String str) {
    String keyName = str
        .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .map((word) => word.toLowerCase())
        .toList()
        .asMap()
        .map((index, word) => MapEntry(
        index,
        index == 0 ? word : word[0].toUpperCase() + word.substring(1)
    ))
        .values
        .join('');

    if (keyName.isEmpty || RegExp(r'^\d').hasMatch(keyName)) {
      keyName = 'text${_stringCounter++}';
    }

    // Ensure uniqueness
    String finalName = keyName;
    int counter = 1;
    while (_extractedStrings.containsKey(finalName)) {
      finalName = '${keyName}_$counter';
      counter++;
    }

    return finalName;
  }

  String _addImportIfNeeded(String content, String className) {
    final importStatement = "import 'l10n/generated/app_localizations.dart';";

    if (content.contains(importStatement)) {
      return content;
    }

    // Find the last import statement
    final lines = content.split('\n');
    int lastImportIndex = -1;

    for (int i = 0; i < lines.length; i++) {
      if (lines[i].trim().startsWith('import ')) {
        lastImportIndex = i;
      }
    }

    if (lastImportIndex != -1) {
      lines.insert(lastImportIndex + 1, importStatement);
    } else {
      // No imports found, add at the top
      lines.insert(0, importStatement);
      lines.insert(1, '');
    }

    return lines.join('\n');
  }

  Future<void> _generateArbFile(String outputDirectory, String templateArbFile) async {
    final outputDir = Directory(outputDirectory);
    await outputDir.create(recursive: true);

    final arbFile = File(path.join(outputDirectory, templateArbFile));
    final Map<String, dynamic> arbData = {};

    final sortedKeys = _extractedStrings.keys.toList()..sort();

    for (final key in sortedKeys) {
      final stringData = _extractedStrings[key]!;
      arbData[key] = stringData['value'];

      if (stringData['description'] != null) {
        arbData['@$key'] = {
          'description': stringData['description'],
        };

        if (stringData['placeholders'] != null) {
          arbData['@$key']['placeholders'] = stringData['placeholders'];
        }
      }
    }

    const encoder = JsonEncoder.withIndent('  ');
    await arbFile.writeAsString(encoder.convert(arbData));
    print('📄 Generated: ${arbFile.path}');
  }

  Future<void> _generateL10nYaml(String outputDirectory, String className) async {
    final l10nFile = File('l10n.yaml');

    if (l10nFile.existsSync()) {
      print('ℹ️  l10n.yaml already exists, skipping generation');
      return;
    }

    final l10nConfig = '''arb-dir: $outputDirectory
template-arb-file: app_en.arb
output-class: $className
output-localization-file: app_localizations.dart
output-dir: $outputDirectory/generated
nullable-getter: false
synthetic-package: false
''';

    await l10nFile.writeAsString(l10nConfig);
    print('📄 Generated: l10n.yaml');
  }
}