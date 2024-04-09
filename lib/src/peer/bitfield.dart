import 'dart:typed_data';

/// The base number used for bitwise AND and OR operations.
///
/// It is represented as: 10000000 (binary representation)
const baseNum = 128;

class Bitfield {
  final int piecesNum;
  final Uint8List buffer;

  List<int>? _completedIndex;
  Bitfield(this.piecesNum, this.buffer);

  bool getBit(int index) {
    if (index < 0 || index >= piecesNum) return false;
    var i = index ~/ 8; // This represents the position of the byte.
    var b = index
        .remainder(8); // This represents the position of the bit in the byte
    var andNum = baseNum >> b;
    return ((andNum & buffer[i]) !=
        0); // If it is equal to 0, it means that the bit at that position is 0, which is equivalent to false.
  }

  ///
  /// If [index] is not within the range [0 - piecesNum], no error will be thrown, and the method will return directly.
  void setBit(int index, bool bit) {
    if (index < 0 || index >= piecesNum) return;
    if (getBit(index) == bit) return;
    var i = index ~/ 8; // This represents the position of the byte.
    var b = index
        .remainder(8); // This represents the position of the bit in the byte
    var orNum = baseNum >> b;
    if (bit) {
      _completedIndex = completedPieces;
      _completedIndex?.add(index);
      buffer[i] = buffer[i] | orNum;
    } else {
      _completedIndex?.remove(index);
      buffer[i] = buffer[i] & (~orNum);
    }
  }

  /// Returns `true` if there is a completed piece, without necessarily checking all of them.
  bool haveCompletePiece() {
    for (var i = 0; i < buffer.length; i++) {
      var a = buffer[i];
      if (a != 0) {
        for (var j = 0; j < 8; j++) {
          var index = i * 8 + j;
          if (getBit(index)) return true;
        }
      }
    }
    return false;
  }

  bool haveAll() {
    for (var i = 0; i < buffer.length - 1; i++) {
      var a = buffer[i];
      if (a != 255) {
        return false;
      }
    }
    var last = buffer.length - 1;
    for (var j = 0; j < 8; j++) {
      var index = last * 8 + j;
      if (index >= piecesNum) break;
      if (!getBit(index)) return false;
    }
    return true;
  }

  bool haveNone() {
    return !haveCompletePiece();
  }

  List<int> get completedPieces {
    if (_completedIndex == null) {
      _completedIndex = <int>[];
      for (var i = 0; i < buffer.length; i++) {
        var a = buffer[i];
        if (a != 0) {
          for (var j = 0; j < 8; j++) {
            var index = i * 8 + j;
            if (getBit(index)) {
              _completedIndex?.add(index);
            }
          }
        }
      }
    }
    return _completedIndex!;
  }

  int get length => buffer.length;

  @override
  String toString() {
    return buffer.fold('Bitfield : ', (previousValue, element) {
      var str = element.toRadixString(2);
      var l = str.length;
      for (var i = 0; i < 8 - l; i++) {
        str = '0$str';
      }
      return '$previousValue$str-';
    });
  }

  static Bitfield copyFrom(int piecesNum, List<int> list,
      [int offset = 0, int? end]) {
    var b = piecesNum ~/ 8;
    if (b * 8 != piecesNum) b++;
    var newBuffer = Uint8List(b);
    end ??= newBuffer.length;
    var index = 0;
    for (var i = offset; i < end; i++, index++) {
      newBuffer[index] = list[i];
    }
    return Bitfield(piecesNum, newBuffer);
  }

  static Bitfield createEmptyBitfield(int piecesNum) {
    var b = piecesNum ~/ 8;
    if (b * 8 != piecesNum) b++;
    return Bitfield(piecesNum, Uint8List(b));
  }
}
