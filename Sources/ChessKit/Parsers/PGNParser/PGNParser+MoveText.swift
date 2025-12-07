//
//  PGNParser+MoveText.swift
//  ChessKit
//

import Foundation

extension PGNParser {
  /// Parses PGN movetext.
  enum MoveTextParser {

    // MARK: Internal

    static func game(
      from moveText: String,
      startingPosition: Position
    ) throws(PGNParser.Error) -> Game {
      let moveTextTokens = try MoveTextParser.tokenize(
        moveText: moveText
      )

      return try MoveTextParser.parse(tokens: moveTextTokens, startingWith: startingPosition)
    }

    // MARK: Private

    private static func tokenize(moveText: String) throws(PGNParser.Error) -> [Token] {
        var inlineMoveText = moveText.components(separatedBy: .newlines).joined(separator: "")
        
        var resultToken: Token? = nil
        var moves = inlineMoveText.components(separatedBy: .whitespaces)
        
        if let resultMove = moves.popLast() {
            var isValidResult = true
            for c in resultMove {
                isValidResult = TokenType.result.isValid(character: c)
                if !isValidResult {
                    break
                }
            }
            
            if isValidResult,
               let token = TokenType.result.convert(resultMove) {
                resultToken = token
                inlineMoveText = moves.joined(separator: " ")
            }
        }
        
        var iterator = inlineMoveText.makeIterator()
        
        var tokens = [Token]()
        var currentTokenType = TokenType.none
        var currentToken = ""
        var commentDepth = 0
        
        while let c = iterator.next() {
            // Handle stateful comment parsing first.
            if c == "{" {
                if commentDepth == 0 { // Entering the outermost comment
                    // Flush any pending token before starting a comment.
                    if !currentToken.isEmpty, let token = currentTokenType.convert(currentToken) {
                        tokens.append(token)
                    }
                    currentToken = ""
                    currentTokenType = .comment
                } else { // Nested comment, '{' is part of the text
                    currentToken += String(c)
                }
                commentDepth += 1
                continue
            } else if c == "}" {
                guard commentDepth > 0 else { throw .unpairedCommentDelimiter }
                commentDepth -= 1
                
                if commentDepth == 0 { // Exiting the outermost comment
                    // Flush the completed comment token.
                    if let token = currentTokenType.convert(currentToken) {
                        tokens.append(token)
                    }
                    currentToken = ""
                    currentTokenType = .none
                } else { // Still inside a nested comment, '}' is part of the text
                    currentToken += String(c)
                }
                continue
            }
            
            // If we are inside a comment, accumulate and skip other logic.
            if commentDepth > 0 {
                currentToken += String(c)
                continue
            }
            
            // Handle token accumulation for all other types.
            if currentTokenType.isValid(character: c) {
                currentToken += String(c)
            } else {
                // Character does not match current token type, so flush the old one and start a new one.
                if !currentToken.isEmpty, let token = currentTokenType.convert(currentToken) {
                    tokens.append(token)
                }
                currentTokenType = .match(character: c)
                currentToken = String(c)
            }
        }
        
        // After the loop, ensure all comments were closed.
        guard commentDepth == 0 else { throw .unpairedCommentDelimiter }
        
        // Flush any remaining token.
        if !currentToken.isEmpty, let token = currentTokenType.convert(currentToken) {
            tokens.append(token)
        }
        
        if let resultToken {
            tokens.append(resultToken)
        }
        
        return tokens
    }

    private static func parse(
      tokens: [Token],
      startingWith position: Position
    ) throws(PGNParser.Error) -> Game {
      var game = Game(startingWith: position)
      var iterator = tokens.makeIterator()

      var currentToken = iterator.next()
      var currentMoveIndex: MoveTree.Index

      // determine if first move is white or black

      if case let .number(number) = currentToken, let n = Int(number.prefix { $0 != "." }) {
        if number.filter({ $0 == "." }).count >= 3 {
          currentMoveIndex = .init(number: n, color: .black).previous
        } else {
          currentMoveIndex = .init(number: n, color: .white).previous
        }
      } else if case let .san(san) = currentToken {
        currentMoveIndex = position.sideToMove == .white ? .minimum : .minimum.next
        if let position = game.positions[currentMoveIndex] {
          if let move = SANParser.parse(move: san, in: position) {
            currentMoveIndex = game.make(move: move, from: currentMoveIndex)
          }
        }
      } else {
        throw .unexpectedMoveTextToken
      }

      // iterate through remaining tokens

      var variationStack = Stack<MoveTree.Index>()

      while let token = iterator.next() {
        currentToken = token

        switch currentToken {
        case .none, .result, .number:
          break
        case let .san(san):
            guard let position = game.positions[currentMoveIndex] else {
                // This indicates a critical internal error, as the parser's state is inconsistent.
                throw .unexpectedMoveTextToken
            }
            
            guard let move = SANParser.parse(move: san, in: position) else {
                // The move SAN is invalid for the current board position. This is a PGN content error.
                let historyIndices = game.moves.history(for: currentMoveIndex)
                let historyMoves = historyIndices.compactMap { game.moves[$0] }
                
                var moveSequence = ""
                var moveNumber = 1
                for move in historyMoves {
                    if move.piece.color == .white {
                        moveSequence += "\(moveNumber). \(move.san) "
                    } else {
                        moveSequence += "\(move.san) "
                        moveNumber += 1
                    }
                }
                
                throw .invalidMove(san: san, fen: position.fen, moveSequence: moveSequence.trimmingCharacters(in: .whitespaces))
            }
            
            currentMoveIndex = game.make(move: move, from: currentMoveIndex)
        case let .annotation(annotation):
          if let rawValue = firstMatch(
            in: annotation, for: .numericPosition
          ), let positionAssessment = Position.Assessment(rawValue: rawValue) {
            game.annotate(
              positionAt: currentMoveIndex,
              assessment: positionAssessment
            )
            continue
          }

          var moveAssessment: Move.Assessment?

          if let notation = firstMatch(in: annotation, for: .traditional) {
            moveAssessment = .init(notation: notation)
          } else if let rawValue = firstMatch(in: annotation, for: .numericMove) {
            moveAssessment = .init(rawValue: rawValue)
          } else {
            throw .invalidAnnotation(annotation)
          }

          if let moveAssessment {
            game.annotate(moveAt: currentMoveIndex, assessment: moveAssessment)
          } else {
            throw .invalidAnnotation(annotation)
          }
        case let .comment(comment):
          game.annotate(moveAt: currentMoveIndex, comment: comment)
        case .variationStart:
          variationStack.push(currentMoveIndex)
            currentMoveIndex = game.moves.index(before: currentMoveIndex)
        case .variationEnd:
          if let index = variationStack.pop() {
            currentMoveIndex = index
          } else {
            throw .unpairedVariationDelimiter
          }
        }
      }

      return game
    }

    private static func firstMatch(in string: String, for pattern: Pattern) -> String? {
      let matches = try? NSRegularExpression(pattern: pattern.rawValue)
        .matches(in: string, range: NSRange(0..<string.utf16.count))

      if let match = matches?.first {
        return NSString(string: string).substring(with: match.range)
      } else {
        return nil
      }
    }

    private enum Pattern: String {
      /// Numeric Annotation Glyphs for moves, e.g. `$1`, `$2`, etc.
      case numericMove = #"^\$\d$"#
      /// Numeric Annotation Glyphs for positions, e.g. `$10`, `$11`, etc.
      case numericPosition = #"^\$\d{2,3}$"#
      /// Traditional suffix annotations, e.g. `!!`, `?!`, `□`, etc.
      case traditional = #"^[!?□]{1,2}$"#
    }

  }
}

// MARK: - Tokens
private extension PGNParser.MoveTextParser {
  private enum Token: Equatable {
    case number(String)
    case san(String)
    case annotation(String)
    case comment(String)
    case variationStart
    case variationEnd
    case result(String)
  }

  private enum TokenType {
    case none
    case number
    case san
    case annotation
    case variationStart
    case variationEnd
    case result
    case comment

    static func isNumber(_ character: Character) -> Bool {
      character.isWholeNumber || character == "."
    }

    static func isSAN(_ character: Character) -> Bool {
      character.isLetter || character.isWholeNumber || ["x", "+", "#", "=", "O", "o", "0", "-"].contains(character)
    }

    static func isAnnotation(_ character: Character) -> Bool {
      character.isWholeNumber || ["$", "?", "!", "□"].contains(character)
    }

    static func isVariationStart(_ character: Character) -> Bool {
      character == "("
    }

    static func isVariationEnd(_ character: Character) -> Bool {
      character == ")"
    }

    static func isResult(_ character: Character) -> Bool {
      ["1", "2", "/", "-", "0", "*", "½"].contains(character)
    }

    func isValid(character: Character) -> Bool {
      switch self {
      // .comment is handled by a separate state machine (commentDepth).
      // .variationStart and .variationEnd are single-character tokens,
      // so they can't be extended. Returning false forces the tokenizer
      // to flush the previous token and process them individually.
      case .none, .comment, .variationStart, .variationEnd:
          return false
      case .number: return Self.isNumber(character)
      case .san: return Self.isSAN(character)
      case .annotation: return Self.isAnnotation(character)
      case .result: return Self.isResult(character)
      }
    }

    static func match(character: Character) -> Self {
      if isNumber(character) {
        .number
      } else if isSAN(character) {
        .san
      } else if isAnnotation(character) {
        .annotation
      } else if isVariationStart(character) {
        .variationStart
      } else if isVariationEnd(character) {
        .variationEnd
      } else if isResult(character) {
        .result
      } else {
        // .comment is omitted from these checks because
        // it is handled separately by checking for { } delimiters
        .none
      }
    }

    func convert(_ text: String) -> Token? {
      switch self {
      case .none: nil
      case .number: .number(text.trimmingCharacters(in: .whitespaces))
      case .san: .san(text.trimmingCharacters(in: .whitespaces))
      case .annotation: .annotation(text.trimmingCharacters(in: .whitespaces))
      case .comment: .comment(text.trimmingCharacters(in: .whitespaces))
      case .variationStart: .variationStart
      case .variationEnd: .variationEnd
      case .result: .result(text.trimmingCharacters(in: .whitespaces))
      }
    }
  }
}
