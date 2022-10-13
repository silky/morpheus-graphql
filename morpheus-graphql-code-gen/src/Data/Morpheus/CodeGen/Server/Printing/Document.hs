{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Morpheus.CodeGen.Server.Printing.Document
  ( renderDocument,
  )
where

import Data.ByteString.Lazy.Char8 (ByteString)
import Data.Morpheus.CodeGen.Internal.AST (CodeGenTypeName (..))
import Data.Morpheus.CodeGen.Printer
  ( Printer (..),
    ignore,
    optional,
    renderExtension,
    renderImport,
    unpack,
  )
import Data.Morpheus.CodeGen.Server.Internal.AST
  ( GQLTypeDefinition (..),
    Kind (..),
    ModuleDefinition (..),
    ServerDeclaration (..),
    ServerDirectiveUsage (..),
    TypeKind,
  )
import Data.Text
  ( pack,
  )
import qualified Data.Text.Lazy as LT
  ( fromStrict,
  )
import Data.Text.Lazy.Encoding (encodeUtf8)
import Prettyprinter
  ( Doc,
    align,
    indent,
    line,
    pretty,
    punctuate,
    tupled,
    vsep,
    (<+>),
  )
import Relude hiding (ByteString, encodeUtf8, optional, print)

renderDocument :: String -> [ServerDeclaration] -> ByteString
renderDocument moduleName types =
  encodeUtf8 $
    LT.fromStrict $
      pack $
        show $
          renderModuleDefinition
            ModuleDefinition
              { moduleName = pack moduleName,
                imports =
                  [ ("Data.Data", ["Typeable"]),
                    ("Data.Morpheus.Kind", ["TYPE"]),
                    ("Data.Morpheus.Types", ["*"]),
                    ("Data.Morpheus", []),
                    ("Data.Text", ["Text"]),
                    ("GHC.Generics", ["Generic"])
                  ],
                extensions =
                  [ "DeriveGeneric",
                    "TypeFamilies",
                    "OverloadedStrings",
                    "DataKinds",
                    "DuplicateRecordFields"
                  ],
                types
              }

renderModuleDefinition :: ModuleDefinition -> Doc n
renderModuleDefinition
  ModuleDefinition
    { extensions,
      moduleName,
      imports,
      types
    } =
    vsep (map renderExtension extensions)
      <> line
      <> line
      <> "module"
      <+> pretty moduleName
      <+> "where"
        <> line
        <> line
        <> vsep (map renderImport imports)
        <> line
        <> line
        <> either (error . show) id (renderTypes types)

type Result = Either Text

renderTypes :: [ServerDeclaration] -> Either Text (Doc ann)
renderTypes = fmap vsep . traverse render

class RenderType a where
  render :: a -> Result (Doc ann)

instance RenderType ServerDeclaration where
  render InterfaceType {} = fail "not supported"
  -- TODO: on scalar we should render user provided type
  render ScalarType {scalarTypeName} =
    pure $ "type" <+> ignore (print scalarTypeName) <+> "= Int"
  render (DataType cgType) = pure (pretty cgType)
  render (GQLTypeInstance gqlType) = pure $ renderGQLType gqlType
  render (GQLDirectiveInstance _) = fail "not supported"

renderTypeableConstraints :: [Text] -> Doc n
renderTypeableConstraints xs = tupled (map (("Typeable" <+>) . pretty) xs) <+> "=>"

defineTypeOptions :: Maybe (TypeKind, Text) -> [Doc n]
defineTypeOptions (Just (kind, tName)) = ["typeOptions _ = dropNamespaceOptions" <+> "(" <> pretty (show kind :: String) <> ")" <+> pretty (show tName :: String)]
defineTypeOptions _ = []

renderGQLType :: GQLTypeDefinition -> Doc ann
renderGQLType gql@GQLTypeDefinition {..}
  | gqlKind == Scalar = ""
  | otherwise =
      "instance"
        <> optional renderTypeableConstraints (typeParameters gqlTarget)
        <+> "GQLType"
        <+> typeHead
        <+> "where"
          <> line
          <> indent 2 (vsep (renderMethods typeHead gql <> defineTypeOptions dropNamespace))
  where
    typeHead = unpack (print gqlTarget)

renderMethods :: Doc n -> GQLTypeDefinition -> [Doc n]
renderMethods typeHead GQLTypeDefinition {..} =
  ["type KIND" <+> typeHead <+> "=" <+> pretty gqlKind]
    <> ["directives _=" <+> renderDirectiveUsages gqlTypeDirectiveUses | not (null gqlTypeDirectiveUses)]

renderDirectiveUsages :: [ServerDirectiveUsage] -> Doc n
renderDirectiveUsages = align . vsep . punctuate " <>" . map pretty