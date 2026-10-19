/// How whole numbers are read and kept, the same way everywhere.
///
/// A count is a whole number from 0 to one billion (the server refuses
/// anything else). Plain `int.tryParse` is too generous for typed text: it
/// accepts " 5", "+5", "-5" and "0x10". [parseCount] accepts digits only.
///
/// Sizes: one count holds 1,000,000,000 at most, a count over three months
/// 3,000,000,000, a seat with eight counts 24,000,000,000, and a company of
/// hundreds of seats stays far below 2^53 (about 9e15), the largest whole
/// number a JavaScript number keeps exactly. The app runs on the web, where
/// every int is such a number, so nothing here uses bit operations.
library;

/// The largest number one count can hold in one month.
const countMax = 1000000000;

/// Digits 0 to 9 only, no sign, no space, no point, no separator, no letters.
/// Null when [raw] is not like that, or is larger than [countMax].
/// Leading zeros are fine ("007" is 7).
int? parseCount(String raw) {
  if (raw.isEmpty || raw.length > 20) return null;
  var n = 0;
  for (final c in raw.codeUnits) {
    if (c < 0x30 || c > 0x39) return null;
    n = n * 10 + (c - 0x30);
    if (n > countMax) return null;
  }
  return n;
}

/// Whether [n] can be a count.
bool isCount(int n) => n >= 0 && n <= countMax;

/// The largest whole number a JavaScript number holds exactly.
const jsSafeMax = 9007199254740991;
