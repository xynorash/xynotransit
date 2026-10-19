/// Character rules shared by every free text field. They mirror the API
/// (xynotransit-api/src/rules.rs) so the app and the server accept and refuse
/// exactly the same text. test/rules_parity_test.dart keeps them honest.
library;

/// Rust's `char::is_control`: the C0 and C1 control characters.
bool isControlRune(int c) => c <= 0x1F || (c >= 0x7F && c <= 0x9F);

/// Characters that show nothing or flip the reading direction. They would let
/// two names look the same, or a name look empty.
bool isInvisibleRune(int c) =>
    c == 0x00AD ||
    c == 0x034F ||
    c == 0x061C ||
    c == 0x115F ||
    c == 0x1160 ||
    c == 0x17B4 ||
    c == 0x17B5 ||
    (c >= 0x180B && c <= 0x180F) ||
    (c >= 0x200B && c <= 0x200F) ||
    (c >= 0x2028 && c <= 0x202E) ||
    (c >= 0x2060 && c <= 0x206F) ||
    c == 0x3164 ||
    (c >= 0xFE00 && c <= 0xFE0F) ||
    c == 0xFEFF ||
    c == 0xFFA0 ||
    (c >= 0xFFF9 && c <= 0xFFFB) ||
    (c >= 0xE0000 && c <= 0xE0FFF);

/// Unicode White_Space, the set Rust's `str::trim` removes.
bool isWhiteSpaceRune(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x20 ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// Trims like the server does (not like `String.trim`, which also eats U+FEFF).
String trimText(String s) {
  final r = s.runes.toList();
  var a = 0;
  var b = r.length;
  while (a < b && isWhiteSpaceRune(r[a])) {
    a++;
  }
  while (b > a && isWhiteSpaceRune(r[b - 1])) {
    b--;
  }
  return (a == 0 && b == r.length) ? s : String.fromCharCodes(r.sublist(a, b));
}

/// Length in characters (code points), as the server counts. Not UTF-16 units.
int charCount(String s) => s.runes.length;

/// The first [max] characters (code points) of [s]. Never cuts a pair of
/// UTF-16 units in two, so an emoji is kept whole or dropped whole.
String cutChars(String s, int max) {
  if (max <= 0) return '';
  var n = 0;
  var i = 0;
  while (i < s.length && n < max) {
    final u = s.codeUnitAt(i);
    final pair =
        u >= 0xD800 &&
        u <= 0xDBFF &&
        i + 1 < s.length &&
        s.codeUnitAt(i + 1) >= 0xDC00 &&
        s.codeUnitAt(i + 1) <= 0xDFFF;
    i += pair ? 2 : 1;
    n++;
  }
  return s.substring(0, i);
}

/// True when [s] has a control or invisible character: the server's list.
bool hasHiddenChars(String s) =>
    s.runes.any((c) => isControlRune(c) || isInvisibleRune(c));

/// Any space that is not the plain one (a non breaking space from a paste, an
/// ideographic space) becomes a plain space. People cannot see the difference,
/// so they must not be refused for it, and it must not make two names look
/// the same but compare different.
String plainSpaces(String s) => s.replaceAllMapped(_oddSpace, (_) => ' ');

final _oddSpace = RegExp(r'(?!\u0020)\p{Zs}', unicode: true);

/// Lower case ASCII letters and digits joined by single dashes. Never empty.
String slugOf(String s) {
  const fold = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
    'ç': 'c',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
    'ñ': 'n',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y',
  };
  final out = StringBuffer();
  var len = 0;
  var dash = false;
  for (final raw in s.toLowerCase().split('')) {
    final c = fold[raw] ?? raw;
    final u = c.codeUnitAt(0);
    final alnum =
        c.length == 1 && ((u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x7A));
    if (alnum) {
      if (dash && len > 0) {
        out.write('-');
        len++;
      }
      dash = false;
      out.write(c);
      len++;
    } else {
      dash = true;
    }
  }
  var t = out.toString();
  if (t.length > 40) t = t.substring(0, 40);
  while (t.endsWith('-')) {
    t = t.substring(0, t.length - 1);
  }
  return t.isEmpty ? 'item' : t;
}

/// [base], then base-2, base-3 ... the first one [taken] does not know.
String uniqueSlug(String base, bool Function(String) taken) {
  var c = base;
  for (var n = 2; taken(c); n++) {
    c = '$base-$n';
  }
  return c;
}
