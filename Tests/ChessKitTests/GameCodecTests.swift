//
//  GameCodecTests.swift
//  ChessKitTests
//
//  GameCodec must give back exactly the game it was given: moves (incl. comments and
//  annotations), variation structure and order, every position, tags and tree bookkeeping.
//

@testable import ChessKit
import Foundation
import Testing

struct GameCodecTests {

  /// Compares everything a cached game is used for. `Move ==` ignores comments and assessments,
  /// so the PGN text (which includes them and the variation order) is the main oracle.
  private func expectIdentical(_ a: Game, _ b: Game, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(PGNParser.convert(game: a) == PGNParser.convert(game: b), sourceLocation: sourceLocation)
    #expect(a.startingIndex == b.startingIndex, sourceLocation: sourceLocation)
    #expect(a.tags == b.tags, sourceLocation: sourceLocation)
    #expect(a.moves.lastMainVariationIndex == b.moves.lastMainVariationIndex, sourceLocation: sourceLocation)
    #expect(a.moves.leafNodeIndices == b.moves.leafNodeIndices, sourceLocation: sourceLocation)
    #expect(a.moves.allLines == b.moves.allLines, sourceLocation: sourceLocation)
    #expect(Set(a.moves.indices) == Set(b.moves.indices), sourceLocation: sourceLocation)
    for index in a.moves.indices {
      let ma = a.moves[index], mb = b.moves[index]
      #expect(ma == mb && ma?.comment == mb?.comment && ma?.assessment == mb?.assessment
              && ma?.checkState == mb?.checkState && ma?.san == mb?.san, sourceLocation: sourceLocation)
      #expect(a.moves.variations(for: index) == b.moves.variations(for: index), sourceLocation: sourceLocation)
    }
    #expect(a.moves.variations(for: a.moves.startIndex) == b.moves.variations(for: b.moves.startIndex), sourceLocation: sourceLocation)
    #expect(Set(a.positions.keys) == Set(b.positions.keys), sourceLocation: sourceLocation)
    for (index, position) in a.positions {
      #expect(b.positions[index]?.fen == position.fen, sourceLocation: sourceLocation)
      #expect(b.positions[index]?.assessment == position.assessment, sourceLocation: sourceLocation)
      #expect(b.positions[index]?.enPassantIsPossible == position.enPassantIsPossible, sourceLocation: sourceLocation)
    }
  }

  private func roundTrip(_ game: Game, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let decoded = try #require(GameCodec.decode(GameCodec.encode(game)), sourceLocation: sourceLocation)
    expectIdentical(game, decoded, sourceLocation: sourceLocation)
  }

  @Test func sampleGames() throws {
    try roundTrip(try PGNParser.parse(pgn: Game.fischerSpassky))
    try roundTrip(try PGNParser.parse(pgn: Game.byrneFischer))
    try roundTrip(Game())
  }

  @Test func commentsAnnotationsVariationsAndRootComment() throws {
    let pgn = "{Opening note} 1. e4! {best by test} e5 (1... c5!? {Sicilian} 2. Nf3 (2. c3 d5) d6) 2. Nf3 $14 Nc6?! 3. Bb5 a6 4. Ba4 *"
    try roundTrip(try PGNParser.parse(pgn: pgn))
  }

  @Test func specialMoves() throws {
    // Castling both ways, en passant, promotion with capture, checks, disambiguation.
    let pgn = "1. e4 d5 2. e5 f5 3. exf6 Nc6 4. fxg7 Bf5 5. gxh8=Q Qd7 6. Nf3 O-O-O 7. Be2 e5 8. O-O Nge7 9. Qxh7 Ng6 10. Nc3 Nce7 11. Qh3 *"
    try roundTrip(try PGNParser.parse(pgn: pgn))
  }

  @Test func startsFromFENWithBlackToMove() throws {
    let pgn = """
    [SetUp "1"]
    [FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 15"]

    15... Nf6 (15... e5 16. Nf3) 16. e5 Nd5 *
    """
    let game = try PGNParser.parse(pgn: pgn)
    #expect(game.startingIndex == MoveTree.Index.minimum.next)
    try roundTrip(game)
  }

  @Test func randomTrees() throws {
    var rng = SystemRandomNumberGenerator()
    let assessments: [Move.Assessment] = [.null, .null, .good, .mistake, .brilliant, .blunder, .interesting, .dubious]
    for _ in 0..<40 {
      var game = Game()
      var frontier = [game.moves.startIndex]
      var budget = Int.random(in: 10...80, using: &rng)
      while budget > 0, !frontier.isEmpty {
        let parent = frontier.removeFirst()
        guard let position = game.positions[parent] else { continue }
        let board = Board(position: position)
        var legal: [Move] = []
        for piece in position.pieces where piece.color == position.sideToMove {
          for target in board.legalMoves(forPieceAt: piece.square) {
            var next = board
            guard var move = next.move(pieceAt: piece.square, to: target) else { continue }
            if case .promotion(let incomplete) = next.state { move = next.completePromotion(of: incomplete, to: .queen) }
            legal.append(move)
          }
        }
        for var move in legal.shuffled(using: &rng).prefix(Int.random(in: 1...2, using: &rng)) {
          budget -= 1
          move.assessment = assessments.randomElement(using: &rng)!
          if Bool.random(using: &rng) { move.comment = "c\(budget) ✓ é" }
          let index = game.make(move: move, from: parent)
          game.annotate(moveAt: index, assessment: move.assessment, comment: move.comment)
          frontier.append(index)
        }
      }
      try roundTrip(game)
      // And again through PGN, as the app stores it.
      try roundTrip(try PGNParser.parse(pgn: game.pgn))
    }
  }

  @Test func rejectsCorruptData() throws {
    let data = GameCodec.encode(try PGNParser.parse(pgn: "1. e4 e5 (1... c5 2. Nf3) 2. Nf3 {x} Nc6 *"))
    #expect(GameCodec.decode(data) != nil)
    #expect(GameCodec.decode(Data()) == nil)
    #expect(GameCodec.decode(Data("not a cache".utf8)) == nil)
    var otherVersion = data
    otherVersion[4] = GameCodec.version &+ 1
    #expect(GameCodec.decode(otherVersion) == nil)
    // Every truncation is rejected, never misread.
    for length in 0..<data.count {
      #expect(GameCodec.decode(data.prefix(length)) == nil, "truncated at \(length)")
    }
    // Trailing garbage is rejected too.
    #expect(GameCodec.decode(data + Data([0])) == nil)
  }

  @Test func muchSmallerThanJSON() throws {
    let game = try PGNParser.parse(pgn: Game.byrneFischer)
    let binary = GameCodec.encode(game).count
    let json = try JSONEncoder().encode(game).count
    #expect(binary * 3 < json, "binary \(binary) vs JSON \(json)")
  }
}
