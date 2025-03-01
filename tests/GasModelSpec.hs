{-# LANGUAGE OverloadedStrings #-}

module GasModelSpec (spec) where

import Test.Hspec
import Test.Hspec.Golden

import qualified Data.ByteString.Lazy as BL
import qualified Data.Set as S
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map

import Control.Exception (bracket, throwIO)
import Control.Monad (when)
import Data.Aeson (eitherDecode, encode)
import Data.Int (Int64)
import Data.List (foldl')
import Test.QuickCheck
import Test.QuickCheck.Gen (Gen(..))
import Test.QuickCheck.Random (mkQCGen)
import System.Directory


import GoldenSpec (golden, cleanupActual)
import Pact.Types.Exp
import Pact.Types.SizeOf
import Pact.Types.PactValue
import Pact.Types.Runtime
import Pact.GasModel.GasModel
import Pact.GasModel.Types
import Pact.GasModel.Utils
import Pact.GasModel.GasTests
import Pact.Gas.Table
import Pact.Native


spec :: Spec
spec = describe "gas model tests" $ do
  describe "untestedNativesCheck" untestedNativesCheck
  describe "allGasTestsAndGoldenShouldPass" allGasTestsAndGoldenShouldPass
  describe "allNativesInGasTable" allNativesInGasTable
  describe "goldenSizeOfPactValues" goldenSizeOfPactValues

untestedNativesCheck :: Spec
untestedNativesCheck = do
  it "only deprecated or constant natives should be missing gas model tests" $
    S.fromList (map asString untestedNatives)
    `shouldBe`
    (S.fromList ["CHARSET_ASCII", "CHARSET_LATIN1",
                 "verify-spv", "public-chain-data", "list"])

allGasTestsAndGoldenShouldPass :: Spec
allGasTestsAndGoldenShouldPass = after_ (cleanupActual "gas-model" []) $ do
  res <- runIO gasTestResults
  -- fails if one of the gas tests throws a pact error

  let gasCost = _evalGas . snd . _gasTestResultSqliteDb
      -- only do golden test for sqlite results
      toGoldenOutput r = (_gasTestResultDesciption r, gasCost r)
      allActualOutputsGolden = map toGoldenOutput res

  it "gas model tests should not return a PactError, but should pass golden" $ do
    (golden "gas-model" allActualOutputsGolden)
      { encodePretty = show } -- effective, but a lot of output is shown

goldenSizeOfPactValues :: Spec
goldenSizeOfPactValues = do
  mapM_ (someGoldenSizeOfPactValue . fst) pactValuesDescAndGen


allNativesInGasTable :: Spec
allNativesInGasTable = do
  it "all native functions should be in gas table" $ do
    let justNatives = map (asString . fst) (concatMap snd natives)
        absent li name = case (Map.lookup name defaultGasTable) of
          Nothing -> name : li
          Just _ -> li
        absentNatives = foldl' absent [] justNatives
    (S.fromList absentNatives)
    `shouldBe`
    (S.fromList ["CHARSET_ASCII", "CHARSET_LATIN1", "public-chain-data", "list"])

gasTestResults :: IO [GasTestResult ([Term Name], EvalState)]
gasTestResults = do
  let runSingleNativeTests t = mapOverGasUnitTests t run run
      run expr dbSetup = do
        (res, st) <- bracket (setupEnv dbSetup) (gasSetupCleanup dbSetup) (mockRun expr)
        res' <- eitherDie (getDescription expr dbSetup) res
        return (res', st)
  concat <$> mapM (runSingleNativeTests . snd) (HM.toList unitTests)


-- Utils
--

-- | Pseudo golden test of the Gas Model's sizeOf function.
-- Enforces that the sizeOf function remains the same for some pre-generated,
-- psuedo-random pact value.
someGoldenSizeOfPactValue :: String -> Spec
someGoldenSizeOfPactValue desc = do
  it ("passes sizeOf golden test with pseudo-random " <> desc <> " pact value") $ do
    (goldenSize, goldenPactValue) <- jsonDecode (goldenPactValueFilePath desc)
    let actualSize = sizeOf goldenPactValue
    actualSize `shouldBe` goldenSize

  where jsonDecode :: FilePath -> IO (Int64, PactValue)
        jsonDecode fp = do
          isGoldenFilePresent <- doesFileExist fp
          when (not isGoldenFilePresent) $ throwIO $ userError $
            "Golden pact value file does not exist: " ++ show fp
          r <- eitherDecode <$> BL.readFile fp
          case r of
            Left e -> throwIO $ userError $ "golden decode failed: " ++ show e
            Right v -> return v

-- | Genearates golden files expected in `someGoldenSizeOfPactValue`
-- Creates a golden file in the format of (sizeOf <somePactValue>, <somePactValue>)
_generateGoldenPactValues :: IO ()
_generateGoldenPactValues = mapM_ f pactValuesDescAndGen
  where
    f (desc, genPv) = do
      let fp = goldenPactValueFilePath desc
      _ <- createDirectoryIfMissing False (goldenPactValueDirectory desc)
      isGoldenFilePresent <- doesFileExist fp
      when (not isGoldenFilePresent) (createGolden fp genPv)

    createGolden fp genPv = do
      -- TODO add quickcheck propeties for json roundtrips
      pv <- generate $
            suchThat genPv satisfiesRoundtripJSON
      jsonEncode fp (sizeOf pv, pv)

    jsonEncode :: FilePath -> (Int64, PactValue) -> IO ()
    jsonEncode fp = BL.writeFile fp . encode


-- | List of pact value pseudo-random generators and their descriptions
pactValuesDescAndGen :: [(String, Gen PactValue)]
pactValuesDescAndGen =
  genSomeLiteralPactValues seed <>
  genSomeGuardPactValues seed <>
  [ ("list", genSomeListPactValue seed)
  , ("object-map", genSomeObjectPactValue seed) ]

goldenPactValueDirectory :: String -> FilePath
goldenPactValueDirectory desc = goldenDirectory <> "/" <> testPrefix <> desc
  where goldenDirectory = "golden"
        testPrefix = "size-of-pactvalue-"

goldenPactValueFilePath :: String -> FilePath
goldenPactValueFilePath desc = (goldenPactValueDirectory desc) <> "/golden"


-- To run a generator in the repl:
-- `import Pact.Types.Pretty`
-- `import Data.Aeson (toJSON)`
-- `fmap (pretty . toJSON) (generate $ genSomeLiteralPactValue seed)`

-- | Generator of some psuedo-random Literal pact values
genSomeLiteralPactValues :: Int -> [(String, Gen PactValue)]
genSomeLiteralPactValues s =
  [ ("literal-string", f genLiteralString)
  , ("literal-integer", f genLiteralInteger)
  , ("literal-decimal", f genLiteralDecimal)
  , ("literal-bool", f genLiteralBool)
  , ("literal-time", f genLiteralTime) ]
  where f g = PLiteral <$> genWithSeed s g

-- | Generator of some psuedo-random List pact value
genSomeListPactValue :: Int -> Gen PactValue
genSomeListPactValue s = genWithSeed s $ PList <$> genPactValueList RecurseTwice

-- | Generator of some psuedo-random ObjectMap pact value
genSomeObjectPactValue :: Int -> Gen PactValue
genSomeObjectPactValue s = genWithSeed s $ PObject <$> genPactValueObjectMap RecurseTwice

-- | Generator of some psuedo-random Guard pact values
genSomeGuardPactValues :: Int -> [(String, Gen PactValue)]
genSomeGuardPactValues s =
  [ ("guard-pact", f $ GPact <$> arbitrary)
  , ("guard-keySet", f $ GKeySet <$> arbitrary)
  , ("guard-keySetRef", f $ GKeySetRef <$> arbitrary)
  , ("guard-module", f $ GModule <$> arbitrary)
  , ("guard-user", f $ genUserGuard RecurseTwice) ]
  where f g = PGuard <$> genWithSeed s g

-- | Generate arbitrary value with the provided "random" seed.
-- Allows for replicating arbitrary values.
genWithSeed :: Int -> Gen a -> Gen a
genWithSeed i (MkGen g) = MkGen (\_ n -> g (mkQCGen i) n)

-- | Random seed used to generate the pact values in the sizeOf golden tests
seed :: Int
seed = 10000000000
