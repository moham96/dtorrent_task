import 'dart:collection';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../peer/protocol/peer.dart';
import '../utils.dart';

class Piece {
  final String hashString;

  final int byteLength;

  final int index;
  // the offset of the piece from the start of the torrent block
  final int offset;
  // the offseted end position relative to the torrent block
  int get end => offset + byteLength;

  Uint8List? _block;

  final Set<Peer> _availablePeers = <Peer>{};
  Set<Peer> get availablePeers => _availablePeers;

  late Queue<int> _subPiecesQueue;

  // pieces that are in memory
  final Set<int> _inMemorySubPieces = <int>{};

  // pieces that were written to disk
  final Set<int> _onDiskSubPieces = <int>{};

  final int _subPiecesCount;

  int get subPiecesCount => _subPiecesCount;
  // Last piece may have a different length
  final int _subPieceSize;
  int get subPieceSize => _subPieceSize;

  late final int _lastSubPieceSize =
      byteLength - (_subPieceSize * (_subPiecesCount - 1));

  bool _flushed = false;

  bool get flushed => _flushed;

  Piece(this.hashString, this.index, this.byteLength, this.offset,
      {int requestLength = DEFAULT_REQUEST_LENGTH, bool isComplete = false})
      : _subPieceSize = requestLength,
        _subPiecesCount = (byteLength + requestLength - 1) ~/ requestLength {
    if (requestLength <= 0) {
      throw Exception('Request length should bigger than zero');
    }
    if (requestLength > DEFAULT_REQUEST_LENGTH) {
      throw Exception('Request length should smaller than 16kb');
    }
    _subPiecesQueue =
        Queue.from(List.generate(_subPiecesCount, (index) => index));
    if (isComplete) {
      _flushed = true;
      _onDiskSubPieces.addAll(_subPiecesQueue);
    }
  }

  void init() {
    if (flushed) return;
    _block ??= Uint8List(byteLength);
  }

  int calculateLastDownloadedByte(int start) {
    // TODO: Does this work if the requested start is inside the lastpiece?
    // TODO: Simplify and refactor

    var subPieces =
        {...subPieceQueue, ..._inMemorySubPieces, ..._onDiskSubPieces}.toList();
    subPieces.sort();

    var startSubpiece = ((start - offset - 1) ~/ _subPieceSize);

    var lastByte = start;
    var firstAdded = false;
    for (var subPiece in subPieces.skip(startSubpiece)) {
      if (_onDiskSubPieces.contains(subPiece)) {
        if (subPiece == subPiecesCount - 1) {
          // last piece may have different size

          if (firstAdded) {
            lastByte = (offset + (subPiece + 1) * _lastSubPieceSize);
          } else {
            lastByte += _lastSubPieceSize;
          }
        } else {
          if (firstAdded) {
            lastByte = (offset + (subPiece + 1) * _subPieceSize);
          } else {
            lastByte += _subPieceSize;
          }
        }

        firstAdded = true;
      } else {
        break;
      }
    }
    return lastByte;
  }

  bool get isDownloading {
    if (subPiecesCount == 0) return false;
    if (isCompletelyDownloaded) return false;
    if (isCompleted) return false;
    return _subPiecesQueue.isNotEmpty;
  }

  Queue<int> get subPieceQueue => _subPiecesQueue;

  double get completed {
    if (subPiecesCount == 0) return 0;
    return _onDiskSubPieces.length / subPiecesCount;
  }

  bool haveAvailableSubPiece() {
    if (_subPiecesCount == 0) return false;
    return _subPiecesQueue.isNotEmpty;
  }

  int get availablePeersCount => _availablePeers.length;

  int get availableSubPieceCount {
    if (_subPiecesCount == 0) return 0;
    return _subPiecesQueue.length;
  }
  // means the pieces are completely validated and on the disk.

  bool get isCompletelyWritten {
    if (subPiecesCount == 0) return false;
    return _onDiskSubPieces.length == subPiecesCount;
  }

  // means the pieces are completely in memory but not validated or written to disk
  bool get isCompletelyDownloaded {
    if (subPiecesCount == 0) return false;
    return _inMemorySubPieces.length == subPiecesCount;
  }

  // the piece is completed whether it's in the memory or disk
  bool get isCompleted => isCompletelyDownloaded || isCompletelyWritten;

  ///
  /// SubPiece download completed.
  ///
  /// Put the subpiece into the _writingSubPieces queue and mark it as completed.
  /// If the subpiece has already been marked, return false; if it hasn't been marked
  /// yet, mark it as completed and return true.
  bool subPieceReceived(int begin, List<int> block) {
    init();
    _block?.setRange(begin, begin + block.length, block);
    var subindex = begin ~/ DEFAULT_REQUEST_LENGTH;
    _subPiecesQueue.remove(subindex);
    return _inMemorySubPieces.add(subindex);
  }

  bool writeComplete() {
    _onDiskSubPieces.addAll(_inMemorySubPieces);
    _inMemorySubPieces.clear();
    subPieceQueue.clear();
    clearAvailablePeer();
    return true;
  }

  ///
  /// Whether the sub-piece [subIndex] is still available.
  ///
  /// When a sub-piece is popped from the stack for download or if the sub-piece has already been downloaded,
  /// the piece is considered to no longer contain that sub-piece.
  bool containsSubpiece(int subIndex) {
    return subPieceQueue.contains(subIndex);
  }

  bool containsAvailablePeer(Peer peer) {
    return _availablePeers.contains(peer);
  }

  bool removeSubpiece(int subIndex) {
    return subPieceQueue.remove(subIndex);
  }

  bool addAvailablePeer(Peer peer) {
    return _availablePeers.add(peer);
  }

  bool removeAvailablePeer(Peer peer) {
    return _availablePeers.remove(peer);
  }

  void clearAvailablePeer() {
    _availablePeers.clear();
  }

  int? popSubPiece() {
    if (subPieceQueue.isNotEmpty) return subPieceQueue.removeFirst();
    return null;
  }

  bool pushSubPiece(int subIndex) {
    if (subPieceQueue.contains(subIndex) ||
        _inMemorySubPieces.contains(subIndex) ||
        _onDiskSubPieces.contains(subIndex)) return false;
    subPieceQueue.addFirst(subIndex);
    return true;
  }

  int? popLastSubPiece() {
    if (subPieceQueue.isNotEmpty) return subPieceQueue.removeLast();
    return null;
  }

  bool pushSubPieceLast(int index) {
    if (subPieceQueue.contains(index) ||
        _inMemorySubPieces.contains(index) ||
        _onDiskSubPieces.contains(index)) return false;
    subPieceQueue.addLast(index);
    return true;
  }

  bool pushSubPieceBack(int index) {
    if (subPieceQueue.contains(index)) return false;
    _inMemorySubPieces.remove(index);
    _onDiskSubPieces.remove(index);
    subPieceQueue.addLast(index);
    return true;
  }

  bool validatePiece() {
    if (_block == null ||
        _block!.length < byteLength ||
        !isCompletelyDownloaded) {
      throw Exception("Piece is cleared");
    }
    var digest = sha1.convert(_block!);
    var valid = digest.toString() == hashString;
    if (!valid) {
      for (var subPiece in {..._inMemorySubPieces}) {
        pushSubPieceBack(subPiece);
      }
    }
    return valid;
  }

  Uint8List? flush() {
    if (_block == null || _flushed) return null;
    var flushed = Uint8List.fromList(_block!);
    _block = null;
    _flushed = true;
    return flushed;
  }

  bool _disposed = false;

  bool get isDisposed => _disposed;

  void dispose() {
    if (isDisposed) return;
    _disposed = true;
    _availablePeers.clear();
    _inMemorySubPieces.clear();
    _onDiskSubPieces.clear();
  }

  @override
  int get hashCode => hashString.hashCode;

  @override
  bool operator ==(other) {
    if (other is Piece) {
      return other.hashString == hashString;
    }
    return false;
  }
}
