{-# LANGUAGE Safe #-}
{- | 

This module exports the type class that every label format must
implement. Labels must form a bounded lattice and be instances of
'Show' and 'Typeable'. The class 'LabelOf' is additionally used to
get the type of labeled objects.

-}

module LIO.Label ( Label(..)
                 , LabelOf(..) ) where

import Data.Typeable

-- | This class defines a label format, corresponding to a bounded
-- lattice. Specifically, it is necessary to define a bottom element
-- 'bottom' (in literature, written as &#8869;), a top element 'top' (in
-- literature, written as &#8868;), a join, or least upper bound, 'join'
-- (in literature, written as &#8852;), a meet, or greatest lower bound,
-- 'meet' (in literature, written as &#8851;), and of course the
-- can-flow-to partial-order 'canFlowTo' (in literature, written as
-- &#8849;).
class (Eq l, Show l, Typeable l) => Label l where
  -- | Bottom
  bottom :: l
  -- | Top
  top :: l
  -- | Join, or Least upper bound, of two labels
  join :: l -> l -> l
  -- | Meet, or greatest lower bound, of two labels
  meet :: l -> l -> l
  -- | Can-flow-to relation
  canFlowTo :: l -> l -> Bool


-- | Generic class used to ge tht type of labeled objects.
class LabelOf t where
  -- | Get the label of a type kinded @* -> *@
  labelOf :: Label l => t l a -> l
  
