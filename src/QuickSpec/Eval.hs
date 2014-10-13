{-# LANGUAGE CPP, TypeSynonymInstances, FlexibleInstances, ScopedTypeVariables, TupleSections #-}
module QuickSpec.Eval where

#include "errors.h"
import QuickSpec.Base hiding (unify)
import qualified QuickSpec.Base as Base
import QuickSpec.Utils
import QuickSpec.Type
import QuickSpec.Term
import QuickSpec.Signature
import QuickSpec.Equation
import Data.Map(Map)
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Set(Set)
import Control.Monad
import QuickSpec.Pruning
import QuickSpec.Pruning.Simple hiding (S)
import qualified QuickSpec.Pruning.Simple as Simple
import qualified QuickSpec.Pruning.E as E
import Data.List hiding (insert)
import Data.Ord
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Class
import Data.MemoCombinators.Class
import QuickSpec.TestSet
import QuickSpec.Rules
import Control.Monad.IO.Class
import QuickSpec.Memo()
import Control.Applicative
import QuickSpec.Test

type M = RulesT Event (StateT S IO)

data S = S {
  schemas       :: Schemas,
  schemaTestSet :: TestSet Schema,
  termTestSet   :: Map Schema (TestSet TermFrom),
  pruner        :: SimplePruner,
  freshTestSet  :: TestSet TermFrom,
  types         :: Set Type }

data Event =
    Schema (Poly Schema) (KindOf Schema)
  | Term   TermFrom      (KindOf TermFrom)
  | ConsiderSchema (Poly Schema)
  | ConsiderTerm   TermFrom
  | Type           (Poly Type)
  | UntestableType (Poly Type)
  deriving (Eq, Ord)

instance Pretty Event where
  pretty (Schema s k) = text "schema" <+> pretty s <> text ":" <+> pretty k
  pretty (Term t k) = text "term" <+> pretty t <> text ":" <+> pretty k
  pretty (ConsiderSchema s) = text "consider schema" <+> pretty s
  pretty (ConsiderTerm t) = text "consider term" <+> pretty t
  pretty (Type ty) = text "type" <+> pretty ty
  pretty (UntestableType ty) = text "untestable type" <+> pretty ty

data KindOf a = Untestable | Representative | EqualTo a
  deriving (Eq, Ord)

instance Pretty a => Pretty (KindOf a) where
  pretty Untestable = text "untestable"
  pretty Representative = text "representative"
  pretty (EqualTo x) = text "equal to" <+> pretty x

type Schemas = Map Int (Map (Poly Type) [Poly Schema])

initialState :: Signature -> TestSet Schema -> TestSet TermFrom -> Set Type -> S
initialState sig ts ts' types =
  S { schemas       = Map.empty,
      schemaTestSet = ts,
      termTestSet   = Map.empty,
      pruner        = emptyPruner types sig,
      freshTestSet  = ts',
      types         = types }

schemasOfSize :: Int -> Signature -> M [Schema]
schemasOfSize 1 sig =
  return $
    [Var (Var (TyVar 0))] ++
    [Fun c [] | c <- constants sig]
schemasOfSize n _ = do
  ss <- lift $ gets schemas
  return $
    [ mono (apply f x)
    | i <- [1..n-1],
      let j = n-i,
      (fty, fs) <- Map.toList =<< maybeToList (Map.lookup i ss),
      canApply fty (poly (Var (TyVar 0))),
      or [ canApply f (poly (Var (Var (TyVar 0)))) | f <- fs ],
      (xty, xs) <- Map.toList =<< maybeToList (Map.lookup j ss),
      canApply fty xty,
      f <- fs,
      canApply f (poly (Var (Var (TyVar 0)))),
      x <- xs ]

quickSpec :: Signature -> IO ()
quickSpec sig = unbuffered $ do
  seeds <- fmap (take 100) (genSeeds 20)
  let e = table (env sig)
      ts = emptyTestSet (makeTester (skeleton . instantiate) e seeds sig)
      ts' = emptyTestSet (makeTester (\(From _ t) -> t) e seeds sig)
      types = typeUniverse sig
  _ <- execStateT (runRulesT (createRules sig >> go 1 sig)) (initialState sig ts ts' types)
  return ()

typeUniverse :: Signature -> Set Type
typeUniverse sig =
  Set.fromList $
    Var (TyVar 0):
    [ monoTyp t | c <- constants sig, t <- subterms (typ c) ]

go :: Int -> Signature -> M ()
go 10 _ = do
  es <- getEvents
  let isSchema (Schema _ _) = True
      isSchema _ = False
      isTerm (Term _ _) = True
      isTerm _ = False
      isCreation (ConsiderSchema _) = True
      isCreation (ConsiderTerm _) = True
      isCreation _ = False
      numEvents = length es
      numSchemas = length (filter isSchema es)
      numTerms = length (filter isTerm es)
      numCreation = length (filter isCreation es)
      numMisc = numEvents - numSchemas - numTerms - numCreation
  h <- numHooks
  liftIO $ putStrLn (show numEvents ++ " events created in total (" ++
                     show numSchemas ++ " schemas, " ++
                     show numTerms ++ " terms, " ++
                     show numCreation ++ " creation, " ++
                     show numMisc ++ " miscellaneous).")
  liftIO $ putStrLn (show h ++ " hooks installed.")
go n sig = do
  lift $ modify (\s -> s { schemas = Map.insert n Map.empty (schemas s) })
  ss <- fmap (sortBy (comparing measure)) (schemasOfSize n sig)
  liftIO $ putStrLn ("Size " ++ show n ++ ", " ++ show (length ss) ++ " schemas to consider:")
  mapM_ (generate . ConsiderSchema . poly) ss
  liftIO $ putStrLn ""
  go (n+1) sig

instantiateFor :: Term -> Schema -> Term
instantiateFor s t = evalState (aux t) (maxVar, Map.fromList varList)
  where
    aux (Var ty) = do
      (n, m) <- get
      index <-
        case Map.lookup (monoTyp ty) m of
          Just ((Variable n' _):ys) -> do
            put (n, Map.insert (monoTyp ty) ys m)
            return n'
          _ -> do
            put (n+1, m)
            return n
      return (Var (Variable index ty))
    aux (Fun f xs) = fmap (Fun f) (mapM aux xs)
    maxVar = 1+maximum (0:map varNumber (vars s))
    varList =
      [ (monoTyp x, xs) | xs@(x:_) <- partitionBy monoTyp (usort (vars s)) ]

allUnifications :: Term -> [Term]
allUnifications t = map f ss
  where
    vs = [ map (x,) xs | xs <- partitionBy monoTyp (usort (vars t)), x <- xs ]
    ss = map Map.fromList (sequence vs)
    go s x = Map.findWithDefault __ x s
    f s = rename (go s) t

createRules :: Signature -> M ()
createRules sig = do
  rule $ do
    Schema s k <- event
    execute $ do
      accept s
      let ms = defaultType (mono s)
      case k of
        Untestable -> return ()
        EqualTo t -> do
          considerRenamings t t
          considerRenamings t ms
        Representative -> do
          when (size ms <= 5) $
            considerRenamings ms ms

  rule $ do
    Term (From s t) k <- event
    execute $
      case k of
        Untestable ->
          ERROR ("Untestable instance " ++ prettyShow t ++ " of testable schema " ++ prettyShow s)
        EqualTo (From _ u) -> found t u
        Representative -> return ()

  rule $ do
    ConsiderSchema s <- event
    types <- execute $ lift $ gets types
    require (and [ monoTyp t `Set.member` types | t <- subterms (mono s) ])
    execute (consider (Schema s) (mono s))

  rule $ do
    ConsiderTerm t <- event
    execute (consider (Term t) t)

  rule $ do
    Schema s _ <- event
    execute $
      generate (Type (polyTyp s))

  rule $ do
    Type ty1 <- event
    Type ty2 <- event
    require (mono ty1 < mono ty2)
    Just mgu <- return (polyMgu ty1 ty2)
    let tys = [ty1, ty2] \\ [mgu]

    Schema s Representative <- event
    require (polyTyp s `elem` tys)

    execute $
      generate (ConsiderSchema (fromMaybe __ (cast (mono mgu) s)))

  rule $ do
    Schema s Untestable <- event
    require (arity (typ s) == 0)
    execute $
      generate (UntestableType (polyTyp (defaultType s)))

  rule $ do
    UntestableType ty <- event
    execute $
      liftIO $ putStrLn $
        "Warning: generated term of untestable type " ++ prettyShow ty

  rule $ event >>= execute . liftIO . prettyPrint

considerRenamings :: Schema -> Schema -> M ()
considerRenamings s s' = do
  sequence_ [ generate (ConsiderTerm (From s t)) | t <- ts ]
  where
    ts = sortBy (comparing measure) (allUnifications (instantiate s'))

class (Eq a, Typed a) => Considerable a where
  toTerm     :: a -> Term
  getTestSet :: a -> M (TestSet a)
  putTestSet :: a -> TestSet a -> M ()

consider :: Considerable a => (KindOf a -> Event) -> a -> M ()
consider makeEvent x = do
  pruner <- lift $ gets pruner
  types  <- lift $ gets types
  let t = toTerm x
  case evalState (rep (etaExpand t)) pruner of
    Just u | measure u < measure t ->
      let mod = execState (unify types (t :=: u))
      in lift $ modify (\s -> s { pruner = mod pruner })
    _ -> do
      ts <- getTestSet x
      case insert (poly x) ts of
        Nothing ->
          generate (makeEvent Untestable)
        Just (Old y) ->
          generate (makeEvent (EqualTo y))
        Just (New ts) -> do
          putTestSet x ts
          generate (makeEvent Representative)

-- NOTE: this is not quite correct because we might get
-- t x --> u x x
-- so we need to check the "all instances are reduced" thing instead.
etaExpand :: Term -> Term
etaExpand t = aux (1+maximum (0:map varNumber (vars t))) t
  where
    aux n t =
      let f = poly t
          x = poly (Var (Variable n (Var (TyVar 0))))
      in case tryApply f x of
        Nothing -> t
        Just u -> aux (n+1) (mono u)

instance Considerable Schema where
  toTerm = instantiate
  getTestSet _ = lift $ gets schemaTestSet
  putTestSet _ ts = lift $ modify (\s -> s { schemaTestSet = ts })

data TermFrom = From Schema Term deriving (Eq, Ord, Show)

instance Pretty TermFrom where
  pretty (From s t) = pretty t <+> text "from" <+> pretty s

instance Typed TermFrom where
  typ (From _ t) = typ t
  typeSubstA f (From s t) = From s <$> typeSubstA f t

instance Considerable TermFrom where
  toTerm (From _ t) = t
  getTestSet (From s _) = lift $ do
    ts <- gets freshTestSet
    gets (Map.findWithDefault ts s . termTestSet)
  putTestSet (From s _) ts =
    lift $ modify (\st -> st { termTestSet = Map.insert s ts (termTestSet st) })

found :: Term -> Term -> M ()
found t u = do
  Simple.S eqs <- lift $ gets pruner
  types <- lift $ gets types
  res <- liftIO $ uncurry (E.eUnify eqs) (toPruningEquation (t :=: u))
  case res of
    True ->
      return ()
    False -> do
      lift $ modify (\s -> s { pruner = execState (unify types (t :=: u)) (pruner s) })
      liftIO $ putStrLn (prettyShow t ++ " = " ++ prettyShow u)

accept :: Poly Schema -> M ()
accept s = do
  lift $ modify (\st -> st { schemas = Map.adjust f (size (mono s)) (schemas st) })
  where
    f m = Map.insertWith (++) (polyTyp s) [s] m
