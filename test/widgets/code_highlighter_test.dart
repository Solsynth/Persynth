import 'package:flutter_test/flutter_test.dart';

import 'package:persynth/widgets/code_highlighter.dart';

/// The runs of [code], as (kind, text) pairs.
List<(CodeTokenKind, String)> _runs(String code, String? language) => [
  for (final token in tokenizeCode(code, language)) (token.kind, token.text),
];

void main() {
  test('paints a language words and comments, and nothing else', () {
    expect(_runs('if (x) return 1; // note', 'dart'), [
      (CodeTokenKind.keyword, 'if'),
      (CodeTokenKind.text, ' (x) '),
      (CodeTokenKind.keyword, 'return'),
      (CodeTokenKind.text, ' 1; '),
      (CodeTokenKind.comment, '// note'),
    ]);
  });

  test('paints a family under every name a fence calls it', () {
    expect(_runs('class A {}', 'kt').first, (CodeTokenKind.keyword, 'class'));
    expect(_runs('function go() {}', 'ts').first, (
      CodeTokenKind.keyword,
      'function',
    ));
    expect(_runs('# comment', 'language-shell'), [
      (CodeTokenKind.comment, '# comment'),
    ]);
  });

  test('a marker inside a string is part of the string', () {
    expect(_runs('const s = "a // b";', 'dart'), [
      (CodeTokenKind.keyword, 'const'),
      (CodeTokenKind.text, ' s = "a // b";'),
    ]);
  });

  test('an escape does not end a string early', () {
    expect(_runs(r'var a = "one \" two"; // tail', 'dart'), [
      (CodeTokenKind.keyword, 'var'),
      (CodeTokenKind.text, ' a = "one \\" two"; '),
      (CodeTokenKind.comment, '// tail'),
    ]);
  });

  test('a string that never closes runs to the end of the block', () {
    expect(_runs('var a = "oops', 'dart'), [
      (CodeTokenKind.keyword, 'var'),
      (CodeTokenKind.text, ' a = "oops'),
    ]);
  });

  test('a reserved word inside a string or a comment stays put', () {
    expect(_runs("x = 'class'", 'dart'), [(CodeTokenKind.text, "x = 'class'")]);
    expect(_runs('# if you like', 'python'), [
      (CodeTokenKind.comment, '# if you like'),
    ]);
    expect(_runs('"""if"""', 'python'), [(CodeTokenKind.text, '"""if"""')]);
  });

  test('a string that spans lines keeps its second line too', () {
    // A backtick string is the one kind that may hold a newline, and `class` on
    // its second line is a string's word, not a language's.
    expect(_runs('const q = `\nclass a\n`;', 'javascript'), [
      (CodeTokenKind.keyword, 'const'),
      (CodeTokenKind.text, ' q = `\nclass a\n`;'),
    ]);
  });

  test('a block comment takes the code after it back out of the wall', () {
    expect(_runs('/* let */ let x', 'swift'), [
      (CodeTokenKind.comment, '/* let */'),
      (CodeTokenKind.text, ' '),
      (CodeTokenKind.keyword, 'let'),
      (CodeTokenKind.text, ' x'),
    ]);
  });

  test('a marker has to start a word to open a comment', () {
    // `#` inside a shell word is part of the word, and `a//b` is floor
    // division in Python rather than a comment.
    expect(_runs('echo foo#bar', 'shell'), [
      (CodeTokenKind.text, 'echo foo#bar'),
    ]);
    expect(_runs('a//b', 'python'), [(CodeTokenKind.text, 'a//b')]);
  });

  test('paints nothing for a language it does not know', () {
    expect(_runs('if (x) {} // yes', 'brainfuck'), [
      (CodeTokenKind.text, 'if (x) {} // yes'),
    ]);
    expect(_runs('if (x) {}', null), [(CodeTokenKind.text, 'if (x) {}')]);
    expect(_runs('', 'dart'), isEmpty);
  });
}
