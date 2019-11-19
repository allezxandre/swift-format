//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftFormatCore
import SwiftSyntax

/// Cases that contain only the `fallthrough` statement are forbidden.
///
/// Lint: Cases containing only the `fallthrough` statement yield a lint error.
///
/// Format: The fallthrough `case` is added as a prefix to the next case unless the next case is
///         `default`; in that case, the fallthrough `case` is deleted.
///
/// - SeeAlso: https://google.github.io/swift#fallthrough-in-switch-statements
public final class NoCasesWithOnlyFallthrough: SyntaxFormatRule {

  public override func visit(_ node: SwitchCaseListSyntax) -> Syntax {
    var newChildren: [Syntax] = []
    var fallthroughOnlyCasesAndLabels: [(case: SwitchCaseSyntax, label: SwitchCaseLabelSyntax)] = []

    /// Flushes any un-collapsed violations to the new cases list.
    func flushViolations() {
      fallthroughOnlyCasesAndLabels.forEach {
        newChildren.append(super.visit($0.case))
      }
      fallthroughOnlyCasesAndLabels.removeAll()
    }

    for element in node {
      guard let switchCase = element as? SwitchCaseSyntax else {
        // If the element isn't a `SwitchCaseSyntax`, it might be an `#if` block surrounding some
        // conditional cases. Just add it to the list of new cases and then reset our current list
        // of violations because this partitions the cases into sets that we can't merge between.
        flushViolations()
        newChildren.append(visit(element))
        continue
      }

      if isFallthroughOnly(switchCase), let label = switchCase.label as? SwitchCaseLabelSyntax {
        // If the case is fallthrough-only, store it as a violation that we will merge later.
        diagnose(.collapseCase(name: "\(label)"), on: switchCase)
        fallthroughOnlyCasesAndLabels.append((case: switchCase, label: label))
      } else {
        guard fallthroughOnlyCasesAndLabels.count > 0 else {
          // If there are no violations recorded, just append the case. There's nothing we can try
          // to merge into it.
          newChildren.append(visit(switchCase))
          continue
        }

        // We have a case that's not fallthrough-only, and a list of fallthrough-only cases before
        // it. Merge them and add the result to the new list.
        var collapsedCase: SwitchCaseSyntax

        if let label = switchCase.label as? SwitchCaseLabelSyntax {
          if retrieveNumericCaseValue(caseLabel: label) != nil {
            collapsedCase = collapseIntegerCases(
              violations: fallthroughOnlyCasesAndLabels.lazy.map { $0.label },
              validCaseLabel: label,
              validCase: switchCase)
          } else {
            collapsedCase = collapseNonIntegerCases(
              violations: fallthroughOnlyCasesAndLabels.lazy.map { $0.label },
              validCaseLabel: label,
              validCase: switchCase)
          }
        } else {
          collapsedCase = switchCase
        }

        // Only the first violation case can have displaced trivia, because any non-whitespace
        // trivia in the other violation cases would've prevented collapsing.
        if let displacedLeadingTrivia =
          fallthroughOnlyCasesAndLabels.first?.1.leadingTrivia?.withoutLastLine()
        {
          let existingLeadingTrivia = collapsedCase.leadingTrivia ?? []
          let mergedLeadingTrivia = displacedLeadingTrivia + existingLeadingTrivia
          collapsedCase = collapsedCase.withLeadingTrivia(mergedLeadingTrivia)
        }

        newChildren.append(visit(collapsedCase))
        fallthroughOnlyCasesAndLabels.removeAll()
      }
    }

    // Flush violations at the end of a list so we don't lose cases that won't get merged with
    // anything.
    flushViolations()

    return SyntaxFactory.makeSwitchCaseList(newChildren)
  }

  /// Returns whether the given `SwitchCaseSyntax` contains only a fallthrough statement.
  /// - Parameter switchCase: A syntax node describing a case in a switch statement.
  private func isFallthroughOnly(_ switchCase: SwitchCaseSyntax) -> Bool {
    // When there are any additional or non-fallthrough statements, it isn't only a fallthrough.
    guard let onlyStatement = switchCase.statements.firstAndOnly,
      onlyStatement.item is FallthroughStmtSyntax
    else {
      return false
    }

    // Check for any comments that are adjacent to the case or fallthrough statement.
    if let leadingTrivia = switchCase.leadingTrivia,
      leadingTrivia.drop(while: { !$0.isNewline }).contains(where: { $0.isComment })
    {
      return false
    }
    if let leadingTrivia = onlyStatement.leadingTrivia,
      leadingTrivia.drop(while: { !$0.isNewline }).contains(where: { $0.isComment })
    {
      return false
    }

    // Check for any comments that are inline on the fallthrough statement. Inline comments are
    // always stored in the next token's leading trivia.
    if let nextLeadingTrivia = onlyStatement.nextToken?.leadingTrivia,
      nextLeadingTrivia.prefix(while: { !$0.isNewline }).contains(where: { $0.isComment })
    {
      return false
    }
    return true
  }

  // Puts all given cases on one line with range operator or commas
  private func collapseIntegerCases<Labels: Sequence>(
    violations: Labels,
    validCaseLabel: SwitchCaseLabelSyntax, validCase: SwitchCaseSyntax
  ) -> SwitchCaseSyntax where Labels.Element == SwitchCaseLabelSyntax {
    var isConsecutive = true
    var index = 0
    var caseNums: [Int] = []

    for item in violations {
      guard let caseNum = retrieveNumericCaseValue(caseLabel: item) else { continue }
      caseNums.append(caseNum)
    }

    guard let validCaseNum = retrieveNumericCaseValue(caseLabel: validCaseLabel) else {
      return validCase
    }
    caseNums.append(validCaseNum)

    while index <= caseNums.count - 2, isConsecutive {
      isConsecutive = caseNums[index] + 1 == caseNums[index + 1]
      index += 1
    }

    var newCaseItems: [CaseItemSyntax] = []
    let first = caseNums[0]
    let last = caseNums[caseNums.count - 1]
    if isConsecutive {
      // Create a case with a sequence expression based on the new range
      let start = SyntaxFactory.makeIntegerLiteralExpr(
        digits: SyntaxFactory.makeIntegerLiteral("\(first)"))
      let end = SyntaxFactory.makeIntegerLiteralExpr(
        digits: SyntaxFactory.makeIntegerLiteral("\(last)"))
      let newExpList = SyntaxFactory.makeExprList(
        [
          start,
          SyntaxFactory.makeBinaryOperatorExpr(
            operatorToken:
              SyntaxFactory.makeUnspacedBinaryOperator("...")),
          end,
        ])
      let newExpPat = SyntaxFactory.makeExpressionPattern(
        expression: SyntaxFactory.makeSequenceExpr(elements: newExpList))
      newCaseItems.append(
        SyntaxFactory.makeCaseItem(pattern: newExpPat, whereClause: nil, trailingComma: nil))
    } else {
      // Add each case item separated by a comma
      for num in caseNums {
        let newExpPat = SyntaxFactory.makeExpressionPattern(
          expression: SyntaxFactory.makeIntegerLiteralExpr(
            digits: SyntaxFactory.makeIntegerLiteral("\(num)")))
        let trailingComma = SyntaxFactory.makeCommaToken(trailingTrivia: .spaces(1))
        let newCaseItem = SyntaxFactory.makeCaseItem(
          pattern: newExpPat,
          whereClause: nil,
          trailingComma: num == last ? nil : trailingComma
        )
        newCaseItems.append(newCaseItem)
      }
    }
    let caseItemList = SyntaxFactory.makeCaseItemList(newCaseItems)
    return validCase.withLabel(validCaseLabel.withCaseItems(caseItemList))
  }

  // Gets integer value from case label, if possible
  private func retrieveNumericCaseValue(caseLabel: SwitchCaseLabelSyntax) -> Int? {
    if let firstTok = caseLabel.caseItems.firstToken, let num = Int(firstTok.text) {
      return num
    }
    return nil
  }

  // Puts all given cases on one line separated by commas
  private func collapseNonIntegerCases<Labels: Sequence>(
    violations: Labels,
    validCaseLabel: SwitchCaseLabelSyntax, validCase: SwitchCaseSyntax
  ) -> SwitchCaseSyntax where Labels.Element == SwitchCaseLabelSyntax {
    var newCaseItems: [CaseItemSyntax] = []
    for violation in violations {
      for item in violation.caseItems {
        let newCaseItem = item.withTrailingComma(
          SyntaxFactory.makeCommaToken(trailingTrivia: .spaces(1)))
        newCaseItems.append(newCaseItem)
      }
    }
    for item in validCaseLabel.caseItems {
      newCaseItems.append(item)
    }
    let caseItemList = SyntaxFactory.makeCaseItemList(newCaseItems)
    return validCase.withLabel(validCaseLabel.withCaseItems(caseItemList))
  }
}

extension TriviaPiece {
  /// Returns whether this piece is any type of comment.
  var isComment: Bool {
    switch self {
    case .lineComment, .blockComment, .docLineComment, .docBlockComment:
      return true
    default:
      return false
    }
  }

  /// Returns whether this piece is a number of newlines.
  var isNewline: Bool {
    switch self {
    case .newlines:
      return true
    default:
      return false
    }
  }
}

extension Diagnostic.Message {
  static func collapseCase(name: String) -> Diagnostic.Message {
    return .init(.warning, "combine fallthrough-only case \(name) with a following case")
  }
}
