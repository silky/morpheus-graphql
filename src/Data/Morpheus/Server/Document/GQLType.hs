{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Morpheus.Server.Document.GQLType
  ( deriveGQLType,
  )
where

--
-- MORPHEUS
import Data.Morpheus.Internal.TH
  ( instanceHeadT,
    instanceProxyFunD,
    tyConArgs,
    typeInstanceDec,
    typeT,
  )
import Data.Morpheus.Kind
  ( ENUM,
    INPUT,
    INTERFACE,
    OUTPUT,
    SCALAR,
    WRAPPER,
  )
import Data.Morpheus.Server.Types.GQLType
  ( GQLType (..),
    TRUE,
  )
import Data.Morpheus.Types (Resolver, interface)
import Data.Morpheus.Types.Internal.AST
  ( ANY,
    DataTypeKind (..),
    GQLTypeD (..),
    Key,
    Meta (..),
    QUERY,
    TypeContent (..),
    TypeD (..),
    TypeDefinition (..),
    isObject,
    isSchemaTypeName,
  )
import Data.Proxy (Proxy (..))
import Data.Semigroup ((<>))
import Data.Text
  ( pack,
    unpack,
  )
import Data.Typeable (Typeable)
import Language.Haskell.TH

interfaceF :: Name -> ExpQ
interfaceF name = [|interface (Proxy :: (Proxy ($(conT name) (Resolver QUERY () Maybe))))|]

introspectInterface :: Key -> ExpQ
introspectInterface = interfaceF . mkName . unpack

deriveGQLType :: GQLTypeD -> Q [Dec]
deriveGQLType GQLTypeD {typeD = TypeD {tName, tMeta}, typeKindD, typeOriginal} =
  pure <$> instanceD (cxt constrains) iHead (functions <> typeFamilies)
  where
    functions =
      map
        instanceProxyFunD
        [ ('__typeName, [|typename|]),
          ('description, descriptionValue),
          ('implements, implementsFunc)
        ]
      where
        typename = toHSTypename tName
        implementsFunc = listE $ map introspectInterface (interfacesFrom (Just typeOriginal))
        descriptionValue = case tMeta >>= metaDescription of
          Nothing -> [|Nothing|]
          Just desc -> [|Just desc|]
    --------------------------------
    typeArgs = tyConArgs typeKindD
    --------------------------------
    iHead = instanceHeadT ''GQLType tName typeArgs
    headSig = typeT (mkName $ unpack tName) typeArgs
    ---------------------------------------------------
    constrains = map conTypeable typeArgs
      where
        conTypeable name = typeT ''Typeable [name]
    -------------------------------------------------
    typeFamilies
      | isObject typeKindD = [deriveKIND, deriveCUSTOM]
      | otherwise = [deriveKIND]
      where
        deriveCUSTOM = deriveInstance ''CUSTOM ''TRUE
        deriveKIND = deriveInstance ''KIND (kindName typeKindD)
        -------------------------------------------------------
        deriveInstance :: Name -> Name -> Q Dec
        deriveInstance insName tyName = do
          typeN <- headSig
          pure $ typeInstanceDec insName typeN (ConT tyName)

kindName :: DataTypeKind -> Name
kindName KindObject {} = ''OUTPUT
kindName KindScalar = ''SCALAR
kindName KindEnum = ''ENUM
kindName KindUnion = ''OUTPUT
kindName KindInputObject = ''INPUT
kindName KindList = ''WRAPPER
kindName KindNonNull = ''WRAPPER
kindName KindInputUnion = ''INPUT
kindName KindInterface = ''INTERFACE

toHSTypename :: Key -> Key
toHSTypename = pack . hsTypename . unpack
  where
    hsTypename ('S' : name) | isSchemaTypeName (pack name) = name
    hsTypename name = name

interfacesFrom :: Maybe (TypeDefinition ANY) -> [Key]
interfacesFrom (Just TypeDefinition {typeContent = DataObject {objectImplements}}) = objectImplements
interfacesFrom _ = []