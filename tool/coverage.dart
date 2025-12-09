#!/usr/bin/env dart
// coverage.dart - Script to run tests with coverage and generate reports

import 'dart:io';

void main(List<String> args) async {
  print('Running tests with coverage...');

  // Run tests with coverage
  final testResult = await Process.run(
    'dart',
    ['test', '--coverage=coverage'],
    workingDirectory: Directory.current.path,
  );

  if (testResult.exitCode != 0) {
    print('Tests failed:');
    print(testResult.stdout);
    print(testResult.stderr);
    exit(testResult.exitCode);
  }

  print('Formatting coverage data...');

  // Format coverage data
  final formatResult = await Process.run(
    'dart',
    [
      'run',
      'coverage:format_coverage',
      '--lcov',
      '--in=coverage',
      '--out=coverage/lcov.info',
      '--packages=.dart_tool/package_config.json',
      '--report-on=lib'
    ],
    workingDirectory: Directory.current.path,
  );

  if (formatResult.exitCode != 0) {
    print('Failed to format coverage:');
    print(formatResult.stdout);
    print(formatResult.stderr);
    exit(formatResult.exitCode);
  }

  print('Coverage report generated at: coverage/lcov.info');
  print(
      'You can view it with tools like genhtml or upload to services like Codecov.');
}
