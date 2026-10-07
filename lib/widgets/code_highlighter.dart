import 'package:flutter/foundation.dart' show immutable;

/// The three things a run of code can be as far as this app is concerned.
enum CodeTokenKind {
  /// The code itself: punctuation, names, numbers, strings.
  text,

  /// A word the language reserves — `if`, `class`, `await`.
  keyword,

  /// Text the language ignores — comments.
  comment,
}

/// One run of [text] that reads in a single tone.
@immutable
class CodeToken {
  const CodeToken(this.kind, this.text);

  final CodeTokenKind kind;
  final String text;

  @override
  String toString() => 'CodeToken($kind, ${text.length} chars)';
}

/// Splits [code] into the runs a renderer tones differently.
///
/// This is a colouring, not a parser, and it is deliberately one left-to-right
/// pass: comments and strings are consumed whole before anything inside them is
/// looked at, so a `//` in a string and a keyword in a comment stay where they
/// belong. Words are only painted when [language] is a language this knows and
/// the word is on its list, so the failure mode is a missed colour rather than
/// a wrong one.
///
/// An unknown [language] claims nothing and the whole block comes back as one
/// run. That is the only honest answer for a language with no entry here: a `#`
/// opens a comment in shell and a directive in C, and guessing would paint other
/// people's code wrong.
List<CodeToken> tokenizeCode(String code, String? language) {
  if (code.isEmpty) return const <CodeToken>[];
  final syntax = _syntaxOf(language);
  if (syntax == null) return <CodeToken>[CodeToken(CodeTokenKind.text, code)];

  final tokens = <CodeToken>[];
  var plain = 0;
  var i = 0;

  /// Everything since the last claim reads in the body tone.
  void flushTo(int end) {
    if (end > plain) {
      tokens.add(CodeToken(CodeTokenKind.text, code.substring(plain, end)));
    }
  }

  void claim(int start, int end, CodeTokenKind kind) {
    flushTo(start);
    tokens.add(CodeToken(kind, code.substring(start, end)));
    plain = end;
  }

  while (i < code.length) {
    // Blocks first: where a language has both, the longer marker has to win.
    final block = _blockOpeningAt(code, i, syntax);
    if (block != null) {
      final close = code.indexOf(block.$2, i + block.$1.length);
      final end = close < 0 ? code.length : close + block.$2.length;
      claim(i, end, CodeTokenKind.comment);
      i = end;
      continue;
    }

    final line = _lineOpeningAt(code, i, syntax);
    if (line != null) {
      final newline = code.indexOf('\n', i);
      final end = newline < 0 ? code.length : newline;
      claim(i, end, CodeTokenKind.comment);
      i = end;
      continue;
    }

    final char = code[i];
    if (char == '"' || char == "'" || char == '`') {
      // Consumed, not claimed: a string is code, but nothing inside it is.
      i = _stringEnd(code, i);
      continue;
    }

    if (_isWordChar(code.codeUnitAt(i))) {
      var end = i + 1;
      while (end < code.length && _isWordChar(code.codeUnitAt(end))) {
        end++;
      }
      if (syntax.keywords.contains(code.substring(i, end))) {
        claim(i, end, CodeTokenKind.keyword);
      }
      i = end;
      continue;
    }

    i++;
  }
  flushTo(code.length);
  return tokens;
}

/// The index just past the string opening at [start], escapes honoured and
/// tripled quotes seen as one delimiter. An unterminated string runs to the end
/// of the block rather than swallowing it forever.
int _stringEnd(String code, int start) {
  final quote = code[start];
  final triple =
      start + 2 < code.length &&
      code[start + 1] == quote &&
      code[start + 2] == quote;
  final delimiter = triple ? 3 : 1;
  var i = start + delimiter;
  while (i < code.length) {
    final char = code[i];
    if (char == '\\') {
      i += 2;
      continue;
    }
    if (char == quote) {
      if (!triple) return i + 1;
      if (i + 2 < code.length && code[i + 1] == quote && code[i + 2] == quote) {
        return i + 3;
      }
    } else if (char == '\n' && !triple && quote != '`') {
      // A quote that never closed: the line ends it either way. A backtick is
      // the exception — Go, JavaScript and the shell all let one span lines.
      return i;
    }
    i++;
  }
  return code.length;
}

/// Whether [code] opens a block comment at [index].
(String, String)? _blockOpeningAt(String code, int index, _Syntax syntax) {
  for (final marker in syntax.block) {
    if (code.startsWith(marker.$1, index)) return marker;
  }
  return null;
}

/// Whether [code] opens a line comment at [index].
///
/// The marker also has to start a word: `a//b` is floor division in Python and
/// `foo#bar` is one word in shell, and neither opens a comment.
String? _lineOpeningAt(String code, int index, _Syntax syntax) {
  for (final marker in syntax.line) {
    if (!code.startsWith(marker, index)) continue;
    if (index == 0 || !_isWordChar(code.codeUnitAt(index - 1))) return marker;
  }
  return null;
}

bool _isWordChar(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
    (codeUnit >= 0x41 && codeUnit <= 0x5A) || // A-Z
    (codeUnit >= 0x61 && codeUnit <= 0x7A) || // a-z
    codeUnit == 0x5F || // _
    codeUnit == 0x24; // $

/// How one language is commented and what it reserves.
class _Syntax {
  const _Syntax({
    this.line = const [],
    this.block = const [],
    required this.keywords,
  });

  /// Line-comment markers, longest first.
  final List<String> line;

  /// Block-comment delimiters, as (opening, closing) pairs.
  final List<(String, String)> block;

  final Set<String> keywords;
}

Set<String> _words(String words) =>
    words.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toSet();

/// Two slash-like languages, one line and one block.
const _slashes = ['//'];
const _blockComment = [('/*', '*/')];

/// The languages a reply is written in. The keyword sets are the words that make
/// code *structure* — control flow, declarations — rather than every reserved
/// word: a colouring is read at a glance, and a line of `int` and `String` in
/// the accent would be noise rather than structure.
final _dart = _Syntax(
  line: _slashes,
  block: _blockComment,
  keywords: _words('''
    abstract as assert async await break case catch class const continue
    covariant default deferred do dynamic else enum export extends extension
    external factory false final finally for get hide if implements import in
    interface is late library mixin new null on operator part required rethrow
    return set show static super switch sync this throw true try typedef var void
    when while with yield
  '''),
);
final _swift = _Syntax(
  line: _slashes,
  block: _blockComment,
  keywords: _words('''
    actor any as associatedtype async await break case catch class continue
    convenience default defer deinit do dynamic else enum extension fallthrough
    false fileprivate final for func guard if import in indirect init inout
    internal is lazy let mutating nil nonmutating open operator override private
    protocol public repeat required rethrows return self some static struct
    subscript super switch throw throws true try typealias unowned var weak where
    while
  '''),
);

/// C, C++, Java, Kotlin and C#: what they agree on, plus the few each one adds
/// that a reader of code would still call a keyword.
final _cLike = _Syntax(
  line: _slashes,
  block: _blockComment,
  keywords: _words('''
    asm auto break case catch class const constexpr continue default delete do
    else enum explicit export extern false final for friend fun goto if import
    inline instanceof interface internal namespace new object operator override
    package private protected public register return sizeof static struct super
    switch template this throw throws true try typedef typeof union using val var
    virtual void volatile when while
  '''),
);
final _javascript = _Syntax(
  line: _slashes,
  block: _blockComment,
  keywords: _words('''
    async await break case catch class const continue debugger default delete do
    else export extends false finally for from function get if import in
    instanceof let new null of return set static super switch this throw true try
    typeof undefined var void while yield
  '''),
);
final _python = _Syntax(
  line: const ['#'],
  keywords: _words('''
    and as assert async await break case class continue def del elif else except
    finally for from global if import in is lambda match nonlocal not or pass
    raise return self try while with yield False None True
  '''),
);
final _go = _Syntax(
  line: _slashes,
  block: _blockComment,
  keywords: _words('''
    break case chan const continue default defer else fallthrough for func go
    goto if import interface map package range return select struct switch type
    var false nil true
  '''),
);
final _rust = _Syntax(
  line: _slashes,
  block: _blockComment,
  keywords: _words('''
    as async await break const continue crate dyn else enum extern false fn for
    if impl in let loop match mod move mut pub ref return self static struct
    super trait true type unsafe use where while
  '''),
);
final _shell = _Syntax(
  line: const ['#'],
  keywords: _words('''
    alias break case continue declare do done elif else esac export fi for
    function if in local readonly return set shift source then time trap unset
    until while
  '''),
);
final _sql = _Syntax(
  line: const ['--'],
  block: _blockComment,
  keywords: _words('''
    alter and as asc by case cast create delete desc distinct drop else end
    exists from group having in inner insert into is join left like limit not
    null offset on or order outer primary references right select set table then
    union unique update values when where
  '''),
);
final _json = _Syntax(
  line: _slashes,
  block: _blockComment,
  keywords: _words('false null true'),
);

/// YAML, TOML, INI: comments, and no reserved word worth painting.
final _hashComment = _Syntax(line: const ['#'], keywords: const {});

/// HTML, XML: one block comment, and no reserved word worth painting.
final _markup = _Syntax(block: const [('<!--', '-->')], keywords: const {});

/// CSS: one block comment, and no reserved word worth painting.
final _css = _Syntax(block: _blockComment, keywords: const {});

/// What a fence's info string has to say, under every name it says it with.
final Map<String, _Syntax> _languages = {
  'dart': _dart,
  'swift': _swift,
  'javascript': _javascript,
  'js': _javascript,
  'jsx': _javascript,
  'mjs': _javascript,
  'ts': _javascript,
  'tsx': _javascript,
  'typescript': _javascript,
  'python': _python,
  'py': _python,
  'py3': _python,
  'go': _go,
  'golang': _go,
  'rust': _rust,
  'rs': _rust,
  'shell': _shell,
  'sh': _shell,
  'bash': _shell,
  'zsh': _shell,
  'console': _shell,
  'shell-session': _shell,
  'sql': _sql,
  'psql': _sql,
  'mysql': _sql,
  'postgres': _sql,
  'json': _json,
  'jsonc': _json,
  'yaml': _hashComment,
  'yml': _hashComment,
  'toml': _hashComment,
  'ini': _hashComment,
  'conf': _hashComment,
  'properties': _hashComment,
  'html': _markup,
  'htm': _markup,
  'xml': _markup,
  'svg': _markup,
  'vue': _markup,
  'css': _css,
  'scss': _css,
  'less': _css,
  'kotlin': _cLike,
  'kt': _cLike,
  'kts': _cLike,
  'java': _cLike,
  'c': _cLike,
  'h': _cLike,
  'cc': _cLike,
  'cpp': _cLike,
  'c++': _cLike,
  'hpp': _cLike,
  'cs': _cLike,
  'csharp': _cLike,
  'objc': _cLike,
  'objective-c': _cLike,
};

/// The syntax behind a fence's info string, or null when it is not a language
/// this renderer knows — in which case nothing is painted.
_Syntax? _syntaxOf(String? language) {
  var name = language?.trim().toLowerCase() ?? '';
  if (name.isEmpty) return null;
  for (final prefix in const ['language-', 'lang-']) {
    if (name.startsWith(prefix)) name = name.substring(prefix.length);
  }
  return _languages[name];
}
