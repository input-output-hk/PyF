{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-}

module PyF.Internal.QQ (
  toExp)
where

import Text.Megaparsec

import qualified Formatting as F

import           Language.Haskell.TH

import Data.Maybe (fromMaybe)

import qualified Data.Text.Lazy.Builder as Builder

import qualified Data.Text.Lazy as LText
import qualified Data.Text as SText
import qualified Data.List.NonEmpty as NonEmpty

import qualified Data.Word as Word
import qualified Data.Int as Int
import Numeric.Natural

import Language.Haskell.Meta.Parse (parseExp)

import PyF.Internal.PythonSyntax
import qualified PyF.Formatters as Formatters
import PyF.Formatters (AnyAlign(..))
import Data.Proxy
import GHC.TypeLits

-- Be Careful: empty format string
toExp:: String -> Q Exp
toExp s = do
  filename <- loc_filename <$> location
  (line, col) <- loc_start <$> location

  let change_log "<interactive>" currentState = currentState
      change_log _ currentState = let
        (SourcePos sName _ _) NonEmpty.:| xs = statePos currentState
        in currentState {statePos = (SourcePos sName (mkPos line) (mkPos col)) NonEmpty.:| xs}

  case parse (updateParserState (change_log filename) >> result) filename s of
    Left err -> do

      if filename == "<interactive>"
        then do
          fail (parseErrorPretty' s err)
        else do
          fileContent <- runIO (readFile filename)
          fail (parseErrorPretty' fileContent err)
    Right items -> goFormat items

goFormat :: [Item] -> Q Exp
goFormat items = foldl1 fofo <$> (mapM toFormat items)

fofo :: Exp -> Exp -> Exp
fofo s0 s1 = InfixE (Just s0) (VarE '(F.%)) (Just s1)

-- Real formatting is here

toFormat :: Item -> Q Exp
toFormat (Raw x) = [| F.now (Builder.fromString x) |]
toFormat (Replacement x y) = do
  formatExpr <- padAndFormat (fromMaybe DefaultFormatMode y)

  case parseExp x of
    Right expr -> pure (AppE (VarE 'F.now) (VarE 'Builder.fromString `AppE` (formatExpr `AppE` expr)))
    Left err -> fail err

changePrec :: Precision -> Maybe Int
changePrec PrecisionDefault = Just 6
changePrec (Precision n) = Just (fromIntegral n)

changePrec' :: Precision -> Maybe Int
changePrec' PrecisionDefault = Nothing
changePrec' (Precision n) = Just (fromIntegral n)

toGrp :: Maybe b -> a -> Maybe (a, b)
toGrp mb a = (a,) <$> mb

-- Todo: Alternates for floating
padAndFormat :: FormatMode -> Q Exp
padAndFormat (FormatMode padding tf grouping) = case tf of
  -- Integrals
  BinaryF AlternateForm s -> [| formatAnyIntegral (Formatters.Alternate Formatters.Binary) s (newPadding padding) (toGrp grouping 4) |]
  BinaryF NormalForm s -> [| formatAnyIntegral Formatters.Binary s (newPadding padding) (toGrp grouping 4) |]
  CharacterF -> [| formatAnyIntegral Formatters.Character Formatters.Minus (newPadding padding) Nothing |]
  DecimalF s -> [| formatAnyIntegral Formatters.Decimal s (newPadding padding) (toGrp grouping 3) |]
  HexF AlternateForm s -> [| formatAnyIntegral (Formatters.Alternate Formatters.Hexa) s (newPadding padding) (toGrp grouping 4) |]
  HexF NormalForm s -> [| formatAnyIntegral Formatters.Hexa s (newPadding padding) (toGrp grouping 4) |]
  OctalF AlternateForm s -> [| formatAnyIntegral (Formatters.Alternate Formatters.Octal) s (newPadding padding) (toGrp grouping 4) |]
  OctalF NormalForm s -> [| formatAnyIntegral Formatters.Octal s (newPadding padding) (toGrp grouping 4) |]
  HexCapsF AlternateForm s -> [| formatAnyIntegral (Formatters.Upper (Formatters.Alternate Formatters.Hexa)) s (newPadding padding) (toGrp grouping 4) |]
  HexCapsF NormalForm s -> [| formatAnyIntegral (Formatters.Upper (Formatters.Hexa)) s (newPadding padding) (toGrp grouping 4) |]

  -- Floating
  ExponentialF prec s -> [| formatAnyFractional (Formatters.Exponent) s (newPadding padding) (toGrp grouping 3) (changePrec prec) |]
  ExponentialCapsF prec s -> [| formatAnyFractional (Formatters.Upper (Formatters.Exponent)) s (newPadding padding) (toGrp grouping 3) (changePrec prec) |]
  GeneralF prec s -> [| formatAnyFractional (Formatters.Generic) s (newPadding padding) (toGrp grouping 3) (changePrec prec) |]
  GeneralCapsF prec s -> [| formatAnyFractional (Formatters.Upper (Formatters.Generic)) s (newPadding padding) (toGrp grouping 3) (changePrec prec) |]
  FixedF prec s -> [| formatAnyFractional (Formatters.Fixed) s (newPadding padding) (toGrp grouping 3) (changePrec prec) |]
  FixedCapsF prec s -> [| formatAnyFractional (Formatters.Upper (Formatters.Fixed)) s (newPadding padding) (toGrp grouping 3) (changePrec prec) |]
  PercentF prec s -> [| formatAnyFractional (Formatters.Percent) s (newPadding padding) (toGrp grouping 3) (changePrec prec) |]

  -- Default / String
  DefaultF prec s -> [| \v ->
      case categorise (Proxy :: Proxy $(typeAllowed)) v of
        Integral i -> formatAnyIntegral Formatters.Decimal s (newPadding padding) (toGrp grouping 3) i
        Fractional f -> formatAnyFractional Formatters.Generic s (newPadding padding) (toGrp grouping 3) (changePrec' prec) f
        StringType f -> Formatters.formatString (newPaddingForString padding) (changePrec' prec) f
                         |]
   where
     typeAllowed :: Q Type
     typeAllowed = case padding of
       PaddingDefault -> [t| EnableForString |]
       Padding _ Nothing -> [t| EnableForString |]
       Padding _ (Just (_, AnyAlign a)) -> case Formatters.getAlignForString a of
         Nothing -> [t| DisableForString |]
         Just _ -> [t| EnableForString |]

  StringF prec -> [| Formatters.formatString pad (changePrec' prec) |]
    where pad = newPaddingForString padding

newPaddingForString :: Padding -> Maybe (Int, Formatters.AlignMode 'Formatters.AlignAll, Char)
newPaddingForString padding = case padding of
    PaddingDefault -> Nothing
    Padding i Nothing -> Just (fromIntegral i, Formatters.AlignLeft, ' ') -- default align left and fill with space for string
    Padding i (Just (mc, AnyAlign a)) -> case Formatters.getAlignForString a of
      Nothing -> error alignErrorMsg
      Just al -> pure (fromIntegral i, al, fromMaybe ' ' mc)

newPadding :: Padding -> Maybe (Integer, AnyAlign, Char)
newPadding padding = case padding of
    PaddingDefault -> Nothing
    (Padding i al) -> case al of
      Nothing -> Just (i, AnyAlign Formatters.AlignRight, ' ') -- Right align and space is default for any object, except string
      Just (Nothing, a) -> Just (i, a, ' ')
      Just (Just c, a) -> Just (i, a, c)

formatAnyIntegral :: (Show i, Integral i) => Formatters.Format t t' 'Formatters.Integral -> Formatters.SignMode -> Maybe (Integer, AnyAlign, Char) -> Maybe (Int, Char) -> i -> String
formatAnyIntegral f s Nothing grouping i = Formatters.formatIntegral f s Nothing grouping i
formatAnyIntegral f s (Just (padSize, AnyAlign alignMode, c)) grouping i = Formatters.formatIntegral f s (Just (fromIntegral padSize, alignMode, c)) grouping i

formatAnyFractional :: (RealFloat i) => Formatters.Format t t' 'Formatters.Fractional -> Formatters.SignMode -> Maybe (Integer, AnyAlign, Char) -> Maybe (Int, Char) -> Maybe Int -> i -> String
formatAnyFractional f s Nothing grouping p i = Formatters.formatFractional f s Nothing grouping p i
formatAnyFractional f s (Just (padSize, AnyAlign alignMode, c)) grouping p i = Formatters.formatFractional f s (Just (fromIntegral padSize, alignMode, c)) grouping p i

data FormattingType where
  StringType :: String -> FormattingType
  Fractional :: RealFloat t => t -> FormattingType
  Integral :: (Show t, Integral t) => t -> FormattingType

class Categorise k t where
  categorise :: Proxy k -> t -> FormattingType

instance Categorise k Integer where categorise _  i = Integral i
instance Categorise k Int where categorise _  i = Integral i
instance Categorise k Int.Int8 where categorise _  i = Integral i
instance Categorise k Int.Int16 where categorise _  i = Integral i
instance Categorise k Int.Int32 where categorise _  i = Integral i
instance Categorise k Int.Int64 where categorise _  i = Integral i

instance Categorise k Natural where categorise _  i = Integral i
instance Categorise k Word where categorise _  i = Integral i
instance Categorise k Word.Word8 where categorise _  i = Integral i
instance Categorise k Word.Word16 where categorise _  i = Integral i
instance Categorise k Word.Word32 where categorise _  i = Integral i
instance Categorise k Word.Word64 where categorise _  i = Integral i

instance Categorise k Float where categorise _  f = Fractional f
instance Categorise k Double where categorise _  f = Fractional f

-- This may use DataKinds extension, however the need for the
-- extension will leak inside the code calling the template haskell
-- quasi quotes.
data EnableForString
data DisableForString

instance Categorise EnableForString LText.Text where categorise _  t = StringType (LText.unpack t)
instance Categorise EnableForString SText.Text where categorise _  t = StringType (SText.unpack t)
instance Categorise EnableForString String where categorise _  t = StringType t

alignErrorMsg :: String
alignErrorMsg = "String Cannot be aligned with the inside `=` mode"

instance TypeError ('Text "String Cannot be aligned with the inside `=` mode") => Categorise DisableForString LText.Text where categorise _ _ = error "unreachable"
instance TypeError ('Text "String Cannot be aligned with the inside `=` mode") => Categorise DisableForString SText.Text where categorise _ _ = error "unreachable"
instance TypeError ('Text "String Cannot be aligned with the inside `=` mode") => Categorise DisableForString String where categorise _ _ = error "unreachable"
