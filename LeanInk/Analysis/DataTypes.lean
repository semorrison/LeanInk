import LeanInk.ListUtil
import LeanInk.Configuration

import Lean.Elab
import Lean.Data.Lsp
import Lean.Syntax

namespace LeanInk.Analysis

open Lean
open Lean.Elab
open Lean.Meta

/- Positional -/
class Positional (α : Type u) where
  headPos : α -> String.Pos
  tailPos : α -> String.Pos

namespace Positonal
  def length {α : Type u } [Positional α] (self : α) : Nat := (Positional.tailPos self) - (Positional.headPos self)
end Positonal

/- Fragment -/
/--
  A `Fragment` is a simple structure that describes an interval within the source text.
  This is similar to the `Positional` type class. However the structure is used as a parent for other structures
  in the Analysis. As a result every `Fragment` automatically conforms to `Positional`
-/
structure Fragment where
  headPos : String.Pos
  tailPos : String.Pos
  deriving Inhabited

instance : Positional Fragment where
  headPos := Fragment.headPos
  tailPos := Fragment.tailPos

/- Token -/
/--
  `TokenInfo` is the base structure of all `Token`.
  Inherently it describe the semantic info of the token, which can and should be used for semantic syntax
  highlighting.
-/
structure TokenInfo extends Fragment where
  semanticType: Option String := none
  deriving Inhabited

/--
  The `TypeTokenInfo` describes the metadata of a source text token that conforms
  to a specific type within our type system.
  E.g.: A variable token `p` might conform to type `Nat`
-/
structure TypeTokenInfo extends TokenInfo where
  type: String
  deriving Inhabited
  
/--
  The `DocStringTokenInfo` describes the metadata of an available docstring of a source text token.
  In this case a source text token may be a function or structure with a docstring.
-/
structure DocStringTokenInfo extends TokenInfo where
  docString: String
  deriving Inhabited

/-- 
  A `Token` describes the metadata of a specific range of source text.
  E.g.: a `Token.type` describes for some variable `p` that it conforms to type `Nat`.
  For every category of metadata there should be an additonal constructor with specified `TokenInfo` to make sure the
  individual tokens can be analyzed independently and only based on one aspect of metadata.
  This also prevents from having tokens with a huge amount of `Option` fields.
-/
inductive Token where
| type (info: TypeTokenInfo)
| docString (info: DocStringTokenInfo)
deriving Inhabited

instance : ToString Token where -- TODO: Improve this
  toString : Token -> String
  | Token.type _ => "Type"
  | Token.docString _ => "DocString"

namespace Token
  def toFragment : Token -> Fragment
  | type info => info.toFragment
  | docString info => info.toFragment
end Token

instance : Positional Token where
  headPos := (λ x => x.toFragment.headPos)
  tailPos := (λ x => x.toFragment.tailPos)

/- Tactics -/
structure Hypothesis where
  names : List String
  type : String
  body : String

structure Goal where
  name : String
  conclusion : String
  hypotheses : List Hypothesis

structure Tactic extends Fragment where
  goals : List Goal
  deriving Inhabited

structure Message extends Fragment where
  msg: String
  deriving Inhabited

/- Sentence -/
inductive Sentence where
| tactic (info: Tactic)
| message (info: Message)
deriving Inhabited

instance : ToString Sentence where -- TODO: Improve this
  toString : Sentence -> String
  | Sentence.tactic _ => "Type"
  | Sentence.message _ => "DocString"

namespace Sentence
  def toFragment : Sentence -> Fragment
  | tactic info => info.toFragment
  | message info => info.toFragment

  def asTactic? : Sentence -> Option Tactic
  | tactic info => info
  | _ => none

  def asMessage? : Sentence -> Option Message
  | message info => info
  | _ => none
end Sentence

instance : Positional Sentence where
  headPos := (λ x => x.toFragment.headPos)
  tailPos := (λ x => x.toFragment.tailPos)

/- InfoTree -/
structure ContextBasedInfo (β : Type) where
  ctx : ContextInfo
  info : β

inductive TraversalFragment where
| tactic (info: ContextBasedInfo TacticInfo)
| term (info: ContextBasedInfo TermInfo)
| field (info: ContextBasedInfo FieldInfo)
| unknown (info: ContextBasedInfo ElabInfo)

namespace TraversalFragment
  private def Info.stx : Info -> Syntax
  | Info.ofTacticInfo i => i.stx
  | Info.ofTermInfo i => i.stx
  | Info.ofCommandInfo i => i.stx
  | Info.ofMacroExpansionInfo i => i.stx
  | Info.ofFieldInfo i => i.stx
  | Info.ofCompletionInfo i => i.stx

  def headPos : TraversalFragment -> String.Pos
  | term fragment => (fragment.info.toElabInfo.stx.getPos? false).getD 0
  | field fragment => (fragment.info.stx.getPos? false).getD 0
  | tactic fragment => (fragment.info.toElabInfo.stx.getPos? false).getD 0
  | unknown fragment => (fragment.info.stx.getPos? false).getD 0

  def tailPos : TraversalFragment -> String.Pos
  | term fragment => (fragment.info.toElabInfo.stx.getTailPos? false).getD 0
  | field fragment => (fragment.info.stx.getTailPos? false).getD 0
  | tactic fragment => (fragment.info.toElabInfo.stx.getTailPos? false).getD 0
  | unknown fragment => (fragment.info.stx.getTailPos? false).getD 0

  private def Info.isExpanded (self : Info) : Bool :=
    let stx := Info.stx self
     match stx.getHeadInfo, stx.getTailInfo with
    | SourceInfo.original .., SourceInfo.original .. => false
    | _, _ => true

  def create (ctx : ContextInfo) (info : Info) : Option TraversalFragment :=
    if Info.isExpanded info then
      none
    else
      match info with 
      | Info.ofTacticInfo info => tactic { info := info, ctx := ctx }
      | Info.ofTermInfo info => term { info := info, ctx := ctx }
      | Info.ofFieldInfo info => field { info := info, ctx := ctx }
      | _ => none

  def runMetaM { α : Type } (func : TraversalFragment -> MetaM α) : TraversalFragment -> AnalysisM α
  | term fragment => fragment.ctx.runMetaM fragment.info.lctx (func (term fragment))
  | field fragment => fragment.ctx.runMetaM fragment.info.lctx (func (field fragment))
  | tactic fragment => fragment.ctx.runMetaM {} (func (tactic fragment))
  | unknown fragment => fragment.ctx.runMetaM {} (func (unknown fragment))

  /- 
    Token Generation
  -/
  def inferType? : TraversalFragment -> MetaM (Option String)
    | term termFragment => do
      let format ← Meta.ppExpr (← Meta.inferType termFragment.info.expr)
      return s!"{format}"
    | _ => none

  def genDocString? (self : TraversalFragment) : MetaM (Option String) := do
    let env ← getEnv
    match self with
    | term fragment =>
      if let some name := fragment.info.expr.constName? then
        findDocString? env name
      else
        none
    | field fragment => findDocString? env fragment.info.projName
    | tactic fragment =>
      let elabInfo := fragment.info.toElabInfo
      return ← findDocString? env elabInfo.elaborator <||> findDocString? env elabInfo.stx.getKind
    | unknown fragment =>
      let elabInfo := fragment.info
      return ← findDocString? env elabInfo.elaborator <||> findDocString? env elabInfo.stx.getKind

  def genDocStringTokenInfo? (self : TraversalFragment) : AnalysisM (Option DocStringTokenInfo) := do
    match ← runMetaM (genDocString?) self with
    | some string => some { headPos := self.headPos, tailPos := self.tailPos, docString := string }
    | none => none

  def genTypeTokenInfo? (self : TraversalFragment) : AnalysisM (Option TypeTokenInfo) := do
    match ← runMetaM (inferType?) self with
    | some string => some { headPos := self.headPos, tailPos := self.tailPos, type := string }
    | none => none

  def genTokens (self : TraversalFragment) : AnalysisM (List Token) := do
    let mut tokens : List Token := []
    if let some typeToken ← self.genTypeTokenInfo? then
      tokens := tokens.append [Token.type typeToken]
    if let some docStringToken ← self.genDocStringTokenInfo? then
      tokens := tokens.append [Token.docString docStringToken]
    return tokens

  /- Sentence Generation -/
  private def genGoal (goalType : Format) (hypotheses : List Hypothesis): Name -> MetaM (Goal)
    | Name.anonymous => do
      return { 
        name := ""
        conclusion := toString goalType
        hypotheses := hypotheses 
      }
    | name => do
      let goalFormatName := format name.eraseMacroScopes
      return { 
        name := toString goalFormatName
        conclusion := toString goalType
        hypotheses := hypotheses 
      }

  /-- 
  This method is a adjusted version of the Meta.ppGoal function. As we do need to extract the goal informations into seperate properties instead
  of a single formatted string to support the Alectryon.Goal datatype.
  -/
  private def evalGoal (mvarId : MVarId)  : MetaM (Option Goal) := do
    match (← getMCtx).findDecl? mvarId with
    | none => return none
    | some decl => do
      let auxDecl := pp.auxDecls.get (<- getOptions)
      let lctx := decl.lctx.sanitizeNames.run' { options := (← getOptions) }
      withLCtx lctx decl.localInstances do
        let (hidden, hiddenProp) ← ToHide.collect decl.type
        let pushPending (list : List Hypothesis) (type? : Option Expr) : List Name -> MetaM (List Hypothesis)
        | [] => pure list
        | ids => do
          match type? with
            | none      => pure list
            | some type => do
              let typeFmt ← ppExpr type
              let names ← ids.reverse.map (λ n => n.toString)
              return list.append [{ names := names, body := "", type := s!"{typeFmt}" }]
        let evalVar (varNames : List Name) (prevType? : Option Expr) (hypotheses : List Hypothesis) (localDecl : LocalDecl) : MetaM (List Name × Option Expr × (List Hypothesis)) := do
          if hiddenProp.contains localDecl.fvarId then
            let newHypotheses ← pushPending [] prevType? varNames
            let type ← instantiateMVars localDecl.type
            let typeFmt ← ppExpr type
            let newHypotheses := newHypotheses.map (λ h => { h with type := h.type ++ s!" : {typeFmt}"})
            pure ([], none, hypotheses.append newHypotheses)
          else
            match localDecl with
            | LocalDecl.cdecl _ _ varName type _ =>
              let varName := varName.simpMacroScopes
              let type ← instantiateMVars type
              if prevType? == none || prevType? == some type then
                pure (varName::varNames, some type, hypotheses)
              else do
                let hypotheses ← pushPending hypotheses prevType? varNames
                pure ([varName], some type, hypotheses)
            | LocalDecl.ldecl _ _ varName type val _ => do
              let varName := varName.simpMacroScopes
              let hypotheses ← pushPending hypotheses prevType? varNames
              let type ← instantiateMVars type
              let val  ← instantiateMVars val
              let typeFmt ← ppExpr type
              let valFmt ← ppExpr val
              pure ([], none, hypotheses.append [{ names := [varName.toString], body := s!"{valFmt}", type := s!"{typeFmt}" }])
        let (varNames, type?, hypotheses) ← lctx.foldlM (init := ([], none, [])) λ (varNames, prevType?, hypotheses) (localDecl : LocalDecl) =>
          if !auxDecl && localDecl.isAuxDecl || hidden.contains localDecl.fvarId then
            pure (varNames, prevType?, hypotheses)
          else
            evalVar varNames prevType? hypotheses localDecl
        let hypotheses ← pushPending hypotheses type? varNames 
        let typeFmt ← ppExpr (← instantiateMVars decl.type)
        return (← genGoal typeFmt hypotheses decl.userName)

  private def genGoals (contextInfo : ContextBasedInfo TacticInfo) : AnalysisM (List Goal) :=
    match contextInfo.info.goalsAfter with
    | [] => []
    | goals => do
      let ctx := { contextInfo.ctx with mctx := contextInfo.info.mctxAfter }
      return (← ctx.runMetaM {} (goals.mapM (evalGoal .))).filterMap (λ x => x)

  def genTactic? (self : TraversalFragment) : AnalysisM (Option Tactic) := do
    match self with
    | tactic fragment => do 
      let goals ← genGoals fragment
      if goals.isEmpty then
        return none
      else
        return some { headPos := self.headPos, tailPos := self.tailPos, goals := goals }
    | _ => none

  def genSentences (self : TraversalFragment) : AnalysisM (List Sentence) := do
    if let some t ← self.genTactic? then
      return [Sentence.tactic t]
    else
      return []
end TraversalFragment

/- Traversal -/
structure AnalysisResult where
  tokens : List Token
  sentences : List Sentence
  deriving Inhabited

namespace AnalysisResult
  def empty : AnalysisResult := { tokens := [], sentences := [] }

  def merge (x y : AnalysisResult) : AnalysisResult := {
    tokens := List.mergeSortedLists (λ x y => x.toFragment.headPos < y.toFragment.headPos) x.tokens y.tokens
    sentences := List.mergeSortedLists (λ x y => x.toFragment.headPos < y.toFragment.headPos) x.sentences y.sentences
  }

  def insertFragment (self : AnalysisResult) (fragment : TraversalFragment) : AnalysisM AnalysisResult := do
    let newTokens ← fragment.genTokens
    let newSentences ← fragment.genSentences
    { self with tokens := self.tokens.append newTokens, sentences := self.sentences.append newSentences }

  def Position.toStringPos (fileMap: FileMap) (pos: Position) : String.Pos :=
    FileMap.lspPosToUtf8Pos fileMap (fileMap.leanPosToLspPos pos)

  private def genMessage (fileMap : FileMap) (message : Lean.Message) : AnalysisM Message := do
    let headPos := Position.toStringPos fileMap message.pos
    let tailPos := Position.toStringPos fileMap (message.endPos.getD message.pos)
    let string ← message.toString
    return { headPos := headPos, tailPos := tailPos, msg := string }

  def insertMessages (self : AnalysisResult) (messages : List Lean.Message) (fileMap : FileMap): AnalysisM AnalysisResult := do
    let messages ← messages.mapM (genMessage fileMap)
    let sortedMessages := List.sort (λ x y => x.headPos < y.headPos) messages
    let newSentences := sortedMessages.map (λ x => Sentence.message x)
    let mergedSentences := List.mergeSortedLists (λ x y => (Positional.headPos x) < (Positional.headPos y)) newSentences self.sentences
    return { self with sentences := mergedSentences }
end AnalysisResult

structure TraversalAux where
  allowsNewTactic : Bool := true
  allowsNewField : Bool := true
  allowsNewTerm : Bool := true
  result : AnalysisResult := AnalysisResult.empty

namespace TraversalAux
  def merge (x y : TraversalAux) : TraversalAux := {
    allowsNewTactic := x.allowsNewTactic ∧ y.allowsNewTactic
    allowsNewField := x.allowsNewField ∧ y.allowsNewField
    allowsNewTerm := x.allowsNewTerm ∧ y.allowsNewTerm
    result := AnalysisResult.merge x.result y.result
  }

  def insertFragment (self : TraversalAux) (fragment : TraversalFragment) : AnalysisM TraversalAux :=
    match fragment with
    | TraversalFragment.term _ => do
      if self.allowsNewTerm then
        let newResult ← self.result.insertFragment fragment
        return { self with allowsNewTerm := false, result := newResult }
      else 
        return self
    | TraversalFragment.field _ => do
      if self.allowsNewField then
        let newResult ← self.result.insertFragment fragment
        return { self with allowsNewField := false, result := newResult }
      else 
        return self
    | TraversalFragment.tactic _ => do
      if self.allowsNewTactic then
        let newResult ← self.result.insertFragment fragment
        return { self with allowsNewTactic := false, result := newResult }
      else 
        return self
    | _=> self
end TraversalAux

partial def _resolveTacticList (ctx?: Option ContextInfo := none) (aux : TraversalAux := {}) : InfoTree -> AnalysisM TraversalAux
  | InfoTree.context ctx tree => _resolveTacticList ctx aux tree
  | InfoTree.node info children =>
    match ctx? with
    | none => aux
    | some ctx => do
      let ctx? := info.updateContext? ctx
      let resolvedChildrenLeafs ← children.toList.mapM (_resolveTacticList ctx? aux)
      let sortedChildrenLeafs := resolvedChildrenLeafs.foldl TraversalAux.merge {}
      let fragment := TraversalFragment.create ctx info
      match fragment with
      | some fragment => sortedChildrenLeafs.insertFragment fragment
      | none => sortedChildrenLeafs
  | _ => aux

def resolveTacticList (trees: List InfoTree) : AnalysisM AnalysisResult := do
  let auxResults ← (trees.map _resolveTacticList).mapM (λ x => x)
  let results := auxResults.map (λ x => x.result)
  return results.foldl AnalysisResult.merge AnalysisResult.empty