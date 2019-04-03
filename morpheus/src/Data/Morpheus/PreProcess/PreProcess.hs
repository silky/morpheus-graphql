{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module Data.Morpheus.PreProcess.PreProcess
  ( preProcessQuery
  ) where

import           Data.Morpheus.Error.Mutation           (mutationIsNotDefined)
import           Data.Morpheus.Error.Selection          (duplicateQuerySelections, hasNoSubfields, selectionError,
                                                         subfieldsNotSelected)
import           Data.Morpheus.Error.Utils              (toGQLError)
import           Data.Morpheus.PreProcess.Arguments     (validateArguments)
import           Data.Morpheus.PreProcess.Fragment      (validateFragments)
import           Data.Morpheus.PreProcess.Spread        (prepareRawSelection)
import           Data.Morpheus.PreProcess.Utils         (differKeys, existsObjectType, fieldOf)
import           Data.Morpheus.PreProcess.Variable      (validateVariables)
import           Data.Morpheus.Schema.Internal.Types    (Core (..), GObject (..), ObjectField (..), OutputObject,
                                                         TypeLib (..))
import qualified Data.Morpheus.Schema.Internal.Types    as SC (Field (..))
import           Data.Morpheus.Schema.TypeKind          (TypeKind (..))
import           Data.Morpheus.Types.Core               (EnhancedKey (..))
import           Data.Morpheus.Types.Error              (MetaValidation, Validation)
import           Data.Morpheus.Types.MetaInfo           (MetaInfo (..), Position)
import           Data.Morpheus.Types.Query.Operator     (Operator (..), RawOperator, ValidOperator)
import           Data.Morpheus.Types.Query.RawSelection (RawArguments, RawSelectionSet)
import           Data.Morpheus.Types.Query.Selection    (Selection (..), SelectionSet)
import           Data.Morpheus.Types.Types              (GQLQueryRoot (..))
import qualified Data.Set                               as S
import           Data.Text                              (Text)

asSelectionValidation :: MetaValidation a -> Validation a
asSelectionValidation = toGQLError selectionError

mapSelectors :: TypeLib -> GObject ObjectField -> SelectionSet -> Validation SelectionSet
mapSelectors typeLib type' selectors = checkDuplicatesOn type' selectors >>= mapM (validateBySchema typeLib type')

isObjectKind :: ObjectField -> Bool
isObjectKind (ObjectField _ field') = OBJECT == SC.kind field'

mustBeObject :: (Text, Position) -> ObjectField -> Validation ObjectField
mustBeObject (key', position') field' =
  if isObjectKind field'
    then pure field'
    else Left $ hasNoSubfields meta
  where
    meta = MetaInfo {position = position', key = key', typeName = SC.fieldType $ fieldContent field'}

notObject :: (Text, Position) -> ObjectField -> Validation ObjectField
notObject (key', position') field' =
  if isObjectKind field'
    then Left $ subfieldsNotSelected meta
    else pure field'
  where
    meta = MetaInfo {position = position', key = key', typeName = SC.fieldType $ fieldContent field'}

validateBySchema :: TypeLib -> GObject ObjectField -> (Text, Selection) -> Validation (Text, Selection)
validateBySchema lib' (GObject parentFields core) (name', SelectionSet args' selectors sPos) = do
  field' <- asSelectionValidation (fieldOf (sPos, name core) parentFields name') >>= mustBeObject (name', sPos)
  typeSD <- asSelectionValidation $ existsObjectType (sPos, name') (SC.fieldType $ fieldContent field') lib'
  headQS <- validateArguments lib' (name', field') sPos args'
  selectorsQS <- mapSelectors lib' typeSD selectors
  pure (name', SelectionSet headQS selectorsQS sPos)
validateBySchema typeLib (GObject parentFields core) (name', Field args' field sPos) = do
  field' <- asSelectionValidation (fieldOf (sPos, name core) parentFields name') >>= notObject (name', sPos)
  headQS <- validateArguments typeLib (name', field') sPos args'
  pure (name', Field headQS field sPos)

selToKey :: (Text, Selection) -> EnhancedKey
selToKey (sName, Field _ _ pos)        = EnhancedKey sName pos
selToKey (sName, SelectionSet _ _ pos) = EnhancedKey sName pos

checkDuplicatesOn :: GObject ObjectField -> SelectionSet -> Validation SelectionSet
checkDuplicatesOn (GObject _ core) keys =
  case differKeys enhancedKeys noDuplicates of
    []         -> pure keys
    duplicates -> Left $ duplicateQuerySelections (name core) duplicates
  where
    enhancedKeys = map selToKey keys
    noDuplicates = S.toList $ S.fromList (map fst keys)

updateQuery :: RawOperator -> SelectionSet -> ValidOperator
updateQuery (Query name' _ _ pos) sel    = Query name' [] sel pos
updateQuery (Mutation name' _ _ pos) sel = Mutation name' [] sel pos

fieldSchema :: [(Text, ObjectField)]
fieldSchema =
  [ ( "__schema"
    , ObjectField
        { args = []
        , fieldContent =
            SC.Field
              { SC.fieldName = "__schema"
              , SC.notNull = True
              , SC.asList = False
              , SC.kind = OBJECT
              , SC.fieldType = "__Schema"
              }
        })
  ]

setFieldSchema :: GObject ObjectField -> GObject ObjectField
setFieldSchema (GObject fields core) = GObject (fields ++ fieldSchema) core

getOperator :: RawOperator -> TypeLib -> Validation (OutputObject, RawArguments, RawSelectionSet)
getOperator (Query _ args' sel _) lib' = pure (snd $ query lib', args', sel)
getOperator (Mutation _ args' sel position') lib' =
  case mutation lib' of
    Just (_, mutation') -> pure (mutation', args', sel)
    Nothing             -> Left $ mutationIsNotDefined position'

preProcessQuery :: TypeLib -> GQLQueryRoot -> Validation ValidOperator
preProcessQuery lib root = do
  (query', args', rawSel) <- getOperator (queryBody root) lib
  validateVariables lib root args'
  validateFragments lib root
  sel <- prepareRawSelection root rawSel
  selectors <- mapSelectors lib (setFieldSchema query') sel
  pure $ updateQuery (queryBody root) selectors