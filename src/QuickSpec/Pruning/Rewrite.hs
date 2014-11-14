module QuickSpec.Pruning.Rewrite where

import QuickSpec.Base
import QuickSpec.Term
import qualified QuickSpec.Pruning.RuleIndex as RuleIndex
import QuickSpec.Pruning.RuleIndex(RuleIndex)
import qualified QuickSpec.Pruning.EquationIndex as EquationIndex
import QuickSpec.Pruning.EquationIndex(EquationIndex)
import QuickSpec.Pruning.Equation
import Data.Maybe
import Data.Set(Set)
import QuickSpec.Pruning.Queue
import Control.Monad
import Data.Rewriting.Rule
import Debug.Trace

type Strategy f v = Tm f v -> [Tm f v]

normaliseWith :: Strategy f v -> Tm f v -> Tm f v
normaliseWith strat t =
  case strat t of
    [] -> t
    (r:_) -> normaliseWith strat r

anywhere :: Strategy f v -> Strategy f v
anywhere strat t = strat t ++ nested (anywhere strat) t

nested :: Strategy f v -> Strategy f v
nested strat Var{} = []
nested strat (Fun f xs) = map (Fun f) (combine xs (map strat xs))
  where
    combine [] [] = []
    combine (x:xs) (ys:yss) =
      [ y:xs | y <- ys ] ++ [ x:zs | zs <- combine xs yss ]

ordered :: (Sized f, Ord f, Ord v) => Strategy f v -> Strategy f v
ordered strat t = [u | u <- strat t, u `simplerThan` t]

tryRule :: (Ord f, Ord v, Numbered v) => Rule f v -> Strategy f v
tryRule rule t = do
  sub <- maybeToList (match (lhs rule) t)
  let rule' = substf (evalSubst sub) rule
  return (rhs rule')

tryRules :: (Ord f, Ord v, Numbered v) => RuleIndex f v -> Strategy f v
tryRules rules t = map (rhs . peel) (RuleIndex.lookup t rules)

tryEquations :: (Ord f, Ord v, Numbered v) => EquationIndex f v -> Strategy f v
tryEquations eqns t = map (eqRhs . peel) (EquationIndex.lookup t eqns)
  where
    eqRhs (_ :==: r) = r

insertWithSubsumptionCheck ::
  (Ord f, Ord v, Numbered v) => Label -> Equation f v -> EquationIndex f v -> Maybe (EquationIndex f v)
insertWithSubsumptionCheck label (l :==: r) idx
  | r `elem` anywhere (tryEquations idx) l = Nothing
  | otherwise = Just (EquationIndex.insert label (l :==: r) idx)
