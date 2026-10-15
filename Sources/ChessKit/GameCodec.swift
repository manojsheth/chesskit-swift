//
//  GameCodec.swift
//  ChessKit
//
//  A compact binary snapshot of a parsed `Game`, for caching. Decoding restores the move tree,
//  moves and positions as stored — no SAN parsing, legal-move generation or FEN parsing — so a
//  cached study opens much faster than re-parsing its PGN, and the file is far smaller than the
//  `Codable` JSON of the same game.
//
//  Layout (little-endian, varints for counts and move numbers):
//    magic "PGNC", version
//    tags          length-prefixed JSON of `Game.Tags` (small, rarely matters)
//    startingIndex, lastMainVariationIndex
//    root          comment, move assessment, position assessment
//    nodes         count, then breadth-first (parents first): index, parent index, asNext, position
//                  assessment, move
//    positions     count, then: index, 12 bitboards, side, castlings, en passant, clock, assessment
//
//  `decode` returns nil for anything it can't read (wrong magic, other version, truncated or
//  inconsistent data); callers then parse the PGN. Bump `version` whenever `Move`, `MoveTree` or
//  `Position` gain state that must survive a round trip.
//

import Foundation

public enum GameCodec {

  public static let version: UInt8 = 1
  private static let magic: [UInt8] = Array("PGNC".utf8)

  // MARK: Encode

  public static func encode(_ game: Game) -> Data {
    var w = Writer()
    w.bytes(magic)
    w.u8(version)

    let tags = (try? JSONEncoder().encode(game.tags)) ?? Data()
    w.varint(UInt64(tags.count))
    w.data.append(tags)

    let tree = game.moves
    w.index(game.startingIndex)
    w.index(tree.lastMainVariationIndex)

    let root = tree.rootMove
    w.string(root.comment)
    w.string(root.assessment.rawValue)
    w.string(tree.rootPositionAssessment.rawValue)

    var nodes = Writer()
    var nodeCount: UInt64 = 0
    tree.forEachNodeBreadthFirst { index, parent, asNext, move, positionAssessment in
      nodeCount += 1
      nodes.index(index)
      nodes.index(parent)
      nodes.u8(asNext ? 1 : 0)
      nodes.string(positionAssessment.rawValue)
      nodes.move(move)
    }
    w.varint(nodeCount)
    w.data.append(nodes.data)

    w.varint(UInt64(game.positions.count))
    for (index, position) in game.positions {
      w.index(index)
      w.position(position)
    }
    return w.data
  }

  // MARK: Decode

  public static func decode(_ data: Data) -> Game? {
    var r = Reader(data)
    do {
      guard try r.bytes(magic.count) == magic, try r.u8() == version else { return nil }

      let tagsLength = try r.count()
      let tags = try JSONDecoder().decode(Game.Tags.self, from: try r.data(tagsLength))

      let startingIndex = try r.index()
      let lastMain = try r.index()

      var tree = MoveTree(startingAt: startingIndex)
      tree.restoreRoot(
        comment: try r.string(),
        assessment: try r.moveAssessment(),
        positionAssessment: try r.positionAssessment()
      )

      for _ in 0..<(try r.count()) {
        let index = try r.index()
        let parent = try r.index()
        let asNext = try r.u8() == 1
        let positionAssessment = try r.positionAssessment()
        let move = try r.move()
        guard tree.restoreNode(index: index, parent: parent, move: move, positionAssessment: positionAssessment, asNext: asNext) else {
          return nil
        }
      }
      tree.finishRestore(lastMainVariationIndex: lastMain)

      var positions: [MoveTree.Index: Position] = [:]
      let positionCount = try r.count()
      positions.reserveCapacity(positionCount)
      for _ in 0..<positionCount {
        let index = try r.index()
        positions[index] = try r.position()
      }
      guard r.isAtEnd, positions[startingIndex] != nil else { return nil }

      return Game(moves: tree, startingIndex: startingIndex, positions: positions, tags: tags)
    } catch {
      return nil
    }
  }
}

// MARK: - Writer

private struct Writer {
  var data = Data()

  mutating func u8(_ v: UInt8) { data.append(v) }
  mutating func bytes(_ v: [UInt8]) { data.append(contentsOf: v) }

  mutating func varint(_ value: UInt64) {
    var v = value
    while v >= 0x80 {
      data.append(UInt8(v & 0x7F) | 0x80)
      v >>= 7
    }
    data.append(UInt8(v))
  }

  mutating func u64(_ v: UInt64) {
    var little = v.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }

  mutating func string(_ s: String) {
    let utf8 = Array(s.utf8)
    varint(UInt64(utf8.count))
    data.append(contentsOf: utf8)
  }

  mutating func index(_ i: MoveTree.Index) {
    varint(UInt64(max(0, i.number)))
    u8(i.color == .white ? 0 : 1)
    varint(UInt64(max(0, i.variation)))
  }

  mutating func color(_ c: Piece.Color) { u8(c == .white ? 0 : 1) }

  mutating func piece(_ p: Piece) {
    u8(UInt8(Piece.Kind.allCases.firstIndex(of: p.kind)!))
    color(p.color)
    u8(UInt8(p.square.rawValue))
  }

  mutating func castling(_ c: Castling) {
    u8((c.side == .king ? 0 : 2) | (c.color == .white ? 0 : 1))
  }

  mutating func move(_ m: Move) {
    piece(m.piece)
    u8(UInt8(m.start.rawValue))
    u8(UInt8(m.end.rawValue))
    switch m.result {
    case .move: u8(0)
    case .capture(let captured): u8(1); piece(captured)
    case .castle(let side): u8(2); castling(side)
    }
    if let promoted = m.promotedPiece { u8(1); piece(promoted) } else { u8(0) }
    switch m.disambiguation {
    case nil: u8(0)
    case .byFile(let file): u8(1); u8(UInt8(Square.File.allCases.firstIndex(of: file)!))
    case .byRank(let rank): u8(2); u8(UInt8(rank.value))
    case .bySquare(let square): u8(3); u8(UInt8(square.rawValue))
    }
    string(m.checkState.rawValue)
    string(m.assessment.rawValue)
    string(m.comment)
  }

  mutating func position(_ p: Position) {
    let s = p.pieceSet
    for board in [s.k, s.q, s.r, s.b, s.n, s.p, s.K, s.Q, s.R, s.B, s.N, s.P] { u64(board) }
    color(p.sideToMove)
    let castlings = p.legalCastlings.castlings
    u8(UInt8(castlings.count))
    castlings.forEach { castling($0) }
    if let ep = p.enPassant { u8(1); piece(ep.pawn) } else { u8(0) }
    u8(p.enPassantIsPossible ? 1 : 0)
    varint(UInt64(max(0, p.clock.halfmoves)))
    varint(UInt64(max(0, p.clock.fullmoves)))
    string(p.assessment.rawValue)
  }
}

// MARK: - Reader

private struct Reader {
  struct Corrupt: Error {}

  private let bytes: [UInt8]
  private var offset = 0

  init(_ data: Data) { bytes = [UInt8](data) }

  var isAtEnd: Bool { offset == bytes.count }

  mutating func u8() throws -> UInt8 {
    guard offset < bytes.count else { throw Corrupt() }
    defer { offset += 1 }
    return bytes[offset]
  }

  mutating func bytes(_ n: Int) throws -> [UInt8] {
    guard n >= 0, offset + n <= bytes.count else { throw Corrupt() }
    defer { offset += n }
    return Array(bytes[offset..<offset + n])
  }

  mutating func data(_ n: Int) throws -> Data { Data(try bytes(n)) }

  mutating func varint() throws -> UInt64 {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while true {
      let byte = try u8()
      result |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return result }
      shift += 7
      guard shift < 64 else { throw Corrupt() }
    }
  }

  /// A count / length: bounded by the remaining bytes, so corrupt data can't allocate wildly.
  mutating func count() throws -> Int {
    let v = try varint()
    guard v <= UInt64(bytes.count - offset) * 8 + 1 else { throw Corrupt() }
    return Int(v)
  }

  mutating func u64() throws -> UInt64 {
    let b = try bytes(8)
    var v: UInt64 = 0
    for (i, byte) in b.enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
    return v
  }

  mutating func string() throws -> String {
    let length = try count()
    guard let s = String(bytes: try bytes(length), encoding: .utf8) else { throw Corrupt() }
    return s
  }

  mutating func index() throws -> MoveTree.Index {
    let number = Int(try varint())
    let color: Piece.Color = try u8() == 0 ? .white : .black
    let variation = Int(try varint())
    return MoveTree.Index(number: number, color: color, variation: variation)
  }

  mutating func color() throws -> Piece.Color {
    switch try u8() {
    case 0: .white
    case 1: .black
    default: throw Corrupt()
    }
  }

  mutating func square() throws -> Square {
    guard let square = Square(rawValue: Int(try u8())) else { throw Corrupt() }
    return square
  }

  mutating func piece() throws -> Piece {
    let kindIndex = Int(try u8())
    guard kindIndex < Piece.Kind.allCases.count else { throw Corrupt() }
    let kind = Piece.Kind.allCases[kindIndex]
    return Piece(kind, color: try color(), square: try square())
  }

  mutating func castling() throws -> Castling {
    let v = try u8()
    guard v < 4 else { throw Corrupt() }
    return Castling(side: v & 2 == 0 ? .king : .queen, color: v & 1 == 0 ? .white : .black)
  }

  mutating func moveAssessment() throws -> Move.Assessment {
    guard let a = Move.Assessment(rawValue: try string()) else { throw Corrupt() }
    return a
  }

  mutating func positionAssessment() throws -> Position.Assessment {
    guard let a = Position.Assessment(rawValue: try string()) else { throw Corrupt() }
    return a
  }

  mutating func move() throws -> Move {
    let piece = try piece()
    let start = try square()
    let end = try square()
    let result: Move.Result
    switch try u8() {
    case 0: result = .move
    case 1: result = .capture(try self.piece())
    case 2: result = .castle(try castling())
    default: throw Corrupt()
    }
    let promoted: Piece? = try u8() == 1 ? try self.piece() : nil
    let disambiguation: Move.Disambiguation?
    switch try u8() {
    case 0: disambiguation = nil
    case 1:
      let i = Int(try u8())
      guard i < Square.File.allCases.count else { throw Corrupt() }
      disambiguation = .byFile(Square.File.allCases[i])
    case 2:
      let rank = Int(try u8())
      guard Square.Rank.range.contains(rank) else { throw Corrupt() }
      disambiguation = .byRank(Square.Rank(rank))
    case 3: disambiguation = .bySquare(try square())
    default: throw Corrupt()
    }
    guard let checkState = Move.CheckState(rawValue: try string()) else { throw Corrupt() }
    let assessment = try moveAssessment()
    let comment = try string()

    var move = Move(result: result, piece: piece, start: start, end: end, checkState: checkState, assessment: assessment, comment: comment)
    move.promotedPiece = promoted
    move.disambiguation = disambiguation
    return move
  }

  mutating func position() throws -> Position {
    var set = PieceSet(pieces: [])
    set.k = try u64(); set.q = try u64(); set.r = try u64(); set.b = try u64(); set.n = try u64(); set.p = try u64()
    set.K = try u64(); set.Q = try u64(); set.R = try u64(); set.B = try u64(); set.N = try u64(); set.P = try u64()
    let side = try color()
    var castlings: [Castling] = []
    for _ in 0..<Int(try u8()) { castlings.append(try castling()) }
    let enPassant: EnPassant? = try u8() == 1 ? EnPassant(pawn: try piece()) : nil
    let enPassantIsPossible = try u8() == 1
    var clock = Clock()
    clock.halfmoves = Int(try varint())
    clock.fullmoves = Int(try varint())
    let assessment = try positionAssessment()
    return Position(
      pieceSet: set, sideToMove: side, legalCastlings: LegalCastlings(legal: castlings),
      enPassant: enPassant, enPassantIsPossible: enPassantIsPossible, clock: clock, assessment: assessment
    )
  }
}
