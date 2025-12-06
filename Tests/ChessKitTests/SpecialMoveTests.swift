//
//  SpecialMoveTests.swift
//  ChessKitTests
//

@testable import ChessKit
import Testing

struct SpecialMoveTests {

  @Test func legalCastlingInvalidationForKings() {
    let blackKing = Piece(.king, color: .black, square: .e8)
    let whiteKing = Piece(.king, color: .white, square: .e1)

    var legalCastlings = LegalCastlings()
    legalCastlings.invalidateCastling(for: blackKing)
    #expect(!legalCastlings.contains(.bK))
    #expect(!legalCastlings.contains(.bQ))
    #expect(legalCastlings.contains(.wK))
    #expect(legalCastlings.contains(.wQ))

    legalCastlings.invalidateCastling(for: whiteKing)
    #expect(!legalCastlings.contains(.bK))
    #expect(!legalCastlings.contains(.bQ))
    #expect(!legalCastlings.contains(.wK))
    #expect(!legalCastlings.contains(.wQ))
  }

  @Test func legalCastlingInvalidationForRooks() {
    let blackKingsideRook = Piece(.rook, color: .black, square: .h8)
    let blackQueensideRook = Piece(.rook, color: .black, square: .a8)
    let whiteKingsideRook = Piece(.rook, color: .white, square: .h1)
    let whiteQueensideRook = Piece(.rook, color: .white, square: .a1)

    var legalCastlings = LegalCastlings()
    legalCastlings.invalidateCastling(for: blackKingsideRook)
    #expect(!legalCastlings.contains(.bK))
    #expect(legalCastlings.contains(.bQ))
    #expect(legalCastlings.contains(.wK))
    #expect(legalCastlings.contains(.wQ))

    legalCastlings.invalidateCastling(for: blackQueensideRook)
    #expect(!legalCastlings.contains(.bK))
    #expect(!legalCastlings.contains(.bQ))
    #expect(legalCastlings.contains(.wK))
    #expect(legalCastlings.contains(.wQ))

    legalCastlings.invalidateCastling(for: whiteKingsideRook)
    #expect(!legalCastlings.contains(.bK))
    #expect(!legalCastlings.contains(.bQ))
    #expect(!legalCastlings.contains(.wK))
    #expect(legalCastlings.contains(.wQ))

    legalCastlings.invalidateCastling(for: whiteQueensideRook)
    #expect(!legalCastlings.contains(.bK))
    #expect(!legalCastlings.contains(.bQ))
    #expect(!legalCastlings.contains(.wK))
    #expect(!legalCastlings.contains(.wQ))
  }

  @Test func enPassantCaptureSquare() {
    let blackPawn = Piece(.pawn, color: .black, square: .d5)
    let blackEnPassant = EnPassant(pawn: blackPawn)
    #expect(blackEnPassant.captureSquare == Square.d6)
    #expect(blackEnPassant.couldBeCaptured(by: Piece(.pawn, color: .white, square: .e5)))
    #expect(blackEnPassant.couldBeCaptured(by: Piece(.pawn, color: .white, square: .c5)))
    #expect(!blackEnPassant.couldBeCaptured(by: Piece(.pawn, color: .black, square: .e5)))
    #expect(!blackEnPassant.couldBeCaptured(by: Piece(.pawn, color: .white, square: .f5)))
    #expect(!blackEnPassant.couldBeCaptured(by: Piece(.pawn, color: .white, square: .b5)))
    #expect(!blackEnPassant.couldBeCaptured(by: Piece(.bishop, color: .white, square: .c5)))

    let whitePawn = Piece(.pawn, color: .white, square: .d4)
    let whiteEnPassant = EnPassant(pawn: whitePawn)
    #expect(whiteEnPassant.captureSquare == Square.d3)
    #expect(whiteEnPassant.couldBeCaptured(by: Piece(.pawn, color: .black, square: .e4)))
    #expect(whiteEnPassant.couldBeCaptured(by: Piece(.pawn, color: .black, square: .c4)))
    #expect(!whiteEnPassant.couldBeCaptured(by: Piece(.pawn, color: .white, square: .e4)))
    #expect(!whiteEnPassant.couldBeCaptured(by: Piece(.pawn, color: .black, square: .f4)))
    #expect(!whiteEnPassant.couldBeCaptured(by: Piece(.pawn, color: .black, square: .b4)))
    #expect(!whiteEnPassant.couldBeCaptured(by: Piece(.bishop, color: .black, square: .c4)))
  }

    @Test("En Passant Possibility After PGN Parse")
    func enPassantAfterPGNParse() throws {
        let pgn = "1. d4 Nf6 2. Nc3 d5 3. Bf4 e6 4. Nb5 Bb4+ 5. c3 Ba5 6. a4 a6 7. b4 axb5 8. axb5 b6 9. bxa5 bxa5 10. e3 O-O 11. Nf3 Nbd7 12. Bd3 Bb7 13. Ne5 Nxe5 14. dxe5 Ne4 15. Qh5 f5"
        
        // 1. Parse the game to get the final state.
        let game = try PGNParser.parse(game: pgn)
        
        // 2. Get the index of the last move (15... f5) and its resulting position.
        let lastMoveIndex = MoveTree.Index(number: 15, color: .black)
        let finalPosition = try #require(game.positions[lastMoveIndex])
        
        // 3. Check that the en passant state is correctly set in the Position object.
        let enPassantState = try #require(finalPosition.enPassant, "En passant state should not be nil.")
        #expect(enPassantState.captureSquare == .f6, "The en passant capture square should be f6.")
        #expect(finalPosition.enPassantIsPossible, "enPassantIsPossible flag should be true.")
        
        // 4. Verify that the FEN string correctly reflects the en passant square.
        #expect(finalPosition.fen.contains(" f6 "), "The generated FEN string must include the 'f6' en passant square.")
        
        // 5. Create a board and verify the capture is a legal move.
        var board = Board(position: finalPosition)
        #expect(board.canMove(pieceAt: .e5, to: .f6), "The en passant capture 'exf6' should be a legal move.")
        
        // 6. Perform the move and confirm it's a capture of the correct pawn.
        let move = board.move(pieceAt: .e5, to: .f6)
        let capturedPawn = Piece(.pawn, color: .black, square: .f5)
        #expect(move?.result == .capture(capturedPawn), "The move should be registered as an en passant capture of the pawn on f5.")
    }

}
