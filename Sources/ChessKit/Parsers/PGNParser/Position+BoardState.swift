//
//  Position+BoardState.swift
//  ChessKit
//

extension Position {
    /// Compares two positions for equality, ignoring the halfmove and fullmove clocks.
    ///
    /// This is useful for finding transpositions or matching FENs where the move clocks
    /// might differ but the actual board state, castling rights, and en passant status are identical.
    ///
    /// - Parameter other: The `Position` to compare against.
    /// - Returns: `true` if the board, side to move, castling rights, and en passant square are the same.
    func hasSameBoardState(as other: Position) -> Bool {
        let selfEnPassantSquare = self.enPassantIsPossible ? self.enPassant?.captureSquare : nil
        let otherEnPassantSquare = other.enPassantIsPossible ? other.enPassant?.captureSquare : nil
        
        return self.pieceSet == other.pieceSet &&
        self.sideToMove == other.sideToMove &&
        self.legalCastlings == other.legalCastlings &&
        selfEnPassantSquare == otherEnPassantSquare
    }
}
