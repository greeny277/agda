{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternGuards #-}

module Agda.TypeChecking.Monad.Signature where

import Control.Applicative
import Control.Monad.State
import Control.Monad.Reader

import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe

import Agda.Syntax.Abstract.Name
import Agda.Syntax.Common
import Agda.Syntax.Internal as I
import Agda.Syntax.Position

import qualified Agda.Compiler.JS.Parser as JS

import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Monad.Context
import Agda.TypeChecking.Monad.Options
import Agda.TypeChecking.Monad.Env
import Agda.TypeChecking.Monad.Mutual
import Agda.TypeChecking.Monad.Open
import Agda.TypeChecking.Monad.State
import Agda.TypeChecking.Substitute
import {-# SOURCE #-} Agda.TypeChecking.CompiledClause.Compile
import {-# SOURCE #-} Agda.TypeChecking.Polarity
import {-# SOURCE #-} Agda.TypeChecking.ProjectionLike

import Agda.Utils.Map as Map
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Size
import Agda.Utils.Permutation
import Agda.Utils.Pretty
import qualified Agda.Utils.HashMap as HMap

#include "../../undefined.h"
import Agda.Utils.Impossible

modifySignature :: (Signature -> Signature) -> TCM ()
modifySignature f = modify $ \s -> s { stSignature = f $ stSignature s }

modifyImportedSignature :: (Signature -> Signature) -> TCM ()
modifyImportedSignature f = modify $ \s -> s { stImports = f $ stImports s }

getSignature :: TCM Signature
getSignature = gets stSignature

getImportedSignature :: TCM Signature
getImportedSignature = gets stImports

setSignature :: Signature -> TCM ()
setSignature sig = modifySignature $ const sig

setImportedSignature :: Signature -> TCM ()
setImportedSignature sig = modify $ \s -> s { stImports = sig }

withSignature :: Signature -> TCM a -> TCM a
withSignature sig m =
    do	sig0 <- getSignature
	setSignature sig
	r <- m
	setSignature sig0
        return r

-- * modifiers for parts of the signature

lookupDefinition :: QName -> Signature -> Maybe Definition
lookupDefinition q sig = HMap.lookup q $ sigDefinitions sig

updateDefinition :: QName -> (Definition -> Definition) -> Signature -> Signature
updateDefinition q f sig = sig { sigDefinitions = HMap.adjust f q (sigDefinitions sig) }

updateTheDef :: (Defn -> Defn) -> (Definition -> Definition)
updateTheDef f def = def { theDef = f (theDef def) }

updateDefType :: (Type -> Type) -> (Definition -> Definition)
updateDefType f def = def { defType = f (defType def) }

updateDefArgOccurrences :: ([Occurrence] -> [Occurrence]) -> (Definition -> Definition)
updateDefArgOccurrences f def = def { defArgOccurrences = f (defArgOccurrences def) }

updateDefPolarity :: ([Polarity] -> [Polarity]) -> (Definition -> Definition)
updateDefPolarity f def = def { defPolarity = f (defPolarity def) }

updateDefCompiledRep :: (CompiledRepresentation -> CompiledRepresentation) -> (Definition -> Definition)
updateDefCompiledRep f def = def { defCompiledRep = f (defCompiledRep def) }

updateFunClauses :: ([Clause] -> [Clause]) -> (Defn -> Defn)
updateFunClauses f def@Function{ funClauses = cs} = def { funClauses = f cs }
updateFunClauses f _                              = __IMPOSSIBLE__

-- | Add a constant to the signature. Lifts the definition to top level.
addConstant :: QName -> Definition -> TCM ()
addConstant q d = do
  reportSLn "tc.signature" 20 $ "adding constant " ++ show q ++ " to signature"
  tel <- getContextTelescope
  let tel' = replaceEmptyName "r" $ killRange $ case theDef d of
	      Constructor{} -> fmap (setHiding Hidden) tel
	      _		    -> tel
  let d' = abstract tel' $ d { defName = q }
  reportSLn "tc.signature" 30 $ "lambda-lifted definition = " ++ show d'
  modifySignature $ \sig -> sig
    { sigDefinitions = HMap.insertWith (+++) q d' $ sigDefinitions sig }
  i <- currentOrFreshMutualBlock
  setMutualBlock i q
  where
    new +++ old = new { defDisplay = defDisplay new ++ defDisplay old
                      , defInstance = defInstance new `mplus` defInstance old }

-- | Set termination info of a defined function symbol.
setTerminates :: QName -> Bool -> TCM ()
setTerminates q b = modifySignature $ updateDefinition q $ updateTheDef $ setT
  where
    setT def@Function{} = def { funTerminates = Just b }
    setT def            = def

-- | Modify the clauses of a function.
modifyFunClauses :: QName -> ([Clause] -> [Clause]) -> TCM ()
modifyFunClauses q f =
  modifySignature $ updateDefinition q $ updateTheDef $ updateFunClauses f

-- | Lifts clauses to the top-level and adds them to definition.
addClauses :: QName -> [Clause] -> TCM ()
addClauses q cls = do
  tel <- getContextTelescope
  modifyFunClauses q (++ abstract tel cls)

addHaskellCode :: QName -> HaskellType -> HaskellCode -> TCM ()
addHaskellCode q hsTy hsDef = modifySignature $ updateDefinition q $ updateDefCompiledRep $ addHs
  -- TODO: sanity checking
  where
    addHs crep = crep { compiledHaskell = Just $ HsDefn hsTy hsDef }

addHaskellExport :: QName -> HaskellType -> String -> TCM ()
addHaskellExport q hsTy hsName = modifySignature $ updateDefinition q $ updateDefCompiledRep $ addHs
  -- TODO: sanity checking
  where
    addHs crep = crep { exportHaskell = Just (HsExport hsTy hsName)}

addHaskellType :: QName -> HaskellType -> TCM ()
addHaskellType q hsTy = modifySignature $ updateDefinition q $ updateDefCompiledRep $ addHs
  -- TODO: sanity checking
  where
    addHs crep = crep { compiledHaskell = Just $ HsType hsTy }

addEpicCode :: QName -> EpicCode -> TCM ()
addEpicCode q epDef = modifySignature $ updateDefinition q $ updateDefCompiledRep $ addEp
  -- TODO: sanity checking
  where
    addEp crep = crep { compiledEpic = Just epDef }

addJSCode :: QName -> String -> TCM ()
addJSCode q jsDef =
  case JS.parse jsDef of
    Left e ->
      modifySignature $ updateDefinition q $ updateDefCompiledRep $ addJS (Just e)
    Right s ->
      typeError (CompilationError ("Failed to parse ECMAScript (..." ++ s ++ ") for " ++ show q))
  where
    addJS e crep = crep { compiledJS = e }

markStatic :: QName -> TCM ()
markStatic q = modifySignature $ updateDefinition q $ mark
  where
    mark def@Defn{theDef = fun@Function{}} =
      def{theDef = fun{funStatic = True}}
    mark def = def

unionSignatures :: [Signature] -> Signature
unionSignatures ss = foldr unionSignature emptySignature ss
  where
    unionSignature (Sig a b) (Sig c d) = Sig (Map.union a c) (HMap.union b d)

-- | Add a section to the signature.
addSection :: ModuleName -> Nat -> TCM ()
addSection m fv = do
  tel <- getContextTelescope
  let sec = Section tel fv
  modifySignature $ \sig -> sig { sigSections = Map.insert m sec $ sigSections sig }

-- | Lookup a section. If it doesn't exist that just means that the module
--   wasn't parameterised.
lookupSection :: ModuleName -> TCM Telescope
lookupSection m = do
  sig  <- sigSections <$> getSignature
  isig <- sigSections <$> getImportedSignature
  return $ maybe EmptyTel secTelescope $ Map.lookup m sig `mplus` Map.lookup m isig

-- Add display forms to all names @xn@ such that @x = x1 es1@, ... @xn-1 = xn esn@.
addDisplayForms :: QName -> TCM ()
addDisplayForms x = do
  def  <- getConstInfo x
  args <- getContextArgs
{- OLD
  n    <- do
    proj <- isProjection x
    return $ case proj of
      Just (_, n) -> n
      Nothing     -> 0
-}
  add (drop (projectionArgs $ theDef def) args) x x []
  where
    add args top x vs0 = do
      def <- getConstInfo x
      let cs = defClauses def
      case cs of
	[ Clause{ namedClausePats = pats, clauseBody = b } ]
	  | all (isVar . namedArg) pats
          , Just (m, Def y es) <- strip (b `apply` vs0)
          , Just vs <- mapM isApplyElim es -> do
	      let ps = raise 1 $ map unArg vs
                  df = Display 0 ps $ DTerm $ Def top $ map Apply args
	      reportSLn "tc.display.section" 20 $ "adding display form " ++ show y ++ " --> " ++ show top
                                                ++ "\n  " ++ show df
	      addDisplayForm y df
	      add args top y vs
	_ -> do
	      let reason = case cs of
		    []    -> "no clauses"
		    _:_:_ -> "many clauses"
		    [ Clause{ clauseBody = b } ] -> case strip b of
		      Nothing -> "bad body"
		      Just (m, Def y es)
			| m < length args -> "too few args"
			| m > length args -> "too many args"
			| otherwise	  -> "args=" ++ show args ++ " es=" ++ show es
		      Just (m, v) -> "not a def body"
	      reportSLn "tc.display.section" 30 $ "no display form from " ++ show x ++ " because " ++ reason
	      return ()
    strip (Body v)   = return (0, unSpine v)
    strip  NoBody    = Nothing
    strip (Bind b)   = do
      (n, v) <- strip $ absBody b
      return (n + 1, ignoreSharing v)

    isVar VarP{} = True
    isVar _      = False

-- | Module application (followed by module parameter abstraction).
applySection
  :: ModuleName                -- ^ Name of new module defined by the module macro.
  -> Telescope                 -- ^ Parameters of new module.
  -> ModuleName                -- ^ Name of old module applied to arguments.
  -> Args                      -- ^ Arguments of module application.
  -> Map QName QName           -- ^ Imported names (given as renaming).
  -> Map ModuleName ModuleName -- ^ Imported modules (given as renaming).
  -> TCM ()
applySection new ptel old ts rd rm = do
  sig  <- getSignature
  isig <- getImportedSignature
  let ss = getOld partOfOldM sigSections    [sig, isig]
      ds = getOldH partOfOldD sigDefinitions [sig, isig]
  reportSLn "tc.mod.apply" 10 $ render $ vcat
    [ text "applySection"
    , text "new  =" <+> text (show new)
    , text "ptel =" <+> text (show ptel)
    , text "old  =" <+> text (show old)
    , text "ts   =" <+> text (show ts)
    ]
  reportSLn "tc.mod.apply" 80 $ "sections:    " ++ show ss ++ "\n" ++
                                "definitions: " ++ show ds
  reportSLn "tc.mod.apply" 80 $ render $ vcat
    [ text "arguments:  " <+> text (show ts)
    ]
  mapM_ (copyDef ts) ds
  mapM_ (copySec ts) ss
  mapM_ computePolarity (Map.elems rd)
  where
    getOld partOfOld fromSig sigs =
      Map.toList $ Map.filterKeys partOfOld $ Map.unions $ map fromSig sigs
    getOldH partOfOld fromSig sigs =
      HMap.toList $ HMap.filterWithKey (const . partOfOld) $ HMap.unions $ map fromSig sigs

    partOfOldM x = x `isSubModuleOf` old
    partOfOldD x = x `isInModule`    old

    -- Andreas, 2013-10-29
    -- Here, if the name x is not imported, it persists as
    -- old, possibly out-of-scope name.
    -- This old name may used by the case split tactic, leading to
    -- names that cannot be printed properly.
    -- I guess it would make sense to mark non-imported names
    -- as such (out-of-scope) and let splitting fail if it would
    -- produce out-of-scope constructors.
    copyName x = Map.findWithDefault x x rd

    copyDef :: Args -> (QName, Definition) -> TCM ()
    copyDef ts (x, d) =
      case Map.lookup x rd of
	Nothing -> return ()  -- if it's not in the renaming it was private and
			      -- we won't need it
	Just y	-> do
	  addConstant y =<< nd y
          makeProjection y
	  -- Set display form for the old name if it's not a constructor.
{- BREAKS fail/Issue478
          -- Andreas, 2012-10-20 and if we are not an anonymous module
	  -- unless (isAnonymousModuleName new || isCon || size ptel > 0) $ do
-}
          -- Issue1238: the copied def should be an 'instance' if the original
          -- def is one. Skip constructors since the original constructor will
          -- still work as an instance.
          unless isCon $ flip (maybe (return ())) inst $ \c -> addNamedInstance y c

	  unless (isCon || size ptel > 0) $ do
	    addDisplayForms y
      where
	t   = defType d `apply` ts
        pol = defPolarity d `apply` ts
        occ = defArgOccurrences d `apply` ts
        rew = defRewriteRules d `apply` ts
        inst = defInstance d
	-- the name is set by the addConstant function
        nd :: QName -> TCM Definition
	nd y = Defn (defArgInfo d) y t pol occ [] (-1) noCompiledRep rew inst <$> def  -- TODO: mutual block?
        oldDef = theDef d
	isCon  = case oldDef of { Constructor{} -> True ; _ -> False }
        mutual = case oldDef of { Function{funMutual = m} -> m              ; _ -> [] }
        extlam = case oldDef of { Function{funExtLam = e} -> e              ; _ -> Nothing }
        with   = case oldDef of { Function{funWith = w}   -> copyName <$> w ; _ -> Nothing }
{- THIS BREAKS A LOT OF THINGS:
        -- Andreas, 2013-10-21:
        -- Even if we apply the record argument, we stay a projection.
        -- This is because we may abstract the record argument later again.
        -- See succeed/ProjectionNotNormalized.agda
        proj   = case oldDef of
          Function{funProjection = Just p@Projection{projIndex = n}}
            -> Just $ p { projIndex    = n - size ts
                        , projDropPars = projDropPars p `apply` ts
                        }
          _ -> Nothing
-}
        -- NB (Andreas, 2013-10-19):
        -- If we apply the record argument, we are no longer a projection!
        proj   = case oldDef of
          Function{funProjection = Just p@Projection{projIndex = n}} | size ts < n
            -> Just $ p { projIndex    = n - size ts
                        , projDropPars = projDropPars p `apply` ts
                        }
          _ -> Nothing

	def  = case oldDef of
                Constructor{ conPars = np, conData = d } -> return $
                  oldDef { conPars = np - size ts
                         , conData = copyName d
                         }
                Datatype{ dataPars = np, dataCons = cs } -> return $
                  oldDef { dataPars   = np - size ts
                         , dataClause = Just cl
                         , dataCons   = map copyName cs
                         }
                Record{ recPars = np, recConType = t, recTel = tel } -> return $
                  oldDef { recPars    = np - size ts
                         , recClause  = Just cl
                         , recConType = apply t ts
                         , recTel     = apply tel ts
                         }
		_ -> do
                  cc <- compileClauses Nothing [cl] -- Andreas, 2012-10-07 non need for record pattern translation
                  let newDef = Function
                        { funClauses        = [cl]
                        , funCompiled       = Just $ cc
                        , funDelayed        = NotDelayed
                        , funInv            = NotInjective
                        , funMutual         = mutual
                        , funAbstr          = ConcreteDef
                        , funProjection     = proj
                        , funStatic         = False
                        , funCopy           = True
                        , funTerminates     = Just True
                        , funExtLam         = extlam
                        , funWith           = with
                        }
                  reportSLn "tc.mod.apply" 80 $ "new def for " ++ show x ++ "\n  " ++ show newDef
                  return newDef
{-
        ts' | null ts   = []
            | otherwise = case oldDef of
                Function{funProjection = Just Projection{ projIndex = n}}
                  | n == 0       -> __IMPOSSIBLE__
                  | otherwise    -> drop (n - 1) ts
                _ -> ts
-}
        head = case oldDef of
                 Function{funProjection = Just Projection{ projDropPars = f}}
                   -> f
                 _ -> Def x []
	cl = Clause { clauseRange     = getRange $ defClauses d
                    , clauseTel       = EmptyTel
                    , clausePerm      = idP 0
                    , namedClausePats = []
                    , clauseBody      = Body $ head `apply` ts
                    , clauseType      = Just $ defaultArg t
                    }

    copySec :: Args -> (ModuleName, Section) -> TCM ()
    copySec ts (x, sec) = case Map.lookup x rm of
	Nothing -> return ()  -- if it's not in the renaming it was private and
			      -- we won't need it
	Just y  ->
          addCtxTel (apply tel ts) $ addSection y 0
      where
	tel = secTelescope sec

addDisplayForm :: QName -> DisplayForm -> TCM ()
addDisplayForm x df = do
  d <- makeOpen df
  modifyImportedSignature (add d)
  modifySignature (add d)
  where
    add df sig = sig { sigDefinitions = HMap.adjust addDf x defs }
      where
	addDf def = def { defDisplay = df : defDisplay def }
	defs	  = sigDefinitions sig

canonicalName :: QName -> TCM QName
canonicalName x = do
  def <- theDef <$> getConstInfo x
  case def of
    Constructor{conSrcCon = c}                                -> return $ conName c
    Record{recClause = Just (Clause{ clauseBody = body })}    -> canonicalName $ extract body
    Datatype{dataClause = Just (Clause{ clauseBody = body })} -> canonicalName $ extract body
    _                                                         -> return x
  where
    extract NoBody           = __IMPOSSIBLE__
    extract (Body (Def x _)) = x
    extract (Body (Shared p)) = extract (Body $ derefPtr p)
    extract (Body _)         = __IMPOSSIBLE__
    extract (Bind b)         = extract (unAbs b)

sameDef :: QName -> QName -> TCM (Maybe QName)
sameDef d1 d2 = do
  c1 <- canonicalName d1
  c2 <- canonicalName d2
  if (c1 == c2) then return $ Just c1 else return Nothing

-- | Can be called on either a (co)datatype, a record type or a
--   (co)constructor.
whatInduction :: QName -> TCM Induction
whatInduction c = do
  def <- theDef <$> getConstInfo c
  case def of
    Datatype{ dataInduction = i } -> return i
    Record{ recRecursive = False} -> return Inductive
    Record{ recInduction = i    } -> return $ fromMaybe Inductive i
    Constructor{ conInd = i }     -> return i
    _                             -> __IMPOSSIBLE__

-- | Does the given constructor come from a single-constructor type?
--
-- Precondition: The name has to refer to a constructor.
singleConstructorType :: QName -> TCM Bool
singleConstructorType q = do
  d <- theDef <$> getConstInfo q
  case d of
    Record {}                   -> return True
    Constructor { conData = d } -> do
      di <- theDef <$> getConstInfo d
      return $ case di of
        Record {}                  -> True
        Datatype { dataCons = cs } -> length cs == 1
        _                          -> __IMPOSSIBLE__
    _ -> __IMPOSSIBLE__

class (Functor m, Applicative m, Monad m) => HasConstInfo m where
  -- | Lookup the definition of a name. The result is a closed thing, all free
  --   variables have been abstracted over.
  getConstInfo :: QName -> m Definition

{-# SPECIALIZE getConstInfo :: QName -> TCM Definition #-}

instance HasConstInfo (TCMT IO) where
  getConstInfo q = join $ pureTCM $ \st env ->
    let defs  = sigDefinitions $ stSignature st
        idefs = sigDefinitions $ stImports st
    in case catMaybes [HMap.lookup q defs, HMap.lookup q idefs] of
        []  -> fail $ "Unbound name: " ++ show q ++ " " ++ showQNameId q
        [d] -> mkAbs env d
        ds  -> fail $ "Ambiguous name: " ++ show q
    where
      mkAbs env d
        | treatAbstractly' q' env =
          case makeAbstract d of
            Just d	-> return d
            Nothing	-> notInScope $ qnameToConcrete q
              -- the above can happen since the scope checker is a bit sloppy with 'abstract'
        | otherwise = return d
        where
          q' = case theDef d of
            -- Hack to make abstract constructors work properly. The constructors
            -- live in a module with the same name as the datatype, but for 'abstract'
            -- purposes they're considered to be in the same module as the datatype.
            Constructor{} -> dropLastModule q
            _             -> q

          dropLastModule q@QName{ qnameModule = m } =
            q{ qnameModule = mnameFromList $ init' $ mnameToList m }

          init' [] = {-'-} __IMPOSSIBLE__
          init' xs = init xs

{-# INLINE getConInfo #-}
{-# SPECIALIZE getConstInfo :: QName -> TCM Definition #-}
getConInfo :: MonadTCM tcm => ConHead -> tcm Definition
getConInfo = liftTCM . getConstInfo . conName

-- | Look up the polarity of a definition.
getPolarity :: QName -> TCM [Polarity]
getPolarity q = defPolarity <$> getConstInfo q

-- | Look up polarity of a definition and compose with polarity
--   represented by 'Comparison'.
getPolarity' :: Comparison -> QName -> TCM [Polarity]
getPolarity' CmpEq  q = map (composePol Invariant) <$> getPolarity q -- return []
getPolarity' CmpLeq q = getPolarity q -- composition with Covariant is identity

-- | Set the polarity of a definition.
setPolarity :: QName -> [Polarity] -> TCM ()
setPolarity q pol = modifySignature $ updateDefinition q $ updateDefPolarity $ const pol

-- | Return a finite list of argument occurrences.
getArgOccurrences :: QName -> TCM [Occurrence]
getArgOccurrences d = defArgOccurrences <$> getConstInfo d

{- OLD
-- | Return a finite list of argument occurrences.
getArgOccurrences :: QName -> TCM [Occurrence]
getArgOccurrences d = do
  def <- theDef <$> getConstInfo d
  return $ getArgOccurrences_ def

getArgOccurrences_ :: Defn -> [Occurrence]
getArgOccurrences_ def = case def of
    Function { funArgOccurrences  = os } -> os
    Datatype { dataArgOccurrences = os } -> os
    Record   { recArgOccurrences  = os } -> os
    Constructor{}                        -> [] -- repeat StrictPos
    _                                    -> [] -- repeat Mixed
-}

getArgOccurrence :: QName -> Nat -> TCM Occurrence
getArgOccurrence d i = do
  def <- getConstInfo d
  return $ case theDef def of
    Constructor{} -> StrictPos
    _             -> (defArgOccurrences def ++ repeat Mixed) !! i

setArgOccurrences :: QName -> [Occurrence] -> TCM ()
setArgOccurrences d os =
  modifySignature $ updateDefinition d $ updateDefArgOccurrences $ const os

{- OLD
getArgOccurrence :: QName -> Nat -> TCM Occurrence
getArgOccurrence d i = do
  def <- theDef <$> getConstInfo d
  return $ case def of
    Function { funArgOccurrences  = os } -> look i os
    Datatype { dataArgOccurrences = os } -> look i os
    Record   { recArgOccurrences  = os } -> look i os
    Constructor{}                        -> StrictPos
    _                                    -> Mixed
  where
    look i os = (os ++ repeat Mixed) !! fromIntegral i
-}

-- | Get the mutually recursive identifiers.
getMutual :: QName -> TCM [QName]
getMutual d = do
  def <- theDef <$> getConstInfo d
  return $ case def of
    Function {  funMutual = m } -> m
    Datatype { dataMutual = m } -> m
    Record   {  recMutual = m } -> m
    _ -> []

-- | Set the mutually recursive identifiers.
setMutual :: QName -> [QName] -> TCM ()
setMutual d m = modifySignature $ updateDefinition d $ updateTheDef $ \ def ->
  case def of
    Function{} -> def { funMutual = m }
    Datatype{} -> def {dataMutual = m }
    Record{}   -> def { recMutual = m }
    _          -> __IMPOSSIBLE__

-- | Check whether two definitions are mutually recursive.
mutuallyRecursive :: QName -> QName -> TCM Bool
mutuallyRecursive d d' = (d `elem`) <$> getMutual d'

-- | Look up the number of free variables of a section. This is equal to the
--   number of parameters if we're currently inside the section and 0 otherwise.
getSecFreeVars :: ModuleName -> TCM Nat
getSecFreeVars m = do
  sig  <- sigSections <$> getSignature
  isig <- sigSections <$> getImportedSignature
  top <- currentModule
  case top `isSubModuleOf` m || top == m of
    True  -> return $ maybe 0 secFreeVars $
               Map.lookup m sig <|> Map.lookup m isig
    False -> return 0

-- | Compute the number of free variables of a module. This is the sum of
--   the free variables of its sections.
getModuleFreeVars :: ModuleName -> TCM Nat
getModuleFreeVars m = sum <$> ((:) <$> getAnonymousVariables m <*> mapM getSecFreeVars ms)
  where
    ms = map mnameFromList . inits . mnameToList $ m

-- | Compute the number of free variables of a defined name. This is the sum of
--   the free variables of the sections it's contained in.
getDefFreeVars :: QName -> TCM Nat
getDefFreeVars q = getModuleFreeVars (qnameModule q)

-- | Compute the context variables to apply a definition to.
freeVarsToApply :: QName -> TCM Args
freeVarsToApply x = genericTake <$> getDefFreeVars x <*> getContextArgs

-- | Instantiate a closed definition with the correct part of the current
--   context.
instantiateDef :: Definition -> TCM Definition
instantiateDef d = do
  vs  <- freeVarsToApply $ defName d
  verboseS "tc.sig.inst" 30 $ do
    ctx <- getContext
    m   <- currentModule
    reportSLn "tc.sig.inst" 30 $
      "instDef in " ++ show m ++ ": " ++ show (defName d) ++ " " ++
      unwords (map show . take (size vs) . reverse . map (fst . unDom) $ ctx)
  return $ d `apply` vs

-- | Give the abstract view of a definition.
makeAbstract :: Definition -> Maybe Definition
makeAbstract d =
  case defAbstract d of
    ConcreteDef -> return d
    AbstractDef -> do
      def <- makeAbs $ theDef d
      return d { defArgOccurrences = [] -- no positivity info for abstract things!
               , defPolarity       = [] -- no polarity info for abstract things!
               , theDef = def
               }
  where
    makeAbs Datatype   {} = Just Axiom
    makeAbs Function   {} = Just Axiom
    makeAbs Constructor{} = Nothing
    -- Andreas, 2012-11-18:  Make record constructor and projections abstract.
    makeAbs d@Record{}    = Just Axiom
    -- Q: what about primitive?
    makeAbs d             = Just d

-- | Enter abstract mode. Abstract definition in the current module are transparent.
inAbstractMode :: TCM a -> TCM a
inAbstractMode = local $ \e -> e { envAbstractMode = AbstractMode,
                                   envAllowDestructiveUpdate = False }
                                    -- Allowing destructive updates when seeing through
                                    -- abstract may break the abstraction.

-- | Not in abstract mode. All abstract definitions are opaque.
inConcreteMode :: TCM a -> TCM a
inConcreteMode = local $ \e -> e { envAbstractMode = ConcreteMode }

-- | Ignore abstract mode. All abstract definitions are transparent.
ignoreAbstractMode :: MonadReader TCEnv m => m a -> m a
ignoreAbstractMode = local $ \e -> e { envAbstractMode = IgnoreAbstractMode,
                                       envAllowDestructiveUpdate = False }
                                       -- Allowing destructive updates when ignoring
                                       -- abstract may break the abstraction.

-- | Check whether a name might have to be treated abstractly (either if we're
--   'inAbstractMode' or it's not a local name). Returns true for things not
--   declared abstract as well, but for those 'makeAbstract' will have no effect.
treatAbstractly :: MonadReader TCEnv m => QName -> m Bool
treatAbstractly q = asks $ treatAbstractly' q

treatAbstractly' :: QName -> TCEnv -> Bool
treatAbstractly' q env = case envAbstractMode env of
  ConcreteMode	     -> True
  IgnoreAbstractMode -> False
  AbstractMode	     -> not $ current == m || current `isSubModuleOf` m
  where
    current = envCurrentModule env
    m	    = qnameModule q

-- | Get type of a constant, instantiated to the current context.
typeOfConst :: QName -> TCM Type
typeOfConst q = defType <$> (instantiateDef =<< getConstInfo q)

-- | Get relevance of a constant.
relOfConst :: QName -> TCM Relevance
relOfConst q = defRelevance <$> getConstInfo q

-- | Get colors of a constant.
colOfConst :: QName -> TCM [Color]
colOfConst q = defColors <$> getConstInfo q

-- | The name must be a datatype.
sortOfConst :: QName -> TCM Sort
sortOfConst q =
    do	d <- theDef <$> getConstInfo q
	case d of
	    Datatype{dataSort = s} -> return s
	    _			   -> fail $ "Expected " ++ show q ++ " to be a datatype."

-- | Is it the name of a record projection?
isProjection :: QName -> TCM (Maybe Projection)
isProjection qn = isProjection_ . theDef <$> getConstInfo qn

isProjection_ :: Defn -> Maybe Projection
isProjection_ def =
  case def of
    Function { funProjection = result } -> result
    _                                   -> Nothing

isProperProjection :: Defn -> Bool
isProperProjection = isJust . (projProper <=< isProjection_)
-- isProperProjection = maybe False projProper . isProjection_

-- | Number of dropped initial arguments.
projectionArgs :: Defn -> Int
projectionArgs = maybe 0 (pred . projIndex) . isProjection_

-- | Apply a function @f@ to its first argument, producing the proper
--   postfix projection if @f@ is a projection.
applyDef :: QName -> I.Arg Term -> TCM Term
applyDef f a = do
  -- get the original projection, if existing
  res <- (projProper =<<) <$> isProjection f
  case res of
    Nothing -> return $ Def f [Apply a]
    Just f' -> return $ unArg a `applyE` [Proj f']

-- | @getDefType f t@ computes the type of (possibly projection-(like))
--   function @t@ whose first argument has type @t@.
--   The `parameters' for @f@ are extracted from @t@.
--   @Nothing@ if @f@ is projection(like) but
--   @t@ is not a data/record/axiom type.
--
--   Precondition: @t@ is reduced.
--
--   See also: 'Agda.TypeChecking.Datatypes.getConType'
getDefType :: QName -> Type -> TCM (Maybe Type)
getDefType f t = do
  def <- getConstInfo f
  let a = defType def
  -- if @f@ is not a projection (like) function, @a@ is the correct type
  caseMaybe (isProjection_ $ theDef def) (return $ Just a) $
    \ (Projection{ projIndex = n }) -> do
      -- otherwise, we have to instantiate @a@ to the "parameters" of @f@
      let npars | n == 0    = __IMPOSSIBLE__
                | otherwise = n - 1
      -- we get the parameters from type @t@
      case ignoreSharing $ unEl t of
        Def d es -> do
          -- Andreas, 2013-10-22
          -- we need to check this @Def@ is fully reduced.
          -- If it is stuck due to disabled reductions
          -- (because of failed termination check),
          -- we will produce garbage parameters.
          flip (ifM $ eligibleForProjectionLike d) (return Nothing) $ do
            -- now we know it is reduced, we can safely take the parameters
            let pars = fromMaybe __IMPOSSIBLE__ $ allApplyElims $ take npars es
            -- pars <- maybe (return Nothing) return $ allApplyElims $ take npars es
            return $ Just $ a `apply` pars
        _ -> return Nothing
