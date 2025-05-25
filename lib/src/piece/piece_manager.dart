import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/peer/protocol/peer.dart';
import 'package:dtorrent_task/src/piece/piece_manager_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:logging/logging.dart';
import '../peer/bitfield.dart';
import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

var _log = Logger('PieceManager');

class PieceManager with EventsEmittable<PieceManagerEvent> implements PieceProvider {
  bool _isFirst = true;

  final Map<int, Piece> _pieces = {};

  @override
  Map<int, Piece> get pieces => _pieces;

  // final Set<int> _completedPieces = <int>{};

  final Set<int> _downloadingPieces = <int>{};
  @override
  Set<int> get downloadingPieces => _downloadingPieces;

  final PieceSelector _pieceSelector;

  PieceSelector get pieceSelector => _pieceSelector;

  PieceManager(this._pieceSelector, int piecesNumber);

  static PieceManager createPieceManager(PieceSelector pieceSelector, Torrent metaInfo, Bitfield bitfield) {
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
        var piece = Piece(metaInfo.pieces[i], i, byteLength, startbyte, isComplete: true);
        _pieces[i] = piece;
      } else {
        var piece = Piece(metaInfo.pieces[i], i, byteLength, startbyte);
        _pieces[i] = piece;
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
  void processPieceWriteComplete(int pieceIndex) {
    var piece = pieces[pieceIndex];
    if (piece != null) {
      piece.writeComplete();
    }
  }

  Piece? selectPiece(Peer peer, PieceProvider provider, final Set<int>? suggestPieces) {
    var piece = _pieceSelector.selectPiece(peer, this, _isFirst, suggestPieces);
    _isFirst = false;
    if (piece != null) processDownloadingPiece(piece.index);
    return piece;
  }

  void processDownloadingPiece(int pieceIndex) {
    _downloadingPieces.add(pieceIndex);
  }

  void processReceivedBlock(int index, int begin, List<int> block) {
    var piece = pieces[index];
    if (piece != null) {
      piece.subPieceReceived(begin, block);
      if (piece.isCompletelyDownloaded) _processCompletePieceDownload(index);
    }
  }

  /// After completing a piece, some processing is required:
  /// - Validate piece
  /// - Remove it from the _downloadingPieces list.
  /// - Notify the listeners.
  void _processCompletePieceDownload(int index) {
    var piece = pieces[index];
    if (piece == null) return;

    if (!piece.validatePiece()) {
      _log.fine('Piece ${piece.index} is rejected');
      events.emit(PieceRejected(index));
      return;
    }
    _log.fine('Piece ${piece.index} is accepted');

    _downloadingPieces.remove(index);
    events.emit(PieceAccepted(index));
  }

  bool _disposed = false;

  bool get isDisposed => _disposed;

  void dispose() {
    if (isDisposed) return;
    events.dispose();
    _disposed = true;
    pieces.forEach((key, value) {
      value.dispose();
    });
    _pieces.clear();
    _downloadingPieces.clear();
  }

  @override
  Piece? operator [](index) {
    return pieces[index];
  }

  // @override
  // Piece getPiece(int index) {
  //   return _pieces[index];
  // }

  @override
  int get length => _pieces.length;
}
