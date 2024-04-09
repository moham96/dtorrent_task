import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/peer/peer.dart';
import 'package:dtorrent_task/src/piece/piece_manager_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import '../peer/bitfield.dart';
import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';
import 'package:collection/collection.dart';

class PieceManager
    with EventsEmittable<PieceManagerEvent>
    implements PieceProvider {
  bool _isFirst = true;

  final List<Piece> _pieces = [];

  @override
  List<Piece> get pieces => _pieces;

  // final Set<int> _completedPieces = <int>{};

  @override
  Iterable<Piece> get downloadingPieces =>
      _pieces.where((piece) => piece.isDownloading == true);

  final PieceSelector _pieceSelector;

  PieceManager(this._pieceSelector, int piecesNumber);

  static PieceManager createPieceManager(
      PieceSelector pieceSelector, Torrent metaInfo, Bitfield bitfield) {
    var p = PieceManager(pieceSelector, metaInfo.pieces.length);
    p.initPieces(metaInfo, bitfield);
    return p;
  }

  void initPieces(Torrent metaInfo, Bitfield bitfield) {
    var startbyte = 0;
    for (var i = 0; i < metaInfo.pieces.length; i++) {
      var byteLength = metaInfo.pieceLength;
      if (i == metaInfo.pieces.length - 1) {
        byteLength = metaInfo.lastPieceLength;
      }

      if (bitfield.getBit(i)) {
        var piece = Piece(metaInfo.pieces[i], i, byteLength, startbyte,
            isComplete: true);
        _pieces.add(piece);
      } else {
        var piece = Piece(metaInfo.pieces[i], i, byteLength, startbyte);
        _pieces.add(piece);
      }
      startbyte = startbyte + byteLength;
    }
  }

  /// This interface is used for FileManager callback.
  ///
  /// Only when all sub-pieces have been written, the piece is considered complete.
  ///
  /// Because if we modify the bitfield only after downloading, it will cause the remote peer
  /// to request sub-pieces that are not yet present in the file system, leading to errors in data reading.
  void processSubPieceWriteComplete(int pieceIndex, int begin, int length) {
    var piece =
        _pieces.firstWhereOrNull((element) => element.index == pieceIndex);
    if (piece != null) {
      piece.subPieceWriteComplete(begin);
      if (piece.isCompleted) _processCompletePiece(pieceIndex);
    }
  }

  Piece? selectPiece(Peer peer, List<int> remoteHavePieces,
      PieceProvider provider, final Set<int>? suggestPieces) {
    var piece = _pieceSelector.selectPiece(
        peer, remoteHavePieces, this, _isFirst, suggestPieces);
    _isFirst = false;
    return piece;
  }

  /// After completing a piece, some processing is required:
  /// - Notify the listeners.
  void _processCompletePiece(int index) {
    try {
      events.emit(PieceWriteCompleted(index));
    } catch (e) {
      // TODO(ivn): throw smth
    }
  }

  bool _disposed = false;

  bool get isDisposed => _disposed;

  void dispose() {
    if (isDisposed) return;
    events.dispose();
    _disposed = true;
    for (var piece in _pieces) {
      piece.dispose();
    }
    _pieces.clear();
  }

  @override
  Piece? operator [](index) {
    return _pieces.firstWhereOrNull((element) => element.index == index);
  }

  // @override
  // Piece getPiece(int index) {
  //   return _pieces[index];
  // }

  @override
  int get length => _pieces.length;
}
