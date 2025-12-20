//
//  MoveTree.swift
//  ChessKit
//

import Foundation

/// A tree-like data structure that represents the moves of a chess game.
///
/// The tree maintains the move order including variations and
/// provides index-based access for any element in the tree.
public struct MoveTree: Codable, Hashable, Sendable {

  /// The index of the root of the move tree.
  ///
  /// Defaults to `MoveTree.Index.minimum`.
  var minimumIndex: Index

  /// The last index of the main variation of the move tree.
  private(set) var lastMainVariationIndex: Index

  /// Dictionary representation of the tree for faster access.
  private(set) var dictionary: [Index: Node]
    
  /// A cache of all leaf node indices for efficient line generation.
  private(set) var leafNodeIndices: Set<Index> = []

  /// The root node of the tree, a dummy node representing the beginning of the game.
  private var rootNode: Node { dictionary[minimumIndex]! }

  /// A dummy move to associate with the `rootNode`.
  private static var dummyMove: Move {
    let dummyPiece = Piece(.pawn, color: .white, square: .a1)
    return Move(result: .move, piece: dummyPiece, start: .a1, end: .a1)
  }

  public init(startingAt index: Index = .minimum) {
    self.minimumIndex = index
    self.lastMainVariationIndex = index

    let dummyNode = Node(move: Self.dummyMove)
    dummyNode.index = index
    self.dictionary = [index: dummyNode]
    self.leafNodeIndices = []
  }

  private enum CodingKeys: String, CodingKey {
    case minimumIndex, lastMainVariationIndex, dictionary, leafNodeIndices
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.minimumIndex = try container.decodeIfPresent(Index.self, forKey: .minimumIndex) ?? .minimum
    self.lastMainVariationIndex = try container.decodeIfPresent(Index.self, forKey: .lastMainVariationIndex) ?? self.minimumIndex
    self.dictionary = try container.decode([Index: Node].self, forKey: .dictionary)

    if self.dictionary[minimumIndex] == nil {
      let dummyNode = Node(move: Self.dummyMove)
      dummyNode.index = minimumIndex
      self.dictionary[minimumIndex] = dummyNode

      let oldRoots = dictionary.values.filter { $0.previous == nil }

      if let firstOldRoot = oldRoots.first {
        dummyNode.next = firstOldRoot
        firstOldRoot.previous = dummyNode

        oldRoots.dropFirst().forEach { variationRoot in
          dummyNode.children.append(variationRoot)
          variationRoot.previous = dummyNode
        }
      }
    }
      
    // Decode the leaf node cache if available; otherwise, rebuild it.
    if let leaves = try container.decodeIfPresent(Set<Index>.self, forKey: .leafNodeIndices) {
        self.leafNodeIndices = leaves
    } else {
        // Rebuild the cache for older data formats.
        var parentIndices: Set<Index> = [minimumIndex]
        for node in dictionary.values {
            if node.next != nil || !node.children.isEmpty {
                parentIndices.insert(node.index)
            }
        }
        let allIndices = Set(dictionary.keys)
        self.leafNodeIndices = allIndices.subtracting(parentIndices)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(minimumIndex, forKey: .minimumIndex)
    try container.encode(lastMainVariationIndex, forKey: .lastMainVariationIndex)
    try container.encode(dictionary, forKey: .dictionary)
    try container.encode(leafNodeIndices, forKey: .leafNodeIndices)
  }

  /// A set containing the indices of all the moves stored in the tree.
  public var indices: [Index] {
    Array(dictionary.keys)
  }

  /// Lock to restrict modification of tree nodes
  /// to ensure `Sendable` conformance for ``Node``.
  private static let nodeLock = NSLock()

  /// Adds a move to the move tree.
  ///
  /// - parameter move: The move to add to the tree.
  /// - parameter moveIndex: The `MoveIndex` of the parent move, if applicable.
  /// If `moveIndex` is `nil`, the move is added as a child of the root,
  /// representing a first move or a variation on the first move.
  ///
  /// - returns: The move index resulting from the addition of the move.
  ///
  @discardableResult
  public mutating func add(
    move: Move,
    toParentIndex moveIndex: Index? = nil
  ) -> Index {
    let newNode = Node(move: move)
    let parentIndex = moveIndex ?? minimumIndex
    guard let parent = dictionary[parentIndex] else {
        // This case should ideally not happen if the caller provides valid indices.
        // A fatal error is appropriate here because the tree is in an inconsistent state.
        fatalError("CRITICAL: Parent node not found at index \(parentIndex) when trying to add move \(move.san).")
    }

    newNode.previous = parent

    // First, find a unique index for the new node.
    // Start with the logical next index and increment the variation
    // number until an unused index is found.
    var newIndex = parentIndex.next
    while dictionary[newIndex] != nil {
      newIndex.variation += 1
    }

    // Now, attach the node to the tree structure.
    // If the parent has no main line continuation, this new node becomes it.
    if parent.next == nil {
      parent.next = newNode
    } else {
      // Otherwise, the parent already has a main line continuation,
      // so this new node is an alternative variation.
      parent.children.append(newNode)
    }

    // Assign the determined unique index to the new node.
    newNode.index = newIndex

    Self.nodeLock.withLock {
      dictionary[newIndex] = newNode
    }
      
    // Update leaf node cache: the new node is a leaf, and its parent is not.
    leafNodeIndices.insert(newIndex)
    if parentIndex != minimumIndex {
        leafNodeIndices.remove(parentIndex)
    }

    if newIndex.variation == Index.mainVariation {
      lastMainVariationIndex = newIndex
    }

    return newIndex
  }
    
    /// Removes a node and its entire subsequent variation from the tree.
    ///
    /// - Note: Removing a node will also remove its entire line of subsequent
    ///   moves (`.next`) and all alternative variations (`.children`).
    ///
    /// - parameter index: The index of the node to remove.
    public mutating func remove(nodeAt index: Index) {
        // Guard against removing the root or a non-existent node.
        guard let nodeToRemove = dictionary[index], index != minimumIndex else {
            return
        }

        // A node must have a parent unless it's the root, which is handled by the guard above.
        guard let parent = nodeToRemove.previous else {
            // This implies an inconsistent tree state.
            return
        }

        // 1. Collect all descendant nodes to be removed using a breadth-first search.
        var indicesToRemove = Set<Index>()
        var queue = [nodeToRemove]

        while !queue.isEmpty {
            let currentNode = queue.removeFirst()
            indicesToRemove.insert(currentNode.index)

            if let nextNode = currentNode.next {
                queue.append(nextNode)
            }
            queue.append(contentsOf: currentNode.children)
        }

        Self.nodeLock.withLock {
            // 2. Update the parent's links.
            if parent.next === nodeToRemove {
                // The removed node was the main continuation. Promote a child if possible.
                if let firstChild = parent.children.first {
                    parent.next = firstChild
                    parent.children.removeFirst()
                } else {
                    // No children to promote, so the parent's main line ends here.
                    parent.next = nil
                }
            } else {
                // The removed node was a side variation. Remove it from the children array.
                parent.children.removeAll { $0 === nodeToRemove }
            }

            // 3. Remove all collected nodes from the dictionary.
            indicesToRemove.forEach { dictionary.removeValue(forKey: $0) }
        }

        // 4. Update the leaf node cache.
        leafNodeIndices.subtract(indicesToRemove)

        // The parent might have become a new leaf node if it has no more children.
        if parent.index != minimumIndex && parent.next == nil && parent.children.isEmpty {
            leafNodeIndices.insert(parent.index)
        }

        // 5. Recalculate the last main variation index, as it could have been part of the removed branch.
        // This is the most robust way to ensure correctness after any removal.
        var newLastMainIndex = minimumIndex
        var currentNode = rootNode.next
        while let node = currentNode {
            newLastMainIndex = node.index
            currentNode = node.next
        }
        self.lastMainVariationIndex = newLastMainIndex
    }
    
    /// Returns all complete lines of play by using the cached leaf nodes and tracing their history to the root.
    public var allLines: [[Index]] {
        // Sort indices for deterministic output, which aids in testing and consistency.
        leafNodeIndices.sorted().map { history(for: $0) }
    }

  /// Returns the index matching `move` in the next or child moves of the
  /// move contained at `index`.
  public func nextIndex(containing move: Move, for index: Index) -> Index? {
    guard let node = dictionary[index] else {
      return nil
    }

    if let next = node.next, next.move == move {
      return next.index
    } else {
      return node.children.first { $0.move == move }?.index
    }
  }

  /// Provides a single history for a given index.
  ///
  /// - parameter index: The index from which to generate the history.
  /// - returns: An array of move indices sorted from beginning to end with
  /// the end being the provided `index`. An empty array is returned if
  /// `index` is the `minimumIndex`.
  ///
  /// For chess this would represent an array of all the move indices
  /// from the starting move until the move defined by `index`, accounting
  /// for any branching variations in between.
  public func history(for index: Index) -> [Index] {
    guard let startNode = dictionary[index], index != minimumIndex else { return [] }

    var currentNode: Node? = startNode
    var history: [Index] = []

    while let node = currentNode, node.index != minimumIndex {
      history.append(node.index)
      currentNode = node.previous
    }

    return history.reversed()
  }

  /// Provides a single future for a given index.
  ///
  /// - parameter index: The index from which to generate the future.
  /// - returns: An array of move indices sorted from beginning to end.
  ///
  /// For chess this would represent an array of all the move indices
  /// from the move after the move defined by `index` to the last move
  /// of the variation.
  public func future(for index: Index) -> [Index] {
    var currentNode = dictionary[index]
    var future: [Index] = []

    while currentNode != nil {
      currentNode = currentNode?.next

      if let node = currentNode {
        future.append(node.index)
      }
    }

    return future
  }

  /// Returns the full variation for a move at the provided `index`.
  ///
  /// This returns the sum of `history(for:)` and `future(for:)`.
  public func fullVariation(for index: Index) -> [Index] {
    history(for: index) + future(for: index)
  }

  /// Returns the indices of all immediate child variations for a given parent index.
  ///
  /// - parameter parentIndex: The index of the parent move.
  /// - returns: An array of move indices for all direct variations, sorted.
  public func variations(for parentIndex: Index) -> [Index] {
      guard let parentNode = dictionary[parentIndex] else {
          return []
      }

      var childIndices: [Index] = []

      if let nextNode = parentNode.next {
          childIndices.append(nextNode.index)
      }

      childIndices.append(contentsOf: parentNode.children.map { $0.index })

      return childIndices.sorted()
  }

  private func indices(between start: Index, and end: Index) -> [Index] {
    var result = [Index]()

    let endNode = dictionary[end]
    var currentNode = dictionary[start]

    while currentNode != endNode {
      if let currentNode {
        result.append(currentNode.index)
      }

      currentNode = currentNode?.previous
    }

    return result
  }

  /// Provides the shortest path through the move tree
  /// from the given start and end indices.
  ///
  /// - parameter startIndex: The starting index of the path.
  /// - parameter endIndex: The ending index of the path.
  /// - returns: An array of indices starting with the index after `startIndex`
  /// and ending with `endIndex`. If `startIndex` and `endIndex`
  /// are the same, an empty array is returned.
  ///
  /// The purpose of this path is return the indices of the moves required to
  /// go from the current position at `startIndex` and end up with the
  /// final position at `endIndex`, so `startIndex` is included in the returned
  /// array, but `endIndex` is not. The path direction included with the index
  /// indicates the direction to move to get to the next index.
  public func path(
    from startIndex: Index,
    to endIndex: Index
  ) -> [(direction: PathDirection, index: Index)] {
    if startIndex == endIndex { return [] }

    if startIndex == minimumIndex {
      return history(for: endIndex).map { (.forward, $0) }
    }
    if endIndex == minimumIndex {
      return history(for: startIndex).reversed().map { (.reverse, $0) }
    }

    var results = [(PathDirection, Index)]()
    let startHistory = history(for: startIndex)
    let endHistory = history(for: endIndex)

    if startHistory.contains(endIndex) {
      results = indices(between: startIndex, and: endIndex)
        .map { (.reverse, $0) }
    } else if endHistory.contains(startIndex) {
      results = indices(between: endIndex, and: startIndex)
        .map { (.forward, $0) }
        .reversed()
    } else {
      // lowest common ancestor
      guard
        let lca = zip(startHistory, endHistory).filter({ $0 == $1 }).last?.0,
        let startLCAIndex = startHistory.firstIndex(where: { $0 == lca }),
        let endLCAIndex = endHistory.firstIndex(where: { $0 == lca })
      else {
        // If no common ancestor, it means they branch from the root.
        let reversePath = startHistory.reversed().map { (PathDirection.reverse, $0) }
        let forwardPath = endHistory.map { (PathDirection.forward, $0) }
        return reversePath + forwardPath
      }

      let startToLCAPath = startHistory[startLCAIndex...]
        .reversed()  // reverse since history is in ascending order
        .dropLast()  // drop LCA; to be included in the next array
        .map { (PathDirection.reverse, $0) }

      let LCAtoEndPath = endHistory[endLCAIndex...]
        .map { (PathDirection.forward, $0) }

      results = startToLCAPath + LCAtoEndPath
    }

    return results
  }

  /// The direction of the ``MoveTree`` path.
  public enum PathDirection: Sendable {
    /// Move forward (i.e. perform a move).
    case forward
    /// Move backward (i.e. undo a move).
    case reverse
  }

  /// Whether the tree is empty or not.
  public var isEmpty: Bool {
    rootNode.next == nil && rootNode.children.isEmpty
  }

  /// Annotates the move at the provided index.
  ///
  /// - parameter index: The index of the move to annotate.
  /// - parameter assessment: The assessment to annotate the move with.
  /// - parameter comment: The comment to annotate the move with.
  ///
  /// - returns: The move updated with the given annotations.
  ///
  @discardableResult
  public mutating func annotate(
    moveAt index: Index,
    assessment: Move.Assessment = .null,
    comment: String = ""
  ) -> Move? {
    Self.nodeLock.withLock {
      dictionary[index]?.move.assessment = assessment
      dictionary[index]?.move.comment = comment
    }
    return dictionary[index]?.move
  }

  /// Annotates the position at the provided index.
  ///
  /// - parameter index: The index of the position to annotate.
  /// - parameter assessment: The assessment to annotate the position with.
  ///
  /// This value is stored in the move tree to generate an accurate
  /// PGN representation with `MoveTree.pgnRepresentation`.
  ///
  public mutating func annotate(
    positionAt index: Index,
    assessment: Position.Assessment
  ) {
    Self.nodeLock.withLock {
      dictionary[index]?.positionAssessment = assessment
    }
  }

  // MARK: - PGN

  /// An element for representing the ``MoveTree`` in
  /// PGN (Portable Game Notation) format.
  public enum PGNElement: Hashable, Sendable {
    /// e.g. `1.`
    case whiteNumber(Int)
    /// e.g. `1...`
    case blackNumber(Int)
    /// e.g. `e4`
    case move(Move, Index)
    /// e.g. `$10`
    case positionAssessment(Position.Assessment)
    /// e.g. `(`
    case variationStart
    /// e.g. `)`
    case variationEnd
  }

  private func pgn(for node: Node?) -> [PGNElement] {
    guard let node else { return [] }
    var result: [PGNElement] = []

    switch node.index.color {
    case .white:
      result.append(.whiteNumber(node.index.number))
    case .black:
      result.append(.blackNumber(node.index.number))
    }

    result.append(.move(node.move, node.index))
    if node.positionAssessment != .null {
      result.append(.positionAssessment(node.positionAssessment))
    }

    var iterator = node.next?.makeIterator()
    var previousIndex = node.index

    while let currentNode = iterator?.next() {
      let currentIndex = currentNode.index

      switch (previousIndex.number, currentIndex.number) {
      case let (x, y) where x < y:
        result.append(.whiteNumber(currentIndex.number))
      default:
        break
      }

      result.append(.move(currentNode.move, currentIndex))

      if currentNode.positionAssessment != .null {
        result.append(.positionAssessment(currentNode.positionAssessment))
      }

      // recursively generate PGN for all child nodes
      currentNode.previous?.children.forEach { child in
        result.append(.variationStart)
        result.append(contentsOf: pgn(for: child))
        result.append(.variationEnd)
      }

      previousIndex = currentIndex
    }

    return result
  }

  /// Returns the ``MoveTree`` as an array of PGN
  /// (Portable Game Format) elements.
  public var pgnRepresentation: [PGNElement] {
    // 1. Get the PGN for the main line starting from the first move.
    var result = pgn(for: rootNode.next)

    // Early exit if there are no variations on the first move.
    guard !rootNode.children.isEmpty else {
        return result
    }

    // 2. Find the insertion point. It's after the first move and its assessment.
    var insertionIndex: Int
    if let firstMoveIndex = result.firstIndex(where: { if case .move = $0 { return true }; return false }) {
        insertionIndex = firstMoveIndex + 1
        // Check for a position assessment immediately following the move.
        if insertionIndex < result.count, case .positionAssessment = result[insertionIndex] {
            insertionIndex += 1
        }
    } else {
        // If there's no first move (empty game), the insertion index is just the end.
        insertionIndex = result.endIndex
    }

    // 3. Generate the PGN for the variations on the first move.
    var rootVariations: [PGNElement] = []
    rootNode.children.forEach { child in
      rootVariations.append(.variationStart)
      rootVariations.append(contentsOf: pgn(for: child))
      rootVariations.append(.variationEnd)
    }

    // 4. Insert the variations at the correct spot.
    result.insert(contentsOf: rootVariations, at: insertionIndex)

    return result
  }

}

// MARK: - Equatable
extension MoveTree: Equatable {

  public static func == (lhs: MoveTree, rhs: MoveTree) -> Bool {
    lhs.dictionary == rhs.dictionary && lhs.leafNodeIndices == rhs.leafNodeIndices
  }

}

// MARK: - Node
extension MoveTree {

  /// Object that represents a node in the move tree.
  class Node: Codable, Hashable, @unchecked Sendable, Sequence {

    /// The move for this node.
    var move: Move
    /// The position assessment for this node.
    var positionAssessment = Position.Assessment.null
    /// The index for this node.
    fileprivate(set) var index: Index
    /// The previous node.
    fileprivate(set) var previous: Node?
    /// The next node.
    fileprivate(set) weak var next: Node?
    /// Children nodes (i.e. variation moves).
    fileprivate var children: [Node] = []

    fileprivate init(move: Move) {
      self.move = move
      self.index = .minimum // Default value
    }

    // MARK: Equatable
    static func == (lhs: Node, rhs: Node) -> Bool {
      lhs.index == rhs.index && lhs.move == rhs.move
    }

    // MARK: Hashable
    func hash(into hasher: inout Hasher) {
      hasher.combine(move)
      hasher.combine(index)
      hasher.combine(previous)
      hasher.combine(next)
      hasher.combine(children)
    }

    // MARK: Sequence
    func makeIterator() -> NodeIterator {
      .init(start: self)
    }

  }

  struct NodeIterator: IteratorProtocol {
    private var current: Node?

    init(start: Node?) {
      current = start
    }



    mutating func next() -> Node? {
      defer { current = current?.next }
      return current
    }
  }

}
