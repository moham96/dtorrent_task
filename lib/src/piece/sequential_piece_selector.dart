import 'package:dtorrent_task/src/peer/protocol/peer.dart';

import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

///
/// Sequential piece selector.
///
class SequentialPieceSelector implements PieceSelector {
  final Set<int> _priorityPieces = {};

  /// should be called when the user seeks to a specific position in the video
  /// to prioritize the pieces that are needed to continue streaming from that position.
  /// also might be called at the start of the download to prioritize the pieces that are
  /// needed to start streaming the video( the moov atom in mp4 files).
  @override
  void setPriorityPieces(Iterable<int> pieces) {
    _priorityPieces.clear();
    _priorityPieces.addAll(pieces);
  }

  @override
  Piece? selectPiece(Peer peer, PieceProvider provider,
      [bool random = false, Set<int>? suggestPieces]) {
    // Check if the current downloading piece can be used by this peer.
    // TODO: for last pieces maybe we can pull pieces even if they are not in the remoteCompletePieces?
    // TODO: investigate the need to sort remoteHavePieces
    for (var piece in _priorityPieces) {
      var p = provider.pieces[piece];
      if (p == null ||
          p.isCompleted ||
          !p.haveAvailableSubPiece() ||
          !peer.remoteCompletePieces.contains(piece)) {
        continue;
      }
      return p; //return the first piece that is not completed and has available sub-pieces and is in the remote complete pieces
    }
    for (var remoteHavePiece in peer.remoteCompletePieces) {
      var p = provider.pieces[remoteHavePiece];
      if (p == null) return null;
      if (!p.isCompleted && p.haveAvailableSubPiece()) return p;
    }

    return null;
  }
}
