import 'package:dtorrent_task/src/peer/protocol/peer.dart';

import 'piece.dart';
import 'piece_provider.dart';

/// Piece selector.
///
/// When the client starts downloading, this class selects appropriate Pieces to download.
abstract class PieceSelector {
  /// Selects the appropriate Piece for the Peer to download.
  ///
  /// [peer] is the Peer that is about to download. This identifier may not necessarily be the peer_id in the protocol, but rather a unique identifier used by the Piece class to distinguish Peers.
  /// This method retrieves the corresponding Piece object using [provider] and [piecesIndexList], and filters it within the [piecesIndexList] collection.
  ///
  Piece? selectPiece(Peer peer, PieceProvider provider,
      [bool first = false, Set<int>? suggestPieces]);

  // prioretize these pieces for the next selectPiece call
  /// Sets the priority pieces for the next call to [selectPiece].
  /// The [pieces] parameter is an iterable of piece indices that should be prioritized.
  /// This method clears any previously set priority pieces and updates the internal state with the new set of priority pieces.
  /// this can be used to prioritize pieces that are more likely to be needed next,
  /// for example when the user is streaming a video and seeks to a specific position this method should be called to prioritize
  /// the pieces that are needed to continue streaming from that position.
  void setPriorityPieces(Iterable<int> pieces);
}
